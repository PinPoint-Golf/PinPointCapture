//  TransportContractTests.swift
//  The transport port surface, exercised without a socket.
//
//  ⚠ Everything here runs on the host in milliseconds. The parts that genuinely
//  need `Network.framework` — a real TLS-PSK handshake, the negotiated mode —
//  live in the app target's `Tests/TransportLoopbackTests.swift`, because they
//  cannot run here and must not be faked here.

import Foundation
import Testing
@testable import CaptureCore

@Suite("Transport contract")
struct TransportContractTests {

    // MARK: - Channels

    @Test("Channel numbers are the ones ENC 2a fixes")
    func channelNumbering() {
        #expect(PpcpChannel.control.rawValue == 0)
        #expect(PpcpChannel.bulk.rawValue == 1)
        #expect(PpcpChannel.preview.rawValue == 2)
        // ⛔ ENC 2a reserves 255. Nothing may claim it.
        #expect(PpcpChannel.allCases.contains { $0.rawValue == 255 } == false)
        // CORE T2 — control plus at least one bulk, always.
        #expect(PpcpChannel.required == [.control, .bulk])
    }

    // MARK: - Credentials

    @Test("K_tls must be 32 bytes and the PSK identity 17 octets")
    func credentialLengthsAreEnforced() throws {
        let key = Data(repeating: 0xAB, count: 32)
        let identity = Data(repeating: 0xCD, count: 17)
        _ = try FixedPskCredentials(tlsKey: key, identity: identity)

        #expect(throws: TransportError.invalidKeyLength(31)) {
            _ = try FixedPskCredentials(tlsKey: Data(repeating: 0, count: 31), identity: identity)
        }
        #expect(throws: TransportError.invalidIdentityLength(16)) {
            _ = try FixedPskCredentials(tlsKey: key, identity: Data(repeating: 0, count: 16))
        }
    }

    /// ⛔ RV 5.3f. The identity is binary. A peer MUST NOT transcode it, validate
    /// it as text, or truncate it — and the §10.2 vector is not valid UTF-8, so a
    /// well-meant `String(data:encoding:)` anywhere on this path is a bug that
    /// only shows up against a real counterpart.
    @Test("A PSK identity that is not valid UTF-8 survives unchanged")
    func identityIsBinaryNotText() throws {
        // 0x01 || rn2 || tag from RV §10.2 — 0xFE/0xFF sequences and lone
        // continuation bytes make this invalid UTF-8 on purpose.
        var bytes = Data([0x01])
        bytes.append(contentsOf: [0xFF, 0xFE, 0x80, 0x81, 0xC0, 0xC1, 0xF5, 0xF6])
        bytes.append(contentsOf: [0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97])
        #expect(bytes.count == 17)
        #expect(String(data: bytes, encoding: .utf8) == nil, "the fixture must be invalid UTF-8")

        let credentials = try FixedPskCredentials(tlsKey: Data(repeating: 1, count: 32),
                                                  identity: bytes)
        #expect(try credentials.nextPskIdentity() == bytes)
    }

    /// ⛔ RV 7.2b — no secret in a log, a crash report or a diagnostic export.
    /// The cheapest way to keep that true is for the type to have nothing to say.
    @Test("Credentials never print their key material")
    func credentialsAreRedacted() throws {
        let credentials = try FixedPskCredentials(tlsKey: Data(repeating: 0xA5, count: 32),
                                                  identity: Data(repeating: 0x5A, count: 17))
        let printed = "\(credentials)"
        #expect(printed == "PpcpCredentials(redacted)")
        #expect(printed.contains("A5") == false)
        #expect(printed.contains("165") == false)
    }

    // MARK: - Negotiated mode (RV 5.4k)

    @Test("The suite iOS actually negotiates is named, and reports no forward secrecy")
    func plainPskIsReportedHonestly() {
        // RV 5.4b1: measured on an iPhone 16 — TLS 1.2, 0x00A8.
        let mode = NegotiatedSecurity(versionCode: 0x0303, cipherSuite: 0x00A8)
        #expect(mode.version == .tls12)
        #expect(mode.cipherSuiteName == "TLS_PSK_WITH_AES_128_GCM_SHA256")
        #expect(mode.keyExchange == .psk)
        #expect(mode.forwardSecrecy == false)
        #expect(mode.summary == "TLS 1.2, TLS_PSK_WITH_AES_128_GCM_SHA256 — no forward secrecy")
    }

    @Test("An ECDHE_PSK suite reports forward secrecy obtained")
    func ecdhePskIsReportedAsSecret() {
        let mode = NegotiatedSecurity(versionCode: 0x0303, cipherSuite: 0xD001)
        #expect(mode.keyExchange == .pskEphemeral)
        #expect(mode.forwardSecrecy == true)
    }

    /// ⚠ RV 5.2i. At TLS 1.3 the suite does not name the key exchange and no
    /// platform interface reports it, so the honest answer is "unknown". ⛔ It is
    /// specifically not `true`: an unknown mode is not a secure one, and 5.4k
    /// exists so a deployment can apply a policy to the real outcome.
    @Test("TLS 1.3 reports an unknown key exchange rather than assuming psk_dhe_ke")
    func tls13ModeIsNotAssumed() {
        let mode = NegotiatedSecurity(versionCode: 0x0304, cipherSuite: 0x1301)
        #expect(mode.version == .tls13)
        #expect(mode.cipherSuiteName == "TLS_AES_128_GCM_SHA256")
        #expect(mode.keyExchange == .unknown)
        #expect(mode.forwardSecrecy == nil)
        #expect(mode.summary.contains("forward secrecy unknown"))
    }

    @Test("An unrecognised suite is reported as its code point, never guessed at")
    func unknownSuiteFallsBackToTheCodePoint() {
        let mode = NegotiatedSecurity(versionCode: 0x0301, cipherSuite: 0x1234)
        #expect(mode.cipherSuiteName == "0x1234")
        #expect(mode.keyExchange == .unknown)
        #expect(mode.version == .other(0x0301))
        #expect(mode.version.displayName == "TLS 0x0301")
    }

    // MARK: - The shapes compose

    @Test("Two in-memory channels satisfy the link contract")
    func aLinkCanBeBuiltFromTheProtocols() async throws {
        let transport = InMemoryTransport(channels: [.control, .bulk, .preview])

        #expect(transport.control.channel == .control)
        #expect(transport.bulk.channel == .bulk)
        #expect(transport.preview?.channel == .preview)
        #expect(transport.channel(.bulk)?.channel == .bulk)
        #expect(transport.security.cipherSuite == 0x00A8)

        try await transport.control.send(Data([0x50, 0x50]))
        let received = try await transport.control.receive()
        #expect(received == Data([0x50, 0x50]))

        // ⚠ CORE T5 — the channels are independent end to end. Bytes written to
        // bulk must not surface on control, and a reader that assumes otherwise
        // is the head-of-line bug §3.1 describes, one layer up.
        try await transport.bulk.send(Data([0xFF]))
        #expect(try await transport.bulk.receive() == Data([0xFF]))
        await transport.close(.normal)
    }

    @Test("receive(exactly:) reassembles a frame header split across arrivals")
    func exactReadReassembles() async throws {
        let channel = InMemoryChannel(channel: .control)
        // Three arrivals, one eight-byte header — which is exactly how a frame
        // header arrives on a real socket, and why this helper is in Core.
        try await channel.send(Data([1, 2, 3]))
        try await channel.send(Data([4, 5]))
        try await channel.send(Data([6, 7, 8]))
        let header = try await channel.receive(exactly: 8)
        #expect(header == Data([1, 2, 3, 4, 5, 6, 7, 8]))
    }

    @Test("receive(exactly:) reports a stream that ended mid-frame rather than short-reading")
    func exactReadRefusesATruncatedFrame() async throws {
        let channel = InMemoryChannel(channel: .control)
        try await channel.send(Data([1, 2, 3]))
        await channel.close(.peerClosed)
        await #expect(throws: TransportError.channelClosed(.peerClosed)) {
            _ = try await channel.receive(exactly: 8)
        }
    }

    /// ⛔ RV 1.3c / 7.5d. Application data before the handshake completes is
    /// refused, not buffered — a resumed connection that accepted `arm` as early
    /// data would accept a replay of it.
    @Test("A channel that has not completed its handshake refuses bytes")
    func bytesBeforeTheHandshakeAreRefused() async throws {
        let channel = InMemoryChannel(channel: .control, handshakeComplete: false)
        await #expect(throws: TransportError.applicationDataBeforeHandshake) {
            try await channel.send(Data([0x01]))
        }
        await #expect(throws: TransportError.applicationDataBeforeHandshake) {
            _ = try await channel.receive()
        }
    }
}

