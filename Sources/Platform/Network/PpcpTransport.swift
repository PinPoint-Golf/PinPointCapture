//  PpcpTransport.swift
//  PPCP transport on Network.framework: two (optionally three) independent
//  `NWConnection`s per peer link, each its own TLS session on the same `K_tls`.
//
//  ⚠ REQ-PORT-3. Every `NWConnection`, `NWListener`, `NWParameters` and
//  `sec_protocol_options_t` in the app lives in this file. What leaves it is
//  `ByteChannel`, `PeerTransport` and `NegotiatedSecurity` — CaptureCore types
//  with no platform inside them.
//
//  ⛔ THERE IS NO PLAINTEXT PATH IN THIS FILE AND THERE MUST NEVER BE ONE.
//  `RV` 5.2f: an implementation MUST NOT fall back to an unencrypted connection
//  under any circumstances, including a handshake failure, a timeout, or a user
//  instruction. A failed handshake is a failed connection. D9's conformance
//  harness needs plaintext loopback sockets for `ppcp-conform`; those belong to a
//  separate type in a `DEBUG`-only file, so that this one keeps no branch that
//  could ever be reached in a shipping build.
//
//  Spec: `CORE` §3 (T1–T5), §3.1; `ENC` §2; `RV` §5.2, §5.3, §5.4, §7.5, §7.7.
//  Decisions: plan A6 (two TCP connections per pair), A7 (TLS lives in the app).

import Foundation
import Network
import Security
import Synchronization
import CaptureCore

// MARK: - The TLS profile

/// How a PPCP connection is secured. One place, so `RV` §5 is read once.
enum PpcpTlsProfile {

    // ─────────────────────────────────────────────────────────────────────────
    //  RT-17 — "The peer offers **every** key-exchange mode and ciphersuite its
    //  platform exposes, and the offered set is derived from a platform
    //  capability query rather than from a constant." Read this block when the
    //  TLS setup path is touched and whenever the platform SDK is updated; that
    //  is what the row asks for, and this is the code it asks to be read.
    //
    //  Two things are asked of the platform here, and both are asked rather than
    //  assumed:
    //
    //  1. **The version ceiling.** `.TLSv13` is set as the MAXIMUM, never as a
    //     constant "use 1.2". The day iOS gains TLS 1.3 with an external PSK,
    //     this code negotiates it with no edit and property 2 of `RV` 5.2h comes
    //     back on its own — which is exactly what RT-17 means by "a platform that
    //     gains TLS 1.3 external PSK silently restores property 2 for an
    //     implementation that asks rather than assumes". The floor is TLS 1.2
    //     (`RV` 5.2a: nothing below it is ever negotiated).
    //
    //  2. **The suite set.** Every group `tls_ciphersuite_group_t` names is
    //     appended, and the set is **asked for at run time, not written down**.
    //     `tls_ciphersuite_group_t.init(rawValue:)` returns a value for exactly
    //     the groups this SDK declares and `nil` for everything else, so walking
    //     the raw values IS the capability query RT-17 asks for: an SDK that adds
    //     a group is offered that group with no edit in this file, and no group
    //     is named as a constant anywhere.
    //
    //  ⛔ AND IT CHANGES NOTHING ON THIS PLATFORM, WHICH IS THE POINT.
    //  `RV` §5.4.1 measured it and 5.4b1 confirmed it on an iPhone 16 on a
    //  release OS: iOS's ciphersuite enumeration **contains no PSK suite at all**,
    //  so the suite that actually negotiates — `0x00A8`,
    //  `TLS_PSK_WITH_AES_128_GCM_SHA256` — cannot be named through this
    //  interface. Neither `TLS_ECDHE_PSK_WITH_AES_128_GCM_SHA256` (RFC 8442) nor
    //  `TLS_ECDHE_PSK_WITH_AES_128_CBC_SHA256` (RFC 5489) can be requested; both
    //  requests are accepted by the API and **silently ignored**. TLS 1.3 with an
    //  external PSK fails outright.
    //
    //  So this peer cannot withhold a stronger mode even if it wanted to. That is
    //  compliance with `RV` 5.2b1 **by construction** rather than by assertion,
    //  which is precisely the case `RV` 5.2i describes and the reason RT-17 is a
    //  `review` row rather than a test. Compliance by construction and compliance
    //  by accident look identical from outside; the difference is that this block
    //  exists, and that it will start offering more the moment the platform does.
    //
    //  ⚠ Widening the offer cannot weaken *this* link. Neither end presents a
    //  certificate (`RV` 5.2e) and neither is configured with an identity, so no
    //  certificate-bearing suite in any of these groups can be selected however
    //  broad the offer is. Withholding a group would risk the opposite: silently
    //  dropping a PSK suite a future OS puts in one of them.
    // ─────────────────────────────────────────────────────────────────────────
    static var offeredCipherSuiteGroups: [tls_ciphersuite_group_t] {
        // ⚠ The bound is a loop guard, not a claim about the platform.
        // `tls_ciphersuite_group_t` is a `CF_ENUM(uint16_t)` whose members have
        // always been small and contiguous; the walk stops well past the last one
        // the SDK declares (5, `ats_fcp_v2_1`, new in iOS 26.5) so that adding a
        // group needs no edit here, and it stops at all so that a future enum with
        // sparse values cannot turn this into a 65,536-iteration loop on every
        // connection.
        (UInt16(0)..<UInt16(64)).compactMap(tls_ciphersuite_group_t.init(rawValue:))
    }

    /// The TLS options for one connection.
    ///
    /// - Parameters:
    ///   - tlsKey: `K_tls` (`RV` 5.1a). 32 bytes, used for TLS and nothing else.
    ///   - identity: the 17-octet PSK identity of `RV` 5.3a.
    ///   - isListener: the listener is the TLS server (`RV` 5.2g).
    static func tlsOptions(tlsKey: Data, identity: Data, isListener: Bool) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions

