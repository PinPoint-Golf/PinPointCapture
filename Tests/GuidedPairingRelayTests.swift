//  GuidedPairingRelayTests.swift
//  `PPCP-RV` RT-20b — this application's acceptor, against `ppcp-relay`.
//
//  ⛔ **THIS IS THE ONLY THING IN THE REPOSITORY THAT CAN SEE TRAP 2.** Sending
//  `bs_accept` only after `pk_i` arrives changes **nothing on the wire**: five
//  well-formed frames in §11.5's order, the same `Z`, the same six digits, and
//  every unit test in `Packages/Core` still green. What it costs is the entire
//  security of the path — an interposer that sees the honest key before choosing
//  its own grinds until both legs show the same digits, which is 2²⁰ trials and
//  seconds of work. `--probe order-acceptor` withholds `bs_reveal` and checks
//  that `pk_a` **had already arrived**, and that is the whole of RT-20b(ii) for
//  an acceptor.
//
//  ⚠ **The instrument was verified before it was trusted**, which is this
//  repository's own rule after four "findings" in one day turned out to be its
//  tooling. `ppcp-relay --selftest` reports six rows, and the sixth is a
//  **negative control**: the same probe run against a stand-in deliberately
//  carrying trap 2 must report a failure, and does. Without that control the
//  ordering probe would be an untested test — which for a defect invisible on
//  the wire is the same as no test at all.
//
//  ## How this is driven
//
//  `make rv6` — the relay DIALS this window, so the harness has to be listening
//  before the relay starts and on a port the harness can be told about. So:
//  `build-for-testing`, launch this test in the background with
//  `TEST_RUNNER_PPCP_RV6_PORT`, wait for the port to appear in `lsof`, then run
//  the relay. Without the variable this test **skips**, which is what happens
//  under a plain `make test-app`.
//
//  ## ⛔ What is measured here and what is NOT
//
//  ⛔ **`PPCP_RV6_MODE=pair` MAKES THIS A NON-CONFORMANT PEER, exactly as
//  `ppcp-relay --peer` says of itself.** 11.7c requires an affirmative act by
//  **this device's own user**, and 11.1d says the comparison has value only
//  because it crosses a channel the attacker is not on — a person looking at two
//  screens. A harness that affirms in software has removed that channel. It is
//  used **only** to let a full five-frame exchange complete unattended, it prints
//  the digits so a person can hold them against the relay's own printed legs, and
//  **no conformance row rests on the affirmation itself**. The `compare` event
//  reaching a screen and a person acting on it is `RT-26`'s review row and the
//  UI's job, not this file's.
//
//  ⛔ **No RV-6 aggregate is claimed anywhere.** 9g forbids one while `RT-20c` is
//  unrun, and RT-20c needs both applications either side of the relay — session
//  C3, not this one.
//
//  Spec: `RV` §11.5, 11.5c, 11.7c, 11.1d, §9 RT-20b. Plan D11.

import Foundation
import Testing
import CaptureCore
@testable import PinPointCapture

@Suite("RV-6 — the acceptor against ppcp-relay", .serialized)
struct GuidedPairingRelayTests {

    /// ⚠ Shorter than 3.7b's 180-second maximum on purpose: the window's own
    /// deadline is what ends this test when no relay ever dials, and it has to
    /// land inside `xcodebuild`'s execution allowance. 3.7b is a *maximum*.
    static let windowTimeoutNs: Int64 = 60 * 1_000_000_000

    @Test("RT-20b — a real bootstrap window, held open for the relay to dial")
    func holdAWindowOpenForTheRelay() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let text = env["PPCP_RV6_PORT"], let port = UInt16(text), port != 0 else {
            print("RV6 SKIP — no PPCP_RV6_PORT. Run `make rv6`.")
            return
        }
        // Which probe is on the other end. ⛔ `pair` is the one knob that makes
        // this peer non-conformant, and nothing else sets it.
        //   order   — `--probe order-acceptor`: withholds `bs_reveal` (11.5c)
        //   decline — `--probe decline`: reaches the digits and then refuses
        //   pair    — `--peer initiator`: an honest counterpart, end to end
        let mode = env["PPCP_RV6_MODE"] ?? "order"
        let affirmInSoftware = (mode == "pair")

