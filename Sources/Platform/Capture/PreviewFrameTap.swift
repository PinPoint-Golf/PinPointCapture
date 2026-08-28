//  PreviewFrameTap.swift
//  Frames for a human to look at, taken off the capture path without costing it
//  anything.
//
//  ⛔ **Off the EXISTING sample callback, and a second output is not an option.**
//  A second `AVCaptureVideoDataOutput` is legal since iOS 16, but it starts
//  `AVCaptureSession.hardwareCost` metering and `> 1.0` refuses to start the
//  session outright — see `capability-spike.md` §2a. E1.1 rejected one for that
//  reason and preview must not quietly reintroduce it, because the failure mode
//  is not a bad preview: it is a session that will not run at all.
//
//  ⛔ **`offer` runs on the capture queue and must cost almost nothing.** At
//  150 fps the budget for the whole callback is 6.7 ms and the ring has first
//  claim on it. So `offer` does two integer comparisons and, at most once every
//  hundred milliseconds, one `CVPixelBuffer` retain and a `DispatchQueue.async`.
//  Everything expensive — downscale, JPEG, the wire — happens on this file's own
//  queue at `.utility`.
//
//  ⛔ **Dropped, never queued** (5.11j). A preview frame that cannot be produced
//  promptly is discarded and accounted for as an `absent` segment with
//  `absent_reason: not_retained` (5.11c3) — never as a gap, which would report a
//  dropout this device did not have. And 5.11i puts preview first in the order of
//  things to lose: preview degrades before transfer, transfer before capture.
//
//  Spec: `CORE` §5.11.1, §5.11.2 (5.11c3, 5.11f–m), §9.2; `ENC` 2.1d.

import Foundation
import AVFoundation
import CoreImage
import CaptureCore

/// Turns a fraction of the capture stream into small JPEGs, off the frame path.
public final class PreviewFrameTap: @unchecked Sendable {

    /// ~10 fps. ⚠ A *request* (5.11k): where a capture Stream is open on the same
    /// Source, what is actually produced is derived from the active capture
    /// profile, and `AchievedSummary` reports what was really made.
    public static let intervalNs: Int64 = 100_000_000

    /// 5.11m's declared frame — small, and the same numbers the preview profile
    /// declares, because a Stream that named one size and produced another would
    /// be the overclaim I5 exists to prevent.
    public static let width = 640
    public static let height = 360

    /// ⛔ Deliberately below the capture queue. A preview frame is the cheapest
    /// thing in the session to lose (5.11i), so it must never be the reason a
    /// captured one is late.
    private let queue = DispatchQueue(label: "org.pinpointstudio.capture.preview",
                                      qos: .utility)
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let deliver: @Sendable (Data, Int64) -> Void

    /// Owned by the **capture** queue, like `routing` and `recorder` are. Read
    /// and written only inside `offer`, which is what makes them free.
    private var nextDueNs: Int64 = 0
    private var inFlight = false
    /// ⚠ Counted BEFORE the due/in-flight guard, because the question this
    /// answers is "is the camera delivering anything at all" — which is a
    /// different question from "did we take it".
    private var offered = 0
    private var encodeFailures = 0

    /// - Parameter deliver: the JPEG and the instant it ends at, on this tap's
    ///   own queue. ⚠ The embedding hops from there to the peer; nothing on the
    ///   capture path ever touches the link.
    public init(deliver: @escaping @Sendable (Data, Int64) -> Void) {
        self.deliver = deliver
    }

    /// Called on the capture queue for every retained frame.
    ///
    /// ⛔ **Two comparisons and a return, in the ordinary case.** Nine frames in
    /// ten at 100 fps leave here without touching anything.
    ///
    /// ⚠ `inFlight` is the drop rule: a frame offered while the previous one is
    /// still being encoded is discarded rather than queued behind it. That is
    /// 5.11j, and it is also what stops a slow encode turning into unbounded
    /// memory on the capture path.
    public func offer(_ sampleBuffer: CMSampleBuffer, atNs: Int64) {
        offered &+= 1
        if offered == 1 { print("[preview] tap: first sample off the capture path") }
        guard atNs >= nextDueNs, inFlight == false else { return }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        nextDueNs = atNs + Self.intervalNs
        inFlight = true
        queue.async { [weak self] in
            guard let self else { return }
            let jpeg = encode(pixels)
            if let jpeg {
                deliver(jpeg, atNs)
            } else {
                self.encodeFailures += 1
                if self.encodeFailures == 1 {
                    print("[preview] tap: JPEG encode returned nil — no picture leaves here")
                }
            }
            // ⚠ Cleared on the capture queue, because that is the only place it
            // is read. A bool written from two queues is a race that shows up as
            // a preview that stops after one frame.
            self.clearInFlight()
        }
    }

    /// Set by the embedding so `inFlight` is cleared where it is read.
    public var scheduleOnCaptureQueue: (@Sendable (@escaping @Sendable () -> Void) -> Void)?

    private func clearInFlight() {
        guard let scheduleOnCaptureQueue else {
            inFlight = false
            return
        }
        scheduleOnCaptureQueue { [weak self] in self?.inFlight = false }
    }

    /// Downscale and JPEG, on this tap's own queue.
    ///
    /// ⚠ `CIContext` is created once: building one per frame is the single most
    /// expensive thing available in this file.
    private func encode(_ pixels: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixels)
        let scaleX = CGFloat(Self.width) / image.extent.width
        let scaleY = CGFloat(Self.height) / image.extent.height
        let scale = min(scaleX, scaleY)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let colours = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.jpegRepresentation(of: scaled, colorSpace: colours,
                                          options: [kCGImageDestinationLossyCompressionQuality
                                                        as CIImageRepresentationOption: 0.6])
    }
}
