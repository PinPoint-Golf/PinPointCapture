//  DeviceCapability.swift
//  What the device says it can do, what it measured itself doing, and what one
//  shot actually delivered. Three different things, routinely different.
//
//  REQ-CAP-1/2/3. Collapsing them into one "capability" is how a session ends up
//  recorded at 120 fps with duplicated frames while every log says 150.
//
//  ⚠ REQ-PORT-11: this vocabulary is PROTOCOL vocabulary. An AVCaptureDevice.Format
//  and an Android StreamConfigurationMap entry must both reduce to these types.
//  Nothing here may name a platform concept.

import Foundation

/// ⚠ REQ-OPT-5: always a *physical* capture device, never a virtual multi-lens one.
/// Virtual devices switch physical lenses on scene and focus distance, silently
/// changing intrinsics mid-session.
public enum Lens: String, Sendable, CaseIterable {
    case wide, ultraWide, telephoto, unknown

    public var displayName: String {
        switch self {
        case .wide: "Wide"
        case .ultraWide: "Ultra-wide"
        case .telephoto: "Telephoto"
        case .unknown: "Unknown"
        }
    }

    /// Preference when two modes are otherwise equal. Lower wins.
    ///
    /// ⚠ Wide is the default capture lens. Ultra-wide offers the same 1080p240 on
    /// current iPhones, so without this an arbitrary tie-break can select it —
    /// and it carries heavy distortion. REQ-OPT-6 treats it as the fallback that
    /// behind-the-golfer placement in a small studio may *force* (UC-2), not as
    /// something to drift into because two formats sorted equal.
    ///
    /// Lens choice is calibration-affecting and forbidden to change within a
    /// session, so picking it by accident is expensive.
    public var captureRank: Int {
        switch self {
        case .wide: 0
        case .telephoto: 1
        case .ultraWide: 2
        case .unknown: 3
        }
    }
}

/// One capture mode the device advertises.
///
/// ⚠ REQ-FPS-2: `fps` is what the device *claims*. A mode advertising a 1–240
/// range will happily accept a 150 fps request and deliver 120 with duplicates.
/// `MeasuredCapability` is what it was caught doing.
public struct VideoMode: Sendable, Hashable, Identifiable {
    public var width: Int
    public var height: Int
    public var fps: Double
    public var lens: Lens
    public var deliversIntrinsics: Bool

    // ─────────────────────────────────────────────────────────────────────────
    //  REQ-PORT-11, and the reason these three arrived with D2. A `VideoMode`
    //  used to carry what the *capability card* needed; a PPCP `CaptureProfile`
    //  (`CORE` 5.7) additionally carries `format.pixel_format` and the `optical`
    //  block, and both come from the same `AVCaptureDevice.Format` the
    //  enumeration already has in its hand. Rather than a second platform walk
    //  producing a second vocabulary, the existing type grew the fields and
    //  became the view over the library's struct that REQ-PORT-11 asks for.
    //
    //  ⚠ All three are optional and absence means **not known**, never a default
    //  (`CORE` 5.1, last paragraph). `optical` and `format` are themselves
    //  optional on the wire, so an unknown one is simply not declared.
    // ─────────────────────────────────────────────────────────────────────────

    /// `CORE` 5.7 `format.pixel_format` — the delivered sample encoding, as the
    /// platform names it (a FourCC on this one). ⛔ Not interpreted here: it is an
    /// open-registry `Kind` and Core has no business parsing it.
    public var pixelFormat: String?

    /// `CORE` 5.7 `optical.exposure_min_ns` / `exposure_max_ns`.
    public var exposureRangeNs: ClosedRange<Int64>?

    /// `CORE` 5.7 `optical.iso_min` / `iso_max`.
    public var isoRange: ClosedRange<Int64>?

    public var id: String { "\(width)x\(height)@\(fps)-\(lens.rawValue)" }

    /// "1080p · 150 fps"
    public var displayName: String { "\(resolutionName) · \(Self.fpsText(fps)) fps" }

    public var resolutionName: String {
        switch height {
        case 2160: "4K"
        case 1080: "1080p"
        case 720: "720p"
        default: "\(width)×\(height)"
        }
    }

