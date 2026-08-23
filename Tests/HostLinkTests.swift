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
//  ⛔ The assertion that matters most here is a **negative**: a live link must not
//  report `.connected` at this level. That state means an arbitrating host and a
//  settled clock estimate, and E3.1 establishes neither.

import Foundation
import Testing
import CaptureCore
@testable import PinPointCapture

// MARK: - An in-memory transport

private actor Pipe {
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

private struct PipeChannel: ByteChannel {
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

private struct PipeTransport: PeerTransport {
    let control: any ByteChannel
    let bulk: any ByteChannel
    let preview: (any ByteChannel)? = nil
    /// ⚠ Says it negotiated nothing rather than claiming an unknown mode (`RV` 5.4k).
    let security = NegotiatedSecurity.directPathPlaintext

    func close(_ reason: ChannelCloseReason) async {
        await control.close(reason)
        await bulk.close(reason)
    }

    static func pair() -> (PipeTransport, PipeTransport) {
        let controlAB = Pipe(), controlBA = Pipe()
        let bulkAB = Pipe(), bulkBA = Pipe()
        let a = PipeTransport(
            control: PipeChannel(channel: .control, outbound: controlAB, inbound: controlBA),
            bulk: PipeChannel(channel: .bulk, outbound: bulkAB, inbound: bulkBA))
        let b = PipeTransport(
            control: PipeChannel(channel: .control, outbound: controlBA, inbound: controlAB),
            bulk: PipeChannel(channel: .bulk, outbound: bulkBA, inbound: bulkAB))
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
