//  RendezvousCoordinator.swift
//  D7 — from a scanned `ppcp:` code to an authenticated link, in the order
//  `PPCP-RV` requires.
//
//  ⛔ **The order is normative and is the whole file.**
//
//   1. Decode (`4.1a`, `4.3`). A `v` this application does not implement is
//      reported as needing a newer application (4.2b) and **nothing else in the
//      payload is acted on** (4.2d). A payload that will not decode is an invalid
//      code and no connection is attempted (4.4b).
//   2. Expiry (`4.4a`, `4.4a1`). Refused when the clock can be trusted; attempted
//      and reported as *possibly* expired when it cannot, because the publisher
//      holds the authoritative clock (7.3e) and a device with a wrong clock at a
//      range has no network to correct it from.
//   3. Network join (`4.3f`, `6a`, `6e`). Where the code carries `wifi` and the
//      device is not already associated, the join happens **before** the endpoint
//      walk, with the user's consent for the specific network.
//   4. Endpoint walk (`4.3c`). `ep` in order, stopping at the first that completes
//      the handshake. The order is the publisher's preference and is never sorted.
//   5. Persistence (`7.4`). Opt-in, visible, revocable — and **never** from a code
//      whose `mu` exceeded 1 (7.4f).
//
//  ⛔ **4.4c / 7.2b: the payload is never logged, never exported, and not retained
//  after the pairing it establishes has ended.** `PpcpPairingCode` keeps its
//  secret private and this type holds one only for as long as it is dialling.
//
//  ⚠ **The local-network permission is inferred, not queried** (`RV` §8, and
//  REQ-DISC-6). iOS exposes no interface to read it back and a single refusal
//  makes the application look permanently broken with no obvious cause. The
//  symptom — every endpoint on a private address failing to connect — is what
//  this reports, and `LocalNetworkBlockedView` is what explains it.
//
//  Spec: `RV` §4, §5, §6, §7, §8. Plan D7.

import Foundation
import CaptureCore

/// What happened, in terms a screen can render.
public enum RendezvousOutcome: Sendable {
    case connected(sessionId: String, security: NegotiatedSecurity, wasPossiblyExpired: Bool)
    /// 4.2b — ⛔ never a generic failure.
    case needsANewerApplication
    /// 4.4b.
    case invalidCode
    /// 4.4a.
    case expired
    /// §6 — the code names a network and consent has not been given yet. ⚠ A
    /// *pause*, not a failure: 6a requires the user's consent for the specific
    /// network before anything is reconfigured, so the walk stops here and
    /// resumes through `continueAfterJoining`.
    case needsNetworkConsent(PairingNetwork)
    /// §6 — the join was declined or the platform refused it.
    case couldNotJoinNetwork(String)
    /// Every endpoint was tried and none completed. ⚠ `localNetworkLikelyBlocked`
    /// is a *symptom* read, not a permission query (RV §8).
    case noEndpointReachable(triedCount: Int, localNetworkLikelyBlocked: Bool)
}