        // ⛔ `RV` 5.3f — the identity is 17 raw octets and generally not valid
        // UTF-8. It is handed to the platform as bytes: no transcoding, no
        // `String(data:encoding:)`, no truncation. `RV` 5.4b2 measured the §10.2
        // identity completing a handshake at TLS 1.2 unchanged on the device.
        let key = tlsKey.withUnsafeBytes { DispatchData(bytes: $0) }
        let psk = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, key as __DispatchData, psk as __DispatchData)

        // `RV` 5.2a. Floor 1.2, ceiling 1.3 — see the RT-17 block above.
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)
        for group in offeredCipherSuiteGroups {
            sec_protocol_options_append_tls_ciphersuite_group(sec, group)
        }

        // `RV` 5.2e — certificates are not part of this model, and a peer MUST NOT
        // reject a counterpart for presenting none. Authentication comes from the
        // PSK, mutually and in both directions. ⚠ This is not "verification off":
        // there is nothing to verify, and leaving the default on makes the client
        // fail a handshake that the specification requires it to complete.
        sec_protocol_options_set_peer_authentication_required(sec, false)

        // ⛔ `RV` 7.5d — no application data on an early-data path. TLS 1.3 early
        // data is replayable by design, and a resumed connection that accepted
        // `arm` as early data would accept a replay of it. Network.framework
        // exposes no 0-RTT switch to turn off, so the guarantee is made twice:
        // here, by refusing false start (which would release application data
        // before the peer's Finished is verified), and in `PpcpByteChannel`,
        // which refuses to carry a byte until the connection is `.ready`.
        sec_protocol_options_set_tls_false_start_enabled(sec, false)

        // TLS 1.2 renegotiation has no use here and is a live attack surface on
        // the plain-PSK leg the platform forces us onto (`RV` §5.4.3).
        sec_protocol_options_set_tls_renegotiation_enabled(sec, false)

        if isListener {
            // `RV` 5.2h property 3, and RT-14's tail: "**Where TLS 1.2 is
            // negotiated, the server sends an *empty* `psk_identity_hint`**" — an
            // obligation that exists only on the newly-permitted path, which is
            // the path this implementation now always takes. Set explicitly to
            // zero length rather than left unset: `RV` 5.2i lists "whether an
            // omitted hint is sent empty or omitted entirely" as something the
            // platform may not expose, and saying it out loud is the one part of
            // that we can control.
            sec_protocol_options_set_tls_pre_shared_key_identity_hint(sec, DispatchData.empty as __DispatchData)
        }

        return options
    }

    /// Parameters for one channel: TLS as above, over TCP.
    static func parameters(tlsKey: Data, identity: Data, isListener: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // `CORE` §3.1 — a shot event must arrive immediately. Nagle coalescing
        // buys nothing when whole `ENC` §3 frames are written in one go, and
        // costs up to a round trip on the control channel where it matters most.
        tcp.noDelay = true
        // ⚠ Long-lived and mostly idle between shots; without this a NAT or a
        // sleeping radio drops the link silently and the first symptom is a
        // missed heartbeat (`CORE` 8.3g) rather than a closed socket.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10

        let parameters = NWParameters(tls: tlsOptions(tlsKey: tlsKey,
                                                      identity: identity,
                                                      isListener: isListener),
                                      tcp: tcp)
        // ⚠ `RV` §8 — "peer-to-peer radios share the antenna". AWDL and
        // infrastructure WiFi degrade each other, and the infrastructure path is
        // the one the pairing code's endpoints are on. Prefer one, explicitly.
        parameters.includePeerToPeer = false
        return parameters
    }

    /// `RV` 5.4k — read back what was actually negotiated.
    ///
    /// ⚠ Read once, on `.ready`, and carried as a value from there on. Asking the
    /// connection later is asking a connection that may already have failed.
    static func negotiated(from connection: NWConnection) -> NegotiatedSecurity? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition)
                as? NWProtocolTLS.Metadata else { return nil }
        let sec = metadata.securityProtocolMetadata
        let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(sec)
        let suite = sec_protocol_metadata_get_negotiated_tls_ciphersuite(sec)
        return NegotiatedSecurity(versionCode: version.rawValue, cipherSuite: suite.rawValue)
    }
}

/// ⚠ A continuation may only be resumed once, and Network.framework's state
/// handler fires many times. `claim()` returns `true` exactly once per mutex, so
/// "resume if nobody has" is one call rather than a pattern each call site
/// reinvents — the version this replaced got it subtly wrong.
private extension Mutex<Bool> {
    func claim() -> Bool {
        withLock { taken in
            if taken { return false }
            taken = true
            return true
        }
    }
}

// MARK: - A channel

/// One `NWConnection` presented as a `ByteChannel`.
///
/// ⚠ `@unchecked Sendable` deliberately: `NWConnection` is safe to call from any
/// thread and delivers its callbacks on the queue it was started with, and every
/// mutable field here is behind `state`.
final class PpcpByteChannel: ByteChannel, @unchecked Sendable {

    private struct State {
        var handshakeComplete = false
        var closeReason: ChannelCloseReason?
    }

    let channel: PpcpChannel
    private let connection: NWConnection
    private let state = Mutex(State())

    init(connection: NWConnection, channel: PpcpChannel) {
        self.connection = connection
        self.channel = channel
    }

    /// Re-label an open stream once its first frame has said which channel it
    /// carries.
    ///
    /// ⚠ `ENC` 2.1b is the reason this exists: a **listener** does not know a
    /// stream's channel until the frame header of its `link_bind` tells it, and
    /// is forbidden from inferring it from arrival order or transport address. So
    /// the stream is opened under a placeholder and re-labelled here, with the
    /// handshake state carried across — the TLS session is the connection's, not
    /// this wrapper's, and the old wrapper is dropped on the spot.
    func adopting(_ channel: PpcpChannel) -> PpcpByteChannel {
        let relabelled = PpcpByteChannel(connection: connection, channel: channel)
        if state.withLock({ $0.handshakeComplete }) { relabelled.markHandshakeComplete() }
        return relabelled
    }

    /// ⛔ `RV` 1.3c / 7.7a — nothing crosses before the handshake completes.
    /// `hello` is the first byte of application data on an established,
    /// authenticated connection, and this is the gate that makes that true even
    /// if a caller gets hold of a channel early.
    private func requireReady() throws {
        try state.withLock { state in
            if let reason = state.closeReason { throw TransportError.channelClosed(reason) }
            guard state.handshakeComplete else {
                throw TransportError.applicationDataBeforeHandshake
            }
        }
    }

