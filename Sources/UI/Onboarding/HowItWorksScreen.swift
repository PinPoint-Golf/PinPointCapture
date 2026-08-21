//
//  HowItWorksScreen.swift
//  PinPointCapture — onboarding A2
//

import SwiftUI
import CaptureCore

/// **A2 How it works.** The single explanatory screen, and it exists to set the
/// two expectations that otherwise become support traffic:
///
/// 1. You never press record — the device retains the seconds around each impact.
/// 2. Video can reach Studio long after the shot did, and that is normal.
///
/// Four numbered rows, one `Continue`. Nothing here is configurable.
public struct HowItWorksScreen: View {

    private let onContinue: () -> Void

    public init(onContinue: @escaping () -> Void) {
        self.onContinue = onContinue
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PPMetrics.groupGap) {
                ForEach(Array(Self.steps.enumerated()), id: \.element.title) { index, step in
                    StepRow(number: index + 1, title: step.title, detail: step.detail)
                }
            }
            .padding(.horizontal, PPMetrics.screenMargin)
            .padding(.vertical, PPMetrics.itemGap)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemBackground))
        .navigationTitle("How it works")
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

    // MARK: - Copy

    private struct Step {
        let title: String
        let detail: String
    }

    private static let steps: [Step] = [
        Step(
            title: "Place the device",
            detail: "On a tripod, facing the mat. Down the line, face on, or behind you — it works out which and tells the host."
        ),
        Step(
            title: "Arm it, then hit",
            detail: "It records continuously and keeps the few seconds around each impact. Nothing to press between shots."
        ),
        Step(
            title: "Review between shots",
            detail: "Step frame by frame from impact and draw on it. Reviewing never stops the camera."
        ),
        Step(
            title: "Send to Studio when you can",
            detail: "Now over Wi-Fi, or at home over a cable. Sessions wait on the device until Studio confirms it has them."
        )
    ]
}

// MARK: - Row

/// One numbered step. Screen-local layout: an accent-wash number tile beside a
/// title and one line of consequence.
private struct StepRow: View {

    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: PPMetrics.itemGap + 2) {
            Text(number, format: .number)
                .font(.ppRowLabel.weight(.semibold))
                .foregroundStyle(Color.ppAccent)
                .frame(
                    width: PPMetrics.Size.minimumTapTarget,
                    height: PPMetrics.Size.minimumTapTarget
                )
                .background(
                    Color.ppAccentWash,
                    in: .rect(cornerRadius: PPMetrics.Radius.control)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.ppRowLabel.weight(.semibold))
                    .foregroundStyle(Color(.label))
                Text(detail)
                    .font(.ppSupporting)
                    .foregroundStyle(Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Step \(number). \(title)"))
        .accessibilityValue(Text(detail))
    }
}

#Preview("A2 — How it works") {
    NavigationStack {
        HowItWorksScreen(onContinue: {})
    }
    .preferredColorScheme(.dark)
}