/// Walks a scanned code to a link.
public actor RendezvousCoordinator {

    /// What the walk produced, held only while a pairing is being established.
    /// ⛔ 4.4c — released as soon as the pairing ends.
    private var code: PpcpPairingCode?
    private var keys: RendezvousKeys?
    private var joinedSsid: String?

    private let connector: any PeerTransportConnector
    private let now: @Sendable () -> Date
    private let clockTrust: @Sendable () -> WallClockTrust

    init(connector: any PeerTransportConnector = PpcpConnector(),
                now: @escaping @Sendable () -> Date = { Date() },
                clockTrust: @escaping @Sendable () -> WallClockTrust
                    = { WallClock.trust() }) {
        self.connector = connector
        self.now = now
        self.clockTrust = clockTrust
    }

    /// The transport, once one is up. ⛔ Handed out rather than held: the peer
    /// engine and the pump own it from here.
    public private(set) var transport: (any PeerTransport)?

    /// Steps 1–4.
    ///
    /// - Parameter networkConsent: whether the user has already agreed to join the
    ///   network the code names. ⛔ `false` on the first call **by design**: 6a
    ///   requires consent for the specific network, and a coordinator that
    ///   defaulted it to true would reconfigure networking silently.
    public func scan(_ uri: String, networkConsent: Bool = false) async -> RendezvousOutcome {
        // 1 — decode.
        let decoded: PpcpPairingCode
        do {
            decoded = try PpcpPairingCode(uri: uri)
        } catch PairingCodeError.requiresNewerApplication {
            return .needsANewerApplication
        } catch {
            return .invalidCode
        }

        // 2 — expiry, against this peer's own opinion of its clock.
        let seconds = UInt64(max(0, now().timeIntervalSince1970))
        let expiry = decoded.expiry(nowUnixSeconds: seconds, trust: clockTrust())
        if expiry == .expired { return .expired }

        code = decoded
        do {
            keys = try decoded.keys()
        } catch {
            return .invalidCode
        }

        // 3 — the network, before the endpoints (4.3f, 6e).
        if let network = decoded.network {
            if await NetworkJoin.hasConfigured(network.ssid) == false {
                guard networkConsent else { return .needsNetworkConsent(network) }
                do {
                    try await NetworkJoin.join(network)
                    joinedSsid = network.ssid
                } catch {
                    return .couldNotJoinNetwork(String(describing: error))
                }
            }
        }

        // 4 — the walk.
        return await walk(decoded, possiblyExpired: expiry == .possiblyExpired)
    }

    /// Resumes after the user agreed on the `JoinNetworkView` sheet.
    public func continueAfterJoining(_ uri: String) async -> RendezvousOutcome {
        await scan(uri, networkConsent: true)
    }

    /// 4.3c — `ep` in order, stopping at the first that completes the handshake.
    private func walk(_ code: PpcpPairingCode,
                      possiblyExpired: Bool) async -> RendezvousOutcome {
        guard let keys else { return .invalidCode }
        // 5.3a — a **fresh** identity per connection, from the platform CSPRNG.
        let credentials = RendezvousCredentials(keys: keys)
        var privateAddressFailures = 0

        for endpoint in code.endpoints {
            do {
                let link = try await connector.connect(to: endpoint,
                                                       credentials: credentials,
                                                       channels: PpcpChannel.required)
                transport = link
                return .connected(sessionId: code.sessionId,
                                  security: link.security,
                                  wasPossiblyExpired: possiblyExpired)
            } catch {
                // ⚠ `RV` §8 — the symptom of a blocked local network is a direct
                // connection to a **private** address failing. Counted rather than
                // concluded from one endpoint, because one unreachable address is
                // ordinary.
                if Self.isPrivateAddress(endpoint.host) { privateAddressFailures += 1 }
                continue
            }
        }
        return .noEndpointReachable(
            triedCount: code.endpoints.count,
            localNetworkLikelyBlocked: privateAddressFailures > 0
                && privateAddressFailures == code.endpoints.count)
    }

    // MARK: Persistence (7.4)

    /// 7.4a/7.4b — persists `PRK` **only** with the user's explicit agreement, and
    /// ⛔ never from a `mu > 1` code (7.4f).
    public func persistPairing(consent: Bool) throws {
        guard let code, let keys else { return }
        try PairingSecretStore.save(code: code, keys: keys,
                                    displayName: code.displayName, consent: consent)
    }

    /// Whether the screen may even offer persistence. ⛔ `false` for a multi-use
    /// code: the offer itself would be a lie.
    public var mayOfferPersistence: Bool { code?.mayPersistPairing ?? false }

    /// 4.4c / 7.2d — the payload is not retained after the pairing it established
    /// has ended, and the network this application joined is left in the user's
    /// control (6b).
    public func endPairing(leaveNetwork: Bool = true) async {
        if leaveNetwork, let joinedSsid { NetworkJoin.leave(joinedSsid) }
        joinedSsid = nil
        code = nil
        keys = nil
        await transport?.close(.normal)
        transport = nil
    }

    /// RFC 1918 and the link-local range, which is what a studio host is on.
    static func isPrivateAddress(_ host: String) -> Bool {
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") {
            return true
        }
        // 172.16.0.0/12
        let parts = host.split(separator: ".")
        if parts.count == 4, parts[0] == "172", let second = Int(parts[1]),
           (16...31).contains(second) { return true }
        // A `.local` name is mDNS, which is the local network by definition.
        return host.hasSuffix(".local") || host.hasSuffix(".local.")
    }
}

// MARK: - The wall clock

/// `RV` 4.4a1 — whether this device has a *positive* reason to distrust its own
/// wall clock.
///
/// ⛔ **Absence of evidence is `trusted`.** The clause names two positive reasons
/// — never synchronised since boot, or reading earlier than the software's own
/// build date — and the default has to be trust, because the alternative locks a
/// user out of a valid code at a range with no network to correct the clock from.
public enum WallClock {

    /// The build date, from the executable's own timestamp. ⚠ Not a compiled-in
    /// literal: a constant baked at source-edit time drifts from the binary, and
    /// the comparison 4.4a1 asks for is against *the software*.
    static var buildDate: Date {
        guard let path = Bundle.main.executableURL?.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attributes[.modificationDate] as? Date else {
            // ⚠ No build date readable: that is not a reason to distrust the
            // clock, it is a reason to have no opinion. Distant past, so the
            // comparison below never fires on it.
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }

    public static func trust(now: Date = Date()) -> WallClockTrust {
        // 4.4a1's second reason. ⛔ The first — "never synchronised since boot" —
        // is not readable on iOS: there is no public interface that reports
        // whether the system clock has been set from the network, and inventing
        // one from a `mach_continuous_time` comparison would be a guess dressed as
        // a measurement. Recorded rather than approximated.
        now < buildDate ? .untrusted : .trusted
    }
}
