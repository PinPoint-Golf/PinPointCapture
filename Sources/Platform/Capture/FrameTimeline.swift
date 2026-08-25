//  FrameTimeline.swift
//  What one frame can honestly be said to carry, read off a `CMSampleBuffer`.
//
//  ⚠ This file, and files like it, are the ONLY place `AVFoundation` and
//  `CoreMedia` types may appear. What leaves it is `CaptureCore` values
//  (REQ-PORT-3).
//
//  ⛔ **`CORE` 5.8h is the reason this file exists rather than a line inside the
//  recorder.** "A peer MUST NOT declare `per_frame` unless the platform attaches
//  the value to the sample. Declaring the stronger provenance is the same error
//  as reporting a cold sample as sustained (I31)." So the question "what may this
//  device claim about its exposure numbers?" is answered once, here, against what
//  the platform actually attaches — and the answer is written down with what was
//  checked, so the next person does not re-decide it optimistically.
//
//  **What was checked (iOS 26/27 SDK, August 2026).** The documented
//  `kCMSampleBufferAttachmentKey_*` set carries no exposure duration and no ISO.
//  `AVCaptureVideoDataOutput` delivers neither: `AVCaptureDevice.exposureDuration`
//  and `.iso` are *device* properties, read at the moment the frame arrives, and
//  that is a `sampled` value by 5.8's own definition. `AVCapturePhotoOutput`
//  attaches exposure to its metadata; the video path does not, and one path's
//  behaviour is not evidence about the other.
//
//  So this application declares:
//
//    exposure locked (REQ-OPT-3, the shipping case)   `locked_constant`, scalar
//    exposure not locked                              `sampled`, per-frame array
//    ever                                             never `per_frame`
//
//  ⚠ Intrinsics ARE attached — `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`
//  is a real per-frame attachment when `isCameraIntrinsicMatrixDeliveryEnabled`
//  is set (REQ-OPT-7) — which is exactly why the two fields get different
//  treatment. The distinction is not a policy; it is what the platform does.
//
//  Spec: `CORE` §5.8 (5.8d, 5.8e, 5.8f, 5.8h), §6.1; `ENC` §4.1; `CONF` CT-S7 (3).

import AVFoundation
import CoreMedia
import Foundation
import CaptureCore
import simd

/// Per-frame facts accumulated on the sample queue.
///
/// ⚠ **No allocation beyond the arrays, no actor hop, no `await`.** At 150 fps
/// the budget is 6.7 ms; anything on this path that suspends is the reason
/// REQ-CAP-3 reports drops the hardware did not have.
final class FrameTimeline {

    private(set) var timestampsNs: [Int64] = []
    private(set) var exposureNs: [Int64] = []
    private(set) var isoValues: [Int64] = []
    private(set) var intrinsics: [PpcpMatrix3] = []
    private(set) var droppedFrames = 0
    /// True once at least one frame arrived carrying an intrinsic matrix.
    private(set) var intrinsicsWereDelivered = false

    func reset() {
        timestampsNs.removeAll(keepingCapacity: true)
        exposureNs.removeAll(keepingCapacity: true)
        isoValues.removeAll(keepingCapacity: true)
        intrinsics.removeAll(keepingCapacity: true)
        droppedFrames = 0
    }

    /// Take everything collected so far and clear, for a fragment boundary.
    func drain() -> FrameTimeline.Batch {
        let batch = Batch(timestampsNs: timestampsNs, exposureNs: exposureNs,
                          iso: isoValues, intrinsics: intrinsics,
                          droppedFrames: droppedFrames)
        reset()
        return batch
    }

    struct Batch {
        var timestampsNs: [Int64] = []
        var exposureNs: [Int64] = []
        var iso: [Int64] = []
        var intrinsics: [PpcpMatrix3] = []
        var droppedFrames = 0
    }

