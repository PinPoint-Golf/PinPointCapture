//  Achieved.swift
//  `CORE` §5.8 — the two halves of *achieved* capability, as Swift views over
//  `libppcp`'s structs.
//
//  §5.8 opens by naming three things that are "routinely different, all on the
//  wire": **claimed** (the profile's own fields, D2), **measured** (the self-test,
//  D2) and **achieved** (this capture, here). This file is the third.
//
//  ⛔ **The split between the two types is I30 and it is not a size optimisation.**
//  `AchievedSummary` travels on control in `capture_announce`; `AchievedFrames`
//  travels with the payload it describes. The library makes that structural —
//  `ppcp_capture` has no `achieved_frames` member at all, and
//  `ppcp_peer_payload_begin` is the only entry point that takes one — so this
//  file cannot put the per-frame series on an announce even by trying.
//
//  ⚠ **Every buffer here is caller-owned.** `libppcp` allocates nothing, so
//  `ppcp_achieved_summary.thermal`, `ppcp_achieved_frames.frames_ns` and the
//  three per-frame arrays are borrowed pointers. That is why the bridges are
//  `withCValue` scopes and not properties: the C struct is valid only inside the
//  closure that pinned its storage, and a stored `ppcp_achieved_frames` would be
//  a dangling pointer the moment the Swift array moved.
//
//  Spec: `CORE` §5.8 (5.8d–5.8j), §6.1; `ENC` §4.1c–d; `CONF` CT-I2, CT-I30,
//  CT-I31, CT-S1 assertion 6, CT-S7 (3).

import Foundation
import CPPCP

// MARK: - `{ min, max, median }`

/// The shape `AchievedSummary.exposure_ns`, `AchievedSummary.iso` and the two
/// `MeasuredCapability` ranges all share (`CORE` §5.8).
public struct PpcpRange3: Sendable, Hashable {
    public var min: Int64
    public var max: Int64
    public var median: Int64

    public init(min: Int64, max: Int64, median: Int64) {
        self.min = min
        self.max = max
        self.median = median
    }

    /// The range of a sample set, with the median taken from the sorted values.
    ///
    /// ⚠ Returns `nil` for an empty set rather than a zeroed triple. A `{0,0,0}`
    /// exposure range is a claim about the light, and "nothing was sampled" is
    /// not that claim — the field is `0..1` precisely so it can be left out.
    public init?(sampling values: [Int64]) {
        guard values.isEmpty == false else { return nil }
        let sorted = values.sorted()
        self.min = sorted[0]
        self.max = sorted[sorted.count - 1]
        self.median = sorted[sorted.count / 2]
    }

    var cValue: ppcp_range3 {
        get throws {
            var range = ppcp_range3()
            try check(ppcp_range3_set(&range, min, max, median))
            return range
        }
    }
}

// MARK: - Thermal timeline

/// One point on `AchievedSummary.thermal`.
///
/// ⚠ `at` is an `Instant` and therefore carries its timebase (I1). The thermal
/// timeline is in the *stream's* clock like everything else on the Capture, not
/// in wall time — a consumer lining thermal degradation up against the frames
/// that degraded needs them on one axis.
public struct PpcpThermalPoint: Sendable, Hashable {
    public var timebaseId: String
    public var atNs: Int64
    public var level: ThermalState

    public init(timebaseId: String, atNs: Int64, level: ThermalState) {
        self.timebaseId = timebaseId
        self.atNs = atNs
        self.level = level
    }

    var cValue: ppcp_thermal_point {
        get throws {
            var point = ppcp_thermal_point()
            try check(ppcp_instant_make_z(&point.at, timebaseId, atNs))
            point.level = level.cLevel
            return point
        }
    }
}

extension ThermalState {
    /// `CORE` §5.8 `ThermalLevel` — ordinal protocol vocabulary, and a mapping
    /// the spec writes out per platform. ⛔ Not a passthrough of the platform's
    /// own name: `.fair` is `elevated`, and the vendor's word for it may travel
    /// separately as `vendor_label` but never here.
    var cLevel: ppcp_thermal_level {
        switch self {
        case .nominal: PPCP_THERMAL_NOMINAL
        case .fair: PPCP_THERMAL_ELEVATED
        case .serious: PPCP_THERMAL_SERIOUS
        case .critical: PPCP_THERMAL_CRITICAL
        }
    }
}

// MARK: - AchievedSummary

/// `CORE` §5.8 — what this Capture actually achieved, small enough for control.
///
/// Every field is `0..1`: a peer that did not count drops leaves `dropped_frames`
/// out rather than sending a zero, because zero drops is a measurement and
/// "nobody counted" is not.
public struct PpcpAchievedSummary: Sendable, Hashable {
    public var frameCount: Int64?
    public var droppedFrames: Int64?
    /// ⚠ **Millihertz** (`CORE` §5.7): 150 fps is `150000`. And *realised*, from
    /// timestamp deltas — REQ-FPS-2/REQ-TIME-5 forbid a count over a wall-clock
    /// interval, and I2 forbids anything derived from frame index.
    public var realisedRateMillihertz: Int64?
    public var exposureNs: PpcpRange3?
    public var iso: PpcpRange3?
    /// ⛔ A timeline, not a single value (`CORE` §5.8). One reading at the end
    /// cannot say whether the device was already hot when the swing happened.
    public var thermal: [PpcpThermalPoint]

