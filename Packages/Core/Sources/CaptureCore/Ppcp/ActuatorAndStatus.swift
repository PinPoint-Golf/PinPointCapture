//  ActuatorAndStatus.swift
//  `PPCP-MSG` §5.5, §5.6 and §12 — the four things CR-02 added that this peer
//  *originates*: `device_status`, `buffer_status`, `actuator_command_ack` and
//  `actuator_state`.
//
//  ⭐ **`actuator_command_ack` IS here now, and that is the D17 finding closed.**
//  D17 recorded that 12.1c — *"`state` reports what the Actuator is actually
//  doing … not an echo of the request"* — was unsatisfiable on this stack:
//  `peer_on_actuator_command` built the ack itself, with `state = b->setting`,
//  and queued it before `PPCP_EVENT_ACTUATOR_COMMAND` reached this application.
//  No hardware had been touched when it was written, and there was no entry
//  point to answer with instead. Both application teams found it independently.
//
//  libppcp L30 fixed it. A well-formed, declared, host-originated command is now
//  **handed over unanswered**: the event arrives with `ppcp_event.status ==
//  PPCP_OK`, meaning *you owe an answer*, and `sendActuatorCommandApplied` /
//  `sendActuatorCommandRefused` below are the two ways to give one. `MSG` 1c
//  makes answering a MUST, so exactly one of them runs per such event.
//
//  ⛔ **What this application must NOT answer**, because the engine still does
//  and answers it *before* raising the event: 12.1d (undeclared Actuator →
//  `error`/`not_declared`), 12.1a/I39 (a shape the Actuator's declared `control`
//  does not name → `error`/`malformed`), and 12a (a non-host sender →
//  `refused`). Each arrives with a non-`PPCP_OK` `status`, which is the only
//  thing that tells them apart from the one this peer owes.
//
//  ⛔ **And `actuator_state` is no longer part of answering a command.** While
//  the engine echoed the request, `HostLinkSession` corrected the record with
//  `actuator_state` wherever the achieved value differed from what was acked.
//  The ack now carries the achieved value itself, so that correction would be
//  exactly the confirmation 12.2a forbids — *"not sent to confirm a command the
//  requester already has an `actuator_command_ack` for"*. What is left for it is
//  the whole of what 12.2a describes: a change with a cause **other than** a
//  command, which on this device is the thermal cutoff / local-toggle path the
//  1 Hz poll observes.
//
//  ⛔ **`device_status` and `buffer_status` are pushed on `readiness`'s
//  discipline** (5.5a, 5.6c): emitted when the thing they report CHANGES, never
//  polled and never on a cadence. The 1 Hz tick is how the change is *noticed*;
//  it is not how often the message goes.
//
//  Spec: `PPCP-MSG` §5.5, §5.6, §12.1, §12.2; `CORE` §5.19–5.21. Plan D15, D16.

import Foundation
import CPPCP

// MARK: - CORE §5.20 — DeviceStatus

/// `CORE` 5.20 `reason` — why a Source cannot be used right now.
///
/// ⛔ **`no_source` is deliberately absent** (5.20d as corrected by erratum
/// E64). `device_status` names an already-declared Source, so "there is no such
/// Source" is a state its own precondition rules out; a value for it would only
/// ever have been used wrongly.
///
/// ⚠ Raw values are the wire spellings from an open registry (5.20), not display
/// strings.
public enum SourceUnavailableReason: String, Sendable, Hashable, CaseIterable {
    /// Something else holds the hardware.
    case inUse = "in_use"
    /// The hardware went away.
    case disconnected = "disconnected"
    /// The user has not granted what using it needs.
    case permissionDenied = "permission_denied"
    /// The platform has taken it away to cool down.
    case thermalLimit = "thermal_limit"
    /// There is nowhere left to put what it would produce.
    case storageFull = "storage_full"
}

/// `CORE` 5.20 — "can this Source be used right now", as a measurement.
///
/// ⛔ **5.5b is held by shape** (CB7): `available` and `reason` cannot be set
/// independently, so an available Source carrying a reason and an unavailable
/// one carrying none are both unconstructible. This is the same move
/// `ppcp_device_status_available` / `_unavailable` makes in the library and the
/// same move `ppcp_readiness_settled` / `_not_settled` made before it.
///
/// ⛔ **5.20b — it does not supersede `Readiness` and neither is derivable from
/// the other.** `Readiness` answers "will this Source produce when armed";
/// this answers "can it be used at all", and it has to be answerable *before*
/// an arm or it is answering the first question again.
public enum SourceAvailability: Sendable, Hashable {
    case available
    case unavailable(SourceUnavailableReason)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var reason: SourceUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// One Source's status, with the instant `available` last changed.
///
/// ⚠ **`since` is when it CHANGED, not when it was read** (5.20). A tick that
/// observes the same value re-stamps nothing, which is what makes the field
/// mean anything at all.
public struct SourceStatus: Sendable, Hashable {
    public let sourceId: String
    public let availability: SourceAvailability
    public let sinceNs: Int64

