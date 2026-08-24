//  ReconnectCoordinator.swift
//  `PPCP-RV` §3 + §5 — reconnecting to a host this device has already paired
//  with, without a code and without a pairing step.
//
//  ⛔ **PinPointStudio advertises and this device dials. Always.** 3.5d forbids
//  an iOS peer advertising for reconnection and forbids it being dialled, for a
//  measured reason: `Network.framework`'s listener cannot resolve a rotating PSK
//  identity (5.3b) — the only server-side entry point registers a (key, identity)
//  pair up front, and `Tests/TransportLoopbackTests` measures the consequence as
//  `PSK_IDENTITY_NOT_FOUND`, alert 115. 3.5e therefore puts the advertising on
//  the host. **There is no listener in this file and there must never be one.**
//
//  ⛔ **3.4c is enforced in `PpcpBrowser.browse` and NOT re-checked here, on
//  purpose.** A browsing peer must not connect to an instance it cannot resolve;
//  the filter lives inside the browse so that no call site — including this one —
//  is ever handed an unresolvable instance to be tempted by. What arrives here is
//  already resolved, and `Found.pairingIndex` names which held pairing resolved
//  it (3.4b). This file's job is to turn that index back into key material and
//  dial.
//
//  ⛔ **DISCOVERY FAILURE IS NOT AN ERROR AND IS NEVER REPORTED AS ONE** (3.6a).
//  On a network with client isolation, on a guest VLAN, or behind an access point
//  that rate-limits multicast, the host simply never appears; that is an ordinary
//  outcome of §3 and the pairing code is the path that always works (3.6b).
//  ``ReconnectOutcome/notFound(_:)`` is therefore not a failure case — but it
//  carries a ``Silence`` so that **"has not appeared yet" and "never appeared"
//  are distinguishable to the caller**, which is the one thing a silent outcome
//  must not take away. ⚠ Where the line between those two falls, and what a
//  screen says on either side of it, is a **UX decision and is deliberately not
//  made here**: this type reports how long and how hard it has looked and offers
//  no words for it.
//
//  ⛔ **THE HOST IS ON DHCP AND ITS ADDRESS WILL CHANGE, so no address is ever
//  written down.** What survives a session is the pairing — `PRK`, and the
//  `K_tls`/`K_id` re-derived from it (5.1c) — and a pairing has nothing to do
//  with an address. §3 is built for this: the instance name and the SRV target
//  are stable while the A/AAAA record moves underneath them, and 3.4b recognises
//  a host by resolving its rotating `rid` against a held `K_id`. So a host that
//  changes address, changes subnet, or is rebuilt on new hardware keeps its
//  pairing, and four rules follow that are easy to break by accident:
//
//   1. **No host address is persisted or cached, here or in
//      `PairingSecretStore`.** The endpoint is resolved fresh on every sweep. A
//      cached address is correct until the day it silently is not, and the
//      failure then reads as "the studio is offline".
//   2. **`rid` is not cached either** — 3.4d rotates it by design. What is held
//      across sessions is `K_id`; `rid` is whatever is on the wire this time.
//   3. **A failed dial re-browses; it does not retry the address.** ``attempt()``
//      holds nothing between sweeps but a counter and a start time, so a retry
//      *is* a new browse by construction rather than by remembering to. The most
//      likely reason a resolved endpoint failed is that it moved.
//   4. **The platform resolves the name, not this file.** `.service` re-resolves
//      on every dial; a host and port extracted once does not. That is the
//      strongest of the reasons `Found` carries the endpoint whole.
//
//  ⚠ **WHEN THIS RUNS, decided here and written down rather than left implicit.**
//
//   * **On an explicit entry to the connect flow, and on the app becoming
//     active while at least one pairing is held and no link is up.** Those are
//     the two moments at which a user is plausibly waiting for the host.
//   * **Never in the background.** `AppModel.linkDidEnterBackground` already
//     drops the socket because iOS suspends it; a browse that continued behind a
//     suspended app would spend radio on a convenience path (3.6b makes the code
//     the reliable one) and could only ever produce a link that is dropped again
//     on the next suspension.
//   * **A bounded, widening cadence** — ``ReconnectCadence/standard``: a
//     three-second sweep, then gaps of 2s, 5s and 10s, then every 30s. It widens
//     because a host that has not appeared in four sweeps is usually a network
//     that will not carry multicast at all, and it does not stop because the
//     host may be switched on at any moment while the user waits.
//
//  Spec: `RV` 3.4b, 3.4c, 3.5d, 3.5e, 3.6a, 3.6b, 5.1c, 5.3a, 7.4, 11.1a.

