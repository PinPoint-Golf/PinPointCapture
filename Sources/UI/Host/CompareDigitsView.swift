//
//  CompareDigitsView.swift
//  `PPCP-RV` §11.7 — the six digits, and the one question a person is asked.
//
//  ⛔ **THIS SCREEN IS THE AUTHENTICATION.** Not the MACs, not the key
//  agreement — 11.1d and 11.4f are explicit that the comparison is what
//  authenticates and the MAC is an agreement-and-liveness proof. An interposed
//  attacker holds `Z` on both legs and forges both MACs correctly and trivially;
//  what it cannot do is make two screens show the same six digits, because
//  11.5c made it commit blind. **The only channel it is not on is a person
//  looking at two screens, and this is that person's half of it.**
//
//  ⛔ **The three things 11.7d requires, and each is easy to undo by accident:**
//
//  1. **The question is whether the numbers MATCH** — not whether to trust,
//     continue, connect or allow. *"A dialogue whose default is Continue is a
//     dialogue that authenticates whatever is on the other end."*
//  2. **The affirmative control is not pre-selected and not where a stray tap
//     lands.** On iOS the bottom-most prominent button is precisely where a thumb
//     rests, so **"They don't match" is the prominent one and it is at the
//     bottom**, and "Yes, they match" sits above it as a plain control. That
//     looks backwards next to every other sheet in this app, and it is
//     deliberate: the cost of a stray affirmative here is a pairing with an
//     attacker, and the cost of a stray refusal is one more window.
//  3. **Both peers group the digits identically** — `313 164`, from
//     `BootstrapDigits.grouped`, which is Core's and not this view's.
//
//  ⛔ **There is no timer bar, no countdown and no auto-dismiss on this screen.**
//  11.3e's sixty seconds are real and the attempt does end, but a control that
//  disappears under a finger is a control that gets pressed in a hurry, and
//  hurrying the operator is the one thing that degrades the comparison.
//
//  ⚠ **`dl` names the counterpart, and 11.3d1 is why it is here.** The operator
//  selected this window *before* the attempt began — the digits did not exist
//  yet — so the label is what that selection was made on, and repeating it here
//  is what lets a person tell which of four bays they are looking at. It is
//  operator-entered and never defaulted from a device name (3.3f).
//
//  Spec: `RV` 11.1d, 11.7a, 11.7b, 11.7c, 11.7d, 11.7e, 11.7f, 3.3f, 11.3d1.
//  Plan D11. RT-26.
//

import SwiftUI
import CaptureCore

public struct CompareDigitsView: View {

    /// ⛔ 11.7e — this view is not constructed before 11.5d has completed. There
    /// is nothing to compare before then, and a progressive display would leak
    /// the value to whichever side an attacker reached first.
    private let digits: BootstrapDigits
    /// 3.3f's `dl`, operator-entered. `nil` where none was set.
    private let label: String?

    /// ⛔ 11.7c — an affirmative act by **this device's own** user. The
    /// counterpart's `bs_confirm` never calls this.
    private let onTheyMatch: () -> Void
    /// 11.4f — reported as `rejected`, indistinguishable to the counterpart from
    /// a failed MAC.
    private let onTheyDoNotMatch: () -> Void

    public init(digits: BootstrapDigits,
                label: String?,
                onTheyMatch: @escaping () -> Void,
                onTheyDoNotMatch: @escaping () -> Void) {
        self.digits = digits
        self.label = label
        self.onTheyMatch = onTheyMatch
        self.onTheyDoNotMatch = onTheyDoNotMatch
    }

    private var prompt: GuidedPairingPrompt {
        // ⛔ The words and the control set are Core's, where a test can read
        // them. A view is where a reasonable person moves a button or changes a
        // verb, and here each of those deletes a normative requirement.
        GuidedPairingPrompt.compare(dl: label)
    }

    public var body: some View {
        VStack(spacing: PPMetrics.groupGap) {
            header
            numbers
            Spacer(minLength: 0)
        }
        .padding(.top, PPMetrics.groupGap)
        .padding(.horizontal, PPMetrics.screenMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) { actions }
        // ⛔ 11.9b — no swipe-to-dismiss. Leaving this screen is a decision, and
        // both decisions are on it. A dismissed sheet would leave an attempt
        // running with nobody watching it.
        .interactiveDismissDisabled(true)
    }

    private var header: some View {
        VStack(spacing: PPMetrics.itemGap) {
            Text(prompt.heading)
                .font(.ppScreenHeading)
                .foregroundStyle(Color(.label))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(prompt.body)
                .font(.ppSupporting)
                .foregroundStyle(Color(.secondaryLabel))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// ⛔ 11.7a — **exactly six decimal digits with leading zeros**; `000042` is a
    /// valid string and is shown as six characters. Monospaced so the two screens
    /// line up character for character, which is what makes a mismatch in one
    /// position visible rather than merely present.
    private var numbers: some View {
        Text(digits.grouped)
            .font(.system(.largeTitle, design: .monospaced).weight(.bold))
            .monospacedDigit()
            .foregroundStyle(Color(.label))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            // ⚠ Read out digit by digit rather than as a number: VoiceOver says
            // "three hundred and thirteen thousand" for `313164` otherwise, which
            // cannot be compared against a printed string.
            .accessibilityLabel(spokenDigits)
            .padding(.vertical, PPMetrics.itemGap)
            .frame(maxWidth: .infinity)
    }

    private var spokenDigits: String {
        digits.text.map(String.init).joined(separator: " ")
    }

    /// ⛔ **The order here is 11.7d and it is not a style choice.** The
    /// destructive answer is prominent and at the bottom, where a stray tap
    /// lands; the affirmative is above it, plain, and nothing pre-selects it.
    private var actions: some View {
        VStack(spacing: PPMetrics.itemGap) {
            if let affirmative = prompt.affirmative {
                Button(affirmative, action: onTheyMatch)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
            }

            Button(prompt.dismissive, role: .destructive, action: onTheyDoNotMatch)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
        }
        .padding(.horizontal, PPMetrics.screenMargin)
        .padding(.top, PPMetrics.itemGap)
        .background(.bar)
    }
}

// MARK: - Previews

#Preview("RV 11.7 · Do these numbers match?") {
    CompareDigitsView(digits: BootstrapDigits(value: 313_164)!,
                      label: "Bay 3",
                      onTheyMatch: {},
                      onTheyDoNotMatch: {})
    .preferredColorScheme(.dark)
}

/// ⛔ 11.7a's own example — `000042` is a valid string and MUST be shown as six
/// characters. The preview exists so a designer meets it before a user does.
#Preview("RV 11.7a · leading zeros") {
    CompareDigitsView(digits: BootstrapDigits(value: 42)!,
                      label: nil,
                      onTheyMatch: {},
                      onTheyDoNotMatch: {})
    .preferredColorScheme(.dark)
}