    /// Record one delivered frame.
    ///
    /// - Parameter device: read for `exposureDuration` and `iso`. ⛔ That read is
    ///   what makes the provenance `sampled` and not `per_frame` — the value
    ///   describes the device at the instant the frame was handed over, not the
    ///   frame.
    func observe(_ sampleBuffer: CMSampleBuffer, device: AVCaptureDevice?) {
        // ⛔ The PRESENTATION timestamp, in the host time clock — the clock
        // `tb:hosttime` names (see the finding at the top of `PpcpTimebases`).
        // Never a frame index and never a wall-clock read (I2, 5.8e).
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        timestampsNs.append(Self.nanoseconds(pts))

        if let device {
            exposureNs.append(Self.nanoseconds(device.exposureDuration))
            // ISO is a `Float` here and an int64 on the wire (`CORE` 5.7/5.8).
            //
            // ⛔ **AND IT IS NOT ALWAYS A NUMBER, WHICH CRASHED THE APP ON A
            // PHONE** (25 August 2026). `Int64(_:)` **traps** on NaN and on
            // infinity, this line runs on the frame path at 240 fps, and the
            // value belongs to AVFoundation rather than to us — it reads NaN
            // while the device is being reconfigured, which is exactly what
            // starting the microphone's `.record` audio session does to a
            // running capture session. `arm()` starts the microphone *after*
            // `startRetaining`, so the two overlap by construction.
            //
            // ⚠ `nanoseconds(_:)` above already guards the same class of read
            // (`isValid`, `isNumeric`) — the CMTime half was protected and the
            // Float half was not.
            //
            // ⚠ **Skipped rather than substituted.** A short series is already
            // the honest outcome: `CaptureBuilder` emits `iso` only where it is
            // exactly as long as `frames.ns` and otherwise omits it, which 5.8f
            // makes "unknown". A zero here would be a *measurement* of an ISO
            // this camera never had.
            let iso = device.iso
            if iso.isFinite { isoValues.append(Int64(iso.rounded())) }
        }
        if let matrix = Self.intrinsicMatrix(of: sampleBuffer) {
            intrinsics.append(matrix)
            intrinsicsWereDelivered = true
        }
    }

    func observeDrop() { droppedFrames += 1 }

    /// `CORE` 5.8 — what this device may honestly claim about its exposure
    /// numbers, given whether the lock held.
    ///
    /// ⛔ `per_frame` is not reachable from here and that is the point (5.8h).
    static func exposure(_ batch: Batch, lockedNs: Int64?) -> ExposureObservation {
        // Under the lock this application takes (REQ-OPT-3) there is one value,
        // and the scalar form is both smaller and truer — 5.8f: a scalar "means
        // the value was constant for every frame".
        if let lockedNs { return .lockedConstant(lockedNs) }
        return .sampledPerFrame(batch.exposureNs)
    }

    /// `CORE` 5.7 `intrinsics: per_frame` — what the connection actually
    /// delivered.
    ///
    /// ⚠ Focus is locked for the session (REQ-OPT-2), so a session's matrices are
    /// normally identical and the scalar form says so honestly. They are compared
    /// rather than assumed: a device that switched physical lenses would change
    /// them, which is the failure REQ-OPT-5 exists to prevent and not one to
    /// paper over here.
    static func intrinsics(_ batch: Batch) -> IntrinsicsObservation? {
        guard let first = batch.intrinsics.first else { return nil }
        if batch.intrinsics.allSatisfy({ $0 == first }) { return .constant(first) }
        return .perFrame(batch.intrinsics)
    }

    // MARK: Platform reads

    static func nanoseconds(_ time: CMTime) -> Int64 {
        guard time.isValid, time.isNumeric else { return 0 }
        return Int64((CMTimeGetSeconds(time) * 1_000_000_000).rounded())
    }

    /// `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` — a real per-frame
    /// attachment, present when `isCameraIntrinsicMatrixDeliveryEnabled` is set
    /// (REQ-OPT-7).
    ///
    /// ⚠ **Transposed on the way out.** `matrix_float3x3` is column-major and
    /// `ENC` §4.1 says row-major. A `Matrix3` that is silently a transpose looks
    /// plausible — the diagonal survives — and puts the principal point in the
    /// wrong place.
    static func intrinsicMatrix(of sampleBuffer: CMSampleBuffer) -> PpcpMatrix3? {
        guard let attachment = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            attachmentModeOut: nil) as? Data,
            attachment.count >= MemoryLayout<matrix_float3x3>.size
        else { return nil }

        let matrix: matrix_float3x3 = attachment.withUnsafeBytes { raw in
            raw.loadUnaligned(as: matrix_float3x3.self)
        }
        return rowMajor(matrix)
    }

    /// `matrix_float3x3` is **column-major** and `ENC` §4.1 is row-major.
    ///
    /// ⛔ Split out so it can be asserted directly. A `Matrix3` that is silently a
    /// transpose looks plausible — the diagonal survives, so `fx` and `fy` are
    /// right — and puts the principal point in the wrong place, which is a
    /// calibration that agrees with itself and with nobody.
    static func rowMajor(_ matrix: matrix_float3x3) -> PpcpMatrix3? {
        var values: [Double] = []
        values.reserveCapacity(9)
        for row in 0..<3 {
            for column in 0..<3 {
                values.append(Double(matrix[column][row]))
            }
        }
        return PpcpMatrix3(values)
    }
}