    public init(frameCount: Int64? = nil,
                droppedFrames: Int64? = nil,
                realisedRateMillihertz: Int64? = nil,
                exposureNs: PpcpRange3? = nil,
                iso: PpcpRange3? = nil,
                thermal: [PpcpThermalPoint] = []) {
        self.frameCount = frameCount
        self.droppedFrames = droppedFrames
        self.realisedRateMillihertz = realisedRateMillihertz
        self.exposureNs = exposureNs
        self.iso = iso
        self.thermal = thermal
    }

    /// ⚠ Scoped, because `thermal` is a borrowed pointer into the array pinned
    /// here. The C struct must not outlive the closure.
    func withCValue<R>(_ body: (UnsafePointer<ppcp_achieved_summary>) throws -> R) throws -> R {
        let points = try thermal.map { try $0.cValue }
        return try points.withUnsafeBufferPointer { buffer in
            var summary = ppcp_achieved_summary()
            if let frameCount {
                summary.has_frame_count = true
                summary.frame_count = frameCount
            }
            if let droppedFrames {
                summary.has_dropped_frames = true
                summary.dropped_frames = droppedFrames
            }
            if let realisedRateMillihertz {
                summary.has_realised_rate_mhz = true
                summary.realised_rate_mhz = realisedRateMillihertz
            }
            if let exposureNs { summary.exposure_ns = try exposureNs.cValue }
            if let iso { summary.iso = try iso.cValue }
            summary.thermal = buffer.baseAddress
            summary.thermal_count = buffer.count
            try check(ppcp_achieved_summary_validate(&summary))
            return try body(&summary)
        }
    }
}

// MARK: - Per-frame values

/// `ENC` 4.1d — a per-frame field is either an array of exactly `frames.ns`
/// length, or a single value meaning the value was constant for every frame.
///
/// ⛔ 5.8f: the scalar "MUST NOT be used to mean 'unknown' or 'not sampled'".
/// That is what the `Optional` wrapper around a `PpcpPerFrame` is for — absent
/// means unknown, `.constant` means measured and constant.
public enum PpcpPerFrame<Value: Sendable & Hashable>: Sendable, Hashable {
    /// One value, true of every frame in this Capture.
    case constant(Value)
    /// One value per frame, parallel to `frames.ns`.
    case perFrame([Value])

    /// The array form's values, or `[]` for the scalar form.
    var arrayValues: [Value] {
        switch self {
        case .constant: []
        case .perFrame(let values): values
        }
    }
}

/// `CORE` §5.8 `exposure_provenance`.
///
/// ⛔ **5.8h is the whole point of this enum and it is a MUST NOT.** A peer must
/// not declare `per_frame` unless the platform attaches the value to the sample:
/// "declaring the stronger provenance is the same error as reporting a cold
/// sample as sustained (I31)". On this platform `AVCaptureVideoDataOutput` hands
/// over a `CMSampleBuffer` with no exposure attachment, so the honest answers are
/// the other two — and under the lock this application takes (REQ-OPT-3) the
/// honest answer is `locked_constant` with the scalar form.
///
/// ⚠ 5.8i: whether `sampled` is good enough is the *consumer's* policy. The
/// protocol carries the fact and never the judgement (I14), so nothing here
/// ranks these.
public enum PpcpExposureProvenance: String, Sendable, Hashable, CaseIterable {
    /// The value the capture pipeline attached to that frame.
    case perFrame = "per_frame"
    /// A device-level exposure property, sampled once per frame.
    case sampled
    /// One value, applied to every frame because exposure was locked.
    case lockedConstant = "locked_constant"

    var cValue: ppcp_exposure_provenance {
        switch self {
        case .perFrame: PPCP_EXP_PER_FRAME
        case .sampled: PPCP_EXP_SAMPLED
        case .lockedConstant: PPCP_EXP_LOCKED_CONSTANT
        }
    }
}

/// `ENC` §4.1 — row-major.
public struct PpcpMatrix3: Sendable, Hashable {
    public var values: [Double]

    /// - Returns: `nil` unless exactly nine values were given. ⛔ A short
    ///   intrinsics matrix padded with zeros is a camera with no focal length.
    public init?(_ values: [Double]) {
        guard values.count == 9 else { return nil }
        self.values = values
    }

    var cValue: ppcp_matrix3 {
        var matrix = ppcp_matrix3()
        withUnsafeMutableBytes(of: &matrix.m) { raw in
            let doubles = raw.bindMemory(to: Double.self)
            for index in 0..<9 { doubles[index] = values[index] }
        }
        return matrix
    }
}

