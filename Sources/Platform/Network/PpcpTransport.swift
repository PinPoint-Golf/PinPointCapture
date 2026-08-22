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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: TransportError.channelClosed(.failed(Self.describe(error))))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive() async throws -> Data? {
        try requireReady()
        while true {
            typealias Arrival = CheckedContinuation<(Data?, Bool), any Error>
            let arrival = try await withCheckedThrowingContinuation { (continuation: Arrival) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: TransportError.channelClosed(.failed(Self.describe(error))))
                    } else {
                        continuation.resume(returning: (data, isComplete))
                    }
                }
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

// MARK: - A link

/// Two channels, three where preview is carried, each a separate TLS session on
/// the same `K_tls` (plan A6; `CORE` §3.1's acceptable table, first row).
struct PpcpPeerLink: PeerTransport {
    let control: any ByteChannel
    let bulk: any ByteChannel
    let preview: (any ByteChannel)?
    let security: NegotiatedSecurity

    init(channels: [PpcpChannel: PpcpByteChannel], security: NegotiatedSecurity) throws {
        guard let control = channels[.control] else { throw TransportError.incompleteLink(missing: .control) }
        guard let bulk = channels[.bulk] else { throw TransportError.incompleteLink(missing: .bulk) }
        self.control = control
        self.bulk = bulk
        self.preview = channels[.preview]
        self.security = security
    }

    func close(_ reason: ChannelCloseReason) async {
        await control.close(reason)
        await bulk.close(reason)
        await preview?.close(reason)
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

        var opened: [PpcpChannel: PpcpByteChannel] = [:]
        var negotiated: NegotiatedSecurity?

        do {
            // ⚠ Sequential, not concurrent, and that is a decision. Separate TCP
            // connections carry no correlation, so until `ENC` §3 framing lands
            // and 2c's channel number identifies each stream, arrival order is
            // the only thing a listener can assemble a link from. It also means
            // a wrong `K_tls` costs one handshake to discover rather than three.
            for channel in channels {
                // `RV` 5.3a — fresh per connection. Each of the two or three
                // links gets its own `rn2`, so an observer watching the
                // `ClientHello`s cannot even tell they belong together.
                let identity = try credentials.nextPskIdentity()
                let parameters = PpcpTlsProfile.parameters(tlsKey: credentials.tlsKey,
                                                           identity: identity,
                                                           isListener: false)
                let connection = NWConnection(host: NWEndpoint.Host(endpoint.host),
                                              port: port,
                                              using: parameters)
                let (wrapped, security) = try await PpcpByteChannel.open(connection,
                                                                         channel: channel,
                                                                         on: queue)
                opened[channel] = wrapped
                negotiated = negotiated ?? security
            }
        } catch {
            for channel in opened.values { await channel.close(.cancelled) }
            throw error
        }

        guard let negotiated else { throw TransportError.incompleteLink(missing: .control) }
        return try PpcpPeerLink(channels: opened, security: negotiated)
    }
}

// MARK: - Listening

/// The listening half, for the discovery path — where the **advertiser** listens
/// and the browser dials, the opposite way round to the pairing-code path
/// (`RV` §2, 3.5b). `RV` §2 recommends the capture peer advertise, so on this
/// platform the device owns both a connector and a listener.
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

    private let credentials: any PpcpCredentials
    private let channels: [PpcpChannel]
    private let requestedPort: UInt16
    private let queue = DispatchQueue(label: "org.pinpointstudio.capture.ppcp.listener")

    private var listener: NWListener?
    private var pending: [ConnectionBox] = []
    private var waiters: [CheckedContinuation<ConnectionBox?, Never>] = []

    init(credentials: any PpcpCredentials,
         channels: [PpcpChannel] = PpcpChannel.required,
         port: UInt16 = 0) {
        self.credentials = credentials
        self.channels = channels
        self.requestedPort = port
    }

    func start() async throws -> UInt16 {
        // ⚠ One listener, one port, N connections. The channels of a link differ
        // by which stream they are, not by where they land — a second port would
        // be a second thing for a pairing code to carry and a second thing for a
        // firewall to block.
        let identity = try credentials.nextPskIdentity()
        let parameters = PpcpTlsProfile.parameters(tlsKey: credentials.tlsKey,
                                                   identity: identity,
                                                   isListener: true)
        let listener: NWListener
        if requestedPort == 0 {
            listener = try NWListener(using: parameters)
        } else {
            guard let port = NWEndpoint.Port(rawValue: requestedPort) else {
                throw TransportError.listenerFailed("port \(requestedPort)")
            }
            listener = try NWListener(using: parameters, on: port)
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let box = ConnectionBox(connection: connection)
            Task { await self.deliver(box) }
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

    func accept() async throws -> any PeerTransport {
        var opened: [PpcpChannel: PpcpByteChannel] = [:]
        var negotiated: NegotiatedSecurity?

        do {
            // ⚠ Arrival order, and it is provisional. `PpcpConnector` dials the
            // channels one at a time and completes each handshake before the
            // next, so the order is deterministic for a single link. It stops
            // being sufficient the moment two peers dial at once, and the real
            // answer is `ENC` 2c — the channel number in every frame header
            // matches the stream it arrives on. When L1's framing lands, this
            // assembles from the first frame header instead and the ordering
            // assumption goes away.
            for channel in channels {
                guard let box = await nextConnection() else {
                    throw TransportError.listenerFailed("stopped while awaiting channel \(channel.rawValue)")
                }
                let (wrapped, security) = try await PpcpByteChannel.open(box.connection,
                                                                         channel: channel,
                                                                         on: queue)
                opened[channel] = wrapped
                negotiated = negotiated ?? security
            }
        } catch {
            for channel in opened.values { await channel.close(.cancelled) }
            throw error
        }

        guard let negotiated else { throw TransportError.incompleteLink(missing: .control) }
        return try PpcpPeerLink(channels: opened, security: negotiated)
    }

    func stop() async {
        listener?.cancel()
        listener = nil
        // ⚠ Wake anyone waiting rather than leaving an `accept()` suspended
        // forever: a session that closes while a peer is half-connected is the
        // ordinary case, not an error case.
        for waiter in waiters { waiter.resume(returning: nil) }
        waiters.removeAll()
        for box in pending { box.connection.cancel() }
        pending.removeAll()
    }

    private func deliver(_ box: ConnectionBox) {
        if waiters.isEmpty {
            pending.append(box)
        } else {
            waiters.removeFirst().resume(returning: box)
        }
    }

    private func nextConnection() async -> ConnectionBox? {
        if pending.isEmpty == false { return pending.removeFirst() }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
