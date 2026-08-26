//  CaptureState.swift
//  The device lifecycle (REQ-STATE-1..5) and the framing check (REQ-SETUP-1/2).

import Foundation

/// REQ-STATE-1..3. Three capture states, crossed with review state.
///
/// ⚠ `warm` exists so arming incurs no AE/AF settling penalty. Rebuilding a
/// capture session costs roughly a second plus settling — and the first shot
/// after a cold re-arm is exactly the one not to lose.
public enum CaptureState: String, Sendable, CaseIterable {
    /// Session torn down, no buffer. Entered by keepalive lapse or a thermal
    /// or battery limit. This is a battery mechanism as much as a thermal one.
    case cold
    /// Session running, locked and settled, but not retaining.
    case warm
    /// Running, locked, settled and retaining into the ring buffer.
    case armed

    public var displayName: String {
        switch self {
        case .cold: "Not capturing"
        case .warm: "Ready"
        case .armed: "Capturing"
        }
    }
}

/// ⛔ The priority rule, §9.2: *capture is non-recoverable; replay is repeatable.
/// Under any resource constraint, replay degrades first and capture degrades last.*
///
/// `isReviewing` is deliberately independent of `state`: armed + reviewing is the
/// normal range state (REQ-STATE-4), not an edge case. Reviewing never disarms
/// capture and never tears down the capture session (REQ-RES-1).
public struct CaptureStatus: Sendable {
    public var state: CaptureState
    public var isReviewing: Bool
    public var thermal: ThermalState
    /// Seconds currently retained in the rolling buffer.
    /// ⛔ `nil` where nothing is retaining. It was a `Double` defaulting to zero,
    /// so C1's rail showed `buffer 0.0 s` — a *measurement of zero* on a device
    /// whose ring is not connected at all (E1.1). "—" and "0.0 s" are different
    /// claims and only one of them is true.
    public var bufferSeconds: Double?
    /// Realised rate, from timestamp deltas.
    public var achievedFPS: Double

    public init(state: CaptureState, isReviewing: Bool = false,
                thermal: ThermalState = .nominal,
                bufferSeconds: Double = 0, achievedFPS: Double = 0) {
        self.state = state
        self.isReviewing = isReviewing
        self.thermal = thermal
        self.bufferSeconds = bufferSeconds
        self.achievedFPS = achievedFPS
    }
}

/// How the device classifies its own viewpoint.
///
/// REQ-SETUP-2: the device classifies and *reports* this rather than asking the
/// user to configure it.
public struct Viewpoint: Sendable, Hashable {
    public enum Angle: String, Sendable {
        case downTheLine, faceOn, behind, unknown

        public var displayName: String {
            switch self {
            case .downTheLine: "DTL"
            case .faceOn: "Face-on"
            case .behind: "Behind"
            case .unknown: "Unknown"
            }
        }
    }

    public enum Handedness: String, Sendable {
        case rightHanded, leftHanded, unknown

        public var displayName: String {
            switch self {
            case .rightHanded: "Right-handed"
            case .leftHanded: "Left-handed"
            case .unknown: "Unknown"
            }
        }
    }

    public var angle: Angle
    public var handedness: Handedness

    public init(angle: Angle, handedness: Handedness) {
        self.angle = angle
        self.handedness = handedness
    }

    /// "DTL · RIGHT-HANDED"
    public var displayText: String {
        "\(angle.displayName) · \(handedness.displayName)"
    }
}

/// REQ-LIGHT-1/2. The binding constraint on how useful the video is.
///
/// ⚠ Warnings never block arming — they state the consequence and offer the trade.
public struct LightAssessment: Sendable, Hashable {
    public enum Verdict: String, Sendable { case good, marginal, insufficient }

    /// Where the reading came from. ⛔ Plan A12 applied to a light figure: a
    /// three-second sample taken cold is not the same claim as a sustained one,
    /// and REQ-CAP-2 makes that distinction the user's to see rather than ours to
    /// smooth over.
    public enum Provenance: String, Sendable, Hashable {
        /// Seconds, at onboarding, thermally cold.
        case coldSample
        /// Taken under sustained thermal load (REQ-ENC-4).
        case sustained
    }

    public var verdict: Verdict
    public var exposureSeconds: Double
    public var iso: Double
    public var fps: Double
    public var provenance: Provenance

    public init(verdict: Verdict, exposureSeconds: Double, iso: Double, fps: Double,
                provenance: Provenance = .coldSample) {
        self.verdict = verdict
        self.exposureSeconds = exposureSeconds
        self.iso = iso
        self.fps = fps
        self.provenance = provenance
    }

