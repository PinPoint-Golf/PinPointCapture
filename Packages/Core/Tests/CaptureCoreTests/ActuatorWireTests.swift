//  ActuatorWireTests.swift
//  D17 — CR-02 on the wire: `Peer.actuators` in `declare` (D13), the
//  `actuator_command` round trip and the event it raises (D15), and the two
//  statistics messages (D16).
//
//  Rows exercised: CT-I39 (device half), CT-S6.

import Foundation
import Testing
import CPPCP
@testable import CaptureCore

@Suite("Actuators and the CR-02 statistics — CORE §5.19–5.21, MSG §5.5, §5.6, §12")
struct ActuatorWireTests {

    static let deviceId = "peer:d15-device"
    static let hostId = "peer:d15-host"
    static let timebase = "tb:hosttime"
    static let torch = PpcpActuatorDeclaration(id: PpcpActuatorDeclaration.torchId,
                                               kind: ActuatorKind.torch,
                                               control: .onOff,
                                               label: "Torch")

    static func input(peerId: String = deviceId,
                      actuators: [PpcpActuatorDeclaration] = [torch]) -> PpcpDeclarationInput {
        PpcpDeclarationInput(
            peerId: peerId,
            profiles: PpcpProfileSet.device,
            timebases: DeclarationTests.timebases,
            captureTimebaseId: timebase,
            capability: DeclarationTests.capability(),
            timing: DeclarationTests.unmeasuredTiming,
            clipCodec: "hevc",
            actuators: actuators)
    }

    /// The one declaration with a torch on it, so a suite that needs a
    /// commandable Actuator does not grow a second spelling of `act:torch`.
    static func declarationWithTorch() throws -> PpcpDeclaration {
        try PpcpDeclaration(input(peerId: "peer:device"))
    }

    // MARK: D13 — CORE §5.19a, the declaration

    /// 5.19a — the Actuator is declared, and the assertion is read **back out of
    /// the `ppcp_actuator` structs the wire will carry**, not off the input.
    ///
    /// ⚠ `CONF` §2c in miniature: a view assembled from the same Swift values
    /// that fed the constructors would agree with itself whatever the library
    /// did with them, which is not evidence of anything.
    @Test("CORE 5.19a — the torch is declared, read back off the C structs")
    func theTorchIsDeclared() throws {
        let declaration = try PpcpDeclaration(Self.input())
        let actuator = try #require(declaration.actuators.first)
        #expect(declaration.actuators.count == 1)
        #expect(actuator.id == "act:torch")
        #expect(actuator.kind == "torch")
        #expect(actuator.control == "on_off")
        #expect(actuator.label == "Torch")
        // 12.1a / I39 — the library's own answer to "what shape does a command
        // to this Actuator take", not a re-reading of the enum we passed in.
        #expect(actuator.isOnOff)
    }

    /// ⛔ **5.19b — an Actuator is not a Source.** The two `kind` registries are
    /// disjoint, so nothing named `torch` may appear among the Sources and the
    /// Actuator carries no `CaptureProfile` to appear with.
    @Test("CORE 5.19b — the torch is not among the Sources")
    func theTorchIsNotASource() throws {
        let declaration = try PpcpDeclaration(Self.input())
        #expect(declaration.sources.contains { $0.kind == "torch" } == false)
        #expect(declaration.sources.contains { $0.id == "act:torch" } == false)
    }

    /// ⚠ **5.19c — a peer owning none participates fully**, and erratum E66 makes
    /// the key absent rather than empty. A front-camera-only phone and the
    /// simulator both land here, and the declaration still validates and encodes.
    @Test("CORE 5.19c — declaring no Actuator is a correct declaration")
    func noActuatorIsLegal() throws {
        let declaration = try PpcpDeclaration(Self.input(actuators: []))
        #expect(declaration.actuators.isEmpty)
        #expect(try declaration.encoded().isEmpty == false)
    }

