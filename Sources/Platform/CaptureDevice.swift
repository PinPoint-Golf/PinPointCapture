//  CaptureDevice.swift
//  The port surface for capture: the abstract interface a platform must
//  implement, and the factory that builds one.
//
//  REQ-PORT-2: the port surface is an explicitly enumerated, deliberately small
//  documented artefact — not an emergent property of the code. This file *is*
//  that artefact for capture. Adding a method here is a decision.
//
//  REQ-PORT-4: abstract base plus factory from the start, consistent with the
//  standing rule applied to all device and product-specific code in PinPointStudio.
//
//  ⚠ REQ-PORT-3: no platform type crosses this boundary. Everything in and out is
//  a Core type. `AVCaptureDevice`, `AVCaptureDevice.Format`, `CMSampleBuffer` and
//  their equivalents stay behind implementations of this protocol.

import Foundation
import CaptureCore

/// Why a capture device could not be opened or armed, in platform-neutral terms.
public enum CaptureDeviceError: Error, Sendable, Equatable {
    case noPhysicalCameraFound
    case permissionDenied
    case modeNotSupported
    case configurationFailed(String)
}

/// A capture device. One physical camera, its microphone, and the locks that
/// keep its measurements comparable across a session.
///
/// ⚠ The 150 fps sample path must never run through an actor or through
/// `async`/`await`. Implementations keep the frame callback on an explicit
/// dispatch queue: actor hops and ARC traffic inside a 6.7 ms budget are exactly
/// how REQ-CAP-3 ends up reporting drops.
public protocol CaptureDevice: AnyObject, Sendable {

    /// REQ-FPS-1 / REQ-CAP-1. Enumerate what the hardware actually offers.
    ///
    /// ⛔ Never assume from a spec sheet. This is the only source for A1's
    /// capability card, and a device that will not clear the host's ingest gate
    /// must be able to say so honestly.
    func enumerateCapability() throws -> DeviceCapability

    /// Bring the session up, locked and settled, without retaining (`warm`).
    ///
    /// REQ-STATE-2: warm exists so arming incurs no AE/AF settling penalty.
    /// Rebuilding a capture session costs roughly a second plus settling, and the
    /// first shot after a cold re-arm is exactly the one not to lose.
    func warmUp(mode: VideoMode) async throws

    /// Tear the session down (`cold`).
    func goCold()

    /// REQ-BUF-1 — start filling the rolling buffer. `CaptureState.armed` is the
    /// application's word for this; ⛔ that word does not cross the wire (5.15a).
    ///
    /// ⚠ **Adding this to the port surface was a decision** (REQ-PORT-2), and it
    /// is the same one already argued for `extractClip` below. The ring was
    /// reachable only from the concrete iOS class, so `extractClip` was a
    /// question nothing above the platform layer could ever make answer `present`
    /// — the getter was on the port and the switch that fills it was not.
    ///
    /// ⛔ **Throwing is how arming stays honest.** A device that cannot retain
    /// must not reach `armed`: §9.2 makes capture the thing that must not be
    /// quietly wrong, and an `armed` peer retaining nothing is the exact failure
    /// `AppModel.arm` already refuses for the warm-up half.
    func startRetaining(mode: VideoMode) throws

    /// Stop retaining and drop what is held, with its files.
    ///
    /// ⚠ Idempotent, and ⛔ **must be called before `goCold`** — `goCold` removes
    /// the session's outputs, and a writer left open across that teardown is one
    /// nothing will ever close.
    func stopRetaining()

    /// What the ring did during the current retention, counted rather than
    /// inferred.
    ///
    /// ⚠ **On the port because the exit criterion is a measurement.** REQ-FPS-2
    /// and REQ-TIME-5 both say the realised rate comes from timestamp deltas and
    /// never from a frame count over a wall clock; `maxInterArrivalNs` is the
    /// field that distinguishes a steady 150 fps from an average one, and a
    /// diagnostic bundle (E10.1) that omits it cannot tell a maintainer which of
    /// the two they had.
    var ringStats: RingStats { get }

    /// REQ-CAP-2. Run the self-test and report what the device sustained.
    ///
    /// ⚠ REQ-ENC-4: a figure obtained from cold is not a measurement. The
    /// duration must be long enough to be honest about thermal behaviour.
    /// ⚠ REQ-FPS-2 / REQ-TIME-5: derive the rate from realised timestamp deltas,
    /// never from a frame count over a wall-clock interval, and never from the
    /// value the platform reports back. Frames drop; indices lie.
    func measureSustainedRate(mode: VideoMode,
                              duration: TimeInterval) async throws -> MeasuredCapability

    /// Current thermal state (REQ-RES-3).
    var thermalState: ThermalState { get }

    /// Storage headroom, for A7 and for the arm-time floor (REQ-OFF-2).
    func storageHeadroom(forMode mode: VideoMode) -> StorageHeadroom