    func markHandshakeComplete() {
        state.withLock { $0.handshakeComplete = true }
    }

    func send(_ bytes: Data) async throws {
        try requireReady()
        // ⚠ This await IS the backpressure (`CORE` T2 per-channel flow control):
        // `.contentProcessed` fires when the transport has taken the bytes, so a
        // bulk sender outrunning the link is throttled here rather than in an
        // unbounded queue of its own.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: TransportError.channelClosed(.failed(Self.describe(error))))
                    } else {
                        continuation.resume()
                    }
                })
            }
        } onCancel: {
            // ⛔ **Cancelling the task cancels the connection, and there is no
            // gentler option.** Network.framework has no per-call cancel: a
            // `send` or `receive` in flight is abandoned only by tearing the
            // connection down. Without this the continuation is never resumed,
            // so the task ignores cancellation entirely — and a structured
            // timeout around it cannot expire, because a task group waits for
            // every child before it returns. That is not a slow timeout; it is
            // no timeout at all.
            connection.cancel()
        }
    }

    func receive() async throws -> Data? {
        try requireReady()
        while true {
            typealias Arrival = CheckedContinuation<(Data?, Bool), any Error>
            let arrival = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: Arrival) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                        if let error {
                            continuation.resume(throwing: TransportError.channelClosed(.failed(Self.describe(error))))
                        } else {
                            continuation.resume(returning: (data, isComplete))
                        }
                    }
                }
            } onCancel: {
                // See `send`. A parked `receive` is the common case — a listener
                // waiting for a `link_bind` that never comes — and it is exactly
                // what `withDeadline` below claims to bound.
                connection.cancel()
            }
            if let data = arrival.0, data.isEmpty == false { return data }
            if arrival.1 {
                state.withLock { if $0.closeReason == nil { $0.closeReason = .peerClosed } }
                return nil
            }
            // Neither bytes nor an end: keep waiting. `CORE` T3 puts message
            // boundaries in the `ENC` §3 framing, not here, so a short read is
            // never an error.
        }
    }

    func close(_ reason: ChannelCloseReason) async {
        state.withLock { if $0.closeReason == nil { $0.closeReason = reason } }
        connection.cancel()
    }

    /// ⛔ `RV` 7.2b — a diagnostic string, so no key material and no payload. An
    /// `NWError` carries neither, but the rule is stated where the string is made.
    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code): "posix \(code.rawValue)"
        case .dns(let code): "dns \(code)"
        case .tls(let status): "tls \(status)"
        // ⚠ `default`, not `@unknown default`: this is a diagnostic string and a
        // transport error nobody has heard of is still just a string. The one
        // place an unhandled `NWError` case would matter is a decision, and no
        // decision in this file is taken from one.
        default: "unknown"
        }
    }

    // MARK: Bringing one up

    /// Dial or adopt a connection and return only once TLS has completed.
    ///
    /// ⛔ `RV` 5.2f — every failure path here throws. There is no return value
    /// that means "connected without TLS", which is how the no-fallback rule is
    /// held by the shape rather than by a reviewer noticing.
    static func open(_ connection: NWConnection,
                     channel: PpcpChannel,
                     on queue: DispatchQueue) async throws -> (PpcpByteChannel, NegotiatedSecurity) {
        let resumed = Mutex(false)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.stateUpdateHandler = { state in
                    // ⚠ Decide the outcome first, claim the continuation second. A
                    // connection reports `.preparing` before `.ready` and may report
                    // more than one terminal state on the way down, so claiming on
                    // every callback and then undoing it is how a double resume —
                    // which traps — gets written by accident.
                    let outcome: Result<Void, any Error>?
                    switch state {
                    case .ready:
                        outcome = .success(())
                    case .failed(let error):
                        outcome = .failure(TransportError.handshakeFailed(describe(error)))
                    case .waiting(let error):
                        // ⚠ Fail rather than let Network.framework retry. `RV` 4.3
                        // has the scanner walk the endpoints of a pairing code **in
                        // order**, so a refused or unreachable address must fail fast
                        // enough for the next one to be tried while the user is still
                        // holding the phone up.
                        outcome = .failure(TransportError.endpointUnreachable(describe(error)))
                    case .cancelled:
                        outcome = .failure(TransportError.channelClosed(.cancelled))
                    case .setup, .preparing:
                        outcome = nil
                    @unknown default:
                        outcome = nil
                    }
                    guard let outcome, resumed.claim() else { return }
                    continuation.resume(with: outcome)
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            // `.cancelled` comes back through the state handler above and
            // resumes the continuation, so cancelling the task really does end
            // the wait rather than merely asking it to.
            connection.cancel()
        }

        guard let security = PpcpTlsProfile.negotiated(from: connection) else {
            // ⛔ A ready connection with no TLS metadata is a connection that is
            // not encrypted. 5.2f: refuse it, do not use it.
            connection.cancel()
            throw TransportError.handshakeFailed("no TLS metadata on a ready connection")
        }

        let wrapped = PpcpByteChannel(connection: connection, channel: channel)
        wrapped.markHandshakeComplete()
        return (wrapped, security)
    }
}

// MARK: - Minting a link_id

/// `ENC` 2.1a — "16 bytes from a cryptographically secure random number
/// generator, fresh per link", minted by the **dialler**.
///
/// ⚠ In the platform layer, and from `SecRandomCopyBytes`, for the same reason
/// `RV` §5's `rn2` is: Core owns no entropy source, and the CSPRNG a security
/// property rests on should be the platform's audited one rather than whatever a
/// portable abstraction happens to wrap. ⛔ A failure is thrown, never
/// substituted — there is no fallback path to a weaker source, which is the same
/// shape as `RV` 5.2f's refusal to fall back to plaintext.
enum PpcpLinkIdSource {
    static func mint() throws -> PpcpLinkId {
        var bytes = [UInt8](repeating: 0, count: PpcpLinkId.byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw TransportError.failedToMintLinkId(Int(status))
        }
        return try PpcpLinkId(bytes: Data(bytes))
    }
}

// MARK: - A link

