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
// ⚠ For §12's originator only — the host half of the actuator round trip has no
// Swift wrapper here, because this application never originates a command.
import CPPCP
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
                                                   timebaseRef: "tb:hosttime",
                                                   openedAtNs: 1_000_000_000))
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

    /// `PPCP-MSG` 12.1 — the command becomes an event the application can act on.
    ///
    /// ⛔ Read through the pump's pointer helper while the `ppcp_msg` is alive
    /// (trap 4, F-D3-1) and harvested with `nextEventImported` (trap 5, E28).
    /// Both are properties of `PeerLinkPump`, which is why this lives here and
    /// not beside the wire assertions in `ActuatorWireTests`.
    @Test("MSG 12.1 — an actuator_command is translated into an event")
    func anActuatorCommandBecomesAnEvent() async throws {
        let (deviceSide, hostSide) = PipeTransport.pair()
        let device = try DevicePeer(peerId: "peer:device", role: .capture)
        // ⛔ `role: .host`. 12a is checked against the REMOTE role, so a capture
        // peer commanding here would be refused inside the engine and this test
        // would pass by never getting an event at all.
        let host = try DevicePeer(peerId: "peer:host", role: .host, listener: true)
        let devicePump = PeerLinkPump(peer: device, transport: deviceSide,
                                      nowNs: { Self.clock() })
        let hostPump = PeerLinkPump(peer: host, transport: hostSide,
                                    nowNs: { Self.clock() })
        await devicePump.start()
        await hostPump.start()

        try await hostPump.perform { try $0.hello() }
        try await devicePump.perform { peer in
            try peer.hello()
            try peer.declare(try ActuatorWireTests.declarationWithTorch())
        }
        // 12.1d — the host may only command what the counterpart declared, so
        // the declaration has to arrive before the command is originable.
        _ = await Self.collect(from: hostPump, until: { events in
            events.contains { if case .declared = $0 { return true }; return false }
        })
        try await hostPump.perform { peer in
            peer.withHandle { handle in
                var setting = ppcp_actuator_setting()
                #expect(ppcp_actuator_setting_on_off(&setting, true) == PPCP_OK)
                #expect(ppcp_peer_actuator_command(handle, "act:torch", &setting) == PPCP_OK)
            }
        }

        let seen = await Self.collect(from: devicePump, until: { events in
            events.contains { if case .actuatorCommanded = $0 { return true }; return false }
        })
        // ⭐ **`engineAnswered: false` — the event is an obligation, not a
        // notification.** Since libppcp L30 the engine writes no ack for a
        // well-formed, declared, host-originated command, so `MSG` 1c's answer is
        // the embedding's; `replyTo` is what correlates it (1a), and a zero there
        // would leave nothing to answer.
        let commanded = try #require(seen.compactMap { event -> (String, Bool, UInt64, Bool)? in
            if case .actuatorCommanded(let id, let isOn, let replyTo, let answered) = event {
                return (id, isOn, replyTo, answered)
            }
            return nil
        }.first)
        #expect(commanded.0 == "act:torch")
        #expect(commanded.1)
        #expect(commanded.2 != 0)
        #expect(commanded.3 == false, "MSG 12.1c — the answer is owed by this peer")

        // ⛔ **And the answer goes back, carrying the ACHIEVED value.** `false`
        // against a request of `true` is the thermal-cutoff case: on the phone it
        // is `isTorchActive` read back after the write, and an echo of the
        // request could not produce it. The host is driven to the point of
        // receiving the ack, so this is the round trip and not a send.
        try await devicePump.perform { peer in
            try peer.sendActuatorCommandApplied(actuatorId: "act:torch", isOn: false,
                                                inReplyTo: commanded.2)
        }
        let acked = await Self.collect(from: hostPump, until: { events in
            events.contains {
                if case .other(let kind) = $0 {
                    return kind == Int32(PPCP_EVENT_ACTUATOR_COMMAND_ACK.rawValue)
                }
                return false
            }
        })
        #expect(acked.contains {
            if case .other(let kind) = $0 {
                return kind == Int32(PPCP_EVENT_ACTUATOR_COMMAND_ACK.rawValue)
            }
            return false
        }, "MSG 1c — answering is a MUST, and the ack reached the host")

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
