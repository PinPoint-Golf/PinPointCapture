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
        case .armed: "Armed"
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
    public var bufferSeconds: Double
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

    public var verdict: Verdict
    public var exposureSeconds: Double
    public var iso: Double
    public var fps: Double

    public init(verdict: Verdict, exposureSeconds: Double, iso: Double, fps: Double) {
        self.verdict = verdict
        self.exposureSeconds = exposureSeconds
        self.iso = iso
        self.fps = fps
    }

    /// "1/1600 s · ISO 2200 · 150 fps" — mono, because the user could not have
    /// guessed any of it.
    public var measurementText: String {
        let shutter = exposureSeconds > 0 ? "1/\(Int((1 / exposureSeconds).rounded()))" : "—"
        return "\(shutter) s · ISO \(Int(iso.rounded())) · \(VideoMode.fpsText(fps)) fps"
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
    public var inFrameAtAddress: Bool
    public var inFrameAtTop: Bool
    public var isSteady: Bool
    public var light: LightAssessment
    public var viewpoint: Viewpoint

    public init(inFrameAtAddress: Bool, inFrameAtTop: Bool, isSteady: Bool,
                light: LightAssessment, viewpoint: Viewpoint) {
        self.inFrameAtAddress = inFrameAtAddress
        self.inFrameAtTop = inFrameAtTop
        self.isSteady = isSteady
        self.light = light
        self.viewpoint = viewpoint
    }

    public var allChecksPass: Bool {
        inFrameAtAddress && inFrameAtTop && isSteady && light.verdict == .good
    }
}
