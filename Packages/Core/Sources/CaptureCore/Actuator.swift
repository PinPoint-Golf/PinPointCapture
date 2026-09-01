//  Actuator.swift
//  `CORE` §5.19 — a commandable device that produces no samples, in
//  platform-neutral terms. On this phone there is exactly one: the torch.
//
//  ⚠ REQ-PORT-11, and it is the same argument `DeviceCapability.swift` makes at
//  the top of itself: this vocabulary is PROTOCOL vocabulary. An
//  `AVCaptureDevice`'s `hasTorch`/`isTorchAvailable`/`isTorchActive` and an
//  Android `CameraManager.setTorchMode` callback must both reduce to these
//  types, and nothing here may name a platform concept. The `AVCaptureDevice`
//  that answers these questions stays behind `CaptureDevice` (REQ-PORT-3) —
//  `LayerPurityTests` fails the build if it does not.
//
//  ⛔ **A Source is observed; an Actuator is commanded, and 5.19b makes the two
//  kind registries disjoint.** The torch is therefore NOT a `SourcePlan` and
//  carries no `CaptureProfile`: nothing about format, rate or calibration
//  applies to something that is switched rather than sampled.
//
//  Spec: `CORE` §5.19; `PPCP-MSG` §12, 12.1b, 12.1c, 12.1c1, 12.2a. Decisions:
//  CB1 (on/off, not level), CB4 (the achieved-differs case is asynchronous),
//  CB7 (invariants held by shape, not by a runtime check).

import Foundation

// MARK: - What shape a command takes

/// `CORE` §5.19 `control` — what shape a command to an Actuator takes.
///
/// ⛔ **`level` is deliberately absent, and its absence is the enforcement.**
/// CB1 fixes the phone's torch at `on_off`, and I39 says a command carries `on`
/// **or** `level`, never neither and never both. The house pattern for an
/// invariant like that is CB7's: hold it by shape rather than by a runtime
/// check, exactly as `ppcp_readiness_settled` / `_not_settled` does. With one
/// case here and a `TorchRequest` that can only be `on` or `off`, there is no
/// way in this application to *construct* the malformed pair.
///
/// ⚠ `control` is an open registry (5.19 — "for the same reason `Source.kind`
/// is"), so adding `level` later is additive and needs no protocol change. It
/// needs a second request type, not a second field on this one.
public enum ActuatorControl: String, Sendable, Hashable, CaseIterable {
    case onOff = "on_off"
}

/// `CORE` §5.19 `kind` — an open registry. Only the one this device owns is
/// spelled, and it is spelled once.
///
/// ⚠ Here rather than as a literal at the declaration site, for the reason
/// `Lens.opticsName` gives: two things need the string and they must agree, and
/// one spelling in one place is what stops the class of defect found in
/// `profile_id` (#102).
public enum ActuatorKind {
    /// The phone's onboard light — CR-02's motivating case.
    public static let torch = "torch"
}

// MARK: - The declaration (CORE 5.19)

/// One Actuator, as this peer declares it.
///
/// ⚠ **5.19a: declared before any `actuator_command` names it.** The list is
/// built at declaration time from what the hardware actually has, never from a
/// spec sheet — the same rule REQ-FPS-1 puts on capture enumeration, and for the
/// same reason.
///
/// ⚠ **5.19c: a peer declaring no Actuators participates fully.** A
/// front-camera-only setup, a phone with no rear flash, and the simulator (which
/// has no camera at all) each produce an **empty** list. That is a correct
/// declaration and never an error.
public struct PpcpActuatorDeclaration: Sendable, Hashable {
    /// `CORE` 5.19 `id` — unique within the owning peer.
    ///
    /// ⚠ Shaped like the Source ids (`src:camera:wide`) but on its own prefix,
    /// because 5.19b makes the two namespaces disjoint and a reader should not
    /// have to know the kind registry to tell which it is holding.
    public let id: String
    /// `CORE` 5.19 `kind` — open registry. See `ActuatorKind`.
    public let kind: String
    /// `CORE` 5.19 `control` — what shape a command takes.
    public let control: ActuatorControl
    /// `CORE` 5.19 `label` — human-readable, informational. ⛔ Nothing is ever
    /// inferred from it, on the same terms as `Peer.product` (5.2c, I19).
    public let label: String?