import Foundation
import Network
import CaptureCore

// MARK: - What a sweep produced

/// ⚠ How hard this has looked, for a caller that must tell "not yet" from "not
/// at all" without either of them being an error (3.6a).
///
/// ⛔ **No threshold and no wording.** A `Silence` after one three-second sweep
/// and a `Silence` after four minutes are the same case to §3 and different
/// sentences to a user, and choosing that sentence is not this type's decision.
public struct Silence: Sendable, Hashable {
    /// Completed browse sweeps since the search began. `1` is the first one.
    public let sweeps: Int
    /// Since the first sweep of this search started — monotonic, so a wall-clock
    /// step cannot make it negative (`RV` 4.4a1 is about a different clock, but
    /// the same distrust applies).
    public let searchedForNs: Int64
    /// How many pairings were offered to the resolver. ⚠ Never zero here: no
    /// pairings held is ``ReconnectOutcome/noPairingsHeld`` and does not browse.
    public let pairingsHeld: Int

    public init(sweeps: Int, searchedForNs: Int64, pairingsHeld: Int) {
        self.sweeps = sweeps
        self.searchedForNs = searchedForNs
        self.pairingsHeld = pairingsHeld
    }
}

/// A link to a host this device already knew.
public struct ReconnectedHost: Sendable {
    public let transport: any PeerTransport
    /// `RV` 4.3e — the Session the pairing was established for.
    public let sessionId: String
    public let security: NegotiatedSecurity
    /// ⛔ **A claim about the pairing, not about the peer that answered.** The
    /// only name in the system is what a publisher put in the code that was
    /// scanned, or what the user was shown at guided pairing; `MSG` §3.3's
    /// `declare` carries a `peer:` UUID and nothing a person would recognise.
    /// 3.3b keeps every name off the advertisement, so nothing on the wire here
    /// contributes to this.
    public let hostDisplayName: String?
    /// The instance name resolved, `PPCP-9B1D2DF9` (3.2a). ⚠ Diagnostic only —
    /// it changes with every `rn` rotation (3.4a) and names nothing durable.
    public let instanceName: String
}

/// ⛔ **Not an `Error` and not a `Result`, because one of these outcomes is a
/// normal quiet Tuesday** (3.6a).
public enum ReconnectOutcome: Sendable {
    case connected(ReconnectedHost)

    /// ⛔ Nothing is held, so there is nothing to resolve against and **no browse
    /// is performed**. 3.4b's resolver needs at least one `K_id`; a browse with
    /// an empty table can only produce instances 3.4c forbids connecting to.
    /// ⚠ This is the honest answer for a device that has never paired, and it is
    /// a different sentence from "your host did not appear".
    case noPairingsHeld

    /// ⛔ **3.6a — NOT an error.** No advertisement resolved against a held
    /// pairing. Either the host is not running, or this network does not carry
    /// multicast between its clients.
    case notFound(Silence)

    /// A host resolved, answered, and refused the key material — which is a
    /// revoked pairing at the other end (7.4d) far more often than anything else.
    /// ⛔ Not `notFound`: something answered, so the network demonstrably works
    /// and a network remedy would be the wrong thing to offer.
    case hostRefusedThePairing(sessionId: String, reason: String)

    /// A host resolved and the dial did not complete. ⚠ Distinct from a refusal
    /// for the same reason `RendezvousCoordinator` keeps them apart: they are
    /// opposite diagnoses.
    case couldNotReachHost(sessionId: String, reason: String)
}

/// ⚠ The retry shape, as a value so it can be shortened in a test without the
/// test waiting out a real one.
public struct ReconnectCadence: Sendable, Hashable {
    /// How long one browse dwells. ⚠ Long enough for an access point to pass a
    /// query and a response, short enough that a user is not watching nothing.
    public let sweepSeconds: Double
    /// The gaps after the first, second and third sweeps.
    public let gapsNs: [Int64]
    /// Every gap thereafter.
    public let steadyGapNs: Int64

    public init(sweepSeconds: Double, gapsNs: [Int64], steadyGapNs: Int64) {
        self.sweepSeconds = sweepSeconds
        self.gapsNs = gapsNs
        self.steadyGapNs = steadyGapNs
    }

    /// ⚠ Widening, and it never stops — see the file header for why.
    public static let standard = ReconnectCadence(
        sweepSeconds: 3,
        gapsNs: [2_000_000_000, 5_000_000_000, 10_000_000_000],
        steadyGapNs: 30_000_000_000)