/// Two channels, three where preview is carried, each a separate TLS session on
/// the same `K_tls` (plan A6; `CORE` §3.1's acceptable table, first row) and
/// each carrying `link_bind` as its first frame (`ENC` 2.1a).
///
/// ⚠ `preview` is mutable and the other two are not, which is `ENC` 2.1d in the
/// type: "a bulk channel MAY be opened at any later point in the session — a
/// `preview` channel after the session is established is the expected case."
/// Channel 0 and channel 1 are what a link is; channel 2 is what it may grow.
final class PpcpPeerLink: PeerTransport, @unchecked Sendable {

    let control: any ByteChannel
    let bulk: any ByteChannel
    let security: NegotiatedSecurity

    /// The dialler's own `link_id`, kept so a later stream can name the same link
    /// (2.1d). ⛔ 2.1f — never persisted and never reused across links; it dies
    /// with this object.
    private let linkId: PpcpLinkId
    private let later = Mutex(LaterChannels())

    /// How a further stream is obtained: by dialling one (the dialler) or by
    /// waiting for the counterpart to bind one (the listener). Exactly one of
    /// these is set, and which one is what makes this link a `DiallingPeerLink`
    /// or a `ListeningPeerLink`.
    private let dial: (@Sendable (PpcpChannel) async throws -> PpcpByteChannel)?

    /// One suspended `channelBound` call.
    ///
    /// ⚠ **A box rather than a bare continuation, so a cancelled waiter can be
    /// taken back out.** A continuation is not `Equatable` and cannot be found in
    /// an array; without an identity to remove, a caller that gives up waiting
    /// for a `preview` leaves its continuation parked here for the life of the
    /// link. ⛔ Every field is touched only inside `later.withLock`, which is what
    /// `@unchecked Sendable` rests on.
    private final class ChannelWaiter: @unchecked Sendable {
        var continuation: CheckedContinuation<any ByteChannel, any Error>?
        var cancelled = false
    }

    private struct LaterChannels {
        var channels: [PpcpChannel: any ByteChannel] = [:]
        var waiters: [PpcpChannel: [ChannelWaiter]] = [:]
        var closed: ChannelCloseReason?
    }

    init(linkId: PpcpLinkId,
         control: any ByteChannel,
         bulk: any ByteChannel,
         security: NegotiatedSecurity,
         dial: (@Sendable (PpcpChannel) async throws -> PpcpByteChannel)?) {
        self.linkId = linkId
        self.control = control
        self.bulk = bulk
        self.security = security
        self.dial = dial
    }

    /// Assemble from a channel map, as both sides do once every required channel
    /// has bound. `CORE` T2: a link with only channel 0 is not a PPCP transport.
    static func assemble(linkId: PpcpLinkId,
                         channels: [PpcpChannel: any ByteChannel],
                         security: NegotiatedSecurity,
                         dial: (@Sendable (PpcpChannel) async throws -> PpcpByteChannel)?)
        throws -> PpcpPeerLink {
        guard let control = channels[.control] else {
            throw TransportError.incompleteLink(missing: .control)
        }
        guard let bulk = channels[.bulk] else {
            throw TransportError.incompleteLink(missing: .bulk)
        }
        let link = PpcpPeerLink(linkId: linkId, control: control, bulk: bulk,
                                security: security, dial: dial)
        for (channel, stream) in channels where channel != .control && channel != .bulk {
            link.attach(stream, as: channel)
        }
        return link
    }

    var preview: (any ByteChannel)? { later.withLock { $0.channels[.preview] } }

    /// Called by the listener when a further stream binds into this link (2.1d),
    /// and by `openChannel` when the dialler opens one.
    func attach(_ stream: any ByteChannel, as channel: PpcpChannel) {
        let waiting = later.withLock { state -> [ChannelWaiter] in
            state.channels[channel] = stream
            return state.waiters.removeValue(forKey: channel) ?? []
        }
        for waiter in waiting {
            let continuation = waiter.continuation
            waiter.continuation = nil
            continuation?.resume(returning: stream)
        }
    }

    func close(_ reason: ChannelCloseReason) async {
        let (extra, waiting) = later.withLock { state -> ([any ByteChannel], [ChannelWaiter]) in
            state.closed = reason
            let channels = Array(state.channels.values)
            let waiters = state.waiters.values.flatMap { $0 }
            state.channels.removeAll()
            state.waiters.removeAll()
            return (channels, waiters)
        }
        // ⚠ Waiters are failed rather than left suspended. A session that closes
        // while a `preview` was being negotiated is the ordinary case, and a task
        // parked forever on a dead link is the kind of leak that only shows up as
        // a battery complaint.
        for waiter in waiting {
            let continuation = waiter.continuation
            waiter.continuation = nil
            continuation?.resume(throwing: TransportError.channelClosed(reason))
        }
        await control.close(reason)
        await bulk.close(reason)
        for channel in extra { await channel.close(reason) }
    }
}

extension PpcpPeerLink: DiallingPeerLink {
    /// `ENC` 2.1d — a further stream carrying `link_bind` with the **same**
    /// `link_id`. ⛔ Not a new one: a new `link_id` would be a new link, and the
    /// listener would treat this stream as a stranger's first connection.
    func openChannel(_ channel: PpcpChannel) async throws -> any ByteChannel {
        if let existing = later.withLock({ $0.channels[channel] }) { return existing }
        if channel == .control { return control }
        if channel == .bulk { return bulk }
        guard let dial else { throw TransportError.channelUnavailable(channel) }
        if let reason = later.withLock({ $0.closed }) {
            throw TransportError.channelClosed(reason)
        }

        let stream = try await dial(channel)
        try await stream.send(PpcpLinkBind.frame(linkId: linkId, channel: channel))
        attach(stream, as: channel)
        return stream
    }
}

