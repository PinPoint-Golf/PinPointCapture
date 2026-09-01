//  ActuatorTests.swift
//  `CORE` §5.19 and `PPCP-MSG` §12, on the half that lives in Core.
//
//  ⚠ **What these can and cannot assert.** The types are neutral values, so
//  every shape invariant CB7 asks to be held *by shape* is checkable here, on the
//  host, in milliseconds. What is not checkable here is the readback: whether
//  `isTorchActive` really reports a light that is out needs a phone with a torch
//  and is the D14 gate in the plan's §8 table ("the torch toggles on a real
//  iPhone"), not a unit test.
//
//  ⛔ These are not the CT-I39 assertions. I39 is `libppcp`'s (L29) and its
//  paired half needs a simulator that can declare Actuators.

import Foundation
import Testing
@testable import CaptureCore

@Suite("Actuator — CORE §5.19, PPCP-MSG §12")
struct ActuatorTests {

    // MARK: 5.19 — the declaration

    @Test("A torch declares control: on_off (CB1)")
    func torchDeclaresOnOff() throws {
        let capability = TorchCapability(present: true, available: true,
                                         supportsOnOff: true)
        let declaration = try #require(capability.actuatorDeclaration)
        #expect(declaration.control == .onOff)
        #expect(declaration.kind == ActuatorKind.torch)
        #expect(declaration.id == PpcpActuatorDeclaration.torchId)
    }

    /// ⛔ CB1 by shape, not by a check. `level` is not a case, so an on/off peer
    /// cannot describe a level actuator even by mistake — the enforcement I39
    /// asks for, in CB7's house style.
    @Test("control has exactly one member, and it is on_off")
    func controlRegistryIsOnOffOnly() {
        #expect(ActuatorControl.allCases == [.onOff])
        #expect(ActuatorControl.onOff.rawValue == "on_off")
    }

    /// ⚠ 5.19b — the two registries are disjoint. `torch` must not collide with
    /// anything `Source.kind` uses, or a reader keying on kind sees one entity.
    @Test("Actuator kind is disjoint from the Source kinds this device declares")
    func actuatorKindIsDisjointFromSourceKinds() {
        let sourceKinds = ["camera", "microphone", "imu"]
        #expect(sourceKinds.contains(ActuatorKind.torch) == false)
    }

    /// ⚠ 5.19c — "a peer declaring no Actuators participates fully". A phone
    /// with no rear flash, a front-camera-only setup and the simulator all land
    /// here, and the answer is an empty list rather than an error.
    @Test("No torch declares nothing, and that is not a failure (5.19c)")
    func absentTorchDeclaresNothing() {
        #expect(TorchCapability.absent.isDeclarable == false)
        #expect(TorchCapability.absent.actuatorDeclaration == nil)

        let input = Self.declarationInput(actuators: [])
        #expect(input.actuators.isEmpty)
    }

    /// ⛔ The declaration must not flicker with a momentary reading. A torch the
    /// platform has withdrawn for heat is still a declared Actuator; the honest
    /// answer to a command in that window is 12.1b's `thermal_limit` refusal.
    @Test("A momentarily unavailable torch is still declared")
    func unavailableTorchIsStillDeclared() {
        let hot = TorchCapability(present: true, available: false, supportsOnOff: true)
        #expect(hot.isDeclarable)
        #expect(hot.actuatorDeclaration != nil)
    }

    /// A driver that will not take the mode CB1 commands has nothing to declare:
    /// declaring it would give a host a switch that answers `unsupported` every
    /// time it is used.
    @Test("A torch that does not support on/off is not declared")
    func torchWithoutOnOffIsNotDeclared() {
        let odd = TorchCapability(present: true, available: true, supportsOnOff: false)
        #expect(odd.isDeclarable == false)
        #expect(odd.actuatorDeclaration == nil)
    }

