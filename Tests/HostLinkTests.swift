//  HostLinkTests.swift
//  E3.1 — the live host link, composed in the app and driven over a pipe.
//
//  ⚠ **No socket.** `AppModel.connect(transport:sessionId:hostDisplayName:)` takes
//  a transport rather than dialling one, which is the seam that makes this
//  testable: the rendezvous owns dialling, this owns what happens after a socket
//  exists. The pipe below is the same shape as the one in
//  `Packages/Core/Tests/CaptureCoreTests/PeerLinkPumpTests.swift`, which is
//  `private` to that file and cannot be shared across the package boundary.
//
//  ⚠ `Pipe`/`PipeChannel`/`PipeTransport` are internal, not `private`, so
//  `HostLinkSyncTests.swift` (E3.2) can reuse them — both files are compiled into
//  the same `PinPointCaptureTests` target.
//
//  ⛔ The assertion that matters most here is a **negative**: a live link must not
//  report `.connected` **without a host that arbitrates**. That state means a
//  settled clock estimate over an arbitrating session; a bare handshake, which is
//  all this pipe's counterpart ever produces, establishes neither.

import Foundation
import Testing
import CaptureCore
@testable import PinPointCapture

// MARK: - An in-memory transport

actor Pipe {
    private var buffered = Data()
    private var waiter: CheckedContinuation<Data?, any Error>?
    private var closed: ChannelCloseReason?

    func write(_ bytes: Data) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: bytes)
            return
        }
        buffered.append(bytes)
    }

    func read() async throws -> Data? {
        if buffered.isEmpty == false {
            let taken = buffered
            buffered.removeAll()
            return taken
        }
        if let closed { throw TransportError.channelClosed(closed) }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func close(_ reason: ChannelCloseReason) {
        closed = reason
        let waiting = waiter
        waiter = nil
        waiting?.resume(returning: nil)
    }
}

struct PipeChannel: ByteChannel {
    let channel: PpcpChannel
    let outbound: Pipe
    let inbound: Pipe

    func send(_ bytes: Data) async throws { await outbound.write(bytes) }
    func receive() async throws -> Data? { try await inbound.read() }
    func close(_ reason: ChannelCloseReason) async {
        await outbound.close(reason)
        await inbound.close(reason)
    }
}

/// ⛔ **`DiallingPeerLink`, because preview needs `ENC` 2.1d's third channel and
/// `openPreviewChannel()` answers `false` to anything that cannot dial one.** The
/// pipe carries the channel from the start rather than dialling it — there is no
/// listener here to bind against — so `openChannel` hands back what it already
/// holds, which is what 2.1d's own "returns the already-bound channel if the link
/// carries it" describes.
struct PipeTransport: PeerTransport, DiallingPeerLink {
    let control: any ByteChannel
    let bulk: any ByteChannel
    let preview: (any ByteChannel)?
    /// ⚠ Says it negotiated nothing rather than claiming an unknown mode (`RV` 5.4k).
    let security = NegotiatedSecurity.directPathPlaintext

    func openChannel(_ channel: PpcpChannel) async throws -> any ByteChannel {
        switch channel {
        case .control: control
        case .bulk: bulk
        default:
            if let preview { preview }
            else { throw TransportError.channelClosed(.cancelled) }
        }
    }

    func close(_ reason: ChannelCloseReason) async {
        await control.close(reason)
        await bulk.close(reason)
        await preview?.close(reason)
    }

    static func pair() -> (PipeTransport, PipeTransport) {
        let controlAB = Pipe(), controlBA = Pipe()
        let bulkAB = Pipe(), bulkBA = Pipe()
        let previewAB = Pipe(), previewBA = Pipe()
        let a = PipeTransport(
            control: PipeChannel(channel: .control, outbound: controlAB, inbound: controlBA),
            bulk: PipeChannel(channel: .bulk, outbound: bulkAB, inbound: bulkBA),
            preview: PipeChannel(channel: .preview, outbound: previewAB, inbound: previewBA))
        let b = PipeTransport(
            control: PipeChannel(channel: .control, outbound: controlBA, inbound: controlAB),
            bulk: PipeChannel(channel: .bulk, outbound: bulkBA, inbound: bulkAB),
            preview: PipeChannel(channel: .preview, outbound: previewBA, inbound: previewAB))
        return (a, b)
    }
}