// MARK: - AchievedFrames

/// `CORE` §5.8 — the per-frame series, carried with the payload it describes.
///
/// ⛔ **`framesNs` has no scalar form** (5.8e, I2): "frames drop; indices lie",
/// and a nominal rate is not a substitute for measured timestamps. The library
/// enforces it by `ppcp_achieved_frames_make` taking an array and nothing else.
///
/// ⚠ **This is the input I17 is missing without.** Converting a sample to its
/// canonical instant needs the profile's `convention`, *that frame's* exposure
/// duration from here, and — for `nominal_frame_start` — the offset. No subset
/// is sufficient, which is why 5.8d makes `exposure_ns` a MUST on any camera
/// Capture that has frames.
public struct PpcpAchievedFrames: Sendable, Hashable {
    /// `frames.tb` — the Stream's timebase.
    public var timebaseId: String
    /// `frames.ns`.
    public var framesNs: [Int64]
    /// 5.8d — mandatory on a camera Capture with frames. `nil` only for a
    /// `preview` Stream, which 5.8j exempts.
    public var exposureNs: PpcpPerFrame<Int64>?
    public var exposureProvenance: PpcpExposureProvenance?
    public var iso: PpcpPerFrame<Int64>?
    /// Where the profile says `intrinsics: per_frame`.
    public var intrinsics: PpcpPerFrame<PpcpMatrix3>?

    public init(timebaseId: String,
                framesNs: [Int64],
                exposureNs: PpcpPerFrame<Int64>? = nil,
                exposureProvenance: PpcpExposureProvenance? = nil,
                iso: PpcpPerFrame<Int64>? = nil,
                intrinsics: PpcpPerFrame<PpcpMatrix3>? = nil) {
        self.timebaseId = timebaseId
        self.framesNs = framesNs
        self.exposureNs = exposureNs
        self.exposureProvenance = exposureProvenance
        self.iso = iso
        self.intrinsics = intrinsics
    }

    /// ⚠ Four nested pins, one per caller-owned buffer. Unlovely and correct:
    /// `withUnsafeBufferPointer` guarantees the address only inside its closure,
    /// and every one of these is a pointer the C struct will keep.
    func withCValue<R>(_ body: (UnsafePointer<ppcp_achieved_frames>) throws -> R) throws -> R {
        let exposureArray = exposureNs?.arrayValues ?? []
        let isoArray = iso?.arrayValues ?? []
        let intrinsicsArray = (intrinsics?.arrayValues ?? []).map(\.cValue)

        return try framesNs.withUnsafeBufferPointer { frames in
            try exposureArray.withUnsafeBufferPointer { exposure in
                try isoArray.withUnsafeBufferPointer { isoValues in
                    try intrinsicsArray.withUnsafeBufferPointer { matrices in
                        var built = ppcp_achieved_frames()
                        try check(ppcp_achieved_frames_make(
                            &built, timebaseId, frames.baseAddress, frames.count))

                        if let exposureNs {
                            // 5.8: `exposure_provenance` is mandatory with
                            // `exposure_ns`. ⛔ It is a *parameter* of the
                            // library's setter, so the pair cannot be split —
                            // which is CT-S7 (3) made unconstructible rather
                            // than checked.
                            guard let exposureProvenance else {
                                throw PpcpLibraryError(PPCP_ERR_INVALID)
                            }
                            var value = try Self.perFrame(exposureNs, array: exposure)
                            try check(ppcp_achieved_frames_set_exposure(
                                &built, &value, exposureProvenance.cValue))
                        }
                        if let iso {
                            var value = try Self.perFrame(iso, array: isoValues)
                            try check(ppcp_achieved_frames_set_iso(&built, &value))
                        }
                        if let intrinsics {
                            var value = ppcp_per_frame_m3()
                            switch intrinsics {
                            case .constant(let matrix):
                                var single = matrix.cValue
                                try check(ppcp_per_frame_m3_scalar(&value, &single))
                            case .perFrame:
                                try check(ppcp_per_frame_m3_array(
                                    &value, matrices.baseAddress, matrices.count))
                            }
                            try check(ppcp_achieved_frames_set_intrinsics(&built, &value))
                        }
                        try check(ppcp_achieved_frames_validate(&built))
                        return try body(&built)
                    }
                }
            }
        }
    }

    private static func perFrame(_ value: PpcpPerFrame<Int64>,
                                 array: UnsafeBufferPointer<Int64>) throws -> ppcp_per_frame_i64 {
        var built = ppcp_per_frame_i64()
        switch value {
        case .constant(let scalar):
            try check(ppcp_per_frame_i64_scalar(&built, scalar))
        case .perFrame:
            try check(ppcp_per_frame_i64_array(&built, array.baseAddress, array.count))
        }
        return built
    }
}
