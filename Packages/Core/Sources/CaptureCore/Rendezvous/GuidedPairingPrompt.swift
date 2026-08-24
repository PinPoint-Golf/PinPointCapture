//  GuidedPairingPrompt.swift
//  `PPCP-RV` 11.7d and 11.9c — the two MUSTs that are UX and are MUSTs anyway.
//
//  ⛔ **THESE ARE NOT COPY DECISIONS AND THEY DO NOT BELONG IN A VIEW.** A view
//  is where a designer reasonably moves a button, changes a verb, or makes the
//  agreeable answer the prominent one — and each of those, here, deletes a
//  normative requirement while leaving every byte on the wire unchanged. So the
//  **control set** lives in Core where a test can read it, and the view renders
//  what it is given.
//
//  ⛔ **11.7d — comparison is the obvious act and acceptance is not the
//  default.** Both peers group the digits identically (`313 164`), the
//  affirmative control is **not pre-selected and not the one a stray tap
//  reaches**, and the prompt asks whether the numbers **match** rather than
//  whether to trust or continue. *"A dialogue whose default is Continue is a
//  dialogue that authenticates whatever is on the other end."*
//
//  ⛔ **11.9c — a mismatch or a MAC failure is NOT reported in terms that invite
//  a retry.** This is unusual for a specification to state and the alternative is
//  worse: every other failure in `RV` is a network problem, users learn from
//  those that retrying is what one does, and a mismatch is **the one signal this
//  path produces that an attack is under way**. A dialogue whose reflex is *try
//  again* converts a one-shot bound into an unbounded one by way of the
//  operator's muscle memory. So where the advice is `doNotRetry` there is **no
//  affirmative control at all** — not a disabled one, not one behind a
//  confirmation.
//
//  ⚠ **11.9b bounds even the permitted retry**: a peer MUST NOT reopen the window
//  without a further explicit user action, so `retry` here means *"offer a
//  control that starts a new attempt"* and never *"reopen the one that closed"*.
//
//  Spec: `RV` 11.7a, 11.7b, 11.7c, 11.7d, 11.9b, 11.9c, 11.9d1, 11.4e. Plan D11.
//  RT-26.

import Foundation

/// What a screen shows, and — the part that matters — which controls it may
/// offer.
public struct GuidedPairingPrompt: Sendable, Equatable {

    public let heading: String
    public let body: String
    /// ⛔ `nil` means **no affirmative control may be shown**. 11.9c, and the
    /// digits' own comparison never has one that is pre-selected (11.7d).
    public let affirmative: String?
    /// Always present. The way out is never the thing a user has to hunt for.
    public let dismissive: String
    /// ⛔ 11.9c — whether a *try again* may be offered at all. Where this is
    /// `false` the honest message is *"do not retry until you know why"*.
    public let offersRetry: Bool
    /// 11.9d1 / 11.4e / 2a — §4's pairing code is REQUIRED of every
    /// implementation and does not depend on multicast, so it is the answer to
    /// both plausible causes of an `unsupported_version`.
    public let offersThePairingCode: Bool

    // MARK: 11.7 — the comparison

    /// ⛔ **The prompt asks whether the numbers MATCH.** Not whether to trust,
    /// not whether to continue, not whether to connect. 11.7d.
    ///
    /// ⚠ The digits are **not** in `body`: they are rendered at their own size
    /// and grouped by `BootstrapDigits.grouped`, because 11.7d's grouping is a
    /// MUST-adjacent property of the *display* and a string interpolated into a
    /// sentence is a string somebody reformats.
    public static func compare(dl label: String?) -> GuidedPairingPrompt {
        GuidedPairingPrompt(
            heading: "Do these numbers match?",
            body: label.map {
                "Check that \($0) is showing the same six digits. If it is not, "
                + "someone else may be on the connection."
            } ?? "Check that the other screen is showing the same six digits. "
               + "If it is not, someone else may be on the connection.",
            // ⛔ Not pre-selected and not where a stray tap lands — the view puts
            // this ABOVE the dismissive control, never in the thumb's resting
            // place. 11.7d.
            affirmative: "Yes, they match",
            dismissive: "They don't match",
            offersRetry: false,
            offersThePairingCode: false)
    }

    // MARK: 11.9 — how it ended

    /// ⛔ **11.9c in one function.** The advice comes from the `bs_abort` reason
    /// the attempt actually ended on, which is why `BootstrapWindow.Close` was
    /// given one: `attemptAbortedOrRejected` alone cannot tell a mismatch from a
    /// dropped connection, and the clause turns on exactly that.
    public static func ended(_ close: BootstrapWindow.Close) -> GuidedPairingPrompt {
        switch close.advice {
        case .doNotRetry:
            // ⛔ NO affirmative control. The two causes are an implementation
            // disagreement or somebody on the link, and neither is answered by
            // pressing the same button again.
            return GuidedPairingPrompt(
                heading: "The numbers did not match",
                body: "Do not try again until you know why. Either the two "
                    + "devices disagree about something, or someone else is on "
                    + "the connection.",
                affirmative: nil,
                dismissive: "Close",
                offersRetry: false,
                offersThePairingCode: false)

        case .offerThePairingCode:
            // 11.4e — reported to the USER as "the counterpart requires a newer
            // version", not as a generic failure: the operator is standing there
            // and can act on it. 11.9d1 — on the FIRST abort, because a second
            // attempt is guaranteed to fail identically.
            return GuidedPairingPrompt(
                heading: "The Studio needs a newer version",
                body: "That Studio is using a version of guided pairing this app "
                    + "does not have yet. A pairing code will work in the "
                    + "meantime.",
                affirmative: "Scan a pairing code",
                dismissive: "Close",
                offersRetry: false,
                offersThePairingCode: true)

        case .ordinaryFailure where close.reason == .pairingCompleted:
            return GuidedPairingPrompt(
                heading: "Paired",
                body: "This device and the Studio now share a pairing. You will "
                    + "not need to do this again.",
                affirmative: nil,
                dismissive: "Done",
                offersRetry: false,
                offersThePairingCode: false)

        case .ordinaryFailure:
            // "A timeout or a closed connection carries no such implication and
            // may be reported as the ordinary failure it is" (11.9c). ⚠ The retry
            // still needs a further explicit user action (11.9b) — this control
            // starts a NEW attempt and never reopens the window that closed.
            return GuidedPairingPrompt(
                heading: "Pairing did not finish",
                body: "The connection ended before both devices had confirmed. "
                    + "You can open a new pairing window and try again.",
                affirmative: "Open a new window",
                dismissive: "Close",
                offersRetry: true,
                offersThePairingCode: false)
        }
    }
}