    /// Everything the peer declaration needs, assembled from the real capture
    /// stack and the model's device-profile entry (D2).
    ///
    /// ⚠ **Adding this here was a decision, and the reason is REQ-PORT-2.** The
    /// declaration was reachable only on the concrete iOS class, so nothing above
    /// the platform layer could build one — which meant D3's bundle writer could
    /// be tested and could not be *used*. An Android port replaces this method
    /// and nothing else; everything in and out is a Core type.
    func ppcpDeclarationInput(peerId: String,
                              viewpoint: PpcpViewpoint?) throws -> PpcpDeclarationInput

    // ─────────────────────────────────────────────────────────────────────────
    //  The torch (`CORE` §5.19, `PPCP-MSG` §12)
    //
    //  ⚠ **Three methods, and adding them was a decision** (REQ-PORT-2). They
    //  are here rather than on `AVFoundationCaptureDevice` for the reason
    //  `startRetaining` and `extractClip` give above and it is the same reason
    //  each time: the thing that owns the hardware is the concrete class, and a
    //  capability nothing above the platform layer can reach is a capability the
    //  application cannot declare, command or report. §12 needs all three of
    //  those, from Core, and `AVCaptureDevice` may not cross this line
    //  (REQ-PORT-3) — `hasTorch`, `torchMode` and `isTorchActive` stay behind
    //  it and only `TorchCapability`, `TorchRequest`, `TorchOutcome` and
    //  `TorchChange` come through. An Android port replaces these three methods
    //  and nothing else.
    //
    //  ⛔ Three rather than one, because they answer three different questions
    //  at three different times: what to *declare* (5.19a, before any command
    //  exists), what a command *achieved* (12.1c, synchronously), and what
    //  changed with *nobody commanding* (12.2a, on a tick). Collapsing any two
    //  would put a wire obligation on the wrong clock.
    // ─────────────────────────────────────────────────────────────────────────

    /// `CORE` 5.19a — what this device would declare in `Peer.actuators`.
    ///
    /// ⛔ **Answerable before `warmUp`, and it has to be.** The declaration is
    /// built at connect time from a hardware walk, not from a running capture
    /// session, so this must not depend on there being one. A device with no
    /// torch — a front-camera-only setup, or a simulator with no camera at all —
    /// answers `.absent`, and 5.19c makes that a full participant rather than an
    /// error. ⛔ It never throws for the same reason.
    func torchCapability() -> TorchCapability

    /// `PPCP-MSG` 12.1 — apply an on/off command and report what the hardware is
    /// **actually** doing afterwards.
    ///
    /// ⛔ **Returns the achieved state, never `Void` and never an echo of the
    /// request** (12.1c). A `Void` setter would make the ack a guess, and trap 3
    /// is the standing lesson that a queued or accepted command is not an
    /// achieved one — it has been fixed twice already, for `arm` and for
    /// `stream_open`, whose comment reads *"we had the comment without the
    /// code."* The read-back is what stops it being written a third time.
    ///
    /// ⛔ **Does not throw, and that is deliberate** — the same argument
    /// `extractClip` makes for `absent`. A refusal is a *result* here: 12.1b
    /// requires exactly one reason from an open registry, and `TorchOutcome`
    /// carries it as a value so D15 can put it straight on the wire. A thrown
    /// `Error` would have to be mapped back into that vocabulary at the call
    /// site, which is where the vocabulary would drift.
    func setTorch(_ request: TorchRequest) -> TorchOutcome

    /// `PPCP-MSG` 12.2a — a state change **no acknowledged command caused**,
    /// since the last time this was asked.
    ///
    /// ⛔ **Consuming.** It reports a change once and re-baselines, so a caller
    /// polling it on a tick emits one `actuator_state` per change rather than
    /// one per tick — which is 12.2a's own distinction and the same
    /// on-change-not-per-tick rule D16's statistics emitters follow.
    ///
    /// ⛔ An applied command re-baselines too, so a change the peer just
    /// acknowledged never surfaces here: 12.2a says `actuator_state` "is not
    /// sent to confirm a command the requester already has an acknowledgement
    /// for", and a port that reported both would make that the caller's problem
    /// to filter — with only the caller's guess about which change was which.
    ///
    /// ⚠ Polled, not observed. See the ⚠ on `TorchChange`: this codebase has no
    /// KVO anywhere and `waitForConvergence` says so where it polls instead.
    func torchChangeSincePoll() -> TorchChange?

    // ─────────────────────────────────────────────────────────────────────────
    //  Per-Source availability (`CORE` §5.20, `PPCP-MSG` §5.5)
    // ─────────────────────────────────────────────────────────────────────────

