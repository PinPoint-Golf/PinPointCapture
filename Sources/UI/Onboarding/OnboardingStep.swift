//
//  OnboardingStep.swift
//  PinPointCapture — onboarding
//
//  The seven screens, named once, in order.
//
//  This is a *description* of the sequence, not a router. Onboarding is a linear
//  push stack and the stack is owned above this directory: no screen in here
//  holds a `NavigationStack`, routes to another screen, or keeps app state.
//  Every screen takes its state as `let` parameters and hands its actions back
//  as closures.
//

import Foundation

/// The onboarding sequence, in flow order.
///
/// Roughly ninety seconds, ending with a device that is placed well and knows
/// what it can sustain. It never assumes a host exists.
public enum OnboardingStep: String, CaseIterable, Sendable, Identifiable, Hashable {

    /// A1 — the measured capability of the phone in hand, before anything else.
    case welcome
    /// A2 — you never press record; video can reach Studio long after the shot.
    case howItWorks
    /// A3 — a routing choice, and reversible. Standalone is the normal case.
    case hostOrStandalone
    /// A4 — camera and microphone first, local network last.
    case permissions
    /// A5 — guidance, not configuration.
    case placement
    /// A6 — the screen that prevents a wasted session.
    case framingCheck
    /// A7 — claimed and measured capability together, and the self-test receipt.
    case ready

    public var id: String { rawValue }

    /// The identifier this screen carries in the design handoff — `"A1"` … `"A7"`.
    public var designID: String {
        "A\((Self.allCases.firstIndex(of: self) ?? 0) + 1)"
    }

    /// The next screen in the push stack, or `nil` at the end of onboarding.
    ///
    /// ⚠ There is no *skip* on ``permissions`` or ``framingCheck``. Both have a
    /// "carry on anyway" out instead — a refused permission and a marginal light
    /// reading are decisions, not blocks.
    public var next: OnboardingStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }
}