    func gapNs(afterSweep sweep: Int) -> Int64 {
        let index = sweep - 1
        return index < gapsNs.count ? gapsNs[index] : steadyGapNs
    }
}

// MARK: - The seams

/// The browse half. ⚠ A protocol only so a test can hand in a sweep without a
/// network; `PpcpBrowser` is the one implementation that ships.
protocol HostBrowsing: Sendable {
    func browse(against identityKeys: [Data], seconds: Double) async -> [PpcpBrowser.Found]
}

extension PpcpBrowser: HostBrowsing {}

/// The dial half, over an endpoint the browser produced rather than one a
/// pairing code spelled out.
protocol DiscoveredHostConnecting: Sendable {
    func connect(to endpoint: NWEndpoint,
                 credentials: any PpcpCredentials,
                 channels: [PpcpChannel]) async throws -> any PeerTransport
}

extension PpcpConnector: DiscoveredHostConnecting {}

/// What this device holds, as three reads.
///
/// ⚠ A struct of closures rather than a direct call to `PairingSecretStore` so a
/// test can exercise the walk without writing to the Keychain — and so that
/// **this file names exactly what it reads**, which is `PRK`-derived key material
/// and one untrusted display string, and nothing else 7.2b would object to.
struct HeldPairings: Sendable {
    /// ⛔ Every held pairing's `K_id`, from the **code path and guided pairing
    /// alike** — 11.1a makes them indistinguishable from 11.6e onward, so a
    /// reconnection that worked for only one of them would be a bug, not a
    /// policy.
    var identityKeys: @Sendable () throws -> [(sessionId: String, identityKey: Data)]
    /// 5.1c — re-derived from the persisted `PRK` on demand, never held at rest.
    var keys: @Sendable (_ sessionId: String) throws -> RendezvousKeys?
    /// 4.4d — untrusted display text, for a screen and never as an identifier.
    var displayName: @Sendable (_ sessionId: String) throws -> String?

    static let keychain = HeldPairings(
        identityKeys: { try PairingSecretStore.identityKeys() },
        keys: { try PairingSecretStore.keys(forSession: $0) },
        displayName: { sessionId in
            try PairingSecretStore.pairings()
                .first { $0.sessionId == sessionId }?.displayName
        })
}

// MARK: - The coordinator

