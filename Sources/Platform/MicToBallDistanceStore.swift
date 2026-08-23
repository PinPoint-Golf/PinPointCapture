//  MicToBallDistanceStore.swift
//  Where the microphone-to-ball distance is kept between sessions.
//
//  ⚠ **Per session, persisted, with a sensible default** — Mark's decision of
//  23 August 2026. The value survives a launch because a golfer sets their tripod
//  once and uses it for months; it is per *session* because a bay is not a mat and
//  a range is not a bay, and the setting screen is reachable while a session is
//  being set up rather than buried.
//
//  ⛔ `UserDefaults`, not the Keychain: this is a preference, not a secret.
//  `RV` 7.2c is about key material and nothing here is key material.
//
//  Spec: `CORE` §5.9, §5.12d, §8.1d; I29. Plan D7.

import Foundation
import CaptureCore

/// Reads and writes the distance setting.
public enum MicToBallDistanceStore {

    private static let metresKey = "org.pinpointstudio.capture.micToBall.metres"
    private static let provenanceKey = "org.pinpointstudio.capture.micToBall.provenance"

    /// ⚠ **The default is returned when nothing was ever set, and it is
    /// `estimated`.** A stored value nobody chose is still a guess, and A12 makes
    /// the provenance the thing that says so.
    public static func load(from defaults: UserDefaults = .standard) -> MicToBallDistance {
        guard defaults.object(forKey: metresKey) != nil else { return MicToBallDistance() }
        let metres = defaults.double(forKey: metresKey)
        let provenance = DistanceProvenance(
            rawValue: defaults.string(forKey: provenanceKey) ?? "") ?? .estimated
        return MicToBallDistance(metres: metres, provenance: provenance)
    }

    public static func save(_ value: MicToBallDistance,
                            to defaults: UserDefaults = .standard) {
        defaults.set(value.metres, forKey: metresKey)
        defaults.set(value.provenance.rawValue, forKey: provenanceKey)
    }

    /// Whether the user has ever chosen one. ⚠ A screen shows the default
    /// differently from a choice: "1.5 m (assumed)" is not the same sentence as
    /// "1.5 m", and the difference is what stops a default reading as a
    /// measurement.
    public static func hasBeenSet(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: metresKey) != nil
    }
}