    @Test("The declaration input carries the enumerated Actuators")
    func declarationInputCarriesActuators() throws {
        let torch = try #require(TorchCapability(present: true, available: true,
                                                  supportsOnOff: true)
            .actuatorDeclaration)
        let input = Self.declarationInput(actuators: [torch])
        #expect(input.actuators.count == 1)
        #expect(input.actuators.first?.control == .onOff)
    }

    // MARK: 12.1 — the command and its ack

    /// ⛔ I39 by shape. Two cases, no payload: an application holding a
    /// `TorchRequest` cannot express "neither" or "both".
    @Test("A command is on or off, and carries no level")
    func commandIsOnOrOff() {
        #expect(TorchRequest.on.wantsOn)
        #expect(TorchRequest.off.wantsOn == false)
    }

    /// ⛔ 12.1b — "`reason` is present if and only if `verdict: refused`". Held
    /// by `TorchOutcome` being an enum with payloads, so both malformed shapes
    /// are unconstructible rather than merely untested.
    @Test("A verdict carries a reason iff it is a refusal (12.1b)")
    func reasonPresentIffRefused() {
        let applied = TorchOutcome.applied(TorchState(on: true, modeIsOn: true))
        #expect(applied.refusalReason == nil)
        #expect(applied.achieved != nil)

        let refused = TorchOutcome.refused(.thermalLimit)
        #expect(refused.refusalReason == .thermalLimit)
        // ⛔ Not `.off`. A refused command changed nothing and the caller must
        // not read a state out of it.
        #expect(refused.achieved == nil)
    }

    /// ⛔ 12.1c1 / erratum E63 — the malformed shape both teams found
    /// independently in review round 1. An `applied` ack whose `state` carries
    /// neither field satisfied the original schema and contradicted 12.1c's own
    /// prose. Here `applied` cannot exist without a `TorchState`, and a
    /// `TorchState` cannot exist without its `on`.
    @Test("An applied verdict always carries a state (12.1c1, E63)")
    func appliedAlwaysCarriesState() {
        let applied = TorchOutcome.applied(.off)
        #expect(applied.achieved?.on == false)
    }

    /// ⚠ 12.1b's registry, in the wire's spellings. These are what D15 puts on
    /// the wire; a display string here would be found only by a counterpart.
    @Test("The refusal vocabulary is 12.1b's, spelled as the wire spells it")
    func refusalVocabularyMatchesTheClause() {
        #expect(Set(ActuatorRefusalReason.allCases.map(\.rawValue))
            == ["no_actuator", "busy", "thermal_limit", "permission_denied",
                "unsupported"])
    }

    /// ⛔ 12.1c — the achieved value is not the request. The type keeps the two
    /// readings apart so a thermal cutoff is expressible; a single `on` would
    /// have made the ack an echo whatever the implementation did.
    @Test("Achieved state is distinguishable from the switch position (12.1c)")
    func achievedIsNotAnEcho() {
        let cutOff = TorchState(on: false, modeIsOn: true)
        #expect(cutOff.on == false)
        #expect(cutOff.achievedDiffersFromMode)

        let lit = TorchState(on: true, modeIsOn: true)
        #expect(lit.achievedDiffersFromMode == false)
    }

    // MARK: 12.2 — an autonomous change

    /// ⚠ CB4: the case that actually occurs on this platform is asynchronous
    /// drift, and `actuator_state` is the only channel that carries it. The
    /// change value has to carry its own instant (12.2 `since`) because the tick
    /// that observed it is not the moment it happened.
    @Test("An autonomous change carries a state and an instant")
    func changeCarriesStateAndInstant() {
        let change = TorchChange(state: TorchState(on: false, modeIsOn: true),
                                 observedAtNs: 1_234_567_890)
        #expect(change.state.achievedDiffersFromMode)
        #expect(change.observedAtNs == 1_234_567_890)
        // Equatable, because the poll compares before with after.
        #expect(change == TorchChange(state: TorchState(on: false, modeIsOn: true),
                                      observedAtNs: 1_234_567_890))
    }

    // MARK: Fixtures

    static func declarationInput(actuators: [PpcpActuatorDeclaration])
        -> PpcpDeclarationInput {
        PpcpDeclarationInput(
            peerId: "peer:test",
            profiles: PpcpProfileSet.device,
            timebases: [PpcpTimebaseDeclaration(id: "tb:hosttime", kind: .monotonic,
                                                epochStable: true, resolutionNs: 1)],
            captureTimebaseId: "tb:hosttime",
            capability: DeviceCapability(modelIdentifier: "iPhone17,3",
                                         modelName: "iPhone 16",
                                         claimed: []),
            timing: PpcpDeviceTimingProfile(
                frameStartToExposureOffsetNs: 0,
                offsetProvenance: .assumed,
                geometry: [PpcpGeometryEntry(
                    readout: .assumedFractionOfFrameInterval(1.0),
                    direction: .topToBottom)]),
            clipCodec: "hevc",
            actuators: actuators)
    }
}
