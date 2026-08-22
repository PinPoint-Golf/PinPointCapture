//  TransportLoopbackTests.swift
//  The one thing about D1 that cannot be asserted from an API: a real TLS-PSK
//  handshake, end to end, and what it actually negotiated.
//
//  ⚠ This is in the app target and not in `Packages/Core` because it needs
//  `Network.framework`, and it needs it for the reason `RV` 5.2i gives: on this
//  platform the ciphersuite is not something the code chooses, so the only
//  evidence that the profile of `RV` §5.2 is met is an observed handshake. RT-4's
//  method is `injected` rather than `static` for exactly that reason.
//
//  ⚠ The keys below are **derived, not written down**. `libppcp`'s L12 landed, so
//  `K_tls` and the 17-octet identity come out of `ppcp_rv_derive` and
//  `ppcp_rv_psk_identity` through `CaptureCore.RendezvousKeys` — the same path a
//  scanned pairing code will take. What remains as literal test data is only what
//  `RV` §10 states as input: a `psk`, a `sid`, and one connection's `rn2`. The
//  byte-for-byte assertions on the outputs live in `Packages/Core`, where they
//  run without a simulator.

import Foundation
import Network
import Testing
import CaptureCore
@testable import PinPointCapture

/// The inputs `PPCP-RV` §10 states. Everything else is derived from them.
private enum RvVectors {
    /// §10.1 `sid` — the HKDF salt, and `Session.id`
    /// `3f2504e0-4f89-41d3-9a0c-0305e82c3301` in canonical text (4.3e).
    static let sid = Data(hex: "3f2504e04f8941d39a0c0305e82c3301")
    /// §10.1 `psk` — the secret a pairing code carries.
    static let psk = Data(hex: "000102030405060708090a0b0c0d0e0f")
    /// §10.2 `rn2` — the eight CSPRNG bytes of one connection's identity.
    ///
    /// ⚠ With this `rn2` the identity is `010f1e2d3c4b5a6978b355ada60b4b5aa8`,
    /// which is deliberately not valid UTF-8: `RV` 5.3f forbids transcoding,
    /// text validation or truncation, and 5.4b2 records this exact value
    /// completing a handshake at TLS 1.2 on an iPhone 16.
    static let rn2 = Data(hex: "0f1e2d3c4b5a6978")
    /// A device that scanned a different code entirely.
    static let otherPsk = Data(hex: "0f0e0d0c0b0a09080706050403020100")

    static func keys() throws -> RendezvousKeys {
        try RendezvousKeys(psk: psk, sid: sid)
    }

    /// ⚠ A fixed `rn2` so both ends of a loopback mint the same identity. The
    /// listener can only accept an identity it registered — see the finding in
    /// `identityRotationAgainstAServerThatCannotResolve` — so a rotating source
    /// on both ends would never connect to itself.
    static func pinned(_ keys: RendezvousKeys) -> RendezvousCredentials {
        RendezvousCredentials(keys: keys, randomBytes: { _ in rn2 })
    }
}

@Suite("PPCP transport over TLS-PSK", .serialized)
struct TransportLoopbackTests {

    // MARK: - The handshake

    /// RT-4 (device half), RT-14 (wire half). A link with matching `K_tls` comes
    /// up, and the negotiated mode is a value the application can read (`RV` 5.4k).
    @Test("A loopback link with matching K_tls completes and reports what it negotiated")
    func matchingKeyHandshakesAndReportsItsMode() async throws {
        let harness = try await LoopbackHarness.up(channels: [.control, .bulk])
        defer { harness.tearDown() }

        let mode = harness.dialled.security
        #expect(harness.served.security == mode,
                "both ends must agree on what they negotiated")

