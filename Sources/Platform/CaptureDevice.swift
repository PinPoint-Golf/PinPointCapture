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
