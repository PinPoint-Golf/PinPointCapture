//  Permissions.swift
//  Platform-neutral readiness, and the audio retention setting.
//
//  ⚠ REQ-PORT-13: the UI consumes a platform-neutral readiness state rather than
//  raw platform permission results. Permission acquisition and its failure
//  handling stay in the Platform layer.

import Foundation

public enum PermissionState: String, Sendable {
    case notRequested, allowed, denied
    /// ⚠ Local network only. iOS exposes **no API to read this back**, so it is
    /// inferred from connection failure rather than queried (REQ-DISC-6). A single
    /// "Don't Allow" otherwise makes the app appear permanently broken.
    case unknown

    /// A4 shows the benefit, never the API name.
    public var displayText: String {
        switch self {
        case .notRequested: "Needed to pair"
        case .allowed: "Allowed"
        case .denied: "Blocked"
        case .unknown: "Not known"
        }
    }
}

public struct Permissions: Sendable {
    public var camera: PermissionState
    public var microphone: PermissionState
    /// ⚠ Inferred, never read. See `PermissionState.unknown`.
    public var localNetwork: PermissionState
    public var motion: PermissionState

    public init(camera: PermissionState = .notRequested,
                microphone: PermissionState = .notRequested,
                localNetwork: PermissionState = .notRequested,
                motion: PermissionState = .notRequested) {
        self.camera = camera
        self.microphone = microphone
        self.localNetwork = localNetwork
        self.motion = motion
    }

    /// ⚠ Capture needs camera and microphone only. Refusing local network costs a
    /// golfer a *network*, not a session — the app records all day without it.
    public var canCapture: Bool { camera == .allowed && microphone == .allowed }
}

/// REQ-PRIV-2 and OPEN-2. Explicit, user-visible and configurable, and honestly
/// reflected in the platform purpose string and privacy label.
///
/// ⚠ **OPEN-2 closed, and the answer moved the shape of this type.** The
/// resolution is candidate-attached windows of ~2 s on a separate `audio` Stream
/// (REQ-PRIV-4 to 7), and `CORE` 5.12.1a makes that a Capture anchored to the
/// **Candidate** rather than to the shot. So the default is no longer "0.5 s
/// around impact": it is a window around **every noise the detector fires on**,
/// including the ones it rejects, and the count of those is not bounded by
/// anything the user does (`CORE` §13c).
///
/// ⛔ **That is why the display text changed.** The requirements review of
/// 22 August found REQ-PRIV-6's arithmetic computed on the shot count while
/// retention attaches to candidates, and REQ-PRIV-2 requires the label to reflect
/// retention *honestly* — a sentence built on the shot count understates it by an
/// unknown factor, and understates exactly the case a user would object to.
/// `CandidateAudioRetention` holds the real bound and the sentence.
///
/// The lesson use case (UC-5) means a continuously open microphone may capture a
/// coach and pupil in conversation. That has a materially different privacy
/// posture from video of a swing, which is why this is surfaced on A4 rather than
/// buried in Settings.
public enum AudioRetention: String, Sendable, CaseIterable {
    case aroundImpactOnly, fullTrack, none

    public var displayText: String {
        switch self {
        case .aroundImpactOnly:
            let seconds = Int((Double(policy.windowNs) / 1_000_000_000).rounded())
            return "\(seconds) s around each detected noise"
        case .fullTrack: return "The whole session"
        case .none: return "Nothing kept"
        }
    }

    /// The retention policy this setting means, and the bound it enforces.
    ///
    /// ⛔ 5.12.1b: the **protocol** must not constrain the window, the emission
    /// threshold or a cap — "these are peer policy, exactly as frame-rate floors
    /// are host policy" (I14). This is where that policy lives.
    public var policy: CandidateAudioRetention {
        switch self {
        case .aroundImpactOnly:
            return CandidateAudioRetention()
        case .fullTrack:
            // ⚠ Still candidate-attached windows, just a great many of them: there
            // is no continuous audio track anywhere in this application, because
            // 5.12.1a puts the evidence on Candidates and REQ-PRIV-5 refuses to
            // mux it into the video.
            return CandidateAudioRetention(maximumRetainedCandidates: 2_000)
        case .none:
            return CandidateAudioRetention(maximumRetainedCandidates: 0)
        }
    }

    /// REQ-PRIV-2 — the sentence the privacy label has to agree with.
    ///
    /// ⛔ "Nothing kept" gets its own, because the general statement describes
    /// retention that is not happening.
    public var userVisibleStatement: String {
        switch self {
        case .none:
            return """
                No sound is kept. The microphone is still used to time each shot, \
                and nothing it hears is written down or sent anywhere.
                """
        case .aroundImpactOnly, .fullTrack:
            return policy.userVisibleStatement
        }
    }
}