extension PpcpPeerLink: ListeningPeerLink {
    /// ⚠ **Cancellable, and it has to be.** 2.1d makes a `preview` channel
    /// something the counterpart *may* open, so waiting for one that never comes
    /// is the ordinary case, not the exception — a caller that gives up (the user
    /// leaves the screen, an enclosing timeout expires) must actually leave. The
    /// `cancelled` flag inside the lock closes the race where cancellation
    /// arrives before the continuation has been installed.
    func channelBound(_ channel: PpcpChannel) async throws -> any ByteChannel {
        if channel == .control { return control }
        if channel == .bulk { return bulk }
        let waiter = ChannelWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate = later.withLock { state -> Result<any ByteChannel, any Error>? in
                    if let existing = state.channels[channel] { return .success(existing) }
                    if let reason = state.closed {
                        return .failure(TransportError.channelClosed(reason))
                    }
                    if waiter.cancelled { return .failure(CancellationError()) }
                    waiter.continuation = continuation
                    state.waiters[channel, default: []].append(waiter)
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let continuation = later.withLock { state -> CheckedContinuation<any ByteChannel, any Error>? in
                waiter.cancelled = true
                guard var list = state.waiters[channel],
                      let index = list.firstIndex(where: { $0 === waiter }) else { return nil }
                list.remove(at: index)
                state.waiters[channel] = list.isEmpty ? nil : list
                let continuation = waiter.continuation
                waiter.continuation = nil
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

// MARK: - Dialling

/// The scanner dials (`RV` 2d), and the dialler is the TLS client (`RV` 5.2g).
/// On the pairing-code path that is this device.
struct PpcpConnector: PeerTransportConnector {

    private let queue = DispatchQueue(label: "org.pinpointstudio.capture.ppcp.connector")

    func connect(to endpoint: PeerEndpoint,
                 credentials: any PpcpCredentials,
                 channels: [PpcpChannel] = PpcpChannel.required) async throws -> any PeerTransport {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw TransportError.endpointUnreachable("port \(endpoint.port)")
        }
        // `RV` 4.3 hands over a host and a port as written in the code, so this
        // is the one place that turns them into an endpoint. Everything below
        // dials an `NWEndpoint` and does not care where it came from.
        return try await connect(to: .hostPort(host: NWEndpoint.Host(endpoint.host),
                                               port: port),
                                 credentials: credentials, channels: channels)
    }

    /// The same dial, from an endpoint the platform produced rather than one a
    /// pairing code spelled out.
    ///
    /// ⛔ **This exists for `RV` §3's reconnection path and `.service` is the
    /// point of it.** An `NWBrowser` result is a *name*, not an address; handing
    /// that endpoint straight to `NWConnection` keeps the resolution the browser
    /// established, walks every address the host publishes, and preserves the
    /// interface scope a link-local address needs. Flattening it to a host string
    /// and a port would throw all three away and re-resolve a name that 3.4a
    /// rotates out from under it — see `PpcpBrowser.Found.endpoint`.
    ///
    /// ⚠ Nothing else differs. The same `link_id`, the same concurrent channels,
    /// the same `RendezvousCredentials`: §5 does not know which of §3 or §4 found
    /// the counterpart, and 11.1a is the clause that insists it must not.
    func connect(to endpoint: NWEndpoint,
                 credentials: any PpcpCredentials,
                 channels: [PpcpChannel] = PpcpChannel.required) async throws -> any PeerTransport {

        // `ENC` 2.1a — one `link_id` for the whole link, minted here because the
        // dialler mints it, and used unchanged on every stream including the ones
        // 2.1d lets us open later.
        let linkId = try PpcpLinkIdSource.mint()
        let dial = Self.dialler(endpoint: endpoint, credentials: credentials, queue: queue)

        // ⚠ **Concurrent, and E1 is what allowed it.** S1 dialled sequentially
        // because the listener assembled a link from arrival order and a
        // concurrent dial would have scrambled it. `link_bind` names the channel
        // in the first frame, so the streams may race — 2.1d says so explicitly —
        // and the user gets the link in one handshake's time instead of two or
        // three, while standing at a tripod holding a phone up.
        //
        // ⚠ The cost 2.1's commentary does not mention: a wrong `K_tls` now costs
        // every handshake rather than one. That is the right trade here, because
        // a wrong key on the pairing-code path means a mistyped or stale code,
        // which fails in well under a second either way.
        var opened: [PpcpChannel: PpcpByteChannel] = [:]
        var negotiated: NegotiatedSecurity?
        do {
            let results = try await withThrowingTaskGroup(
                of: (PpcpChannel, PpcpByteChannel, NegotiatedSecurity).self
            ) { group in
                for channel in channels {
                    group.addTask {
                        let (stream, security) = try await dial(channel)
                        // 2.1a — **the first frame on every stream**, before
                        // `hello` on channel 0 (2.1d) and before any payload
                        // frame on a bulk one.
                        try await stream.send(PpcpLinkBind.frame(linkId: linkId,
                                                                 channel: channel))
                        return (channel, stream, security)
                    }
                }
                var collected: [(PpcpChannel, PpcpByteChannel, NegotiatedSecurity)] = []
                for try await result in group { collected.append(result) }
                return collected
            }
            for (channel, stream, security) in results {
                opened[channel] = stream
                negotiated = negotiated ?? security
            }
        } catch {
            for channel in opened.values { await channel.close(.cancelled) }
            throw error
        }

        guard let negotiated else { throw TransportError.incompleteLink(missing: .control) }
        return try PpcpPeerLink.assemble(linkId: linkId, channels: opened,
                                         security: negotiated,
                                         dial: { channel in try await dial(channel).0 })
    }

    /// One dial, reusable: the task group uses it, and so does `openChannel` for
    /// a `preview` stream opened after the session is established (2.1d).
    private static func dialler(endpoint: NWEndpoint,
                                credentials: any PpcpCredentials,
                                queue: DispatchQueue)
        -> @Sendable (PpcpChannel) async throws -> (PpcpByteChannel, NegotiatedSecurity) {
        { channel in
            // `RV` 5.3a — fresh per connection. Each stream gets its own `rn2`,
            // so an observer watching the `ClientHello`s cannot tell they belong
            // together. ⚠ And `link_id` does not undo that: it travels **inside**
            // TLS (2.1f), which is the whole reason it can be a stable name.
            let identity = try credentials.nextPskIdentity()
            let parameters = PpcpTlsProfile.parameters(tlsKey: credentials.tlsKey,
                                                       identity: identity,
                                                       isListener: false)
            let connection = NWConnection(to: endpoint, using: parameters)
            return try await PpcpByteChannel.open(connection, channel: channel, on: queue)
        }
    }
}

// MARK: - Listening

/// The listening half, for the discovery path — where the **advertiser** listens
/// and the browser dials, the opposite way round to the pairing-code path
/// (`RV` §2, 3.5b).
///
/// ⚠ **Rewritten for erratum E1, and the rewrite deleted what S1 shipped.** This
/// listener used to take channels in *arrival order*, on the reasoning that the
/// connector dialled them one at a time. `ENC` §2.1's commentary names that as
/// one of the two implicit rules the erratum withdraws, and it is right to: the
/// rule holds only against a dialler that serialises, breaks the moment two peers
/// connect at once, cannot accept the later `preview` stream of 2.1d, and has
/// nothing to work with at all on the `direct` path where there is no TLS
/// identity. It is now `link_bind`, and arrival order is not consulted anywhere.
///
/// ⛔ **A measured finding, recorded where an implementer will hit it, and NOT
/// worked around.** `RV` 5.3a makes the PSK identity fresh per connection and
/// 5.3b requires a server to resolve an offered identity by recomputing its tag
/// with the `K_id` of every pairing it holds. **Network.framework can do neither
/// on the server side.**
///
/// The only server-side entry point is `add_pre_shared_key`, which registers a
/// (key, identity) pair up front;
/// `sec_protocol_options_set_pre_shared_key_selection_block` is documented as
/// being "invoked when *the client* must choose a PSK identity given a hint from
/// its peer" and has no server-side counterpart. `Tests/TransportLoopbackTests`
/// measures what follows: a client offering an identity the listener did not
/// register is refused with `PSK_IDENTITY_NOT_FOUND`, alert 115
/// (`unknown_psk_identity`).
///
/// Two consequences, both reported with D1 rather than papered over:
///
/// 1. This listener can only accept the identity it registered. A rotating
///    identity — which is every conformant client — cannot reach it, so the
///    discovery path of `RV` §3 is not implementable on the device side as §5.3
///    is written. That is awkward precisely because 3.5b recommends the **capture
///    peer advertise**, making this device the listener on that path.
/// 2. `RV` 5.3c ("the same alert it would send for a resolved identity and a
///    wrong key") is unachievable here: a wrong key fails at Finished with
///    `bad_record_mac`, alert 20, and an unresolvable identity fails earlier with
///    alert 115. Different content, different timing, no interface to change it.
///    ⚠ Narrower than it looks, and the tests say why: `K_tls` and `K_id` come
///    from the same `PRK` (`RV` §5.1), so no scanned code and no persisted
///    pairing can produce a counterpart whose identity resolves and whose key
///    then fails. The gap is real in the API and unreachable through the
///    protocol's own key schedule.
///
/// The connector is unaffected: as the TLS client it rotates `rn2` per connection
/// exactly as 5.3a requires, and the pairing-code path — the one `RV` 2a makes
/// REQUIRED — dials rather than listens.
actor PpcpListener: PeerTransportListener {

    /// ⚠ `NWConnection` is not `Sendable`, and it has to cross from the
    /// listener's dispatch queue into this actor. It is safe to call from any
    /// thread; the box says so once instead of scattering `@unchecked`.
    private struct ConnectionBox: @unchecked Sendable {
        let connection: NWConnection
    }

    /// A link the listener is still assembling: some streams have bound, channel
    /// 0 may or may not be among them, and 2.1c's timeout is counting.
    private struct PendingLink {
        var linkId: PpcpLinkId
        var channels: [PpcpChannel: any ByteChannel] = [:]
        var security: NegotiatedSecurity?
        var deadline: Task<Void, Never>?
    }

    private let credentials: any PpcpCredentials
    private let required: [PpcpChannel]
    private let requestedPort: UInt16
    private let queue = DispatchQueue(label: "org.pinpointstudio.capture.ppcp.listener")

    /// `ENC` 2.1c — "a link that has not bound channel 0 within the listener's own
    /// timeout is discarded with every stream it holds; **the timeout is the
    /// embedding's policy**."
    ///
    /// ⚠ Five seconds, and it covers rather more than 2.1c asks. 2.1c names only
    /// the channel-0 case; this listener applies the same deadline to *completing
    /// the required channel set*, because a link holding channel 0 and no bulk is
    /// equally unusable — `CORE` T2 makes two independently flow-controlled
    /// channels the definition of a PPCP transport, not a preference. The same
    /// deadline also bounds an accepted connection that completes TLS and then
    /// says nothing, which is otherwise an unbounded resource a stranger controls.
    let bindTimeout: Duration

    private var listener: NWListener?
    /// ⛔ **The link table is `libppcp`'s — F-D3-3 closed.** This listener used to
    /// keep its own, because `ppcp_link_binder_offer` took a `stream_channel` a
    /// stream-per-connection transport has no way to supply: a freshly accepted
    /// `NWConnection` carries no channel of its own, and 2.1b forbids inferring one
    /// from arrival order or from the transport address. L9 changed the signature
    /// to take the channel **from the frame header** and report it, so the three
    /// refusals of 2.1c now live in one place for both applications instead of two
    /// places that had already chosen different implicit rules.
    private let binder = PpcpLinkBinder()
    /// Keyed on the **library's** link index, which is what `offer` reports.
    private var pending: [Int: PendingLink] = [:]
    private var live: [Int: PpcpPeerLink] = [:]
    private var completed: [PpcpPeerLink] = []
    /// One suspended `accept()`.
    ///
    /// ⚠ Same reason as `PpcpPeerLink.ChannelWaiter`: a continuation has no
    /// identity, so without a box a cancelled `accept()` cannot be taken out of
    /// the queue. ⛔ Every field is touched only on this actor.
    private final class AcceptWaiter: @unchecked Sendable {
        var continuation: CheckedContinuation<PpcpPeerLink?, Never>?
        var cancelled = false
    }

    private var waiters: [AcceptWaiter] = []
    private var stopped = false

    /// ⛔ **Loopback only, for the wired path** — see `WiredPresenceListener`.
    /// The default is the all-interfaces bind every other caller wants; on a
    /// cable the only reader is the usbmux daemon on this device, and a
    /// LAN-reachable PPCP listener there would pull in the local-network
    /// permission for nothing and advertise a pairing this device is not
    /// advertising (`RV` 3.5d).
    private let loopbackOnly: Bool

    /// The identity `start()` registered with the platform.
    ///
    /// ⛔ **The wired path cannot work without reading this back.** The listener
    /// accepts exactly the one identity it registered (the finding above), so on
    /// a direct path the device has to *publish* it and the host has to offer it
    /// back verbatim (`RV` 5.3b, run client-side — design §5.2). ⚠ 17 raw octets,
    /// generally not valid UTF-8: 5.3f forbids transcoding, text validation and
    /// truncation anywhere on the way out.
    private var registered: Data?

    init(credentials: any PpcpCredentials,
         channels: [PpcpChannel] = PpcpChannel.required,
         port: UInt16 = 0,
         bindTimeout: Duration = .seconds(5),
         loopbackOnly: Bool = false) {
        self.credentials = credentials
        self.required = channels
        self.requestedPort = port
        self.bindTimeout = bindTimeout
        self.loopbackOnly = loopbackOnly
    }

    /// `nil` before `start()`. See `registered`.
    func registeredIdentity() -> Data? { registered }

    func start() async throws -> UInt16 {
        // ⚠ One listener, one port, N connections. The channels of a link differ
        // by which stream they are, not by where they land — a second port would
        // be a second thing for a pairing code to carry and a second thing for a
        // firewall to block.
        //
        // ⛔ **And exactly one identity, drawn here, for the life of this
        // listener session.** `RV` 5.3a says fresh per *connection*; the platform
        // gives a server no way to honour that (it registers one (key, identity)
        // pair up front), so on the direct path of design §5.5 this is a
        // per-listener-session draw with an erratum proposed. Do not "fix" it by
        // re-drawing per connection — there is no interface to draw into.
        let identity = try credentials.nextPskIdentity()
        registered = identity
        let parameters = PpcpTlsProfile.parameters(tlsKey: credentials.tlsKey,
                                                   identity: identity,
                                                   isListener: true)
        if loopbackOnly {
            // ⛔ `requiredLocalEndpoint`, which is what pins the *local* address
            // of the bind — not `NWListener(using:on:)`, which fixes only the
            // port and leaves the address `0.0.0.0`.
            parameters.requiredLocalEndpoint =
                .hostPort(host: .ipv4(.loopback),
                          port: requestedPort == 0
                              ? .any
                              : (NWEndpoint.Port(rawValue: requestedPort) ?? .any))
        }
        let listener: NWListener
        if requestedPort == 0 || loopbackOnly {
            // ⚠ With `requiredLocalEndpoint` set, the port comes from it; passing
            // `on:` as well would be two sources for one number.
            listener = try NWListener(using: parameters)
        } else {
            guard let port = NWEndpoint.Port(rawValue: requestedPort) else {
                throw TransportError.listenerFailed("port \(requestedPort)")
            }
            listener = try NWListener(using: parameters, on: port)
        }
        self.listener = listener

        // ⚠ Each connection is taken into its own Task rather than pulled from a
        // queue by `accept()`. That is E1's doing too: with `link_bind`, the
        // streams of one link may arrive concurrently and interleaved with
        // another peer's, so a serial intake would head-of-line block the whole
        // listener behind one slow handshake — and a stranger who connects and
        // then says nothing would block it indefinitely.
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let box = ConnectionBox(connection: connection)
            Task { await self.take(box) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let outcome: Result<UInt16, any Error>?
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        outcome = .success(port)
                    } else {
                        outcome = .failure(TransportError.listenerFailed("no bound port"))
                    }
                case .failed(let error):
                    outcome = .failure(TransportError.listenerFailed(PpcpByteChannel.describe(error)))
                case .cancelled:
                    outcome = .failure(TransportError.listenerFailed("cancelled"))
                default:
                    outcome = nil
                }
                guard let outcome, resumed.claim() else { return }
                continuation.resume(with: outcome)
            }
            listener.start(queue: queue)
        }
    }