    /// Frame rate as the design writes it: whole numbers bare, otherwise one
    /// decimal — `150`, `149.6`. Public so a screen never reimplements it and
    /// ends up showing `149.60` in one place and `150` in another.
    public static func fpsText(_ value: Double) -> String {
        value == value.rounded()
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    public init(width: Int, height: Int, fps: Double, lens: Lens,
                deliversIntrinsics: Bool = false,
                pixelFormat: String? = nil,
                exposureRangeNs: ClosedRange<Int64>? = nil,
                isoRange: ClosedRange<Int64>? = nil) {
        self.width = width
        self.height = height
        self.fps = fps
        self.lens = lens
        self.deliversIntrinsics = deliversIntrinsics
        self.pixelFormat = pixelFormat
        self.exposureRangeNs = exposureRangeNs
        self.isoRange = isoRange
    }

    /// `CORE` 5.7 — "Millihertz, so 150 fps is `150000`. Avoids a float on the
    /// wire for a value used in scheduling."
    public var rateMillihertz: Int64 { Int64((fps * 1000).rounded()) }
}

/// REQ-RES-3. Thermal state is first-class so degradation is *reported* rather
/// than silently producing worse data. The four levels are the common ground
/// between Apple's and Android's thermal reporting.
public enum ThermalState: String, Sendable, Comparable, CaseIterable {
    case nominal, fair, serious, critical

    public var displayName: String { rawValue }

    /// `CORE` §5.8 `ThermalLevel` — "an **ordinal protocol vocabulary, not a
    /// platform passthrough**: `nominal` < `elevated` < `serious` < `critical`.
    /// A peer MUST map its platform's states onto it."
    ///
    /// ⛔ **`fair` is `elevated` on the wire, and the difference is not
    /// cosmetic.** These four cases are named after iOS's
    /// `ProcessInfo.ThermalState`, which is exactly the passthrough 5.8 forbids —
    /// Android's `PowerManager` has `NONE`, `LIGHT`, `MODERATE`, `SEVERE`,
    /// `CRITICAL`, `EMERGENCY` and `SHUTDOWN`, and two of those collapse onto
    /// each end. Sending `fair` would oblige every consumer to know what iOS
    /// calls things, which is the open-protocol commitment given away for a
    /// spelling. The mapping is the specification's own table.
    public var ppcpLevel: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "elevated"
        case .serious: "serious"
        case .critical: "critical"
        }
    }

    private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: Self, b: Self) -> Bool { a.order < b.order }
}

/// REQ-CAP-2. What self-test caught the device sustaining.
///
/// ⚠ REQ-ENC-4: a measurement taken from cold is not a measurement. Sustained
/// rate must be verified under thermal load, not at start-up.
public struct MeasuredCapability: Sendable, Hashable {

    /// `CORE` 5.8a — **mandatory**, and 5.8b says why: "a short sample taken
    /// during onboarding is `cold_sample`, and a consumer MUST NOT treat it as a
    /// sustained figure."
    ///
    /// ⛔ **This field arrived with D2 and its absence was a defect.** REQ-ENC-4
    /// already said "a measurement taken from cold is not a measurement", and the
    /// comment below has always said it — but there was no field to *carry* the
    /// distinction, so a cold onboarding sample and a thermally-loaded self-test
    /// were the same value on the wire. 5.8a and 5.8b exist because, in the
    /// specification's own words, "without `method` the cold number quietly
    /// becomes the displayed one". That is I28's other half.
    public enum Method: String, Sendable, Hashable, Codable {
        /// Seconds, at onboarding, thermally cold.
        case coldSample = "cold_sample"
        /// Taken under sustained thermal load (5.8b).
        case sustained
    }