    /// REQ-LIGHT-1 from a real self-test, or `nil`.
    ///
    /// ⛔ **`nil` rather than a guess.** `exposureSeconds` and `iso` are optional
    /// on `MeasuredCapability` because a run may not have observed them, and a
    /// verdict invented from absent inputs is exactly the dishonesty A6 existed
    /// to remove — the screen showed an invented reading for months.
    ///
    /// ⚠ **The thresholds below are `assumed` and have not been through a rig.**
    /// REQ-CAP-4 asks for a *measured* noise or contrast figure and no device has
    /// one (REQ-TEST-1). They are a defensible starting point, not a calibration,
    /// and E-M1 is what replaces them.
    public static func from(_ measured: MeasuredCapability) -> LightAssessment? {
        guard let exposureSeconds = measured.exposureSeconds,
              let iso = measured.iso,
              exposureSeconds > 0, measured.achievedFPS > 0 else { return nil }

        // The ceiling the frame rate imposes: you cannot expose for longer than
        // the interval between frames.
        //
        // ⚠ Clamped to the claimed rate. A cold run can realise slightly *above*
        // the mode's nominal rate, which would make the ceiling — and therefore
        // the headroom — flatteringly small.
        let ceiling = 1.0 / min(measured.achievedFPS, measured.mode.fps)
        // How much of that ceiling the run actually used. Near 1.0 means the
        // sensor needed every bit of light the frame rate allowed.
        let headroom = exposureSeconds / ceiling

        let verdict: Verdict
        switch (iso, headroom) {
        case let (iso, headroom) where iso >= 3200 || headroom >= 0.95:
            verdict = .insufficient
        case let (iso, headroom) where iso >= 1600 || headroom >= 0.7:
            verdict = .marginal
        default:
            verdict = .good
        }

        return LightAssessment(
            verdict: verdict,
            exposureSeconds: exposureSeconds,
            iso: iso,
            fps: measured.achievedFPS,
            provenance: measured.method == .sustained ? .sustained : .coldSample)
    }

    /// "1/1600 s · ISO 2200 · 150 fps" — mono, because the user could not have
    /// guessed any of it.
    public var measurementText: String {
        let shutter = exposureSeconds > 0 ? "1/\(Int((1 / exposureSeconds).rounded()))" : "—"
        return "\(shutter) s · ISO \(Int(iso.rounded())) · \(VideoMode.fpsText(fps)) fps"
    }

    /// ⚠ What this reading is, said out loud. A cold three-second sample read as
    /// a sustained figure is REQ-CAP-2's named failure mode.
    public var provenanceText: String {
        switch provenance {
        case .coldSample: "measured cold, over a few seconds"
        case .sustained: "measured under sustained load"
        }
    }

    /// The consequence, stated plainly, with the trade offered.
    public var consequenceText: String? {
        switch verdict {
        case .good:
            nil
        case .marginal:
            "The shaft will be noisy near impact. Add light, or drop to 120 fps for a brighter frame."
        case .insufficient:
            "There is not enough light for the shaft to be measurable. Add light, or drop the frame rate."
        }
    }
}

/// REQ-SETUP-1. Verified at arm time, and updated continuously while A6 is visible.
///
/// REQ-SETUP-3: framing validation may use platform body-pose detection. That is
/// framing validation and is *not* analysis — it does not move the §2 line.
public struct FramingStatus: Sendable {

    /// ⛔ **Three states, not two.** A `Bool` cannot say "nobody looked", and for
    /// months this screen rendered `false`-as-fixture and `true`-as-fixture with
    /// no way to tell either from a real answer. Pose detection does not exist
    /// yet (E8.2), so ``notChecked`` is the honest value for three of these rows
    /// and the screen says so rather than showing an unearned tick.
    public enum Check: String, Sendable, Hashable {
        case notChecked, pass, fail

        public var isPass: Bool { self == .pass }
    }

    public var inFrameAtAddress: Check
    public var inFrameAtTop: Check
    public var isSteady: Check
    /// `nil` until a self-test has produced one (``LightAssessment/from(_:)``).
    public var light: LightAssessment?
    /// `nil` until something classifies it. Nothing does yet (REQ-SETUP-2).
    public var viewpoint: Viewpoint?

    public init(inFrameAtAddress: Check = .notChecked,
                inFrameAtTop: Check = .notChecked,
                isSteady: Check = .notChecked,
                light: LightAssessment? = nil,
                viewpoint: Viewpoint? = nil) {
        self.inFrameAtAddress = inFrameAtAddress
        self.inFrameAtTop = inFrameAtTop
        self.isSteady = isSteady
        self.light = light
        self.viewpoint = viewpoint
    }

    /// ⚠ An unchecked row is **not** a pass. Arming is never blocked by this
    /// (REQ-SETUP-1 warns, it does not gate) — but the summary must not claim a
    /// check that never ran.
    public var allChecksPass: Bool {
        inFrameAtAddress.isPass && inFrameAtTop.isPass && isSteady.isPass
            && light?.verdict == .good
    }

    /// Whether anything here was actually established, for a screen deciding
    /// between a checklist and an explanation.
    public var hasAnyRealCheck: Bool {
        light != nil || [inFrameAtAddress, inFrameAtTop, isSteady].contains { $0 != .notChecked }
    }
}