// MARK: - The tests

@Suite("E3.1 — the live host link")
@MainActor
struct HostLinkTests {

    /// The declaration a device with no camera makes — the harness's own
    /// camera-less fallback, which exists for exactly this case. ⚠ Injecting it
    /// is what lets the handshake be exercised on a simulator; without it this
    /// seam's first run would be on a phone.
    private func testDeclaration() throws -> PpcpDeclaration {
        try PpcpDeclaration(
            ConformanceHarness.declarationWithoutACamera(peerId: PeerIdentity.current),
            allowingNoCameraSource: true)
    }

    /// A counterpart that answers, in-process. ⚠ `listener: true` is how
    /// `PeerLinkPumpTests` stands one up — `CaptureCore` cannot declare a *host*
    /// peer, so the far end is a second capture peer that listens.
    private func counterpart(on transport: PipeTransport) async throws -> PeerLinkPump {
        let peer = try DevicePeer(peerId: "peer:test-host", role: .capture, listener: true)
        let pump = PeerLinkPump(peer: peer, transport: transport,
                                nowNs: { Int64(Date().timeIntervalSince1970 * 1_000_000_000) })
        await pump.start()
        return pump
    }

    /// Drains a pump until a predicate holds or a deadline passes — the shape
    /// `PeerLinkPumpTests.collect` uses, because `takeEvents` is a poll and a
    /// silent counterpart is a legitimate outcome rather than a hang.
    private func drain(_ pump: PeerLinkPump,
                       until predicate: @escaping ([PeerLinkEvent]) -> Bool,
                       seconds: Double = 2) async -> [PeerLinkEvent] {
        var collected: [PeerLinkEvent] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            collected.append(contentsOf: await pump.takeEvents(waitingUpTo: 0.05))
            if predicate(collected) { break }
            await pump.tickOnce()
        }
        return collected
    }

    @Test("A handshake over a real byte pipe moves the link off none")
    func handshakeEstablishesTheLink() async throws {
        let model = AppModel()
        let declaration = try testDeclaration()

        let (deviceSide, hostSide) = PipeTransport.pair()
        let hostPump = try await counterpart(on: hostSide)
        defer { Task { await hostPump.stop() } }

        #expect(model.hostLink.state == .none)
        await model.connect(transport: deviceSide, sessionId: "ses:test",
                            hostDisplayName: "Bay 3 — Mac Studio",
                            declaration: declaration)

        let link = try #require(model.link)
        #expect(link.hasSettled, "hello and declare should have crossed")
        #expect(model.hostLink.state != .none)
        // ⚠ From the scanned code, because the wire carries no name.
        #expect(model.hostLink.hostName == "Bay 3 — Mac Studio")

        // The counterpart really did receive a declaration.
        let seen = await drain(hostPump, until: { events in
            events.contains { if case .declared = $0 { return true }; return false }
        })
        #expect(seen.contains { if case .declared = $0 { return true }; return false })

        await model.disconnect()
    }

    @Test("A live link never reports connected at this level")
    func neverClaimsConnected() async throws {
        let model = AppModel()
        let declaration = try testDeclaration()

        let (deviceSide, hostSide) = PipeTransport.pair()
        let hostPump = try await counterpart(on: hostSide)
        defer { Task { await hostPump.stop() } }

        await model.connect(transport: deviceSide, sessionId: "ses:test",
                            hostDisplayName: nil, declaration: declaration)

        // ⛔ The load-bearing negative. `.connected` means an arbitrating host and
        // a settled clock estimate; E3.1 runs no sync burst, so claiming it would
        // be exactly the fixture dishonesty this work removed from the screens.
        #expect(model.hostLink.state == .pairing)
        #expect(model.hostLink.clock == nil,
                "a displayed offset of 0.000 ms reads as a very good measurement")

        await model.disconnect()
    }

    @Test("Disconnect is idempotent and leaves nothing running")
    func disconnectIsIdempotent() async throws {
        let model = AppModel()
        let declaration = try testDeclaration()

        let (deviceSide, hostSide) = PipeTransport.pair()
        let hostPump = try await counterpart(on: hostSide)
        defer { Task { await hostPump.stop() } }

        await model.connect(transport: deviceSide, sessionId: "ses:test",
                            hostDisplayName: nil, declaration: declaration)
        #expect(model.link != nil)

        await model.disconnect()
        #expect(model.link == nil)
        #expect(model.hostLink.state == .none)

        // Called again with nothing up — must not trap, must not resurrect state.
        await model.disconnect()
        #expect(model.link == nil)
        #expect(model.hostLink.state == .none)
    }

    @Test("Backgrounding drops the link and says lost")
    func backgroundingReportsLost() async throws {
        let model = AppModel()
        let declaration = try testDeclaration()

        let (deviceSide, hostSide) = PipeTransport.pair()
        let hostPump = try await counterpart(on: hostSide)
        defer { Task { await hostPump.stop() } }

        await model.connect(transport: deviceSide, sessionId: "ses:test",
                            hostDisplayName: nil, declaration: declaration)
        await model.linkDidEnterBackground()

        // ⛔ `lost`, not `none`. The user had a host a moment ago and the app must
        // not quietly forget it — reconnection is E3.5's, but the honest report is
        // this level's.
        #expect(model.hostLink.state == .lost)
        #expect(model.link == nil)
    }

    @Test("Backgrounding with no link is a no-op")
    func backgroundingWithoutALinkDoesNothing() async {
        let model = AppModel()
        await model.linkDidEnterBackground()
        #expect(model.hostLink.state == .none)
    }
}

