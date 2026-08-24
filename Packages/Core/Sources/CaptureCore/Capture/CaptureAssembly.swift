//  CaptureAssembly.swift
//  Turning what the ring extracted into the two halves the protocol carries: an
//  `AchievedSummary` on `capture_announce` and an `AchievedFrames` with the
//  payload.
//
//  ⛔ **The honest-provenance rule is a constructor here, not a check.** 5.8h is a
//  MUST NOT — a peer must not declare `per_frame` unless the platform attaches
//  the value to the sample, and "declaring the stronger provenance is the same
//  error as reporting a cold sample as sustained (I31)". `ExposureObservation`
//  has one case per honest answer and each case carries the shape that goes with
//  it, so `per_frame` with a scalar and `locked_constant` with a varying array
//  are both unrepresentable. On this platform `AVCaptureVideoDataOutput` attaches
//  no exposure to a `CMSampleBuffer`, so the first case is unreachable from the
//  iOS capture path and the code says why.
//
//  Spec: `CORE` §5.8 (5.8d–5.8j), §5.14, §6.1, §8.4; `CONF` CT-I17, CT-I30,
//  CT-I31, CT-S1 assertion 6, CT-S7 (3).

import Foundation

// MARK: - What the platform can honestly say about exposure

/// `CORE` §5.8 `exposure_ns` + `exposure_provenance`, as one value.
///
/// ⚠ Each case fixes both the provenance token and the wire form, because the
/// pair is what 5.8h is about. Splitting them into two parameters is what lets a
/// caller claim `per_frame` for a number it sampled off the device.
public enum ExposureObservation: Sendable, Hashable {

    /// `per_frame` — the value the capture pipeline attached to **that** frame.
    ///
    /// ⛔ Only where the platform really attaches it. Nothing in this
    /// application's iOS path produces this case today, and a future one must
    /// come with the attachment key it read.
    case attachedPerFrame([Int64])

    /// `sampled` — a device-level exposure property, read once per frame.
    ///
    /// Exact while exposure is locked, approximate otherwise. 5.8i leaves
    /// "is that good enough" to the consumer (I14).
    case sampledPerFrame([Int64])

    /// `locked_constant` — one value, because exposure was locked and was not
    /// observed to change (REQ-OPT-3).
    ///
    /// ⚠ **This is the case the shipping product uses**, which is why CT-S1
    /// assertion 6 exists: "the scalar form and an equivalent constant array
    /// produce identical canonical instants … a conversion test that exercises
    /// only the varying-exposure path does not test what ships."
    case lockedConstant(Int64)

    public var provenance: PpcpExposureProvenance {
        switch self {
        case .attachedPerFrame: .perFrame
        case .sampledPerFrame: .sampled
        case .lockedConstant: .lockedConstant
        }
    }

    public var values: PpcpPerFrame<Int64> {
        switch self {
        case .attachedPerFrame(let v), .sampledPerFrame(let v): .perFrame(v)
        case .lockedConstant(let v): .constant(v)
        }
    }

    /// The samples, for `AchievedSummary.exposure_ns`'s `{min,max,median}`.
    var samples: [Int64] {
        switch self {
        case .attachedPerFrame(let v), .sampledPerFrame(let v): v
        case .lockedConstant(let v): [v]
        }
    }
}

/// `CORE` §5.8 `intrinsics`, where the profile declares `intrinsics: per_frame`.
///
/// ⚠ `ENC` 4.1d's exception lives on this field: both forms are CBOR arrays, so
/// they are distinguished by the type of the **first element** — a number means
/// one constant `Matrix3`, an array means one per frame — and an empty array is
/// malformed because it has no first element to branch on. The library holds
/// that; this enum keeps the two forms apart on the way in.
public enum IntrinsicsObservation: Sendable, Hashable {
    /// From `isCameraIntrinsicMatrixDeliveryEnabled` — one matrix per frame.
    case perFrame([PpcpMatrix3])
    /// Focus is locked for the session's lifetime (REQ-OPT-2), so the matrix is
    /// constant and the scalar form is both smaller and *truer*.
    case constant(PpcpMatrix3)

