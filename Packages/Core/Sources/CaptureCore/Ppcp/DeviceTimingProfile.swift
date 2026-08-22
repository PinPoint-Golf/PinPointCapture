//  DeviceTimingProfile.swift
//  The per-model PPCP timing and geometry facts — as DATA, in the neutral layer.
//
//  ⚠ **Plan A13 / REQ-PORT-10: device profile data is a JSON file keyed by model,
//  loaded by the app and validated by the library's provenance rules.** These
//  types are the shape of that data. They live in Core, not beside the JSON in
//  `Sources/Platform`, for REQ-PORT-11's reason: the vocabulary is the
//  *protocol's*, an Android port will read the same fields out of a file of its
//  own, and a type that named `AVCaptureDevice.Format` would have to be rewritten
//  rather than ported.
//
//  ⛔ **Nothing here is measured, and the types make that impossible to forget.**
//  Plan A12: "every timing constant nobody has measured is declared `assumed` …
//  no exception until the rig exists." Both quantities the protocol asks for —
//  `frame_start_to_exposure_offset_ns` (`CORE` 5.7b) and
//  `rolling_shutter.readout_ns` (5.7e) — come from an LED timecode rig, per
//  device model, and **no model has been through one** (REQ-TEST-1/2). So every
//  provenance in `DeviceProfiles.json` today is `assumed`, and `measured` is not
//  reachable from a table at all: 5.7f forbids it and `Provenance.measured`
//  below says so where an editor will read it.
//
//  Spec: `CORE` §5.7 (5.7a, 5.7b, 5.7e, 5.7f), §6.2; `CONF` CT-S7, CT-I31.

import Foundation

// MARK: - Provenance

/// `CORE` §5.7 — where a declared timing constant came from.
///
/// ⛔ **`measured` means measured on *this device model*, by *this project*
/// (5.7f).** Not vendor-documented, not inherited from a sibling model, not
/// interpolated, and above all not "the value we have always shipped". CT-S7
/// assertion 2 tests exactly this by supplying a profile entry with no rig
/// measurement and asserting the emitted provenance is not `measured` — which is
/// why this enum is decodable from the data file *including* the `measured` case
/// but the data file has none.
public enum PpcpProvenance: String, Sendable, Codable, Hashable, CaseIterable {
    /// Not measured for this device model. A placeholder, frequently zero.
    case assumed
    /// From a vendor document or a platform API that states it.
    case vendor
    /// Measured directly on this device model, by this project.
    case measured
}

/// `CORE` §6.2 — which way the sensor reads out.
///
/// ⚠ **A finding, recorded where it bites.** `readout_ns` carries a mandatory
/// `readout_provenance` (5.7e, I31) and `direction` carries **nothing**. So an
/// implementation that has guessed the direction — which this one has, from the
/// physical orientation of every rear iPhone sensor and not from a rig — is
/// indistinguishable on the wire from one that measured it, which is precisely
/// the defect I31 exists to close one field to the left. Reported, not worked
/// around: there is no field to put the honest answer in.
public enum PpcpRollingDirection: String, Sendable, Codable, Hashable {
    case topToBottom = "top_to_bottom"
    case bottomToTop = "bottom_to_top"
}

// MARK: - Readout

/// How a profile's `rolling_shutter.readout_ns` is arrived at.
///
/// ⚠ **Two forms, and the split is the point.** A measured model carries a number
/// from the rig. An unmeasured one carries a *rule* — a fraction of the nominal
/// frame interval — rather than a number, because a number in a table is
/// indistinguishable from a number from a rig once it is in the JSON, and the
/// next person to edit the file cannot tell which they are looking at. The rule
/// form can only ever produce `assumed`; `Self.provenance` is not a field the
/// data can set on it.
///
/// ⛔ **The fraction is not a measurement and must not be read as one.** It says:
/// "we do not know this sensor's readout time; a rolling sensor at its maximum
/// rate typically reads out over most of a frame interval, so take that as the
/// placeholder." It is wrong by an unknown amount and the `assumed` provenance is
/// the only honest thing about it. A rig measurement replaces the entry with the
/// `measured` form and **nothing in code changes** — which is what REQ-PORT-10
/// is for.
public enum PpcpReadout: Sendable, Codable, Hashable {

    /// From the LED timecode rig, on this device model (5.7f).
    case measured(ns: Int64)
    /// A vendor document or a platform API that states it.
    case vendor(ns: Int64)
    /// Unmeasured: this fraction of the profile's nominal frame interval.
    case assumedFractionOfFrameInterval(Double)

    public var provenance: PpcpProvenance {
        switch self {
        case .measured: .measured
        case .vendor: .vendor
        case .assumedFractionOfFrameInterval: .assumed
        }
    }

    /// The value to declare for a profile running at `rateMillihertz`.
    ///
    /// - Returns: `nil` where the rule form has no rate to apply itself to. ⛔ A
    ///   profile with no declared rate and no measured readout has nothing honest
    ///   to say, and the caller declares `global` geometry rather than inventing
    ///   a number — see `PpcpDeclaration`.
    public func readoutNs(rateMillihertz: Int64?) -> Int64? {
        switch self {
        case .measured(let ns), .vendor(let ns):
            return ns
        case .assumedFractionOfFrameInterval(let fraction):
            guard let rateMillihertz, rateMillihertz > 0 else { return nil }
            // Millihertz to a nanosecond interval: 1e12 / mHz.
            let intervalNs = 1_000_000_000_000.0 / Double(rateMillihertz)
            return Int64((intervalNs * fraction).rounded())
        }
    }