    public init(id: String, kind: String, control: ActuatorControl,
                label: String? = nil) {
        self.id = id
        self.kind = kind
        self.control = control
        self.label = label
    }

    /// The id this application gives its one Actuator.
    ///
    /// ⚠ Not per-camera. The torch is a property of the phone's rear assembly,
    /// not of a lens: wide, ultra-wide and telephoto share one light, so a
    /// per-Source id would declare three Actuators for one piece of hardware and
    /// give a host three switches that fight over it.
    public static let torchId = "act:torch"
}

// MARK: - Capability

/// What the platform says about the torch, before anyone commands it.
///
/// ⛔ **Three separate facts, and collapsing them is how a host ends up with a
/// switch that does nothing.** `present` is a property of the hardware and never
/// changes; `available` is momentary and goes false when the light is too hot to
/// use; `supportsOnOff` is whether the mode this application commands is one the
/// driver accepts. `DeviceCapability`'s own header makes the identical argument
/// about claimed-vs-measured-vs-achieved, and this is the same mistake in a
/// smaller place.
public struct TorchCapability: Sendable, Hashable {
    /// The hardware has a torch at all.
    public let present: Bool
    /// The torch is usable **right now**. ⚠ Momentary: a platform takes this
    /// away while the light is overheated and gives it back when it cools.
    public let available: Bool
    /// The driver accepts the on/off control CB1 declares.
    public let supportsOnOff: Bool

    public init(present: Bool, available: Bool, supportsOnOff: Bool) {
        self.present = present
        self.available = available
        self.supportsOnOff = supportsOnOff
    }

    /// What a device with no torch says. ⚠ 5.19c — a *result*, not a failure.
    public static let absent = TorchCapability(present: false, available: false,
                                               supportsOnOff: false)

    /// Whether this torch is declared in `Peer.actuators`.
    ///
    /// ⛔ **`available` is deliberately not part of this.** Availability is
    /// momentary and the declaration is not: withdrawing an Actuator because the
    /// light is briefly hot would make 12.1d ("MUST NOT command an Actuator not
    /// in the target's last-known `Peer.actuators`") race a thermal reading, and
    /// the honest answer to a command in that window is a `refused` /
    /// `thermal_limit` ack — which is a thing the protocol has, unlike a
    /// declaration that flickers.
    public var isDeclarable: Bool { present && supportsOnOff }

    /// The declaration this capability makes, or `nil` where there is nothing to
    /// declare (5.19c).
    public var actuatorDeclaration: PpcpActuatorDeclaration? {
        guard isDeclarable else { return nil }
        return PpcpActuatorDeclaration(id: PpcpActuatorDeclaration.torchId,
                                       kind: ActuatorKind.torch,
                                       control: .onOff,
                                       label: "Torch")
    }
}

// MARK: - The command

/// `PPCP-MSG` 12.1 `actuator_command` for an `on_off` Actuator.
///
/// ⛔ Two cases and no payload, so I39's "never neither, never both" is not
/// something this application can get wrong (CB7).
public enum TorchRequest: Sendable, Hashable {
    case on
    case off

    public var wantsOn: Bool { self == .on }
}

// MARK: - The achieved state

/// `PPCP-MSG` 12.1c — what the torch is **actually** doing, never an echo of the
/// request.
///
/// ⛔ **`on` is the light emitting, not the switch position, and the difference
/// is the whole point of the type.** A platform can hold a torch's mode at "on"
/// while the hardware has cut the light for heat; 12.1c says the wire carries
/// what it is doing. `modeIsOn` is kept beside it so a diagnostic can say
/// *which* of the two happened, and it does not go on the wire.
///
/// ⚠ CB4: the two disagreeing is not the clamp case 12.1c's own prose describes
/// — iOS's level setter throws rather than clamping, so that case does not occur
/// on this platform. It is a thermal cutoff, it arrives asynchronously, and
/// `actuator_state` (12.2a) is the only channel that carries it. That is what
/// `TorchChange` below is for.
public struct TorchState: Sendable, Hashable {
    /// 12.1c — the achieved value. The light is emitting.
    public let on: Bool
    /// What the mode is set to. ⛔ Diagnostic only; never the wire's `on`.
    public let modeIsOn: Bool