// MARK: - The endpoint walk's diagnosis

/// A refusal and an unreachable host are opposite findings, and the walk
/// reported both as "nothing answered" until 23 August 2026.
///
/// ⛔ The bug had a cost: PinPointStudio logged "a phone reached this computer and
/// the secure connection failed" while this app told the user it had tried six
/// addresses and reached none of them. Every occurrence sent someone to debug a
/// network that was working.
@Suite("Rendezvous — what the walk concludes")
struct EndpointWalkDiagnosisTests {

    /// A connector that fails every endpoint with a chosen error.
    private struct FailingConnector: PeerTransportConnector {
        let error: any Error
        func connect(to endpoint: PeerEndpoint,
                     credentials: any PpcpCredentials,
                     channels: [PpcpChannel]) async throws -> any PeerTransport {
            throw error
        }
    }

    private func outcome(dialling error: any Error) async -> RendezvousOutcome {
        let coordinator = RendezvousCoordinator(connector: FailingConnector(error: error))
        // A code with endpoints that will each fail the way the test chose.
        return await coordinator.scan(Self.sampleCode)
    }

    /// `RV` §10.3's minimal vector — a real, decodable code, so the walk is
    /// actually reached rather than short-circuited at the decode.
    ///
    /// ⚠ It carries **no `exp`**, so it never expires and the test is not a clock
    /// away from failing.
    private static let sampleCode =
        "ppcp:pWF2AWJlcIGiYWhsMTkyLjE2OC4xLjIwYXAZHmxibXUBY3Bza1AAAQIDBAUGBwgJCgsMDQ4P"
        + "Y3NpZFA_JQTgT4lB05oMAwXoLDMB"

    @Test("A host that answers and refuses is not reported as unreachable")
    func refusalIsNotUnreachability() async throws {
        let result = await outcome(dialling: TransportError.handshakeFailed("alert 20"))
        guard case .hostRefusedTheCode = result else {
            Issue.record("expected hostRefusedTheCode, got \(result)")
            return
        }
    }

    @Test("A host that never answers is still reported as unreachable")
    func unreachabilityIsUnchanged() async throws {
        let result = await outcome(dialling: TransportError.endpointUnreachable("posix 61"))
        guard case .noEndpointReachable = result else {
            Issue.record("expected noEndpointReachable, got \(result)")
            return
        }
    }
}