// MARK: - Test doubles

/// A loopback-in-a-box channel: whatever is sent is what is received.
///
/// ⚠ This exists to exercise the *shapes*, not the transport. It proves the
/// protocols can be conformed to and composed; it proves nothing about TLS, and
/// the app-target suite is where that is settled.
private actor InMemoryChannel: ByteChannel {
    nonisolated let channel: PpcpChannel
    private var queue: [Data] = []
    private var handshakeComplete: Bool
    private var closeReason: ChannelCloseReason?

    init(channel: PpcpChannel, handshakeComplete: Bool = true) {
        self.channel = channel
        self.handshakeComplete = handshakeComplete
    }

    func send(_ bytes: Data) async throws {
        guard handshakeComplete else { throw TransportError.applicationDataBeforeHandshake }
        if let closeReason { throw TransportError.channelClosed(closeReason) }
        queue.append(bytes)
    }

    func receive() async throws -> Data? {
        guard handshakeComplete else { throw TransportError.applicationDataBeforeHandshake }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    func close(_ reason: ChannelCloseReason) async {
        closeReason = reason
    }
}

private struct InMemoryTransport: PeerTransport {
    let control: any ByteChannel
    let bulk: any ByteChannel
    let preview: (any ByteChannel)?
    let security: NegotiatedSecurity

    init(channels: [PpcpChannel]) {
        control = InMemoryChannel(channel: .control)
        bulk = InMemoryChannel(channel: .bulk)
        preview = channels.contains(.preview) ? InMemoryChannel(channel: .preview) : nil
        security = NegotiatedSecurity(versionCode: 0x0303, cipherSuite: 0x00A8)
    }

    func close(_ reason: ChannelCloseReason) async {
        await control.close(reason)
        await bulk.close(reason)
        await preview?.close(reason)
    }
}