    public var values: PpcpPerFrame<PpcpMatrix3> {
        switch self {
        case .perFrame(let v): .perFrame(v)
        case .constant(let v): .constant(v)
        }
    }
}

// MARK: - The assembled Capture

/// A Capture and the per-frame series that travels behind it.
///
/// ⛔ Two fields, and they go to two different places: `record` to
/// `capture_announce` on control, `achievedFrames` to `payload_begin` on bulk
/// (I30). Nothing here can put them in one message, because the library has no
/// message that takes both.
public struct CaptureAssembly: Sendable {
    public var record: PpcpCaptureRecord
    /// `nil` for an `absent` Capture — 5.8d: "a Capture of `completeness: absent`
    /// has no frames and carries no `AchievedFrames`".
    public var achievedFrames: PpcpAchievedFrames?

    public init(record: PpcpCaptureRecord, achievedFrames: PpcpAchievedFrames? = nil) {
        self.record = record
        self.achievedFrames = achievedFrames
    }
}

// MARK: - Building one

public enum CaptureBuilder {

    /// A shot-anchored Capture from what the ring extracted around `t0`.
    ///
    /// - Parameters:
    ///   - stream: the Stream it lands on. Its `continuity` decides whether the
    ///     extraction's holes may be expressed as `gaps` at all (I11) — for
    ///     `video`, which is always `shot_windowed` (§5.11), they may not, and
    ///     they are why the Capture is `partial` instead.
    ///   - exposure: 5.8d — mandatory on a camera Capture that has frames,
    ///     because I17's conversion is impossible without it.
    ///   - thermal: `CORE` §5.8 — a timeline over the Capture's interval, not one
    ///     reading at the end.
    public static func shotCapture(id: String,
                                   shotId: String,
                                   stream: PpcpStreamRecord,
                                   extraction: ClipExtraction,
                                   exposure: ExposureObservation,
                                   intrinsics: IntrinsicsObservation? = nil,
                                   thermal: [PpcpThermalPoint] = []) -> CaptureAssembly {
        anchored(.shot(shotId), id: id, stream: stream, extraction: extraction,
                 exposure: exposure, intrinsics: intrinsics, thermal: thermal)
    }

    /// A candidate-anchored Capture — the audio window that explains why
    /// detection fired (§5.12.1). D5 owns the detector; the shape is the same.
    public static func candidateCapture(id: String,
                                        candidateId: String,
                                        stream: PpcpStreamRecord,
                                        extraction: ClipExtraction,
                                        exposure: ExposureObservation,
                                        thermal: [PpcpThermalPoint] = []) -> CaptureAssembly {
        anchored(.candidate(candidateId), id: id, stream: stream, extraction: extraction,
                 exposure: exposure, intrinsics: nil, thermal: thermal)
    }

