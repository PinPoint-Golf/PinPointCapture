//  NetworkJoin.swift
//  `PPCP-RV` §6 — joining the network a pairing code carries.
//
//  ⛔ **6a: the join happens through a platform interface that obtains the user's
//  consent for the specific network, and networking is never reconfigured
//  silently.** On iOS that interface is `NEHotspotConfigurationManager`, which
//  shows a system alert naming the SSID. There is no API that joins without it and
//  this application wants none.
//
//  ⛔ **6b, and only the second branch is available here.** "A peer that joins for
//  a pairing restores the prior network configuration when the session ends, **or**
//  leaves the join in the user's control." iOS lets an application remove its own
//  configuration but cannot reassociate a network the user was previously on —
//  reassociation is the system's decision. 6b's disjunction exists for exactly
//  that, and the clause says so: "On platforms where an application may remove its
//  own network configuration but cannot reassociate a previously-used network …
//  only the second branch is available, and that is conformant."
//
//  ⚠ **So this removes its configuration on session end and tells the user.** It
//  does not pretend to have restored anything, because it has not.
//
//  ⛔ **6c/7.2b — the passphrase is a credential in every respect.** It is passed
//  to the platform and never logged, never exported, never stored by this
//  application, and `PairingNetwork.description` names the SSID alone.
//
//  ⚠ **The entitlement.** `NEHotspotConfiguration` needs
//  `com.apple.developer.networking.HotspotConfiguration`, which is in
//  `Support/PinPointCapture.entitlements`. A device build needs the capability
//  enabled on the App ID; without it the API returns an error rather than
//  crashing, and this reports it as "could not join" rather than as a bug.
//
//  Spec: `RV` §4.3f, §6. Plan D7.

import Foundation
import CaptureCore
#if canImport(NetworkExtension)
import NetworkExtension
#endif

/// Joins and leaves the network a code names.
public enum NetworkJoin {

    public enum JoinError: Error, Sendable, Equatable {
        /// The platform refused, or the user declined the system alert. ⛔ Both
        /// are the same outcome from here: the device is not on that network, and
        /// 4.3f's endpoint walk must not start.
        case refused(String)
        /// The platform has no such interface — a simulator, or a build without
        /// the entitlement.
        case unavailable
    }

    /// Whether the device is already associated. `RV` 4.3f: "where it is already
    /// associated, it walks `ep` directly".
    ///
    /// ⛔ **iOS will not tell us the current SSID** without location permission
    /// and a `NEHotspotNetwork` fetch, which is a second permission prompt for a
    /// question the join itself answers. So this reports what *this application*
    /// configured, which is the honest half: a network the user joined themselves
    /// is one this application must not claim to know about.
    public static func hasConfigured(_ ssid: String) async -> Bool {
        #if canImport(NetworkExtension)
        await withCheckedContinuation { continuation in
            NEHotspotConfigurationManager.shared.getConfiguredSSIDs { ssids in
                continuation.resume(returning: ssids.contains(ssid))
            }
        }
        #else
        false
        #endif
    }

    /// 6a — the system alert names the network; this is the only join path.
    ///
    /// ⚠ `joinOnce: false` so the configuration persists for the session and the
    /// device does not drop off the studio network between the pairing and the
    /// first shot. It is removed by `leave` when the session ends (6b).
    public static func join(_ network: PairingNetwork) async throws {
        #if canImport(NetworkExtension)
        let configuration: NEHotspotConfiguration
        if let passphrase = network.passphrase {
            configuration = NEHotspotConfiguration(ssid: network.ssid,
                                                   passphrase: passphrase,
                                                   isWEP: false)
        } else {
            // §6's table: `k` absent means an open network.
            configuration = NEHotspotConfiguration(ssid: network.ssid)
        }
        configuration.hidden = network.isHidden
        configuration.joinOnce = false

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                guard let error = error as NSError? else {
                    continuation.resume()
                    return
                }
                // ⚠ "Already associated" is success, not failure: 4.3f says a peer
                // already on the network walks `ep` directly.
                if error.domain == NEHotspotConfigurationErrorDomain,
                   error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                    continuation.resume()
                    return
                }
                // ⛔ The code, never the passphrase and never the configuration
                // (6c, 7.2b).
                continuation.resume(throwing: JoinError.refused("hotspot \(error.code)"))
            }
        }
        #else
        throw JoinError.unavailable
        #endif
    }

    /// 6b, second branch — removes this application's own configuration when the
    /// session ends. ⛔ It does **not** claim to have restored the previous
    /// network, because iOS cannot reassociate one.
    public static func leave(_ ssid: String) {
        #if canImport(NetworkExtension)
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        #endif
    }

    /// What the screen says after leaving, so the user is not left wondering why
    /// their phone is on nothing. ⚠ Copy, not a log line: 6b's "leaves the join in
    /// the user's control" is only true if the user is told they have it.
    public static let leftNetworkExplanation =
        "The studio network has been removed. iOS chooses which network to join "
        + "next — pick your usual one in Settings if it does not come back on its own."
}
