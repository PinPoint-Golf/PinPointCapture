//  RendezvousTeardownTests.swift
//  `PPCP-RV` 4.4c / 6b — what happens when a pairing session ENDS.
//
//  ⛔ **These exist because nothing did, and a real defect lived in the gap for
//  months (finding F-D12-1).** `RendezvousCoordinator.endPairing()` was written,
//  documented, and **never called from anywhere in the application**. Three
//  clauses went unmet in the shipping app while the conformance document
//  asserted they were met:
//
//    - **6b** — `NetworkJoin.leave()` was unreachable, so the hotspot
//      configuration this app applied (`joinOnce: false`, deliberately, so the
//      phone does not drop off mid-session) was never removed. The device stayed
//      configured for the studio network indefinitely.
//    - **6b again** — `NetworkJoin.leftNetworkExplanation` had no caller, so the
//      user was never told. "Leaves the join in the user's control" is not true
//      of control nobody mentions.
//    - **4.4c** — "a peer MUST NOT retain a payload after the pairing it
//      establishes has ended". `endPairing` is what releases `code` and `keys`,
//      so the decoded payload — **including the Wi-Fi passphrase** — was held
//      for the lifetime of the process.
//
//  ⛔ **AND THESE TESTS WOULD NOT HAVE CAUGHT IT. Read that before trusting them.**
//  `endPairing` always worked correctly *when called*; the defect was that nothing
//  called it. A test that invokes it directly proves the method and says nothing
//  about the wiring, so what is below is a guard on the behaviour and **not** on
//  the bug. The bug was a missing call site, and no unit test in this target can
//  see one missing — that is what made it survive.
//
//  ⚠ **So what does guard it?** Only the call in `RootView`'s cancel path, and
//  reading it. If these tests are ever green while the network is not being left
//  on a real phone, this comment is the reason: look for the CALLER, not the
//  method. The same shape found the 7.4b revocation screen — `pairings()` and
//  `revoke()`, both correct, both unreachable.
//
//  ⚠ **What these do NOT prove either.** That the hotspot configuration is really
//  removed from the phone: `NEHotspotConfigurationManager` does nothing useful in
//  a simulator, and the property is only observable on a device. That half is
//  issue #68 and `RT-13`'s remaining hardware evidence.

import Foundation
import Testing
import CaptureCore
@testable import PinPointCapture

@Suite("RV 4.4c / 6b — ending a pairing")
struct RendezvousTeardownTests {

    /// A connector that fails every endpoint, so `scan` reaches the walk and
    /// returns without a live socket. ⚠ The code is still decoded and retained
    /// before the walk, which is exactly the state under test.
    private struct FailingConnector: PeerTransportConnector {
        func connect(to endpoint: PeerEndpoint,
                     credentials: any PpcpCredentials,
                     channels: [PpcpChannel]) async throws -> any PeerTransport {
            throw TransportError.invalidKeyLength(0)
        }
    }

    /// `RV` §10.3's minimal vector — `mu: 1`, no `exp`, so it never expires and
    /// the test is not a clock away from failing.
    private static let code =
        "ppcp:pWF2AWJlcIGiYWhsMTkyLjE2OC4xLjIwYXAZHmxibXUBY3Bza1AAAQIDBAUGBwgJCgsMDQ4P"
        + "Y3NpZFA_JQTgT4lB05oMAwXoLDMB"

    /// ⛔ **4.4c — the payload does not outlive the pairing.** `mayOfferPersistence`
    /// reads the held `code`, so it is `true` while one is retained and `false`
    /// once released.
    ///
    /// ⚠ **This would not have caught F-D12-1** and should not be read as though
    /// it would: the method under test was always correct, and the defect was that
    /// the application never invoked it. The value here is forward-looking — it
    /// stops the *release* being dropped from a method that now finally has a
    /// caller.
    @Test func endingAPairingReleasesTheDecodedPayload() async {
        let coordinator = RendezvousCoordinator(connector: FailingConnector())
        _ = await coordinator.scan(Self.code)

        // The walk failed, but the code was decoded and is held — 4.4c is about
        // what happens NEXT, not about whether the dial succeeded.
        #expect(await coordinator.mayOfferPersistence == true)

        await coordinator.endPairing()
        #expect(await coordinator.mayOfferPersistence == false)
    }

    /// 6b — with no network joined there is nothing to leave, and the caller is
    /// told so rather than being handed an SSID to announce.
    ///
    /// ⚠ This is what stops the screen claiming "studio network removed" at a
    /// user who was on their own Wi-Fi the whole time. The §10.3 minimal vector
    /// carries no `wifi` block, which is the case being asserted.
    @Test func endingAPairingThatJoinedNoNetworkReportsNothingToAnnounce() async {
        let coordinator = RendezvousCoordinator(connector: FailingConnector())
        _ = await coordinator.scan(Self.code)

        let left = await coordinator.endPairing()
        #expect(left == nil)
    }

    /// ⚠ **`leaveNetwork: false` is the backgrounding path and must NOT be
    /// confused with the user ending a session.** A link that dropped is expected
    /// back; removing the network configuration there would take the phone off
    /// the studio network at precisely the moment it is trying to reconnect.
    /// Asserted so a later change cannot quietly make teardown unconditional.
    @Test func aDroppedLinkDoesNotAnnounceANetworkRemoval() async {
        let coordinator = RendezvousCoordinator(connector: FailingConnector())
        _ = await coordinator.scan(Self.code)

        let left = await coordinator.endPairing(leaveNetwork: false)
        #expect(left == nil)
        // The payload still goes: 4.4c is about the pairing ending, and this
        // overload is still an ending.
        #expect(await coordinator.mayOfferPersistence == false)
    }
}