    /// `CORE` §2.2.3 — `actuate` is claimed, and read off the declaration rather
    /// than off `PpcpProfileSet` (I24 is asserted against what a counterpart
    /// *received*).
    @Test("The declaration carries the actuate profile")
    func actuateIsDeclared() throws {
        #expect(try PpcpDeclaration(Self.input()).declaredProfiles.contains("actuate"))
    }

    // MARK: D15 — MSG §12, the round trip

    /// ⭐ **The `actuator_command` round trip, host to device, through the
    /// library at both ends.**
    ///
    /// ⛔ The three refusals that need no hardware are still made *inside the
    /// engine* before an event exists — 12a's non-host origination, 12.1d's
    /// undeclared Actuator, 12.1a's wrong shape — so an event arriving here has
    /// passed all three.
    ///
    /// ⭐ **What changed, and it is the D17 finding closed.** D17 asserted here
    /// that the ack's `state` was the ECHO of the request, because
    /// `peer_on_actuator_command` wrote `state = b->setting` before this
    /// application knew a command existed — 12.1c unsatisfiable on this stack,
    /// recorded in a test so it could not rot. libppcp L30 hands the command
    /// over instead: this now asserts that **the engine writes no ack of its
    /// own**, and that the one the embedding sends carries the value the
    /// embedding supplied.
    @Test("MSG 12.1c — the engine hands the command over and the embedding answers")
    func anActuatorCommandRoundTrips() throws {
        let device = try DevicePeer(peerId: Self.deviceId, role: .capture)
        let host = try DevicePeer(peerId: Self.hostId, role: .host, listener: true)

        // ⛔ **Both `hello`s BEFORE either is fed.** `ppcp_peer_hello` refuses a
        // peer that has left `PPCP_PEER_INIT`, and a peer that has received one
        // has left it — so feeding first makes the second `hello` an error, not
        // a late one. ⚠ 12a is checked against the REMOTE role, which is learned
        // from `hello` / `hello_accept` and from nowhere else.
        try device.hello()
        try host.hello()
        _ = try host.feed(try device.drain(.control), on: .control)
        _ = try device.feed(try host.drain(.control), on: .control)

        try device.declare(try PpcpDeclaration(Self.input()))
        // 12.1d — the host may only command an Actuator in the counterpart's
        // last-known `Peer.actuators`, so the declaration has to cross first.
        _ = try host.feed(try device.drain(.control), on: .control)

        // The host originates. ⛔ `_on_off` and not a `_make`: CB7/I39 make the
        // wrong shape unconstructible rather than rejected.
        try host.withHandle { handle in
            var setting = ppcp_actuator_setting()
            #expect(ppcp_actuator_setting_on_off(&setting, true) == PPCP_OK)
            #expect(ppcp_peer_actuator_command(handle, "act:torch", &setting) == PPCP_OK)
        }
        _ = try device.feed(try host.drain(.control), on: .control)

        // 1 — the event reaches the device, with the setting the host sent, and
        // with `status == PPCP_OK`: the engine's way of saying "you owe an
        // answer". ⛔ `nextEventImported`, never `nextEvent` (E28 / F-S5-3).
        var seen: (id: String, isOn: Bool, owed: Bool, replyTo: UInt64)?
        while let event = device.nextEventImported({ kind, _, imported, status, msg -> Bool in
            guard imported == false, kind == PPCP_EVENT_ACTUATOR_COMMAND,
                  let msg else { return false }
            let replyTo = msg.pointee.env.msg_id
            // ⛔ Trap 4 — through a pointer to `body`, never `msg.pointee.body.x`.
            let mutable = UnsafeMutablePointer(mutating: msg)
            withUnsafeMutablePointer(to: &mutable.pointee.body) { field in
                field.withMemoryRebound(to: ppcp_body_actuator_command.self,
                                        capacity: 1) { command in
                    seen = (ppcpString(command.pointee.actuator_id),
                            command.pointee.setting.has_on && command.pointee.setting.on,
                            status == PPCP_OK,
                            replyTo)
                }
            }
            return true
        }) {
            if event { break }
        }
        let command = try #require(seen)
        #expect(command.id == "act:torch")
        #expect(command.isOn)
        #expect(command.owed,
                "12.1c — PPCP_OK on this event means the embedding owes the answer")
        #expect(command.replyTo != 0, "MSG 1a — an ack correlates by reply_to")

