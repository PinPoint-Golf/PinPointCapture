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
/// ⚠ OPEN-2 is unresolved and **blocks schema work**. The "0.5 s around impact"
/// default below is the design's *proposal for confirmation*, not a decision, and
/// must not be baked into any persisted schema until OPEN-2 closes.
///
/// The lesson use case (UC-5) means a continuously open microphone may capture a
/// coach and pupil in conversation. That has a materially different privacy
/// posture from video of a swing, which is why this is surfaced on A4 rather than
/// buried in Settings.
public enum AudioRetention: String, Sendable, CaseIterable {
    case aroundImpactOnly, fullTrack, none

    public var displayText: String {
        switch self {
        case .aroundImpactOnly: "0.5 s around impact only"
        case .fullTrack: "The whole session"
        case .none: "Nothing kept"
        }
    }
}