        // ⛔ Never below TLS 1.2 (`RV` 5.2a).
        #expect(mode.version == .tls12 || mode.version == .tls13,
                "negotiated \(mode.version.displayName), which 5.2a forbids")
        #expect(mode.cipherSuite != 0)
        #expect(mode.summary.isEmpty == false)

        switch mode.version {
        case .tls12:
            // `RV` 5.4b1, measured on an iPhone 16 and reproduced here: the
            // platform's enumeration names no PSK suite, so 0x00A8 is what
            // negotiates and forward secrecy is not obtained. §5.4.3 accepts that.
            #expect(mode.cipherSuite == 0x00A8)
            #expect(mode.cipherSuiteName == "TLS_PSK_WITH_AES_128_GCM_SHA256")
            #expect(mode.forwardSecrecy == false)
        case .tls13:
            // ⚠ Not a failure — a *finding*. `RV` 5.4b says so in as many words:
            // "If TLS 1.3 with an external PSK proves reachable there, property 2
            // is obtained on that leg, 5.2b1 already requires it to be used, and
            // the relaxation simply never applies."
            Issue.record("""
                RV 5.4b: TLS 1.3 with an external PSK completed on this platform, \
                which 5.4b1 recorded as failing. Property 2 of 5.2h may be back. \
                Re-run the §5.4.1 measurement and tell the protocol owner before \
                changing anything.
                """)
        case .other(let code):
            Issue.record("negotiated an unexpected TLS version 0x\(String(code, radix: 16))")
        }
    }

    /// ⛔ `RV` 5.2f — a failed handshake is a failed connection. There is no
    /// result here that means "connected anyway".
    ///
    /// ⚠ Worth knowing *where* it fails, because it is not where you would guess.
    /// `K_tls` and `K_id` come from the same `PRK` (`RV` §5.1), so a peer holding
    /// the wrong secret also computes the wrong identity tag and is refused at
    /// identity resolution — alert 115 — long before anything reaches Finished.
    /// A wrong key that *does* resolve cannot arise from a real pairing at all;
    /// `wrongKeyWithAResolvableIdentityFailsLater` constructs one by hand to show
    /// what it would look like.
    @Test("A mismatched pairing fails, and fails closed")
    func mismatchedKeyIsRefused() async throws {
        // ⚠ The same `sid`, a different `psk` — a photographed code from another
        // session, which is the shape this actually takes in the field.
        let listenerCredentials = RvVectors.pinned(try RvVectors.keys())
        let dialCredentials = RvVectors.pinned(try RendezvousKeys(psk: RvVectors.otherPsk,
                                                                  sid: RvVectors.sid))
        let listener = PpcpListener(credentials: listenerCredentials,
                                    channels: [.control],
                                    port: 0)
        let port = try await listener.start()
        let accepting = Task { try await listener.accept() }

        var failed = false
        do {
            _ = try await withTimeout(seconds: 20) {
                try await PpcpConnector().connect(to: PeerEndpoint(host: "127.0.0.1", port: port),
                                                  credentials: dialCredentials,
                                                  channels: [.control])
            }
        } catch {
            failed = true
        }
        accepting.cancel()
        await listener.stop()

        #expect(failed, "a wrong K_tls must not produce a usable link (RV 5.2f)")
    }

    /// ⛔ **The evidence behind the `RV` 5.3c finding**, and the reason that
    /// finding is narrower than it first looked.
    ///
    /// 5.3c requires a server to fail identically for an unresolvable identity
    /// and for a resolved identity with a wrong key. On this platform it does
    /// not: this pairing — a valid, registered identity with a key that does not
    /// match it — fails at Finished with `bad_record_mac`, alert 20, where an
    /// unresolvable identity fails earlier with alert 115. Different content,
    /// different timing, and no interface to change either.
    ///
    /// ⚠ But this combination has to be **built by hand**. `RV` §5.1 derives
    /// `K_tls` and `K_id` from the same `PRK`, so no scanned code and no
    /// persisted pairing can produce a counterpart that resolves and then fails
    /// the key — a wrong secret is wrong in both derivations at once. The 5.3c
    /// gap is therefore real in the API and not reachable through the protocol's
    /// own key schedule.
    @Test("A wrong key with a resolvable identity fails later than an unknown one")
    func wrongKeyWithAResolvableIdentityFailsLater() async throws {
        let keys = try RvVectors.keys()
        let identity = try RvVectors.pinned(keys).nextPskIdentity()
        let listenerCredentials = try FixedPskCredentials(tlsKey: keys.tlsKey, identity: identity)
        // The identity the listener registered, over a key it was never derived
        // from — which RV's key schedule cannot produce, and an attacker cannot
        // reach without `PRK`.
        let impossible = try FixedPskCredentials(tlsKey: keys.identityKey, identity: identity)

        let listener = PpcpListener(credentials: listenerCredentials, channels: [.control], port: 0)
        let port = try await listener.start()
        let accepting = Task { try await listener.accept() }

        var completed = false
        do {
            _ = try await withTimeout(seconds: 20) {
                try await PpcpConnector().connect(to: PeerEndpoint(host: "127.0.0.1", port: port),
                                                  credentials: impossible,
                                                  channels: [.control])
            }
            completed = true
        } catch {
            completed = false
        }
        accepting.cancel()
        await listener.stop()

        #expect(completed == false, "5.2f — a wrong key must never produce a usable link")
    }

    // MARK: - Two channels, independently (CORE T2 / T5)

    @Test("The two channels are separate streams that do not share bytes or fate")
    func channelsAreIndependent() async throws {
        let harness = try await LoopbackHarness.up(channels: [.control, .bulk])
        defer { harness.tearDown() }

        #expect(harness.dialled.control.channel == .control)
        #expect(harness.dialled.bulk.channel == .bulk)

        // Bytes written to one do not surface on the other. That is `CORE` T5:
        // the transport preserves the channels' independence end to end.
        let controlBytes = Data("control".utf8)
        let bulkBytes = Data(repeating: 0x2A, count: 4096)
        try await harness.dialled.control.send(controlBytes)
        try await harness.dialled.bulk.send(bulkBytes)

        let gotControl = try await withTimeout(seconds: 20) {
            try await harness.served.control.receive(exactly: controlBytes.count)
        }
        let gotBulk = try await withTimeout(seconds: 20) {
            try await harness.served.bulk.receive(exactly: bulkBytes.count)
        }
        #expect(gotControl == controlBytes)
        #expect(gotBulk == bulkBytes)

        // ⚠ And they do not share fate. `CORE` §3.1's whole argument is that a
        // capture in flight must not stop a shot event; a bulk channel that took
        // the control channel down with it would be worse than the single
        // connection the split exists to avoid.
        await harness.dialled.bulk.close(.normal)
        try await harness.dialled.control.send(Data("still here".utf8))
        let after = try await withTimeout(seconds: 20) {
            try await harness.served.control.receive(exactly: 10)
        }
        #expect(after == Data("still here".utf8))
    }

    // MARK: - Nothing before the handshake

    /// ⛔ `RV` 1.3c / 7.7a / 7.5d. `hello` is the first byte of application data
    /// on an established, authenticated connection, and TLS 1.3 early data is
    /// replayable by design — a resumed connection that accepted `arm` as early
    /// data would accept a replay of it.
    @Test("A channel refuses to carry a byte until its handshake has completed")
    func applicationDataBeforeTheHandshakeIsRefused() async throws {
        // Never started: `markHandshakeComplete()` is what `PpcpByteChannel.open`
        // calls, and only after `.ready` plus TLS metadata.
        let credentials = RvVectors.pinned(try RvVectors.keys())
        let parameters = PpcpTlsProfile.parameters(tlsKey: credentials.tlsKey,
                                                   identity: try credentials.nextPskIdentity(),
                                                   isListener: false)
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: parameters)
        let channel = PpcpByteChannel(connection: connection, channel: .control)

        await #expect(throws: TransportError.applicationDataBeforeHandshake) {
            try await channel.send(Data([0x01]))
        }
        await #expect(throws: TransportError.applicationDataBeforeHandshake) {
            _ = try await channel.receive()
        }
        await channel.close(.cancelled)
    }

    // MARK: - What the platform actually does with a rotating identity

    /// ⛔ **A measured platform finding, and it is a problem for `RV` §5.3.**
    ///
    /// 5.3a makes the PSK identity fresh per connection; 5.3b asks a server to
    /// resolve an offered identity by recomputing its tag with the `K_id` of every
    /// pairing it holds. **Neither is reachable from a Network.framework
    /// listener.** Measured here, on the simulator, iOS 27:
    ///
    /// - the listener matches the offered identity against the ones registered by
    ///   `sec_protocol_options_add_pre_shared_key` and refuses anything else with
    ///   `PSK_IDENTITY_NOT_FOUND` → alert 115, `unknown_psk_identity`;
    /// - there is no server-side selection hook to put 5.3b's HMAC inside.
    ///   `sec_protocol_options_set_pre_shared_key_selection_block` is documented
    ///   as "invoked when **the client** must choose a PSK identity given a hint
    ///   from its peer" and has no server-side counterpart.
    ///
    /// So an iOS peer can be a fully conformant *client* — rotating `rn2` per
    /// connection exactly as 5.3a requires — and cannot be a conformant *server*
    /// at all. That matters more than it sounds: `RV` 3.5b recommends the capture
    /// peer **advertise**, which makes it the listener on the discovery path.
    ///
    /// It also breaks 5.3c on this platform. A wrong key fails with
    /// `bad_record_mac` (alert 20, at Finished) and an unresolvable identity fails
    /// with `unknown_psk_identity` (alert 115, earlier) — the two cases 5.3c says
    /// MUST be indistinguishable, distinguishable in both content and timing, with
    /// no interface to make them otherwise.
    ///
    /// Reported with D1. Nothing here works around it.
    @Test("An iOS listener refuses a PSK identity it did not register (RV 5.3a/5.3b finding)")
    func identityRotationAgainstAServerThatCannotResolve() async throws {
        let keys = try RvVectors.keys()
        let listenerCredentials = RvVectors.pinned(keys)
        // ⚠ The real thing: a conformant client, minting `rn2` from the platform
        // CSPRNG per connection exactly as `RV` 5.3a requires. Same `K_tls`, same
        // `K_id`, same pairing — only the identity is fresh, which is precisely
        // what the second connection of any real pairing looks like.
        let dialCredentials = RendezvousCredentials(keys: keys)

        let listener = PpcpListener(credentials: listenerCredentials, channels: [.control], port: 0)
        let port = try await listener.start()
        let accepting = Task { try await listener.accept() }

        var completed = false
        do {
            _ = try await withTimeout(seconds: 20) {
                try await PpcpConnector().connect(to: PeerEndpoint(host: "127.0.0.1", port: port),
                                                  credentials: dialCredentials,
                                                  channels: [.control])
            }
            completed = true
        } catch {
            completed = false
        }
        accepting.cancel()
        await listener.stop()

        // ⚠ The assertion IS the measurement, and it asserts the unwelcome answer
        // rather than the convenient one. If this ever starts failing, iOS has
        // gained a way to accept an identity it did not register — which is the
        // day the discovery path becomes implementable on the device side, and
        // the day the finding above should be re-taken to the specification.
        #expect(completed == false, """
            The listener accepted an identity it had not registered. That is the \
            opposite of what was measured on iOS 27; re-read RV 5.3a/5.3b, because \
            the discovery path may now be open to a device listener.
            """)
    }
}

// MARK: - Binding streams to a link (ENC §2.1, erratum E1)

/// ⚠ **These four tests are the reason E1 exists**, and three of them could not
/// have been written against the arrival-order listener D1 shipped: concurrent
/// dials, a third channel opened after the session is up, and a stream whose
/// first frame is not a `link_bind`. The fourth — a stream whose `channel`
/// disagrees with its header — had no way to be detected at all.
@Suite("link_bind over a real link — ENC §2.1", .serialized)
struct LinkBindLoopbackTests {

    /// 2.1a/2.1b — the dialler sends `link_bind` first on every stream and the
    /// listener takes each stream's channel from the header.
    ///
    /// ⛔ `PpcpConnector` now dials **concurrently** (2.1d: "bulk channels MAY be
    /// opened before, after, or concurrently with channel 0"), so the order the
    /// two handshakes complete in is genuinely unspecified. That the listener
    /// still lands channel 0 on `control` and channel 1 on `bulk` is the whole
    /// claim, and under the old rule it would have been a coin toss.
    @Test("Concurrently dialled channels bind to the right stream")
    func concurrentDialsBindByLinkId() async throws {
        let harness = try await LoopbackHarness.up(channels: [.control, .bulk])
        defer { harness.tearDown() }

        #expect(harness.served.control.channel == .control)
        #expect(harness.served.bulk.channel == .bulk)

        // And they really are different streams: `CORE` T2's independent flow
        // control is the reason there are two, so bytes must not cross over.
        try await harness.dialled.control.send(Data("on-control".utf8))
        try await harness.dialled.bulk.send(Data("on-bulk".utf8))
        #expect(try await harness.served.control.receive() == Data("on-control".utf8))
        #expect(try await harness.served.bulk.receive() == Data("on-bulk".utf8))
    }

    /// 2.1d — "a bulk channel MAY be opened at any later point in the session — a
    /// `preview` channel after the session is established is the expected case —
    /// by a further stream carrying `link_bind` with the same `link_id`."
    ///
    /// ⛔ This is the case arrival order could not serve at all: a third stream
    /// arriving mid-session is indistinguishable from a *new peer's* first stream
    /// unless it names the link it belongs to.
    @Test("A preview channel opened after the session binds into the same link")
    func aLaterPreviewChannelBinds() async throws {
        let harness = try await LoopbackHarness.up(channels: [.control, .bulk])
        defer { harness.tearDown() }

        #expect(harness.dialled.preview == nil, "not asked for, not opened")
        #expect(harness.served.preview == nil)

        let dialling = try #require(harness.dialled as? DiallingPeerLink)
        let listening = try #require(harness.served as? ListeningPeerLink)

        let waiting = Task { try await listening.channelBound(.preview) }
        let opened = try await withTimeout(seconds: 30) { try await dialling.openChannel(.preview) }
        let bound = try await withTimeout(seconds: 30) { try await waiting.value }

        #expect(opened.channel == .preview)
        #expect(bound.channel == .preview)
        // Bound into the link that already existed, not into a second one.
        #expect(harness.served.preview != nil)
        #expect(harness.dialled.preview != nil)

        try await opened.send(Data("preview-frame".utf8))
        #expect(try await bound.receive() == Data("preview-frame".utf8))
    }

    /// 2.1c, refusal one — "a listener closes a stream whose first frame is not
    /// `link_bind`".
    ///
    /// ⚠ The TLS handshake **succeeds** here and the stream is closed anyway.
    /// That is the point: `RV` §5 authenticates the peer and says nothing about
    /// whether it speaks PPCP, and on the `direct` path of D9's harness there is
    /// no PSK at all. The bind is the protocol's own gate.
    @Test("A first frame that is not link_bind closes the stream and yields no link")
    func aBadFirstFrameIsRefused() async throws {
        let credentials = RvVectors.pinned(try RvVectors.keys())
        let listener = PpcpListener(credentials: credentials,
                                    channels: [.control, .bulk], port: 0,
                                    bindTimeout: .seconds(2))
        let port = try await listener.start()
        defer { Task { await listener.stop() } }

        let accepting = Task { try await listener.accept() }
        let queue = DispatchQueue(label: "test.badfirstframe")

        // A real TLS-PSK connection that then speaks nonsense.
        let parameters = PpcpTlsProfile.parameters(tlsKey: credentials.tlsKey,
                                                    identity: try credentials.nextPskIdentity(),
                                                    isListener: false)
        let connection = NWConnection(host: "127.0.0.1",
                                      port: NWEndpoint.Port(rawValue: port)!,
                                      using: parameters)
        let (stream, _) = try await withTimeout(seconds: 30) {
            try await PpcpByteChannel.open(connection, channel: .control, on: queue)
        }
        // A well-formed ENC §3 frame on channel 0 whose payload is not a
        // `link_bind` envelope — so the refusal is the bind's and not the
        // framing's.
        var frame = Data([0, 0, 0, 4, 0, 0, 0, 0])
        frame.append(contentsOf: [0xA1, 0x61, 0x61, 0x01])   // { "a": 1 }
        try await stream.send(frame)

        // The listener has nothing to hand back, and says so within its own
        // timeout rather than waiting forever (2.1c).
        await #expect(throws: (any Error).self) {
            try await withTimeout(seconds: 20) { try await accepting.value }
        }
        await stream.close(.cancelled)
    }

    /// 2.1c, refusal three — "…or whose `link_id` names a link that already holds
    /// that channel". ⚠ Two diallers, two `link_id`s, one listener: the *second*
    /// link is a different link and both must assemble, which is the case
    /// arrival order got wrong first and silently.
    @Test("Two peers dialling at once assemble into two links, not one")
    func twoPeersDoNotCrossOver() async throws {
        let credentials = RvVectors.pinned(try RvVectors.keys())
        let listener = PpcpListener(credentials: credentials,
                                    channels: [.control, .bulk], port: 0)
        let port = try await listener.start()
        defer { Task { await listener.stop() } }

        let endpoint = PeerEndpoint(host: "127.0.0.1", port: port)
        let first = Task { try await listener.accept() }
        let second = Task { try await listener.accept() }

        // ⚠ `Task`, not `async let`. Both start the moment they are made, so the
        // two dials really are concurrent — which is the whole point of the test
        // — but a `Task` can be awaited from inside `withTimeout`'s closure and
        // an `async let` binding cannot be captured by one at all.
        let dialledA = Task {
            try await PpcpConnector().connect(to: endpoint, credentials: credentials,
                                              channels: [.control, .bulk])
        }
        let dialledB = Task {
            try await PpcpConnector().connect(to: endpoint, credentials: credentials,
                                              channels: [.control, .bulk])
        }
        let linkA = try await withTimeout(seconds: 40) { try await dialledA.value }
        let linkB = try await withTimeout(seconds: 40) { try await dialledB.value }
        let servedA = try await withTimeout(seconds: 40) { try await first.value }
        let servedB = try await withTimeout(seconds: 40) { try await second.value }

        // Four streams, two links, and every one on the channel it announced.
        for link in [servedA, servedB] {
            #expect(link.control.channel == .control)
            #expect(link.bulk.channel == .bulk)
        }

        // ⛔ The assertion that matters: bytes written to one peer's control
        // channel do not surface on the other's. Under arrival order, two
        // concurrent dials could interleave and produce exactly that.
        try await linkA.control.send(Data("A".utf8))
        try await linkB.control.send(Data("B".utf8))
        let a = try await servedA.control.receive()
        let b = try await servedB.control.receive()
        #expect(Set([a, b]) == Set([Data("A".utf8), Data("B".utf8)]))
        #expect(a != b)

        await linkA.close(.normal)
        await linkB.close(.normal)
        await servedA.close(.normal)
        await servedB.close(.normal)
    }
}

private struct LoopbackHarness {
    let listener: PpcpListener
    let served: any PeerTransport
    let dialled: any PeerTransport

    static func up(channels: [PpcpChannel]) async throws -> LoopbackHarness {
        let credentials = RvVectors.pinned(try RvVectors.keys())
        let listener = PpcpListener(credentials: credentials, channels: channels, port: 0)
        let port = try await listener.start()

        // ⚠ Accept first, then dial — now only so the test does not race its own
        // `accept()`. It used to be load-bearing: the listener assembled a link
        // from arrival order and a late `accept()` started a channel behind.
        // `ENC` 2.1 (erratum E1) removed that: streams are taken into the
        // listener as they arrive, bound by `link_id`, and `accept()` collects a
        // link that is already complete.
        let accepting = Task { try await listener.accept() }
        let dialled = try await withTimeout(seconds: 30) {
            try await PpcpConnector().connect(to: PeerEndpoint(host: "127.0.0.1", port: port),
                                              credentials: credentials,
                                              channels: channels)
        }
        let served = try await withTimeout(seconds: 30) { try await accepting.value }
        return LoopbackHarness(listener: listener, served: served, dialled: dialled)
    }

    func tearDown() {
        let listener = listener
        let served = served
        let dialled = dialled
        Task {
            await dialled.close(.normal)
            await served.close(.normal)
            await listener.stop()
        }
    }
}

/// ⚠ A handshake that never completes must fail the suite rather than hang it.
/// Swift Testing's time-limit trait has a one-minute floor, which is long enough
/// that a hung loopback looks like a hung machine.
private func withTimeout<T: Sendable>(seconds: Double,
                                      _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TransportError.handshakeFailed("timed out after \(seconds)s")
        }
        guard let first = try await group.next() else {
            throw TransportError.handshakeFailed("no result")
        }
        group.cancelAll()
        return first
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