        let advertiser = try BootstrapAdvertiser(timeoutNs: Self.windowTimeoutNs)
        let events = await advertiser.events()
        let opened = try await advertiser.open(
            on: BootstrapWindow.UserAction(control: "pair-a-new-host")!,
            label: BootstrapLabel(operatorEntered: "Bay 1"),
            distinctFrom: nil,
            on: port)

        print("RV6 mode \(mode) listening on \(opened.port) as \(opened.instanceName)"
              + (affirmInSoftware ? "  [AFFIRM-IN-SOFTWARE — not a conformant peer]" : ""))

        var sawCompare = false
        var sawPaired = false
        var abort: (BootstrapAbortReason, BootstrapAbortAdvice)?

        // ⚠ Terminates on its own: `withdraw()` finishes the stream, and the
        // window's own deadline calls it. No sleep races a continuation here —
        // that pattern deadlocked this suite for 25 minutes once.
        for await event in events {
            switch event {
            case .compare(let digits):
                sawCompare = true
                // ⛔ 11.7d — grouped identically at both ends so a person can
                // hold them against the relay's own printed leg. This tool does
                // not compare them and never will (11.1d).
                print("RV6 digits \(digits.grouped)")
                if affirmInSoftware {
                    await advertiser.affirm(
                        on: BootstrapWindow.UserAction(control: "harness-affirm")!)
                }
            case .paired(let pairing):
                sawPaired = true
                print("RV6 paired, session \(pairing.sessionId)")
            case .aborted(let reason, let advice):
                abort = (reason, advice)
                print("RV6 aborted \(reason) advice \(advice)")
            }
        }

        let window = await advertiser.window
        // 3.7b / 11.9a — whatever happened, the window is shut and did not reopen.
        #expect(window.isOpen == false)
        print("RV6 window closed: \(String(describing: window.lastClose))")

        switch mode {
        case "pair":
            // The honest stand-in's leg completes: five frames, both users, a
            // pairing at each end. ⚠ Evidence that the exchange RUNS, not that
            // the comparison authenticated anything — the affirmation was this
            // harness's, and 11.7c wants a person's.
            #expect(sawCompare, "no comparison was reached")
            #expect(sawPaired, "the exchange did not complete")

        case "decline":
            // ⛔ RT-20b(iii) — the counterpart's user declines. 11.5g needs BOTH
            // ends, so a declined comparison pairs NEITHER, and 11.9a leaves no
            // pairing at either peer.
            #expect(sawCompare, "the decline probe declines AT the comparison")
            #expect(sawPaired == false, "⛔ a declined comparison must pair nothing")
            let ended = try #require(abort, "the attempt never ended")
            // 11.4f — a user's refusal and a failed MAC are the same code, and
            // this side cannot tell which it met. Either way 11.9c forbids
            // reporting it in terms that invite a retry.
            #expect(ended.0 == .rejected, "expected `rejected`, got \(ended.0)")
            #expect(ended.1 == .doNotRetry)
            #expect(window.lastClose?.abortReason == .rejected)
            #expect(window.lastClose?.advice == .doNotRetry)
            // ⛔ RT-20b(iv)'s half that lives HERE — 11.9b. Nothing in this
            // application reopens a window on its own, and the relay's second
            // dial is the other half. The listener is gone with the window.
            #expect(window.advertisement == nil)

        default:
            // ⛔ `--probe order-acceptor` withholds `bs_reveal` after seeing
            // `bs_accept`, so this side never derives and never displays. Reaching
            // the comparison here would mean the probe had not withheld anything.
            #expect(sawCompare == false,
                    "the ordering probe withholds bs_reveal — nothing should have been derived")
            let ended = try #require(abort, "the attempt never ended")
            // 11.3e — the probe goes silent and the attempt times out. ⚠ L21's
            // own self-test failed usefully here first: withholding used to mean
            // "keep sending", which made the honest peer abort as `malformed` for
            // a reason the harness had manufactured. Silence is what it means now.
            #expect(ended.0 == .timeout || ended.0 == .malformed)
        }
        await advertiser.close(on: BootstrapWindow.UserAction(control: "close-the-window")!)
    }
}