    public init(sourceId: String, availability: SourceAvailability, sinceNs: Int64) {
        self.sourceId = sourceId
        self.availability = availability
        self.sinceNs = sinceNs
    }
}

// MARK: - CORE §5.21 — BufferMargin

/// `CORE` 5.21 — a `shot_windowed` Stream's **current standing margin**.
///
/// ⛔ **Only these four quantities cross** (review Q4). `gapBuckets` and
/// `largestGaps` — the ring's own histogram — are receiver-side aggregation over
/// repeated readings and are reconstructible from them; putting them on the wire
/// would be sending a derived thing beside the thing it derives from.
///
/// ⛔ **5.21b: this is not a failed request's `absent_reason`.** It says what the
/// ring holds now; why one particular `capture_request` could not be served is
/// that request's answer to give.
public struct BufferMargin: Sendable, Hashable {
    public let streamId: String
    /// The oldest instant still retained, on the Stream's timebase.
    public let retainedFromNs: Int64
    /// What the ring is *trying* to hold, as a duration.
    public let retentionTargetNs: Int64?
    /// ⛔ **5.21a — only what NEVER became part of any Capture, and only since
    /// this Stream opened** (trap 7). A frame later extracted into a `partial`
    /// Capture is that Capture's `achieved_summary` to account for and is not
    /// counted twice, which is why encoder-busy drops are excluded here.
    public let discardedSinceOpen: UInt64
    /// The most recent span the ring dropped. One statement, so both halves
    /// travel together or neither does.
    public let lastDiscardSinceNs: Int64?
    public let lastDiscardDurationNs: Int64?

    public init(streamId: String, retainedFromNs: Int64, retentionTargetNs: Int64?,
                discardedSinceOpen: UInt64,
                lastDiscardSinceNs: Int64? = nil,
                lastDiscardDurationNs: Int64? = nil) {
        self.streamId = streamId
        self.retainedFromNs = retainedFromNs
        self.retentionTargetNs = retentionTargetNs
        self.discardedSinceOpen = discardedSinceOpen
        self.lastDiscardSinceNs = lastDiscardSinceNs
        self.lastDiscardDurationNs = lastDiscardDurationNs
    }
}

// MARK: - The senders

public extension DevicePeer {

    /// `PPCP-MSG` 5.5 — a Source became usable, or stopped being usable.
    ///
    /// ⛔ **Emitted on change and unprompted** (5.5a). There is no request that
    /// asks for one; the engine checks 5.5c — that this peer actually declared
    /// the Source — before a byte is queued.
    ///
    /// ⚠ `sinceNs` is on `timebaseId`, which for this device is the capture
    /// timebase. A bare number would leave the receiver converting from a clock
    /// it had assumed (`CORE` 5.1, `ENC` 4.1a).
    func sendDeviceStatus(_ status: SourceStatus,
                          timebaseId: String) throws {
        let peer = try handleForLive()
        var since = ppcp_instant()
        try check(ppcp_instant_make_z(&since, timebaseId, status.sinceNs))
        var value = ppcp_device_status()
        switch status.availability {
        case .available:
            try check(ppcp_device_status_available(&value, status.sourceId, &since))
        case .unavailable(let reason):
            try check(ppcp_device_status_unavailable(&value, status.sourceId,
                                                     reason.rawValue, &since))
        }
        try check(ppcp_device_status_validate(&value))
        try check(ppcp_peer_device_status(peer, &value))
    }

    /// `PPCP-MSG` 5.6 — the ring's standing margin on one `shot_windowed`
    /// Stream.
    ///
    /// ⛔ **`shot_windowed` only** (5.21c / 5.6a). A `continuous` Stream has no
    /// ring to have a margin in; the engine checks the Stream it was opened as.
    func sendBufferStatus(_ margin: BufferMargin, timebaseId: String) throws {
        let peer = try handleForLive()
        var retainedFrom = ppcp_instant()
        try check(ppcp_instant_make_z(&retainedFrom, timebaseId, margin.retainedFromNs))
        var value = ppcp_buffer_margin()
        try check(ppcp_buffer_margin_make(&value, margin.streamId, &retainedFrom,
                                          margin.discardedSinceOpen))
        if let target = margin.retentionTargetNs {
            try check(ppcp_buffer_margin_set_retention_target(&value, target))
        }
        // ⚠ Both halves or neither — `last_discard` is one statement, and the
        // library's setter takes them together for exactly that reason.
        if let sinceNs = margin.lastDiscardSinceNs,
           let durationNs = margin.lastDiscardDurationNs {
            var since = ppcp_instant()
            try check(ppcp_instant_make_z(&since, timebaseId, sinceNs))
            try check(ppcp_buffer_margin_set_last_discard(&value, &since, durationNs))
        }
        try check(ppcp_buffer_margin_validate(&value))
        try check(ppcp_peer_buffer_status(peer, &value))
    }