    /// Await one complete link: every required channel bound, `link_bind` seen
    /// and accepted on each.
    /// ⛔ **Cancellable, and this was the defect that hung the test suite.**
    /// `accept()` resumes when a link assembles or when `stop()` is called, and
    /// 2.1c means a stream the listener *refuses* produces neither — which is
    /// correct behaviour, and left the waiter parked forever. A caller that gave
    /// up (an enclosing timeout, a user leaving the connect screen) could not
    /// leave: `Task.cancel()` reached a continuation that ignored it, and a
    /// structured timeout around it could never expire, because a task group does
    /// not return until every child has finished.
    ///
    /// ⚠ The `cancelled` flag closes the race where cancellation arrives before
    /// the continuation is installed — `withTaskCancellationHandler` runs
    /// `onCancel` immediately for an already-cancelled task, which is *before*
    /// the operation body has run.
    func accept() async throws -> any PeerTransport {
        if completed.isEmpty == false { return completed.removeFirst() }
        guard stopped == false else {
            throw TransportError.listenerFailed("stopped while awaiting a link")
        }
        let waiter = AcceptWaiter()
        let link = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PpcpPeerLink?, Never>) in
                if waiter.cancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiter.continuation = continuation
                    waiters.append(waiter)
                }
            }
        } onCancel: {
            Task { await self.withdraw(waiter) }
        }
        guard let link else {
            if waiter.cancelled { throw CancellationError() }
            throw TransportError.listenerFailed("stopped while awaiting a link")
        }
        return link
    }

    /// Take a cancelled `accept()` back out of the queue and let it go.
    private func withdraw(_ waiter: AcceptWaiter) {
        waiter.cancelled = true
        guard let index = waiters.firstIndex(where: { $0 === waiter }) else { return }
        waiters.remove(at: index)
        let continuation = waiter.continuation
        waiter.continuation = nil
        continuation?.resume(returning: nil)
    }

    func stop() async {
        stopped = true
        listener?.cancel()
        listener = nil

        for waiter in waiters {
            let continuation = waiter.continuation
            waiter.continuation = nil
            continuation?.resume(returning: nil)
        }
        waiters.removeAll()
        for (_, link) in pending {
            link.deadline?.cancel()
            for channel in link.channels.values { await channel.close(.cancelled) }
        }
        pending.removeAll()
        for link in completed { await link.close(.cancelled) }
        completed.removeAll()
        live.removeAll()
    }

    // MARK: One connection, from accept to bind

    /// Complete TLS, read the stream's first frame, and bind it (2.1a–c).
    ///
    /// ⛔ Every refusal ends in `connection.cancel()`. 2.1c gives a listener one
    /// action for a stream it will not bind — close it — and there is no response
    /// to send: `MSG` 3.0c says `link_bind` "requires no response: a listener that
    /// accepts the binding does nothing, and one that refuses it closes the
    /// stream". A refused stream also has no session to carry an `error` on.
    private func take(_ box: ConnectionBox) async {
        guard stopped == false else { box.connection.cancel(); return }

        do {
            let (stream, security) = try await withDeadline(bindTimeout) {
                let (stream, security) = try await PpcpByteChannel.open(
                    box.connection, channel: .control, on: self.queue)
                return (stream, security)
            }

            // ⚠ The channel this stream was opened with is a placeholder — the
            // listener does not know it yet, and 2.1b forbids inferring it from
            // arrival order or from the transport address. It comes from the frame
            // header of the first frame, and the **library** reads it there.
            let (binding, residue) = try await withDeadline(bindTimeout) { [weak self] in
                var buffer = Data()
                while true {
                    if let self, let bound = try await self.offer(buffer) {
                        return (bound, buffer.dropFirst(bound.consumed))
                    }
                    guard let next = try await stream.receive() else {
                        // The stream ended before it said what it was. 2.1c's
                        // outcome either way is that the stream is discarded.
                        throw TransportError.bindRefused(.notLinkBind)
                    }
                    buffer.append(next)
                }
            }

            // Whatever TCP coalesced behind `link_bind` is application data and
            // must survive the bind.
            let adopted = stream.adopting(binding.channel)
            let carrying: any ByteChannel = residue.isEmpty
                ? adopted
                : PrefixedByteChannel(adopted, holding: residue)

            try bind(carrying, binding: binding, security: security)
        } catch {
            box.connection.cancel()
        }
    }

    /// Offers a candidate first frame to the library's binder, on the actor.
    ///
    /// ⚠ `nil` means "not a whole frame yet, read more" — `ENC` 3c makes
    /// truncation the reader's decision, and here it simply means the stream has
    /// not finished speaking.
    private func offer(_ bytes: Data) throws -> PpcpLinkBinder.Bound? {
        try binder.offer(bytes)
    }

    /// 2.1b — "associates streams into a link by `link_id` and takes each stream's
    /// channel from the header". 2.1c's three refusals are the **library's**, and
    /// have already fired by the time this is reached.
    private func bind(_ stream: any ByteChannel,
                      binding: PpcpLinkBinder.Bound,
                      security: NegotiatedSecurity) throws {
        // A `link_bind` naming a link that is already live is 2.1d's later bulk
        // channel — the `preview` case — and attaches to the link in place. ⚠ The
        // duplicate-channel refusal is not repeated here: `ppcp_link_binder_offer`
        // has already refused a second claim on a channel this link holds, which
        // is exactly what F-D3-3 was about.
        if let existing = live[binding.link] {
            existing.attach(stream, as: binding.channel)
            return
        }

        var link = pending[binding.link] ?? PendingLink(linkId: binding.linkId)
        link.channels[binding.channel] = stream
        link.security = link.security ?? security

        // 2.1c — "a link that has not bound channel 0 within the listener's own
        // timeout is discarded with every stream it holds". ⛔ **The timeout is the
        // embedding's policy** and is deliberately not in the library; the
        // predicate and the discard are.
        if link.deadline == nil {
            let index = binding.link
            let timeout = bindTimeout
            link.deadline = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard Task.isCancelled == false else { return }
                await self?.discard(index)
            }
        }

        guard required.allSatisfy({ link.channels[$0] != nil }) else {
            pending[binding.link] = link
            return
        }

        link.deadline?.cancel()
        pending.removeValue(forKey: binding.link)
        guard let negotiated = link.security else {
            throw TransportError.incompleteLink(missing: .control)
        }
        // ⚠ The library's own readiness predicate, not a count of our own: 2.1c
        // makes channel 0 the thing a link must have bound, and a link holding a
        // bulk channel and no control channel is not a link.
        guard binder.isReady(link: binding.link) else {
            throw TransportError.incompleteLink(missing: .control)
        }
        // ⛔ `dial: nil` — this side listens. `ENC` 2.1a puts minting and opening
        // in the dialler's hands, so a listening link can only *wait* for a further
        // stream, never open one.
        let assembled = try PpcpPeerLink.assemble(linkId: link.linkId,
                                                  channels: link.channels,
                                                  security: negotiated,
                                                  dial: nil)
        live[binding.link] = assembled
        deliver(assembled)
    }

    /// 2.1c — the timeout expired. "…is discarded with every stream it holds."
    private func discard(_ index: Int) async {
        guard let link = pending.removeValue(forKey: index) else { return }
        link.deadline?.cancel()
        // The library forgets it too, so the slot is available again and a later
        // `link_bind` with the same `link_id` opens a fresh link rather than
        // colliding with a half-assembled one.
        try? binder.discard(link: index)
        for channel in link.channels.values {
            await channel.close(.protocolViolation(TransportError.BindRefusal.timedOut.rawValue))
        }
    }

    private func deliver(_ link: PpcpPeerLink) {
        guard waiters.isEmpty == false else {
            completed.append(link)
            return
        }
        let waiter = waiters.removeFirst()
        let continuation = waiter.continuation
        waiter.continuation = nil
        continuation?.resume(returning: link)
    }

    /// ⚠ A deadline around an `await`, because `NWConnection` has no handshake
    /// timeout of its own that fails closed the way this needs to: `.waiting` is
    /// already turned into a failure in `PpcpByteChannel.open`, but a peer that
    /// completes TLS and then sends nothing at all is invisible to it.
    private func withDeadline<T: Sendable>(_ duration: Duration,
                                           _ work: @escaping @Sendable () async throws -> T)
        async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw TransportError.bindRefused(.timedOut)
            }
            guard let first = try await group.next() else {
                throw TransportError.bindRefused(.timedOut)
            }
            group.cancelAll()
            return first
        }
    }
}
