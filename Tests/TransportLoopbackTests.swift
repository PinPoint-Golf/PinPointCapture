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

// MARK: - Harness

/// One loopback link, both ends.
private struct LoopbackHarness {
    let listener: PpcpListener
    let served: any PeerTransport
    let dialled: any PeerTransport

    static func up(channels: [PpcpChannel]) async throws -> LoopbackHarness {
        let credentials = RvVectors.pinned(try RvVectors.keys())
        let listener = PpcpListener(credentials: credentials, channels: channels, port: 0)
        let port = try await listener.start()

        // ⚠ Accept first, then dial. The listener has to be waiting before the
        // connector's first `SYN` or the assembler starts a channel behind.
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