    /// `PPCP-MSG` 12.1c — **the answer this peer owes**, applied, carrying what
    /// the Actuator is ACTUALLY doing.
    ///
    /// - Parameter isOn: 12.1c's `state`, and ⛔ **the ACHIEVED reading, never
    ///   the request and never the mode.** On this device it is
    ///   `TorchState.on`, which `AVFoundationCaptureDevice.readTorchState` takes
    ///   from `isTorchActive` after the write; `torchMode` — the switch — is
    ///   `TorchState.modeIsOn` and is diagnostic only. The two differ exactly
    ///   when the platform has cut the light for heat, which is the case 12.1c
    ///   exists for.
    ///
    /// ⛔ **Answering is a MUST** (`MSG` 1c). Since libppcp L30 the engine writes
    /// nothing for a well-formed, declared, host-originated command, so silence
    /// here is nonconformance rather than latency.
    ///
    /// ⚠ `inReplyTo` is the command's `msg_id` off the event, not a fresh one:
    /// 1a matches a Response to its Request by `reply_to` and by nothing else.
    func sendActuatorCommandApplied(actuatorId: String, isOn: Bool,
                                    inReplyTo: UInt64) throws {
        let peer = try handleForLive()
        var achieved = ppcp_actuator_setting()
        // ⛔ CB1/I39 — `_on_off` and no `_make`. This peer's one Actuator is
        // `control: on_off`, and the library re-checks the achieved shape
        // against the DECLARED control before a byte is queued, so a driver
        // reporting the wrong shape is refused here rather than on the wire.
        try check(ppcp_actuator_setting_on_off(&achieved, isOn))
        try check(ppcp_peer_actuator_command_applied(peer, actuatorId, &achieved,
                                                     inReplyTo))
    }

    /// `PPCP-MSG` 12.1b — the answer this peer owes, refused.
    ///
    /// ⛔ **No `state`, and it is unconstructible rather than omitted.** Nothing
    /// was applied, so there is no achieved value to report; the library's two
    /// entry points are two precisely so a refusal cannot carry one and an
    /// `applied` cannot lack one.
    ///
    /// - Parameter reason: REQUIRED, from 12.1b's open registry — `no_actuator`,
    ///   `busy`, `thermal_limit`, `permission_denied`, `unsupported`. Carried as
    ///   `ActuatorRefusalReason.rawValue`; the library refuses an empty one.
    func sendActuatorCommandRefused(actuatorId: String, reason: String,
                                    inReplyTo: UInt64) throws {
        let peer = try handleForLive()
        try check(ppcp_peer_actuator_command_refused(peer, actuatorId, reason,
                                                     inReplyTo))
    }

    /// `PPCP-MSG` 12.2 — an Actuator's state, for a change **no acknowledged
    /// command caused**.
    ///
    /// ⛔ **Not a confirmation** (12.2a). It "is not sent to confirm a command
    /// the requester already has an `actuator_command_ack` for", so a caller
    /// that emitted one after every applied command would be sending the wrong
    /// message on the right occasion. ⭐ **Nor is it a correction any more.**
    /// While the engine echoed the request there was a record to correct, and
    /// CB4 accepted this as the channel for it; L30 moved the achieved value
    /// onto the ack itself, so the only caller left is the autonomous one — the
    /// 1 Hz poll that notices a thermal cutoff or a local toggle.
    ///
    /// - Parameter isOn: 12.1's `on`. ⛔ CB1/I39: this peer's one Actuator is
    ///   `control: on_off`, so the setting is built by
    ///   `ppcp_actuator_setting_on_off` and the `level` shape is not reachable
    ///   from here. There is no `ppcp_actuator_setting_make` to reach it with.
    func sendActuatorState(actuatorId: String, isOn: Bool,
                           sinceNs: Int64, timebaseId: String) throws {
        let peer = try handleForLive()
        var setting = ppcp_actuator_setting()
        try check(ppcp_actuator_setting_on_off(&setting, isOn))
        var since = ppcp_instant()
        try check(ppcp_instant_make_z(&since, timebaseId, sinceNs))
        try check(ppcp_peer_actuator_state(peer, actuatorId, &setting, &since))
    }
}
