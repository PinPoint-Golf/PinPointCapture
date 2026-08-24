//  RetainedClip.swift
//  E1.2 / E1.3 — everything a shot-anchored Capture needs from the capture
//  stack, in one value.
//
//  ⚠ **This type exists because three closures had drifted out of step with the
//  builder they feed.** `DetectAndMint` took `extractVideo`, `videoExposure` and
//  `videoPayload`; `CaptureBuilder.shotCapture` takes an extraction, an
//  exposure, an intrinsics observation and a thermal timeline. The two lists
//  stopped matching, and the consequence was not theoretical: the intrinsics
//  `FrameTimeline` collects were dropped on the floor for want of a closure to
//  carry them, and the exposure a real device measures was replaced by a
//  hardcoded `.lockedConstant(0)` that nothing noticed for months. One value
//  that mirrors the builder cannot drift the same way.
//
//  Spec: `CORE` §5.8, §5.14, §8.4; `ENC` §7c; requirements REQ-CLIP-1,
//  REQ-META-1, REQ-STANDALONE-3.

import Foundation

/// What the capture stack retained around one `t0`.
public struct RetainedClip: Sendable {

    /// Which frames were there, and what interval they realised.
    public var extraction: ClipExtraction

    /// `CORE` 5.8d — mandatory on a camera Capture that has frames, because
    /// I17's canonical-instant conversion is impossible without it.
    ///
    /// ⛔ Not a placeholder. The value this replaced was `.lockedConstant(0)`,
    /// which is a number rather than a measurement and would have converted
    /// every instant on the wire by the wrong amount.
    public var exposure: ExposureObservation

    /// `CORE` §5.8 `intrinsics`, where the connection delivered them.
    ///
    /// ⚠ `nil` — not an empty series — where none were delivered. `ENC` 4.1d
    /// distinguishes the constant and per-frame forms by the type of the FIRST
    /// element, so an empty array has nothing to branch on and is malformed.
    public var intrinsics: IntrinsicsObservation?

    /// `CORE` §5.8 — a timeline **over the Capture's interval**, not one reading
    /// taken at the end.
    public var thermal: [PpcpThermalPoint]

    /// The clip's bytes, fetched only when the payload is written.
    ///
    /// ⛔ **Lazy, and it must stay lazy.** `ENC` 7c holds payloads until after
    /// the manifest, and the capability spike puts a fifty-shot session at
    /// ~1.4 GB — materialising every clip at announce time would hold the
    /// session in memory. `nil` for an `absent` Capture, which by 5.8d has no
    /// payload to provide.
    public var payload: (@Sendable () throws -> Data)?

    public init(extraction: ClipExtraction,
                exposure: ExposureObservation,
                intrinsics: IntrinsicsObservation? = nil,
                thermal: [PpcpThermalPoint] = [],
                payload: (@Sendable () throws -> Data)? = nil) {
        self.extraction = extraction
        self.exposure = exposure
        self.intrinsics = intrinsics
        self.thermal = thermal
        self.payload = payload
    }

    /// Nothing was retained around this interval — 8.4b's `outside_buffer`.
    ///
    /// ⛔ A **result**, not a failure (I10). The Shot still exists and is still
    /// recorded; it simply has no Capture behind it.
    public static func nothingRetained(
        _ requestedNs: Range<Int64>,
        reason: String = PpcpAbsentReason.outsideBuffer) -> RetainedClip {
        RetainedClip(extraction: .nothingRetained(requestedNs, reason: reason),
                     exposure: .noExposure)
    }
}
