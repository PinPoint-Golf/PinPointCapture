//
//  HostOrStandaloneScreen.swift
//  PinPointCapture — onboarding A3
//

import SwiftUI
import CaptureCore

/// Which of the two A3 cards is selected.
///
/// ⚠ This is a *routing* choice and nothing else. It is reversible at any time,
/// which is why A3 is two tappable cards rather than a `Picker` or a `Toggle`,
/// and why the sub-heading says so out loud.
public enum CaptureContext: String, Sendable, CaseIterable, Identifiable, Hashable {
    /// UC-2: paired with PinPoint Studio, shots correlated as they happen.
    case withHost
    /// UC-1, and the **normal** case: the session is complete on the device.
    case standalone

    public var id: String { rawValue }
}

/// **A3 Where are you today?**
///
/// ⚠ The two cards carry equal visual weight and equal copy length by design.
/// Standalone (REQ-STANDALONE-1, UC-1) is the normal case, not the consolation
/// prize — do not add a "recommended" badge, reorder for emphasis, or let the
/// host card grow. The footnote does the real work: it removes the fear of
/// picking wrong, which is what makes people abandon setup.
public struct HostOrStandaloneScreen: View {

    private let selection: CaptureContext
    private let onSelect: (CaptureContext) -> Void
    private let onContinue: () -> Void

    /// - Parameters:
    ///   - selection: the currently chosen context.
    ///   - onSelect: the user tapped a card. Always allowed, in both directions.
    ///   - onContinue: continues into A4.
    public init(
        selection: CaptureContext,
        onSelect: @escaping (CaptureContext) -> Void,
        onContinue: @escaping () -> Void
    ) {
        self.selection = selection
        self.onSelect = onSelect
        self.onContinue = onContinue
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PPMetrics.itemGap) {
                Text("This only changes what happens next. You can switch whenever you like.")
                    .font(.ppSupporting)
                    .foregroundStyle(Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, PPMetrics.itemGap)

                ChoiceCard(
                    title: "In a studio, with a host",
                    description: "Pair with PinPoint Studio. Shots are correlated as you hit them and the video follows across the network.",
                    chips: ["Scan a code to pair", "Wi-Fi or cable"],
                    isSelected: selection == .withHost,
                    action: { onSelect(.withHost) }
                )

                ChoiceCard(
                    title: "At a range, on my own",
                    description: "Capture and review here. The session is complete on the device and goes to Studio later — tonight, or next week.",
                    chips: ["No network needed", "Nothing is lost"],
                    isSelected: selection == .standalone,
                    action: { onSelect(.standalone) }
                )

                InfoCard(
                    "A host that appears mid-session is picked up automatically. A host that disappears is not a problem — capture carries on either way.",
                    systemImage: "info.circle"
                )
                .padding(.top, PPMetrics.itemGap)
            }
            .padding(.horizontal, PPMetrics.screenMargin)
            .padding(.vertical, PPMetrics.itemGap)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Where are you today?")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom) {
            Button("Continue", action: onContinue)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
                .padding(.horizontal, PPMetrics.screenMargin)
                .padding(.bottom, PPMetrics.itemGap)
                .background(.bar)
        }
    }
}

#Preview("A3 — Host or standalone") {
    @Previewable @State var selection: CaptureContext = .withHost

    NavigationStack {
        HostOrStandaloneScreen(
            selection: selection,
            onSelect: { selection = $0 },
            onContinue: {}
        )
    }
    .preferredColorScheme(.dark)
}
