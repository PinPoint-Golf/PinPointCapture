//  OnboardingStateStore.swift
//  Whether the seven onboarding screens have been walked.
//
//  ⛔ **It was not persisted, and the app restarted at A1 on every launch.** A
//  golfer who set the phone on a tripod, walked through placement and framing and
//  armed a session got the whole sequence again the next time they opened it —
//  including the permission screen, whose whole design rests on being asked once,
//  in order, with local network last (REQ-DISC-6).
//
//  ⚠ **Completion is not consent, and this stores only completion.** Permissions
//  are read back from the platform every launch (`PermissionsService.current`),
//  never from here: a user who granted the camera and later revoked it in
//  Settings must not be treated as having granted it because a flag says the
//  screen was seen.
//
//  ⛔ `UserDefaults`, not the Keychain — a preference, not a secret. Same
//  reasoning as `MicToBallDistanceStore`, and deliberately the same shape so
//  there is one pattern here rather than two.

import Foundation

/// Reads and writes whether onboarding has been completed.
public enum OnboardingStateStore {

    private static let completedKey = "org.pinpointstudio.capture.onboarding.completed"

    public static func hasCompleted(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: completedKey)
    }

    public static func setCompleted(_ completed: Bool,
                                    in defaults: UserDefaults = .standard) {
        defaults.set(completed, forKey: completedKey)
    }

    /// ⚠ For the debug gallery and for tests. Not reachable from the app: a
    /// golfer who wants the guidance again is better served by the placement
    /// screen being reachable than by their session state being reset.
    public static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: completedKey)
    }
}