/// Finds a host this device has already paired with, and dials it.
public actor ReconnectCoordinator {

    private let browser: any HostBrowsing
    private let connector: any DiscoveredHostConnecting
    private let held: HeldPairings
    private let cadence: ReconnectCadence
    private let nowNs: @Sendable () -> Int64

    /// Sweeps since this search began, and when it began. ⚠ Actor state rather
    /// than a parameter because ``Silence`` is a statement about the *search*,
    /// and a caller that had to keep the count would be the one place it could
    /// be got wrong.
    private var sweeps = 0
    private var searchStartedNs: Int64?

    init(browser: any HostBrowsing = PpcpBrowser(),
         connector: any DiscoveredHostConnecting = PpcpConnector(),
         held: HeldPairings = .keychain,
         cadence: ReconnectCadence = .standard,
         nowNs: @escaping @Sendable () -> Int64 = { MachClock.hostTimeNs }) {
        self.browser = browser
        self.connector = connector
        self.held = held
        self.cadence = cadence
        self.nowNs = nowNs
    }

    public init() {
        self.init(browser: PpcpBrowser())
    }

    /// Forgets how long this search has been going. ⚠ Call when the user leaves
    /// and comes back, so a fresh wait does not inherit an old one's `Silence`
    /// and read as hopeless before it has looked once.
    public func reset() {
        sweeps = 0
        searchStartedNs = nil
    }

    /// One sweep: browse, resolve, dial.
    ///
    /// ⛔ The order is not adjustable. Keys first — with none there is nothing
    /// 3.4b could resolve and 3.4c would forbid every result — then the browse,
    /// which filters to what resolved, then the dial.
    public func attempt() async -> ReconnectOutcome {
        let pairings: [(sessionId: String, identityKey: Data)]
        do {
            pairings = try held.identityKeys()
        } catch {
            // ⚠ The Keychain refused to be read — on a locked device, most
            // likely, since `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is
            // what these are stored under. Nothing is held **that can be used**,
            // which is the same answer for the caller and is not a discovery
            // failure to dress up as one.
            return .noPairingsHeld
        }
        guard pairings.isEmpty == false else { return .noPairingsHeld }

        if searchStartedNs == nil { searchStartedNs = nowNs() }
        sweeps += 1

        let found = await browser.browse(against: pairings.map(\.identityKey),
                                         seconds: cadence.sweepSeconds)

        // ⛔ 3.5e — the **host** advertises. A `capture` or `observer` instance
        // that resolved against a held pairing is another device of this user's,
        // and dialling it would be this device trying to be a host.
        let hosts = found.filter { $0.role == .host }
        guard hosts.isEmpty == false else {
            return .notFound(Silence(sweeps: sweeps,
                                     searchedForNs: nowNs() - (searchStartedNs ?? nowNs()),
                                     pairingsHeld: pairings.count))
        }

        // ⛔ A refusal outranks unreachability, exactly as it does on the code
        // path: if any host answered, "nothing was found" is false, and telling
        // the user to go and fix a network that just answered them is the error
        // `RendezvousCoordinator.hostRefusedTheCode` exists to prevent.
        var refusal: (sessionId: String, reason: String)?
        var unreachable: (sessionId: String, reason: String)?

        for host in hosts {
            guard host.pairingIndex >= 0, host.pairingIndex < pairings.count else {
                // 3.4b's index came from the resolver against this very table, so
                // this cannot happen — and if it ever does, it is not an instance
                // to connect to (3.4c).
                continue
            }
            let sessionId = pairings[host.pairingIndex].sessionId
            // ⚠ `try?` flattens, so one unwrap covers both "the read failed"
            // and "the pairing is gone" — and both mean the same thing here:
            // there is no key material, so there is nothing to dial with.
            guard let keys = try? held.keys(sessionId) else { continue }

            do {
                // ⛔ 5.3a — a **fresh** PSK identity per connection, drawn inside
                // `RendezvousCredentials`. ⚠ The same type the code path and the
                // guided path build, over the same `RendezvousKeys`: 11.1a says a
                // pairing is a pairing, and sharing the code is how that stays
                // true rather than being asserted.
                let transport = try await connector.connect(
                    to: host.endpoint,
                    credentials: RendezvousCredentials(keys: keys),
                    channels: PpcpChannel.required)
                // ⚠ A name is a nicety; failing to read one is not a reason to
                // drop a link that just came up.
                let name = (try? held.displayName(sessionId)).flatMap { $0 }
                return .connected(ReconnectedHost(
                    transport: transport,
                    sessionId: sessionId,
                    security: transport.security,
                    hostDisplayName: name,
                    instanceName: host.instanceName))
            } catch TransportError.handshakeFailed(let reason) {
                if refusal == nil { refusal = (sessionId, reason) }
            } catch {
                if unreachable == nil {
                    unreachable = (sessionId, String(describing: error))
                }
            }
        }

        if let refusal {
            return .hostRefusedThePairing(sessionId: refusal.sessionId,
                                          reason: refusal.reason)
        }
        if let unreachable {
            return .couldNotReachHost(sessionId: unreachable.sessionId,
                                      reason: unreachable.reason)
        }
        // Every resolved host was skipped for want of key material — which means
        // the pairing was revoked between the browse and the dial. Nothing is
        // reachable and nothing refused us.
        return .notFound(Silence(sweeps: sweeps,
                                 searchedForNs: nowNs() - (searchStartedNs ?? nowNs()),
                                 pairingsHeld: pairings.count))
    }

    /// Sweeps on the cadence until a link comes up, the caller stops listening,
    /// or there is nothing held to look for.
    ///
    /// ⚠ **Every outcome is yielded, including every `notFound`.** A caller that
    /// only heard about success could not tell a search that had just begun from
    /// one that had been going for a minute, which is precisely the distinction
    /// 3.6a's silence must not cost.
    ///
    /// ⛔ Terminates on `.connected` — the transport is handed over and dialling
    /// a second one would be two links to the same host — and on
    /// `.noPairingsHeld`, which no amount of waiting changes. A refusal or an
    /// unreachable host is yielded and then **retried**: a host restarted, or a
    /// pairing re-established on the other end, is exactly the case waiting is
    /// for.
    public func search() -> AsyncStream<ReconnectOutcome> {
        AsyncStream { continuation in
            let task = Task {
                while Task.isCancelled == false {
                    let outcome = await self.attempt()
                    continuation.yield(outcome)
                    switch outcome {
                    case .connected, .noPairingsHeld:
                        continuation.finish()
                        return
                    case .notFound, .hostRefusedThePairing, .couldNotReachHost:
                        break
                    }
                    let gap = await self.gapAfterCurrentSweep()
                    try? await Task.sleep(for: .nanoseconds(gap))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func gapAfterCurrentSweep() -> Int64 {
        cadence.gapNs(afterSweep: sweeps)
    }
}
