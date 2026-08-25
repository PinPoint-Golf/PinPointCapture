//  GuidedPairingCoordinatorTests.swift
//  `PPCP-RV` 11.5g and 11.2b — what may be held, and when the roles swap.
//
//  ⛔ 11.5g is the clause with the sharpest edge in §11: *"The pairing exists
//  only when a peer has BOTH affirmed at its own end and verified the
//  counterpart's MAC. Until then it holds nothing and MUST NOT persist,
//  advertise, or offer anything derived from the exchange."* A peer computes the
//  whole chain the moment it holds `Z` — up to the sixty seconds 11.3e allows
//  before either user has acted — so there is a real window in which a `PRK`
//  exists for a pairing that does not. **Computing is not holding.**
//
//  Spec: `RV` 11.1a, 11.2b, 11.5g, 11.6e, 7.4b. Plan D11.

import Foundation
import Testing
import CaptureCore
@testable import PinPointCapture

@Suite("RV 11.5g / 11.2b — the coordinator", .serialized)
struct GuidedPairingCoordinatorTests {

    @Test("⛔ 11.5g — nothing may be persisted or dialled before the pairing exists")
    func nothingBeforeThePairing() async throws {
        let coordinator = try GuidedPairingCoordinator()
        await #expect(throws: GuidedPairingCoordinator.Failure.noPairingYet) {
            try await coordinator.persist(displayName: "Studio")
        }
        await #expect(throws: GuidedPairingCoordinator.Failure.noPairingYet) {
            _ = try await coordinator.connectToHost(
                at: PeerEndpoint(host: "127.0.0.1", port: 1))
        }
    }

    /// ⚠ **The persistence round trip is NOT tested here, and the reason is the
    /// guarantee rather than an omission.** `BootstrapPairing` has no public
    /// initialiser — 11.5g means the only way to obtain one is to complete an
    /// exchange — so this target cannot fabricate one, and PinPointCapture is
    /// acceptor-only (CA4) so it has no initiator to complete one against. The
    /// re-derivation half of 11.1a is asserted in `Packages/Core` where a real
    /// exchange runs; the persistence half runs for the first time against
    /// PinPointStudio, which is RT-20c and session C3.
}