    public var method: Method
    /// `CORE` 5.8a — mandatory. How long the self-test ran.
    public var durationSeconds: Double
    /// `CORE` 5.8a `observed_at`, in the peer's own capture timebase.
    ///
    /// ⚠ Not `measuredAt`, which is a wall-clock `Date` for display. An `Instant`
    /// needs a `tb` (I1) and `CORE` 5.3b forbids a `wall` timebase where an
    /// interval will be computed, so the protocol value is a host-time reading
    /// and the `Date` beside it is a label. `nil` where the caller had no
    /// host-time reading to give, in which case no `measured` block is declared
    /// at all — I28 refuses a synthesised one more readily than an incomplete one.
    public var observedHostTimeNs: Int64?

    public var mode: VideoMode
    /// Derived from realised timestamp deltas — never from a frame count over a
    /// wall-clock interval, and never from the value the platform reports back
    /// (REQ-TIME-5: frames drop, indices lie).
    public var achievedFPS: Double
    public var droppedFrames: Int
    public var thermalAtEnd: ThermalState
    public var measuredAt: Date

    /// REQ-CAP-4. Optical quality, not only frame rate — "120 fps capable" can
    /// hide frames the shaft detector cannot use.
    public var exposureSeconds: Double?
    public var iso: Double?

    public init(mode: VideoMode, achievedFPS: Double, droppedFrames: Int,
                thermalAtEnd: ThermalState, measuredAt: Date,
                method: Method, durationSeconds: Double,
                observedHostTimeNs: Int64? = nil,
                exposureSeconds: Double? = nil, iso: Double? = nil) {
        self.method = method
        self.durationSeconds = durationSeconds
        self.observedHostTimeNs = observedHostTimeNs
        self.mode = mode
        self.achievedFPS = achievedFPS
        self.droppedFrames = droppedFrames
        self.thermalAtEnd = thermalAtEnd
        self.measuredAt = measuredAt
        self.exposureSeconds = exposureSeconds
        self.iso = iso
    }

    /// "149.6 fps · 0 drops"
    public var displaySummary: String {
        "\(VideoMode.fpsText(achievedFPS)) fps · \(droppedFrames) drops"
    }

    /// `CORE` 5.8 — the realised rate in millihertz, as the wire carries it.
    public var sustainedRateMillihertz: Int64 { Int64((achievedFPS * 1000).rounded()) }
}

/// The claimed / measured / achieved triple. Drives A1, A7 and the C1 rail.
public struct DeviceCapability: Sendable {
    /// Device profile key (REQ-PORT-10: profiles are data keyed by model, not code).
    public var modelIdentifier: String
    /// Marketing name for display: "iPhone 16".
    public var modelName: String
    public var claimed: [VideoMode]
    public var measured: MeasuredCapability?

    public init(modelIdentifier: String, modelName: String,
                claimed: [VideoMode], measured: MeasuredCapability? = nil) {
        self.modelIdentifier = modelIdentifier
        self.modelName = modelName
        self.claimed = claimed
        self.measured = measured
    }

    /// The mode to describe on A1, warm up with, and size storage against.
    ///
    /// ⚠ Ranked by **frame rate first**, resolution second. Ranking by resolution
    /// first picks the stills format — an iPhone 16 reports 4032×3024 at 30 fps,
    /// which beats 1080p240 on height and is useless for a swing. That produced a
    /// capability card reading "4032×3024 at up to 30 fps … Good for capture.",
    /// where the verdict and the description contradicted each other.
    ///
    /// Frame-rate-first is also what REQ-RES-1 asks for on its own terms: target
    /// 1080p at the highest sustainable rate, and do not reach for 4K. Trading
    /// temporal resolution for spatial is the wrong direction when shaft tracking
    /// needs ≥100 fps and measures speed from streak length.
    public var bestMode: VideoMode? {
        claimed.max {
            // Note the inverted lens term: `captureRank` is lower-is-better, so it
            // is negated to keep the whole comparison higher-is-better.
            ($0.fps, $0.height, -$0.lens.captureRank)
                < ($1.fps, $1.height, -$1.lens.captureRank)
        }
    }

    /// The lenses this device offers, in a canonical order.
    ///
    /// ⚠ Ordered by `Lens.allCases`, not by whatever order the modes happened to
    /// sort into. Otherwise the A1 sentence reads "ultra-wide and wide" on one
    /// device and "wide and ultra-wide" on another purely because of how their
    /// formats enumerated — and the wide lens is the primary one, so it leads.
    public var availableLenses: [Lens] {
        let present = Set(claimed.map(\.lens))
        return Lens.allCases.filter { present.contains($0) }
    }

