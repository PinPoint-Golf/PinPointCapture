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
    func warmUp(mode: VideoMode) throws

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
    /// `HostlessRecordingSession` filled the gap with a hardcoded
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
