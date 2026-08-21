//
//  PlacementGuidanceScreen.swift
//  PinPointCapture — onboarding A5
//

import SwiftUI
import CaptureCore

/// **A5 Set it down.** Guidance, not configuration.
///
/// The app classifies its own viewpoint rather than asking the user to declare
/// it (REQ-SETUP-2), so nothing on this screen is a control. It is four rules
/// and a diagram.
///
/// ⚠ The diagram is an explicit **placeholder** — a dashed box, exactly as the
/// handoff shipped it. Do not invent an illustration here. Once a real drawing
/// of the three positions around a mat exists, most of the body copy below can
/// go with it.
public struct PlacementGuidanceScreen: View {

    private let onCheckFraming: () -> Void

    /// - Parameter onCheckFraming: continues into A6.
    public init(onCheckFraming: @escaping () -> Void) {
        self.onCheckFraming = onCheckFraming
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PPMetrics.groupGap) {
                Text("Anywhere you like. Behind you works well in a small bay.")
                    .font(.ppSupporting)
                    .foregroundStyle(Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)

                placementDiagramPlaceholder

                VStack(alignment: .leading, spacing: PPMetrics.groupGap - 4) {
                    ForEach(Self.rules, id: \.self) { rule in
                        RuleRow(text: rule)
                    }
                }
            }
            .padding(.horizontal, PPMetrics.screenMargin)
            .padding(.vertical, PPMetrics.itemGap)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Set it down")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom) {
            Button("Check the framing", action: onCheckFraming)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
                .padding(.horizontal, PPMetrics.screenMargin)
                .padding(.bottom, PPMetrics.itemGap)
                .background(.bar)
        }
    }

    // MARK: - Placeholder

    /// A dashed box that says what it is. It stands in for an illustration that
    /// does not exist yet and needs a designer, not code.
    private var placementDiagramPlaceholder: some View {
        VStack(spacing: PPMetrics.itemGap) {
            EyebrowLabel("Placeholder")
            Text("Placement diagram — the three common positions around a mat, with rough distances")
                .font(.ppSupporting)
                .foregroundStyle(Color(.tertiaryLabel))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PPMetrics.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 260)
        .overlay {
            RoundedRectangle(cornerRadius: PPMetrics.Radius.card)
                .strokeBorder(
                    Color(.tertiaryLabel),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Placement diagram"))
        .accessibilityValue(Text("Placeholder. An illustration of the three common positions around a mat is not drawn yet."))
    }

    // MARK: - Copy

    private static let rules: [String] = [
        "Tripod, or anything that will not move. Handheld will not do.",
        "Roughly hip height, landscape, whole swing in view.",
        "As much light on the ball as you can manage. Indoors, this matters more than anything else.",
        "Once armed, leave the lens alone. Switching lens mid-session restarts calibration."
    ]
}

// MARK: - Row

private struct RuleRow: View {

    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PPMetrics.itemGap) {
            Text(verbatim: "•")
                .font(.ppFootnote)
                .foregroundStyle(Color.ppAccent)
                .accessibilityHidden(true)

            Text(text)
                .font(.ppRowLabel)
                .foregroundStyle(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(text))
    }
}

#Preview("A5 — Placement guidance") {
    NavigationStack {
        PlacementGuidanceScreen(onCheckFraming: {})
    }
    .preferredColorScheme(.dark)
}