    /// The A1 card sentence. ⚠ Populated from real format enumeration, never a
    /// spec-sheet lookup (REQ-FPS-1). A device that will not clear the host's
    /// ingest gate says so *here*, in these terms, rather than at arm time.
    public var summarySentence: String {
        guard let best = bestMode else {
            return "\(modelName) — no usable capture format was found."
        }
        let lenses = availableLenses.filter { $0 != .unknown }
            .map(\.displayName).map { $0.lowercased() }
        let lensText = ListFormatter.localizedString(byJoining: lenses)
        return "\(modelName) — \(best.resolutionName) at up to "
            + "\(VideoMode.fpsText(best.fps)) fps, \(lensText)."
    }
}

/// Storage headroom, surfaced on A7 to pre-empt the low-space refusal (REQ-OFF-2).
public struct StorageHeadroom: Sendable, Hashable {
    public var estimatedSessions: Int
    public var freeBytes: Int64

    public init(estimatedSessions: Int, freeBytes: Int64) {
        self.estimatedSessions = estimatedSessions
        self.freeBytes = freeBytes
    }

    /// "about 40 sessions"
    public var displayText: String { "about \(estimatedSessions) sessions" }
}

// MARK: - Host ingest policy

/// What a host will accept.
///
/// ⛔ REQ-CAP-5. This is **host ingest policy, not a protocol constraint.** A
/// device may honestly declare 60 fps and a host may refuse it; the wire format
/// must never encode anyone's floor. That is why this is a *value* — a host can
/// state its own at negotiation — rather than a constant compiled into a screen.
///
/// PinPoint Studio's current floor is 1080p at 120 fps, consistent with the
/// documented ≥100 fps requirement for full-swing shaft tracking (OPEN-3).
///
/// ⚠ Frame rate alone is not the whole gate. REQ-CAP-4 requires an optical
/// quality bar too — "120 fps capable" can hide frames the shaft detector cannot
/// use. That bar needs a measured noise figure, which no device has yet, so it is
/// deliberately absent rather than guessed.
public struct HostIngestPolicy: Sendable, Hashable {
    public var minimumHeight: Int
    public var minimumFPS: Double

    public init(minimumHeight: Int, minimumFPS: Double) {
        self.minimumHeight = minimumHeight
        self.minimumFPS = minimumFPS
    }

    /// PinPoint Studio as of this build. Not a protocol fact.
    public static let pinPointStudioCurrent = HostIngestPolicy(minimumHeight: 1080,
                                                               minimumFPS: 120)

    public func accepts(_ mode: VideoMode) -> Bool {
        mode.height >= minimumHeight && mode.fps >= minimumFPS
    }

    /// "1080p at 120 fps"
    public var displayRequirement: String {
        let name = switch minimumHeight {
        case 2160: "4K"
        case 1080: "1080p"
        case 720: "720p"
        default: "\(minimumHeight)p"
        }
        return "\(name) at \(VideoMode.fpsText(minimumFPS)) fps"
    }
}

extension DeviceCapability {
    /// Whether any claimed mode clears a given host's gate.
    ///
    /// ⚠ Answered on A1, at the very start, rather than at arm time. A user whose
    /// device cannot do the job deserves to know on the first screen — not after
    /// setting up a tripod.
    public func clearsGate(_ policy: HostIngestPolicy = .pinPointStudioCurrent) -> Bool {
        claimed.contains { policy.accepts($0) }
    }

    /// The verdict sentence that closes A1's capability card.
    ///
    /// ⚠ "Good for capture." is the design's own copy. The failure sentence is
    /// **not** in the handoff and is provisional wording pending review.
    public func verdictSentence(_ policy: HostIngestPolicy = .pinPointStudioCurrent) -> String {
        clearsGate(policy)
            ? "Good for capture."
            : "Below what a host will accept — PinPoint Studio needs "
                + "\(policy.displayRequirement)."
    }
}