    // ── Codable ──────────────────────────────────────────────────────────────
    //
    // ⚠ Hand-written rather than synthesised so the JSON reads as an editor would
    // write it — `{ "measuredNs": 4123456 }` or
    // `{ "assumedFractionOfFrameInterval": 0.9 }` — and so that a typo in the key
    // is a decode failure rather than a silently defaulted value.

    private enum CodingKeys: String, CodingKey {
        case measuredNs, vendorNs, assumedFractionOfFrameInterval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let ns = try container.decodeIfPresent(Int64.self, forKey: .measuredNs) {
            self = .measured(ns: ns)
        } else if let ns = try container.decodeIfPresent(Int64.self, forKey: .vendorNs) {
            self = .vendor(ns: ns)
        } else if let fraction = try container.decodeIfPresent(
            Double.self, forKey: .assumedFractionOfFrameInterval) {
            self = .assumedFractionOfFrameInterval(fraction)
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "a readout entry needs exactly one of measuredNs, "
                    + "vendorNs or assumedFractionOfFrameInterval"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .measured(let ns): try container.encode(ns, forKey: .measuredNs)
        case .vendor(let ns): try container.encode(ns, forKey: .vendorNs)
        case .assumedFractionOfFrameInterval(let f):
            try container.encode(f, forKey: .assumedFractionOfFrameInterval)
        }
    }
}

// MARK: - Geometry, per format

/// One rolling-shutter entry. `CORE` 5.7: "per **profile**, not per source:
/// readout time differs per mode."
public struct PpcpGeometryEntry: Sendable, Codable, Hashable {

    /// Which profiles this entry covers. All three `nil` is the model's default.
    public var width: Int?
    public var height: Int?
    /// Matched on the profile's nominal rate, rounded to whole frames per second.
    public var fps: Int?

    public var readout: PpcpReadout
    public var direction: PpcpRollingDirection

    /// `CORE` 6.2b — "rows in the delivered image, R".
    ///
    /// ⚠ **Absent is the normal case and means "the format's height", which is
    /// what 6.2b defines R to be.** It is here as an override for the one thing
    /// that could make them differ — a model that delivers a row count the format
    /// description does not report — and no model does today. A stored copy of
    /// the height would be a second source of truth for a number the format
    /// already carries, and the two would drift.
    public var rows: Int?

    public init(width: Int? = nil, height: Int? = nil, fps: Int? = nil,
                readout: PpcpReadout, direction: PpcpRollingDirection,
                rows: Int? = nil) {
        self.width = width
        self.height = height
        self.fps = fps
        self.readout = readout
        self.direction = direction
        self.rows = rows
    }

    func matches(width candidateWidth: Int, height candidateHeight: Int,
                 fps candidateFps: Double) -> Bool {
        if let width, width != candidateWidth { return false }
        if let height, height != candidateHeight { return false }
        if let fps, fps != Int(candidateFps.rounded()) { return false }
        return true
    }

    var isDefault: Bool { width == nil && height == nil && fps == nil }
}

// MARK: - The per-model block

/// Everything `DeviceProfiles.json` says about one model's PPCP timing.
public struct PpcpDeviceTimingProfile: Sendable, Codable, Hashable {

    /// `CORE` 5.7b — "declared explicitly, **including when it is zero**, and
    /// always with its provenance". ⛔ Not optional, and not defaulted: a
    /// defaulted zero is exactly what I22 and CT-I22 refuse to let this
    /// implementation produce, and a declared zero with no provenance is what
    /// 5.7b calls indistinguishable from an unmeasured one.
    public var frameStartToExposureOffsetNs: Int64
    public var offsetProvenance: PpcpProvenance

    /// `CORE` 5.7 — SHOULD be present where provenance is `measured`. Absent
    /// everywhere today, because nothing is measured.
    public var offsetSigmaNs: Double?

    /// Per-format entries, most specific first, with at most one default.
    public var geometry: [PpcpGeometryEntry]

    public init(frameStartToExposureOffsetNs: Int64,
                offsetProvenance: PpcpProvenance,
                offsetSigmaNs: Double? = nil,
                geometry: [PpcpGeometryEntry]) {
        self.frameStartToExposureOffsetNs = frameStartToExposureOffsetNs
        self.offsetProvenance = offsetProvenance
        self.offsetSigmaNs = offsetSigmaNs
        self.geometry = geometry
    }

    /// The entry to declare for one enumerated format. A specific match beats the
    /// default; `nil` means the model's data says nothing at all, and the caller
    /// must not invent something.
    public func geometryEntry(width: Int, height: Int, fps: Double) -> PpcpGeometryEntry? {
        geometry.first { $0.isDefault == false && $0.matches(width: width, height: height, fps: fps) }
            ?? geometry.first { $0.isDefault }
    }

    /// ⚠ The stance this project is in, stated as a value so a test can assert it
    /// and a reviewer can find it. CT-S7 assertion 1: every constant this
    /// implementation emits that has not been through a rig is `assumed`.
    public var isFullyUnmeasured: Bool {
        offsetProvenance != .measured
            && geometry.allSatisfy { $0.readout.provenance != .measured }
    }
}