    public init(on: Bool, modeIsOn: Bool) {
        self.on = on
        self.modeIsOn = modeIsOn
    }

    public static let off = TorchState(on: false, modeIsOn: false)

    /// The hardware is not doing what its mode says — a cutoff, or a light that
    /// has not lit yet.
    public var achievedDiffersFromMode: Bool { on != modeIsOn }
}

// MARK: - The verdict

/// `PPCP-MSG` 12.1b — `actuator_command_ack.reason`, an open registry whose
/// five current members are named in the clause.
///
/// ⚠ Raw values are the wire spellings and are what D15 will put on it. They are
/// not display strings.
public enum ActuatorRefusalReason: String, Sendable, Hashable, CaseIterable {
    /// No such Actuator on this peer, or nothing to command it through.
    case noActuator = "no_actuator"
    /// Something else holds the hardware.
    case busy = "busy"
    /// The platform has taken the light away to cool down.
    case thermalLimit = "thermal_limit"
    /// The user has not granted what commanding it needs.
    case permissionDenied = "permission_denied"
    /// The hardware is there and will not do this.
    case unsupported = "unsupported"
}

/// `PPCP-MSG` 12.1 `actuator_command_ack`'s verdict, before it is a message.
///
/// ⛔ **12.1b — "`reason` is present if and only if `verdict: refused`" — is held
/// by this being an enum with payloads rather than a struct with two optionals**
/// (CB7). A `refused` with no reason and an `applied` with one are both
/// unconstructible, so D15 has no check to forget and no check to write.
///
/// ⛔ Likewise 12.1c1/E63: an `applied` verdict *always* carries a `TorchState`,
/// so `state: {}` — the malformed shape both teams found independently in review
/// round 1 — cannot be produced here either.
public enum TorchOutcome: Sendable, Hashable {
    /// The command was applied; the payload is what the torch is now doing.
    case applied(TorchState)
    /// The command was refused, with the one reason 12.1b requires.
    case refused(ActuatorRefusalReason)

    /// The achieved state where there is one. ⚠ `nil` on a refusal is not "off"
    /// — a refused command changed nothing and the caller must not claim it did.
    public var achieved: TorchState? {
        if case .applied(let state) = self { return state }
        return nil
    }

    public var refusalReason: ActuatorRefusalReason? {
        if case .refused(let reason) = self { return reason }
        return nil
    }
}

// MARK: - An autonomous change (12.2a)

/// A change in Actuator state that **no acknowledged command caused** — a
/// thermal cutoff, or a local toggle.
///
/// ⛔ 12.2a: `actuator_state` "is not sent to confirm a command the requester
/// already has an acknowledgement for". So this is only ever produced for a
/// change the peer did not itself just apply; the implementation re-baselines on
/// every applied command precisely so a commanded change never surfaces here.
///
/// ⚠ **Observed by polling, and that is a decision** (plan §7). This codebase
/// has no KVO anywhere — `AVFoundationCaptureDevice.waitForConvergence` says so
/// where it polls `MachClock` instead — and a torch state read is two boolean
/// property reads, which is cheaper than the 1 Hz health tick's existing
/// `storageHeadroom` call. Introducing the first KVO in the codebase to watch a
/// switch would be a large exception for a small thing.
public struct TorchChange: Sendable, Hashable {
    public let state: TorchState
    /// `PPCP-MSG` 12.2 `since: Instant` — when the change was **observed**, on
    /// the capture timebase.
    ///
    /// ⚠ Observed, not occurred, and the difference is a poll interval. It is
    /// honest at the resolution the tick gives and is not claimed to be better:
    /// `CORE` §5.1's last paragraph is that absence means not known, and an
    /// invented sub-tick instant would be worse than a coarse true one.
    public let observedAtNs: Int64

    public init(state: TorchState, observedAtNs: Int64) {
        self.state = state
        self.observedAtNs = observedAtNs
    }
}