        // 2 — ⭐ **THE ENGINE WROTE NOTHING.** This is the D17 finding inverted:
        // until libppcp L30 an `actuator_command_ack` carrying the REQUESTED
        // setting was already on the control queue at this point, written before
        // any hardware was touched. Nothing is queued now, so 12.1c's "not an
        // echo of the request" is reachable — and MSG 1c's answer is this
        // application's to give.
        #expect(device.pending(.control) == 0,
                "12.1c — a well-formed command is handed over UNANSWERED")

        // 3 — the embedding answers, with the ACHIEVED value.
        //
        // ⭐ **`false` against a request of `true`**, which is the thermal-cutoff
        // case 12.1c exists for and the one an echo cannot express. On the phone
        // this is `AVFoundationCaptureDevice.readTorchState`'s `isTorchActive`
        // read back after the write; here it is supplied directly, because what
        // is under test is that the wire carries what the embedding supplied.
        try device.sendActuatorCommandApplied(actuatorId: "act:torch", isOn: false,
                                              inReplyTo: command.replyTo)
        let answer = try Self.decodeFirst(try device.drain(.control))
        #expect(answer.type == PPCP_MT_ACTUATOR_COMMAND_ACK)
        #expect(answer.verdict == PPCP_ACTUATOR_APPLIED)
        #expect(answer.hasReason == false, "12.1b — reason iff refused")
        #expect(answer.replyTo == command.replyTo, "MSG 1a — correlated, not broadcast")
        #expect(answer.hasState)
        #expect(answer.stateIsOn == false,
                """
                12.1c — `state` is what the Actuator is ACTUALLY doing. The \
                request was `on`; the ack carries the embedding's achieved \
                reading, and an echo would have said `true` here.
                """)
    }

    /// ⛔ **12.1b — the other half of the answer, and it carries no state.**
    /// `ppcp_peer_actuator_command_refused` takes no setting at all, so "a
    /// refusal reports no achieved value" is unconstructible rather than
    /// checked — which is why libppcp L30 is two entry points and not one with
    /// two optional arguments.
    @Test("MSG 12.1b — a refused ack carries the reason and no state")
    func aRefusalCarriesTheReasonAndNoState() throws {
        let device = try DevicePeer(peerId: Self.deviceId, role: .capture)
        try device.hello()
        try device.declare(try PpcpDeclaration(Self.input()))
        _ = try device.drain(.control)

        try device.sendActuatorCommandRefused(actuatorId: "act:torch",
                                              reason: ActuatorRefusalReason
                                                  .thermalLimit.rawValue,
                                              inReplyTo: 4242)
        let answer = try Self.decodeFirst(try device.drain(.control))
        #expect(answer.type == PPCP_MT_ACTUATOR_COMMAND_ACK)
        #expect(answer.verdict == PPCP_ACTUATOR_REFUSED)
        #expect(answer.hasReason)
        #expect(answer.reason == "thermal_limit")
        #expect(answer.hasState == false,
                "12.1b — nothing was applied, so there is no achieved value")
        #expect(answer.replyTo == 4242)

        // 12.1b — `reason` is REQUIRED, and an empty one is refused by the
        // library rather than encoded as an absent field.
        #expect(throws: (any Error).self) {
            try device.sendActuatorCommandRefused(actuatorId: "act:torch",
                                                  reason: "", inReplyTo: 4243)
        }
    }

    /// ⭐ **12.2a — a change with a cause OTHER than a command, and since
    /// libppcp L30 that is ALL it carries.** D17 also sent this after a command
    /// wherever the hardware achieved something other than the setting the
    /// engine had echoed — a correction rather than a confirmation, which is the
    /// only reading under which 12.2a permitted it. The ack now carries the
    /// achieved value itself, so that emission is gone and what is left is the
    /// autonomous path: a thermal cutoff, a local toggle, backgrounding. The
    /// instant proves it — `sinceNs` is when the change was OBSERVED by the
    /// 1 Hz poll, which a commanded change would have no occasion to produce.
    @Test("MSG 12.2 — actuator_state carries the achieved value and its instant")
    func actuatorStateCarriesTheAchievedValue() throws {
        let device = try DevicePeer(peerId: Self.deviceId, role: .capture)
        try device.hello()
        try device.declare(try PpcpDeclaration(Self.input()))
        _ = try device.drain(.control)

        // The light is OUT although the switch was told `on` — the thermal
        // cutoff CB4 names, reported as the state it is actually in.
        try device.sendActuatorState(actuatorId: "act:torch", isOn: false,
                                     sinceNs: 7_000_000_000, timebaseId: Self.timebase)
        let sent = try Self.decodeFirst(try device.drain(.control))
        #expect(sent.type == PPCP_MT_ACTUATOR_STATE)
        #expect(sent.stateIsOn == false)
        #expect(sent.sinceNs == 7_000_000_000)
        #expect(sent.sinceTimebase == Self.timebase)
    }

    /// ⛔ **12.1d, from the far end.** A host may not command an Actuator the
    /// counterpart never declared, and the library refuses to originate one — so
    /// the device never has to.
    @Test("MSG 12.1d — an undeclared actuator is not commandable")
    func anUndeclaredActuatorIsRefusedAtSource() throws {
        let device = try DevicePeer(peerId: Self.deviceId, role: .capture)
        let host = try DevicePeer(peerId: Self.hostId, role: .host, listener: true)
        try device.hello()
        try host.hello()
        _ = try host.feed(try device.drain(.control), on: .control)
        _ = try device.feed(try host.drain(.control), on: .control)
        // ⚠ Declared with NO Actuators — 5.19c's legal case, which is exactly the
        // one 12.1d is about.
        try device.declare(try PpcpDeclaration(Self.input(actuators: [])))
        _ = try host.feed(try device.drain(.control), on: .control)

        host.withHandle { handle in
            var setting = ppcp_actuator_setting()
            #expect(ppcp_actuator_setting_on_off(&setting, true) == PPCP_OK)
            #expect(ppcp_peer_actuator_command(handle, "act:torch", &setting) != PPCP_OK,
                    "12.1d — not in the counterpart's last-known Peer.actuators")
        }
    }

    /// ⛔ **12a — a command from a peer that is not the host, and the engine
    /// still answers this one itself.** It needs no hardware to decide, so it is
    /// refused BEFORE the event is raised: the event arrives with a non-`PPCP_OK`
    /// status, an ack is already on the control queue, and an embedding that
    /// answered anyway would put a second, contradicting Response against one
    /// Request (1a).
    ///
    /// ⭐ This is what `PeerLinkEvent.actuatorCommanded(engineAnswered:)` is read
    /// from, and it is the reason the torch is not touched for such a command:
    /// a peer that may not command must not get the light lit on the way to
    /// being told so.
    @Test("MSG 12a — a non-host command is refused by the engine, not by us")
    func aNonHostCommandIsAnsweredByTheEngine() throws {
        let device = try DevicePeer(peerId: Self.deviceId, role: .capture)
        // ⛔ `role: .capture` on BOTH ends. 12a is checked against the REMOTE
        // role, learned from `hello` and from nowhere else.
        let other = try DevicePeer(peerId: "peer:d19-other", role: .capture,
                                   listener: true)
        try device.hello()
        try other.hello()
        _ = try other.feed(try device.drain(.control), on: .control)
        _ = try device.feed(try other.drain(.control), on: .control)

        try device.declare(try PpcpDeclaration(Self.input()))
        _ = try other.feed(try device.drain(.control), on: .control)

        // ⚠ **Hand-built, and it has to be.** `ppcp_peer_actuator_command`
        // refuses a non-host ORIGINATOR too, so a conformant peer cannot produce
        // this frame at all — which is the point: 12a defends the responder
        // against a peer that is not conformant, and the only way to exercise
        // the responder's half is to be that peer. `ppcp_peer_send` is still C2-
        // and channel-checked; what it skips is the originator's role check.
        try other.withHandle { handle in
            _ = handle
            var message = ppcp_msg()
            #expect(ppcp_msg_init(&message, PPCP_MT_ACTUATOR_COMMAND, 1) == PPCP_OK)
            #expect(ppcp_id_set_z(&message.body.actuator_command.actuator_id,
                                  "act:torch") == PPCP_OK)
            #expect(ppcp_actuator_setting_on_off(&message.body.actuator_command.setting,
                                                 true) == PPCP_OK)
            #expect(throws: Never.self) { try other.send(&message, on: .control) }
        }
        // ⚠ The feed itself reports the refusal, and that is not a test failure:
        // the events it raised on the way to refusing are harvested first.
        _ = try? device.feed(try other.drain(.control), on: .control)

        var owed: Bool?
        while let event = device.nextEventImported({ kind, _, _, status, _ -> Bool in
            guard kind == PPCP_EVENT_ACTUATOR_COMMAND else { return false }
            owed = status == PPCP_OK
            return true
        }) {
            if event { break }
        }
        #expect(owed == false, "12a — already answered; the embedding owes nothing")

        let answer = try Self.decodeFirst(try device.drain(.control))
        #expect(answer.type == PPCP_MT_ACTUATOR_COMMAND_ACK)
        #expect(answer.verdict == PPCP_ACTUATOR_REFUSED)
        #expect(answer.hasReason)
        #expect(answer.hasState == false)
    }

    // MARK: D16 — MSG §5.5 and §5.6

    /// 5.5 / 5.20 — `device_status`, and 5.5b held by shape: an unavailable
    /// Source carries a reason and an available one cannot.
    @Test("MSG 5.5 — device_status carries the source, the reason and the instant")
    func deviceStatusIsWellFormed() throws {
        let device = try DevicePeer(peerId: Self.deviceId, role: .capture)
        try device.hello()
        try device.declare(try PpcpDeclaration(Self.input()))
        _ = try device.drain(.control)

        let sourceId = try #require(
            try PpcpDeclaration(Self.input()).sources.first { $0.kind == "camera" }?.id)
        try device.sendDeviceStatus(SourceStatus(sourceId: sourceId,
                                                 availability: .unavailable(.inUse),
                                                 sinceNs: 3_000_000_000),
                                    timebaseId: Self.timebase)
        let sent = try Self.decodeFirst(try device.drain(.control))
        #expect(sent.type == PPCP_MT_DEVICE_STATUS)
        #expect(sent.sourceId == sourceId)
        #expect(sent.available == false)
        #expect(sent.reason == "in_use")
        #expect(sent.sinceNs == 3_000_000_000)

        // 5.5b — available carries none, and there is no constructor that could
        // give it one.
        try device.sendDeviceStatus(SourceStatus(sourceId: sourceId,
                                                 availability: .available,
                                                 sinceNs: 4_000_000_000),
                                    timebaseId: Self.timebase)
        let back = try Self.decodeFirst(try device.drain(.control))
        #expect(back.available)
        #expect(back.hasReason == false)
    }

    /// ⛔ **5.20d / erratum E64 — `no_source` is not in this vocabulary.** The
    /// event only fires for an already-declared Source, so the value names a case
    /// its own precondition rules out. Asserted, because "we left it out" and "it
    /// was never there" look identical in a diff.
    @Test("CORE 5.20d — no_source is not a device_status reason")
    func noSourceIsNotAReason() {
        #expect(SourceUnavailableReason(rawValue: "no_source") == nil)
        #expect(SourceUnavailableReason.allCases.map(\.rawValue).sorted()
                == ["disconnected", "in_use", "permission_denied",
                    "storage_full", "thermal_limit"])
    }

    /// 5.6 / 5.21 — `buffer_status`, all four fields and no fifth.
    @Test("MSG 5.6 — buffer_status carries the margin and its last discard")
    func bufferStatusIsWellFormed() throws {
        let device = try DevicePeer(peerId: Self.deviceId, role: .capture)
        try device.hello()
        try device.declare(try PpcpDeclaration(Self.input()))
        try device.openSession(PpcpSessionRecord(id: "ses:d16",
                                                 timebaseRef: Self.timebase,
                                                 openedAtNs: 1_000_000_000))
        try device.openStream(PpcpStreamRecord(
            id: "str:video", sessionId: "ses:d16", sourceId: "src:camera:wide",
            kind: PpcpStreamKind.video, profileId: "1920x1080@150",
            timebaseId: Self.timebase, continuity: .shotWindowed,
            openedAtNs: 1_000_000_000))
        _ = try device.drain(.control)

        try device.sendBufferStatus(
            BufferMargin(streamId: "str:video",
                         retainedFromNs: 5_000_000_000,
                         retentionTargetNs: 10_000_000_000,
                         discardedSinceOpen: 7,
                         lastDiscardSinceNs: 4_500_000_000,
                         lastDiscardDurationNs: 500_000_000),
            timebaseId: Self.timebase)
        let sent = try Self.decodeFirst(try device.drain(.control))
        #expect(sent.type == PPCP_MT_BUFFER_STATUS)
        #expect(sent.streamId == "str:video")
        #expect(sent.retainedFromNs == 5_000_000_000)
        #expect(sent.retentionTargetNs == 10_000_000_000)
        #expect(sent.discardedSinceOpen == 7)
        #expect(sent.lastDiscardSinceNs == 4_500_000_000)
        #expect(sent.lastDiscardDurationNs == 500_000_000)
    }

    /// ⛔ **Trap 8 — the histogram does not cross.** `ppcp_buffer_margin` has
    /// four quantities and no bucket array; the assertion is that nothing here
    /// grew one, because the pressure to add it comes back every time somebody
    /// wants a nicer chart. `gapBuckets`/`largestGaps` are receiver-side
    /// aggregation over repeated readings of these four.
    @Test("CORE 5.21 — only the four fields cross, never the ring's histogram")
    func theHistogramDoesNotCross() {
        let margin = BufferMargin(streamId: "str:video", retainedFromNs: 0,
                                  retentionTargetNs: nil, discardedSinceOpen: 0)
        // A compile-time statement as much as a run-time one: if a fifth
        // quantity is ever added, this initialiser stops matching.
        #expect(margin.lastDiscardSinceNs == nil)
        #expect(margin.lastDiscardDurationNs == nil)
        #expect(margin.retentionTargetNs == nil,
                "5.21 — absent is not zero, and a zero target would say the ring holds nothing")
    }

    // MARK: Decoding, through the library

    struct Decoded {
        var type: ppcp_msg_type
        /// `MSG` 1a / `ENC` 5b — what Request this Response answers.
        var replyTo: UInt64 = 0
        var verdict: ppcp_actuator_verdict = PPCP_ACTUATOR_APPLIED
        var hasReason = false
        var reason = ""
        var hasState = false
        var stateIsOn: Bool?
        var sinceNs: Int64?
        var sinceTimebase = ""
        var sourceId = ""
        var available = false
        var streamId = ""
        var retainedFromNs: Int64?
        var retentionTargetNs: Int64?
        var discardedSinceOpen: UInt64 = 0
        var lastDiscardSinceNs: Int64?
        var lastDiscardDurationNs: Int64?
    }

    /// ⛔ Decoded with `ppcp_msg_decode` and never with a parser written here — a
    /// second decoder in a test would agree with the encoder it is checking.
    static func decodeFirst(_ frames: Data) throws -> Decoded {
        try frames.withUnsafeBytes { raw -> Decoded in
            var header = ppcp_frame_header()
            var payload: UnsafePointer<UInt8>?
            var consumed = 0
            try check(ppcp_frame_read(raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                                      &header, &payload, &consumed))
            let bytes = MemoryLayout<ppcp_msg>.stride
            let scratch = UnsafeMutableRawPointer.allocate(
                byteCount: bytes, alignment: MemoryLayout<ppcp_msg>.alignment)
            scratch.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
            defer { scratch.deallocate() }
            let message = scratch.assumingMemoryBound(to: ppcp_msg.self)
            try check(ppcp_msg_decode(payload, Int(header.payload_len),
                                      ppcp_cbor_limits_for_channel(header.channel),
                                      nil, message))

            var decoded = Decoded(type: message.pointee.type)
            decoded.replyTo = message.pointee.env.has_reply_to
                ? message.pointee.env.reply_to : 0
            // ⛔ Trap 4 — one pointer to `body`, never a read of the 48 KB union.
            withUnsafeMutablePointer(to: &message.pointee.body) { body in
                switch message.pointee.type {
                case PPCP_MT_ACTUATOR_COMMAND_ACK:
                    body.withMemoryRebound(to: ppcp_body_actuator_command_ack.self,
                                           capacity: 1) { ack in
                        decoded.verdict = ack.pointee.verdict
                        decoded.hasReason = ack.pointee.has_reason
                        decoded.reason = ppcpString(ack.pointee.reason)
                        decoded.hasState = ack.pointee.has_state
                        decoded.stateIsOn = ack.pointee.state.has_on
                            ? ack.pointee.state.on : nil
                    }
                case PPCP_MT_ACTUATOR_STATE:
                    body.withMemoryRebound(to: ppcp_body_actuator_state.self,
                                           capacity: 1) { state in
                        decoded.stateIsOn = state.pointee.state.has_on
                            ? state.pointee.state.on : nil
                        decoded.sinceNs = state.pointee.since.ns
                        decoded.sinceTimebase = ppcpString(state.pointee.since.tb)
                    }
                case PPCP_MT_DEVICE_STATUS:
                    body.withMemoryRebound(to: ppcp_body_device_status.self,
                                           capacity: 1) { status in
                        decoded.sourceId = ppcpString(status.pointee.status.source_id)
                        decoded.available = status.pointee.status.available
                        decoded.hasReason = status.pointee.status.has_reason
                        decoded.reason = ppcpString(status.pointee.status.reason)
                        decoded.sinceNs = status.pointee.status.since.ns
                        decoded.sinceTimebase = ppcpString(status.pointee.status.since.tb)
                    }
                case PPCP_MT_BUFFER_STATUS:
                    body.withMemoryRebound(to: ppcp_body_buffer_status.self,
                                           capacity: 1) { status in
                        let margin = status.pointee.margin
                        decoded.streamId = ppcpString(margin.stream_id)
                        decoded.retainedFromNs = margin.retained_from.ns
                        decoded.retentionTargetNs = margin.has_retention_target
                            ? margin.retention_target_ns : nil
                        decoded.discardedSinceOpen = margin.discarded_since_open
                        decoded.lastDiscardSinceNs = margin.has_last_discard
                            ? margin.last_discard_since.ns : nil
                        decoded.lastDiscardDurationNs = margin.has_last_discard
                            ? margin.last_discard_duration_ns : nil
                    }
                default:
                    break
                }
            }
            return decoded
        }
    }

}
