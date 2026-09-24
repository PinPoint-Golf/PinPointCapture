//
//  OnboardingStep.swift
//  PinPointCapture — onboarding
//
//  The four screens, named once, in order.
//
//  ⛔ **It was seven, and the order put framing BEFORE pairing** — Mark, 25
//  August 2026, from a real setup on a tripod. The pairing code is on the Studio
//  screen, so scanning it means carrying the phone to the Mac; framing first
//  meant clamping the phone at hip height, getting the ball in shot, and then
//  picking it all up again. **The order now follows where the golfer is
//  standing**: pair at the Mac, then walk over and set it down. Permissions stay
//  second because pairing needs the camera and the local network.
//
//  ⚠ **Three screens were cut and none of what they said was lost.** `A2 How it
//  works` was a tour of a thing not yet seen — its two load-bearing sentences
//  moved to the screens where they bite. `A3 Where are you today?` asked the
//  golfer to declare what §3's browse discovers a second later. `A5 Set it
//  down` was an undrawn placeholder above four rules the framing check already
//  verifies live, and is now a line on that screen. `A7 Ready to capture` was a
//  receipt shown on a screen you immediately leave.
//
//  ⚠ Their SCREENS still exist and are still reachable from the debug gallery;
//  what changed is that they are no longer in the sequence.
//
//  This is a *description* of the sequence, not a router. Onboarding is a linear
//  push stack and the stack is owned above this directory: no screen in here
//  holds a `NavigationStack`, routes to another screen, or keeps app state.
//  Every screen takes its state as `let` parameters and hands its actions back
//  as closures.
//

import Foundation
import CaptureCore

/// The onboarding sequence, in flow order.
///
/// Roughly ninety seconds, ending with a device that is placed well and knows
/// what it can sustain. It never assumes a host exists.
public enum OnboardingStep: String, CaseIterable, Sendable, Identifiable, Hashable {

    /// A1 — what the phone in hand can do, before anything else.
    case welcome
    /// A4 — camera and microphone first, local network last. ⛔ Before pairing,
    /// which needs both the camera (to scan) and the local network (to dial).
    case permissions
    /// B1, as a step — **at the Mac, before the phone is set down**.
    case pairing
    /// A6 — the screen that prevents a wasted session, and the last thing a
    /// golfer touches. Carries A5's placement rules.
    case framingCheck

    public var id: String { rawValue }

    /// The identifier this screen carries in the design handoff.
    ///
    /// ⚠ **No longer derived from the position in the sequence.** It was
    /// `"A\(index + 1)"`, which was true only while the sequence and the handoff
    /// agreed; three screens have left the sequence and one comes from the B
    /// series, so the mapping is now stated rather than counted.
    public var designID: String {
        switch self {
        case .welcome: "A1"
        case .permissions: "A4"
        case .pairing: "B1"
        case .framingCheck: "A6"
        }
    }

    /// The next screen in the push stack, or `nil` at the end of onboarding.
    ///
    /// ⚠ There is no *skip* on ``permissions`` or ``framingCheck``. Both have a
    /// "carry on anyway" out instead — a refused permission and a marginal light
    /// reading are decisions, not blocks. ``pairing`` **does** have one, and it is
    /// not the same thing: a golfer at a range with no Mac is not carrying on
    /// despite a problem, they are using the product as designed (REQ-STANDALONE-1).
    public var next: OnboardingStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }
}
