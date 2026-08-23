//  PeerLinkPumpTests.swift
//  The driver, over an in-memory transport — two `ppcp_peer`s talking through
//  `PeerLinkPump` rather than through a test writing `a.feed(b.drain())`.
//
//  ⚠ **This is still an implementation talking to itself**, and `CONF` §2c is
//  explicit that such a test is not sufficient. It is here for the half it *can*
//  settle — that the pump moves whole frames in both directions, respects
//  backpressure through peek/commit, and surfaces the events an embedding acts
//  on. The half it cannot settle is D9's, against `ppcp-sim`.
//
//  Spec: `CORE` §3 (T1–T5); `ENC` §3; `MSG` §3–§4. Plan D9.

import Foundation
import Testing
@testable import CaptureCore

// MARK: - An in-memory link

/// One direction of a byte pipe.
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
    /// ⚠ The in-memory pipe negotiated nothing, and says so rather than claiming
    /// an unknown mode (`RV` 5.4k).
    let security = NegotiatedSecurity.directPathPlaintext

    func close(_ reason: ChannelCloseReason) async {
        await control.close(reason)
        await bulk.close(reason)
    }

    /// Two transports back to back.
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

@Suite("PeerLinkPump — bytes between a transport and a peer")
struct PeerLinkPumpTests {

    /// ⚠ The same shape `DetectMintTests` uses — one camera, a microphone and an
    /// IMU on one timebase (I4), every constant `assumed` (A12).
    private static func declaration(peerId: String) throws -> PpcpDeclaration {
        try PpcpDeclaration(PpcpDeclarationInput(
            peerId: peerId,
            profiles: PpcpProfileSet.device,
            timebases: [PpcpTimebaseDeclaration(id: "tb:hosttime", kind: .monotonic,
                                                epochStable: true, resolutionNs: 42,
                                                origin: "CMClockGetHostTimeClock")],
            captureTimebaseId: "tb:hosttime",
            capability: DeviceCapability(
                modelIdentifier: "iPhone17,3", modelName: "iPhone 16",
                claimed: [VideoMode(width: 1920, height: 1080, fps: 150, lens: .wide,
                                    pixelFormat: "420v")],
                measured: nil),
            timing: PpcpDeviceTimingProfile(
                frameStartToExposureOffsetNs: 0, offsetProvenance: .assumed,
                geometry: [PpcpGeometryEntry(readout: .assumedFractionOfFrameInterval(1.0),
                                             direction: .topToBottom)]),
            clipCodec: "hevc",
            declaresMicrophone: true,
            declaresIMU: true))
    }

    /// `MSG` §3 — the handshake crosses a real transport in both directions, and
    /// each end learns the other's `Peer.id` from the `declare` that arrived
    /// rather than from a value the test handed it.
    @Test("A hello and a declare cross the pump in both directions")
    func theHandshakeCrossesTheLink() async throws {
        let (deviceSide, hostSide) = PipeTransport.pair()
        // ⚠ **Two capture peers, and that is `RV` 2e rather than a shortcut**:
        // "Two capture peers pairing directly — the multi-device case — is one
        // displaying a code and the other scanning it, with no host involved."
        // `PpcpDeclarationInput` builds a `role: capture` descriptor and nothing
        // else, so a host peer is not declarable from this package — which is
        // exactly why D9's counterpart has to be `ppcp-sim`.
        let device = try DevicePeer(peerId: "peer:device", role: .capture)
        let host = try DevicePeer(peerId: "peer:other", role: .capture, listener: true)

        let devicePump = PeerLinkPump(peer: device, transport: deviceSide,
                                      nowNs: { Self.clock() })
        let hostPump = PeerLinkPump(peer: host, transport: hostSide,
                                    nowNs: { Self.clock() })
        await devicePump.start()
        await hostPump.start()

        try await devicePump.perform { peer in
            try peer.hello()
            try peer.declare(try Self.declaration(peerId: "peer:device"))
        }

        // The host sees `hello` and `declare`, and answers.
        let seenByHost = await Self.collect(from: hostPump, until: { events in
            events.contains { if case .declared = $0 { return true }; return false }
        })
        #expect(seenByHost.contains { if case .hello = $0 { return true }; return false })
        #expect(seenByHost.contains {
            if case .declared(let id) = $0 { return id == "peer:device" }
            return false
        })

        try await hostPump.perform { peer in
            try peer.declare(try Self.declaration(peerId: "peer:other"))
        }
        let seenByDevice = await Self.collect(from: devicePump, until: { events in
            events.contains { if case .declared = $0 { return true }; return false }
        })
        #expect(seenByDevice.contains {
            if case .declared(let id) = $0 { return id == "peer:other" }
            return false
        })

        // ⛔ F-L13-1 — `peer.h`: "a conformance harness asserts it is zero".
        #expect(try await devicePump.perform { $0.droppedEventCount } == 0)
        #expect(try await hostPump.perform { $0.droppedEventCount } == 0)

        await devicePump.stop()
        await hostPump.stop()
    }

    /// `MSG` 4.1 — the Session one peer opens is the Session the other joins, and
    /// I16's parameters arrive unchanged.
    @Test("A session_open crosses and its parameters arrive intact")
    func aSessionOpenCrosses() async throws {
        let (deviceSide, hostSide) = PipeTransport.pair()
        let device = try DevicePeer(peerId: "peer:device", role: .capture)
        let host = try DevicePeer(peerId: "peer:other", role: .capture, listener: true)
        let devicePump = PeerLinkPump(peer: device, transport: deviceSide,
                                      nowNs: { Self.clock() })
        let hostPump = PeerLinkPump(peer: host, transport: hostSide,
                                    nowNs: { Self.clock() })
        await devicePump.start()
        await hostPump.start()

        try await devicePump.perform { peer in
            try peer.hello()
            try peer.declare(try Self.declaration(peerId: "peer:device"))
        }
        _ = await Self.collect(from: hostPump, until: { events in
            events.contains { if case .declared = $0 { return true }; return false }
        })
        try await hostPump.perform { peer in
            try peer.declare(try Self.declaration(peerId: "peer:other"))
            // `CORE` 4.1b — the hostless form, which a capture peer may originate.
            try peer.openSession(PpcpSessionRecord(id: "ses:pump",
                                                   timebaseRef: "tb:hosttime"))
        }

        let seen = await Self.collect(from: devicePump, until: { events in
            events.contains { if case .sessionOpened = $0 { return true }; return false }
        })
        #expect(seen.contains {
            if case .sessionOpened(let id) = $0 { return id == "ses:pump" }
            return false
        })
        let parameters = try #require(try await devicePump.perform { $0.sessionParameters })
        #expect(parameters.sessionId == "ses:pump")
        #expect(parameters.timebaseRefId == "tb:hosttime")

        await devicePump.stop()
        await hostPump.stop()
    }

    /// A monotonic clock for the pump's tick. ⚠ `Date` rather than a mach clock:
    /// `CaptureCore` owns no clock (ground rule 8), and the reading is the
    /// embedding's to supply — which is what this parameter exists to demonstrate.
    private static func clock() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000_000_000)
    }

    /// Drains a pump until `predicate` holds or a second elapses.
    private static func collect(from pump: PeerLinkPump,
                                until predicate: ([PeerLinkEvent]) -> Bool) async
        -> [PeerLinkEvent] {
        var collected: [PeerLinkEvent] = []
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            collected.append(contentsOf: await pump.takeEvents(waitingUpTo: 0.05))
            if predicate(collected) { break }
            await pump.tickOnce()
        }
        return collected
    }
}
