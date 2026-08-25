//
//  GuidedPairingCoordinator.swift
//  `PPCP-RV` §11 end to end on the device — open a window, compare, pair, and
//  then **dial the host**.
//
//  ⛔ **11.2b — THE ROLES SWAP BETWEEN THE TWO CONNECTIONS, AND THAT IS THE
//  WHOLE POINT OF THIS FILE.** On the bootstrap connection this device is the
//  *acceptor*: it opens the window (3.7a) and PinPointStudio dials it, because
//  11.2a leaves that direction unconstrained — there is no pre-shared key at
//  first contact, so the platform limitation that shapes the rest of `RV` does
//  not reach it. *"That is what makes 'the host PC finds the device and connects
//  to it' reachable, and it is reachable only at first contact."*
//
//  The moment the pairing exists, §5 applies exactly as it does to any other
//  pairing (11.1a), and 3.5d puts this device back on the dialling end: an iOS
//  peer MUST NOT advertise for reconnection, because `Network.framework`'s
//  listener cannot resolve a rotating PSK identity server-side. **So the peer
//  that just accepted a connection now makes one.** Both directions are
//  available, on different connections, for different reasons, and neither
//  contradicts the other.
//
//  ⛔ **11.5h — the bootstrap connection is NOT upgraded in place.** It is closed
//  once both MACs verify, and §5's connection is a fresh one. A17's argument is
//  that upgrading would give §5 two shapes — one negotiated on a new connection
//  and one layered onto a live plaintext stream — and the second is a new attack
//  surface and a second code path in every implementation. The cost of not doing
//  it is one TCP setup, once, while an operator is watching a screen.
//
//  ⛔ **11.10c — everything received on the bootstrap connection is spent when it
//  closes.** Nothing from it is persisted except 11.6e's `PRK`, and only after
//  11.5g. That is why `persist` refuses before the pairing exists rather than
//  storing something provisional.
//
//  ⚠ **What this file does NOT do, stated rather than left to be discovered.** It
//  does not *find* the host. §5's endpoint comes from discovery, and 3.4c
//  requires a browsing peer to resolve an instance's `rid` against a held `K_id`
//  before connecting to it — which now has a `K_id` to work with for the first
//  time, but only once a pairing with the real PinPointStudio exists. That is
//  RT-20c and session C3. So the endpoint is a parameter here.
//
//  Spec: `RV` 11.2a, 11.2b, 11.5g, 11.5h, 11.6e, 11.10c, 3.5d, 3.7a, 7.4b, §5.
//  Plan D11.
//

import Foundation
import CaptureCore

/// Owns one guided pairing, from the user pressing a control to the §5
/// connection that follows it.
public actor GuidedPairingCoordinator {

    public enum Failure: Error, Sendable, Equatable {
        /// ⛔ 11.5g — asked for a pairing before both ends had affirmed and both
        /// MACs had verified. Until then a peer holds nothing and MUST NOT
        /// persist, advertise, or offer anything derived from the exchange.
        case noPairingYet
    }

    private let advertiser: BootstrapAdvertiser
    /// ⛔ The one pairing this attempt produced, held only until it is persisted
    /// or the coordinator is finished with. `BootstrapAcceptor` has already
    /// erased everything ephemeral (11.6f); what is left is what 11.6e says may
    /// survive.
    private var pairing: BootstrapPairing?

    public init(timeoutNs: Int64 = BootstrapAdvertisement.maximumTimeoutNs) throws {
        advertiser = try BootstrapAdvertiser(timeoutNs: timeoutNs)
    }

    /// The attempt's events, for a screen. `.compare` is what `CompareDigitsView`
    /// renders; `.paired` is what unlocks `persist` and `connectToHost`.
    public func events() async -> AsyncStream<BootstrapAdvertiser.GuidedPairingEvent> {
        await advertiser.events()
    }

    /// ⛔ 3.7a — opens only on an explicit user action, and 11.9b forbids
    /// reopening without a further one.
    @discardableResult
    public func openWindow(on action: BootstrapWindow.UserAction,
                           label: BootstrapLabel?,
                           distinctFrom ppcpListenerPort: UInt16?) async throws
    -> BootstrapAdvertiser.Opened {
        try await advertiser.open(on: action, label: label,
                                  distinctFrom: ppcpListenerPort)
    }

    /// ⛔ 11.7c — **this device's own user**. The counterpart's `bs_confirm`
    /// never reaches this method; nothing in `BootstrapAdvertiser` calls it on a
    /// received frame.
    public func affirm(on action: BootstrapWindow.UserAction) async {
        await advertiser.affirm(on: action)
    }

    /// The user said the numbers do not match. 11.4f — `rejected`, and
    /// indistinguishable to the counterpart from a failed MAC.
    public func decline(on action: BootstrapWindow.UserAction) async {
        await advertiser.decline(on: action)
    }

    /// Record what a `.paired` event handed over.
    public func remember(_ pairing: BootstrapPairing) { self.pairing = pairing }

    public func currentWindow() async -> BootstrapWindow {
        await advertiser.window
    }

    /// ⛔ 7.4b — kept without asking, as the code path is (#96). 11.1a is the
    /// reason there is no second policy here: from 11.6e onward a guided pairing
    /// is indistinguishable from a scanned one.
    ///
    /// ⚠ 7.4f's `mu` predicate has no counterpart here and needs none: there is
    /// no code, so there is no multi-use code to refuse.
    public func persist(displayName: String?) throws {
        guard let pairing else { throw Failure.noPairingYet }
        try PairingSecretStore.save(guidedPairing: pairing,
                                    displayName: displayName)
    }

    /// ⛔ **11.2b — the swap.** The peer that just accepted a bootstrap
    /// connection now dials §5's, because 3.5d leaves it no choice.
    ///
    /// ⚠ **§5 is taken verbatim and this method proves it by having nothing of
    /// its own in it.** `RendezvousCredentials` is the same type the pairing-code
    /// path builds, over the same `RendezvousKeys`, drawing a fresh PSK identity
    /// per connection under 5.3a1 — because 11.1a says a guided pairing is
    /// *indistinguishable* from a code-established one from 11.6e onward, and the
    /// way to keep that true is to share the code rather than to assert it.
    ///
    /// - Parameter endpoint: from discovery. ⛔ 3.4c — a browsing peer resolves
    ///   an instance's `rid` against a held `K_id` before connecting to it, and
    ///   an unresolvable instance is not offered at all.
    public func connectToHost(at endpoint: PeerEndpoint,
                              channels: [PpcpChannel] = PpcpChannel.required)
    async throws -> any PeerTransport {
        guard let pairing else { throw Failure.noPairingYet }
        let credentials = RendezvousCredentials(keys: pairing.keys)
        return try await PpcpConnector().connect(to: endpoint,
                                                 credentials: credentials,
                                                 channels: channels)
    }

    /// 3.7b's fourth cause — a further user action.
    public func closeWindow(on action: BootstrapWindow.UserAction) async {
        await advertiser.close(on: action)
    }

    /// ⛔ 11.6f / 11.10c — drops what the attempt produced. Safe on any path the
    /// app abandons; the acceptor's own erasure has already happened inside the
    /// advertiser.
    public func forget() { pairing = nil }
}