    private static func anchored(_ anchor: PpcpCaptureAnchor,
                                 id: String,
                                 stream: PpcpStreamRecord,
                                 extraction: ClipExtraction,
                                 exposure: ExposureObservation,
                                 intrinsics: IntrinsicsObservation?,
                                 thermal: [PpcpThermalPoint]) -> CaptureAssembly {
        switch extraction.outcome {
        case .absent(let reason):
            // ⛔ No `interval` on an absent shot- or candidate-anchored Capture:
            // 5.14 removes it there, and `ppcp_capture_validate` refuses one. The
            // mandatory-interval rule is the *segment*'s (5.14d).
            return CaptureAssembly(record: PpcpCaptureRecord(
                id: id, anchor: anchor, streamId: stream.id,
                timebaseId: stream.timebaseId,
                completeness: .absent, absentReason: reason))

        case .present(let completeness):
            // I11 — a gap is meaningful only on a `continuous` Stream, and the
            // library refuses one anywhere else. On `shot_windowed` the holes
            // are still honoured: they are what makes this `partial`.
            let gaps = stream.continuity == .continuous ? extraction.holesNs : []
            let summary = PpcpAchievedSummary(
                frameCount: Int64(extraction.frameTimestampsNs.count),
                droppedFrames: Int64(extraction.droppedFrames),
                realisedRateMillihertz: extraction.realisedRateMillihertz,
                exposureNs: PpcpRange3(sampling: exposure.samples),
                iso: PpcpRange3(sampling: extraction.iso),
                thermal: thermal)

            let record = PpcpCaptureRecord(
                id: id, anchor: anchor, streamId: stream.id,
                timebaseId: stream.timebaseId,
                completeness: completeness,
                intervalNs: extraction.realisedNs,
                gapsNs: gaps,
                achievedSummary: summary,
                bytes: extraction.byteCount > 0 ? UInt64(extraction.byteCount) : nil)

            let frames = PpcpAchievedFrames(
                timebaseId: stream.timebaseId,
                framesNs: extraction.frameTimestampsNs,
                exposureNs: exposure.values,
                exposureProvenance: exposure.provenance,
                // ⚠ `iso` only where every frame in the clip carried one. 5.8f
                // makes a parallel array exactly `frames.ns` long, and a short
                // one would be a different claim.
                iso: extraction.iso.count == extraction.frameTimestampsNs.count
                    ? .perFrame(extraction.iso) : nil,
                // ⛔ **The same 5.8f rule as `iso`, and it was missing.** A
                // parallel array is exactly `frames.ns` long; a shorter one is a
                // different claim, not a partial one. It could not bite while
                // intrinsics were always `nil` (E1.3 is what started filling
                // them), which is exactly the kind of latent mismatch that
                // surfaces the first time a device delivers matrices for only
                // some of its frames.
                //
                // ⚠ The CONSTANT form is exempt and must stay so: one matrix for
                // the whole clip is not a series and has no length to match.
                intrinsics: Self.parallelIntrinsics(intrinsics, frameCount:
                                                    extraction.frameTimestampsNs.count))

            return CaptureAssembly(record: record, achievedFrames: frames)
        }
    }

    /// 5.8f — a per-frame series must be exactly as long as `frames.ns`.
    ///
    /// - Returns: the constant form untouched; the per-frame form only where it
    ///   matches frame for frame; `nil` otherwise. ⛔ `nil` rather than a
    ///   truncated or padded array: absent means "not delivered", which is true,
    ///   while a series of the wrong length is a claim about frames it does not
    ///   describe.
    private static func parallelIntrinsics(_ observation: IntrinsicsObservation?,
                                           frameCount: Int) -> PpcpPerFrame<PpcpMatrix3>? {
        switch observation {
        case .none: nil
        case .constant(let matrix): .constant(matrix)
        case .perFrame(let matrices): matrices.count == frameCount
            ? .perFrame(matrices) : nil
        }
    }
}

// MARK: - ENC 6g / MSG 8.3h (erratum E7) — the container a payload is framed in

/// The IANA media types this application's payloads are.
///
/// ⛔ **Named here once, because `ENC` 6h forbids a receiver inferring one.** It
/// may not read it off `format.codec`, off `Stream.kind`, or by sniffing — and it
/// could not: H.264 is QuickTime, fragmented MP4 and Annex B, and those are three
/// different files that a decoder opens three different ways. A sender that omits
/// the container where the bytes are container-framed hands the receiver a guess.
public enum PpcpMediaType {
    /// Every clip this application extracts. `AVAssetWriter` writes an MP4 with
    /// HEVC or H.264 inside it; the codec is in the `CaptureProfile` and the
    /// **container** is this.
    public static let clip = "video/mp4"
    /// 5.12.1a's Candidate evidence — the window of microphone audio that
    /// explains why detection fired.
    public static let audioEvidence = "audio/mp4"
}