    /// `CORE` 5.20 — what the **hardware** says about each Source this device
    /// declares, keyed by the `source_id` on the wire.
    ///
    /// ⛔ **Hardware only, and the split is the point.** `in_use` and
    /// `disconnected` are things only an `AVCaptureDevice` can answer;
    /// `permission_denied`, `thermal_limit` and `storage_full` are already read
    /// elsewhere in this application and would be read twice, from two clocks,
    /// if they were answered here as well. The caller overlays those.
    ///
    /// ⛔ **Answerable before `warmUp`** — 5.20b turns on `DeviceStatus` being
    /// reachable earlier than `Readiness`, and a method that needed a running
    /// session would answer the `Readiness` question instead. It walks the
    /// discovery session, exactly as `torchCapability()` does and for the same
    /// reason.
    ///
    /// ⚠ **Keyed on `source_id`, never on a device's `uniqueID`.** The wire
    /// names Sources and a receiver joins on that name; anything else is a
    /// second identity for the same thing.
    ///
    /// ⚠ A Source this device cannot read a hardware answer for is **absent from
    /// the dictionary** rather than reported `available`. Absence is "not known"
    /// (`CORE` §5.1) and the caller says nothing about it.
    func sourceHardwareAvailability() -> [String: SourceAvailability]

    /// `CORE` §5.11.2 — take preview frames off the capture path, or stop.
    ///
    /// ⚠ Defaulted, because a device with no sample callback has nothing to tap
    /// and saying so is better than every stub carrying an empty method. ⛔ The
    /// default is a no-op **and preview then simply does not happen**: 5.11i
    /// makes preview the first thing to lose, so its absence is never an error.
    func attachPreviewTap(_ tap: PreviewFrameTap?)

    /// `CORE` 8.4b — the retained window around an interval, as a Core value.
    ///
    /// ⚠ **Adding this to the port surface was a decision** (REQ-PORT-2). The
    /// ring lives in `Sources/Platform/Capture/RingBufferRecorder.swift` and was
    /// reachable only from that concrete class, so the one thing D5's pipeline
    /// needs from the capture stack — "give me the frames around this `t0`" —
    /// could not be asked for through the port. `ClipExtraction` is a Core type
    /// in and a Core type out; an Android port replaces this method and nothing
    /// else.
    ///
    /// ⛔ **`absent` is a result, not a failure** (I10, 8.4b). An implementation
    /// that is not retaining answers `outside_buffer` and the Shot still exists.
    /// It never invents frames and it never throws.
    func extractClip(_ requestedNs: Range<Int64>) -> ClipExtraction

    /// Everything a shot-anchored Capture needs from the capture stack around a
    /// `t0` — the extraction, the measured exposure, the intrinsics the
    /// connection delivered, a thermal timeline over the interval, and a lazy
    /// provider for the clip's bytes.
    ///
    /// ⚠ **Adding this was a decision** (REQ-PORT-2), and the reason is that
    /// `extractClip` above answers only half the question. A `Capture` needs
    /// four more things and none of them was reachable through the port, so
    /// `RecordingSession` filled the gap with a hardcoded
    /// `.lockedConstant(0)` exposure, no intrinsics and no payload — an
    /// announced Capture with a fabricated number in the one field 5.8d calls
    /// mandatory. One method that returns what the builder consumes is what
    /// stops that recurring.
    ///
    /// ⛔ **Does not throw.** 8.4b/I10: a ring holding nothing answers an
    /// `absent` extraction, which is a *result* and leaves the Shot intact.
    /// Only `RetainedClip.payload` throws, and only where a backing that ought
    /// to have bytes cannot produce them.
    ///
    /// ⛔ **`RetainedClip.payload` must be consumed while retention is still
    /// live.** It reads the rolling buffer, so a caller that stops retaining —
    /// or simply waits ten seconds — gets nothing back. `RecordingSession`
    /// closes this by materialising the bytes to `clips/` the moment the clip is
    /// extracted and handing on a file-backed provider; any other caller must do
    /// the same or consume immediately. ⚠ Not a defect in the laziness, which
    /// `ENC` 7c requires — a defect in assuming the ring is a store.
    ///
    /// ⚠ `RetainedClip` is a Core type in and a Core type out; an Android port
    /// replaces this method and nothing else.
    func retainedClip(aroundNs t0: Int64, preNs: Int64, postNs: Int64) -> RetainedClip

    /// `CORE` 7.3d — platform interruptions, reported as **completed** gaps.
    ///
    /// ⛔ The handler is called when an interruption *ends*, because the gap is
    /// the deliverable and a gap with no end is not one. Recovering is the half
    /// everybody implements; recording the gap is the half that stops a consumer
    /// interpolating across it (5.14b).
    ///
    /// ⚠ Here rather than on the concrete class so `AVCaptureSession` stays
    /// behind the port: the session is what has to be observed, and it must not
    /// become reachable from a view model (REQ-PORT-3).
    func observeInterruptions(_ handler: @escaping @MainActor (InterruptionRecord) -> Void)
}

/// Builds the capture device for the running platform.
///
/// One `create` call, so a second platform is a new case here and nothing else.
public enum CaptureDeviceFactory {
    public static func create() -> any CaptureDevice {
        #if canImport(AVFoundation) && (os(iOS) || os(tvOS))
        return AVFoundationCaptureDevice()
        #else
        #error("No CaptureDevice implementation for this platform.")
        #endif
    }
}


public extension CaptureDevice {
    /// A device that does not deliver sample buffers has no preview to give.
    func attachPreviewTap(_ tap: PreviewFrameTap?) {}
}
