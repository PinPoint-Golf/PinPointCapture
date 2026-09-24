//
//  ReconcileSessionView.swift
//  B5 — Studio has part of this session already.
//
//  ⚠ **Never auto-merge** (REQ-OFF-12). The user picks, and the *evidence* for
//  each candidate is on screen so the choice is informed rather than guessed:
//  how many shots the spacing matched, and the largest disagreement in ms.
//
//  ⚠ The orange notice is a **coverage gap**, surfaced here rather than in
//  Studio (REQ-OFF-13), so nothing downstream is analysed on absent launch
//  monitor data.
//

import SwiftUI
import CaptureCore

/// One candidate session held by the host, with the evidence for the match.
///

public struct ReconcileSessionView: View {

    private let candidates: [SessionMatchCandidate]
    private let selectedCandidateID: SessionMatchCandidate.ID?
    /// The count in "Review the 41 shots".
    private let shotCount: Int
    /// ⚠ The coverage gap. `nil` only when every shot has a launch monitor
    /// record — which is rare enough that it must not be assumed.
    private let coverageNotice: String?

    private let onSelect: (SessionMatchCandidate.ID) -> Void
    private let onReview: () -> Void
    private let onSendAsNewSession: () -> Void

    public init(
        candidates: [SessionMatchCandidate],
        selectedCandidateID: SessionMatchCandidate.ID? = nil,
        shotCount: Int,
        coverageNotice: String? = nil,
        onSelect: @escaping (SessionMatchCandidate.ID) -> Void,
        onReview: @escaping () -> Void,
        onSendAsNewSession: @escaping () -> Void
    ) {
        self.candidates = candidates
        self.selectedCandidateID = selectedCandidateID
        self.shotCount = shotCount
        self.coverageNotice = coverageNotice
        self.onSelect = onSelect
        self.onReview = onReview
        self.onSendAsNewSession = onSendAsNewSession
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PPMetrics.groupGap) {
                Text("It looks like the same range session. Nothing is merged until you say so.")
                    .font(.ppSupporting)
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: PPMetrics.itemGap + 4) {
                    ForEach(candidates) { candidate in
                        candidateBlock(candidate)
                    }
                }

                if let coverageNotice {
                    InfoCard(coverageNotice,
                             systemImage: "exclamationmark.circle.fill",
                             tone: .warning)
                }
            }
            .padding(.horizontal, PPMetrics.screenMargin)
            .padding(.bottom, PPMetrics.groupGap)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Studio has part of this session already")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom) { actions }
    }

    // MARK: - A candidate and its evidence

    private func candidateBlock(_ candidate: SessionMatchCandidate) -> some View {
        VStack(spacing: 0) {
            ChoiceCard(
                title: candidate.title,
                description: candidate.detail,
                chips: [candidate.likelihood.chipTitle],
                isSelected: candidate.id == selectedCandidateID,
                action: { onSelect(candidate.id) }
            )

            // The evidence for this candidate. Mono values, because these are
            // measurements — the whole point is that the user can check them.
            if !candidate.evidence.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(candidate.evidence.enumerated()), id: \.offset) { index, item in
                        if index > 0 {
                            Divider().overlay(Color(.separator))
                        }
                        TelemetryRow(item.label, item.value,
                                     spokenValue: item.spokenValue)
                    }
                }
                .padding(.horizontal, PPMetrics.cardPadding)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: PPMetrics.Radius.card,
                                         style: .continuous)
                )
                .padding(.horizontal, PPMetrics.itemGap)
                .padding(.top, -PPMetrics.itemGap / 2)
                .accessibilityLabel(Text("Evidence for \(candidate.title)"))
            }
        }
    }

    private var actions: some View {
        VStack(spacing: PPMetrics.itemGap) {
            Button("Review the \(shotCount) shots", action: onReview)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)

            // Inherits the app accent — no hand-applied tint on a stock control.
            Button("Send as a new session", action: onSendAsNewSession)
                .buttonStyle(.borderless)
                .font(.ppRowLabel.weight(.semibold))
                .frame(maxWidth: .infinity,
                       minHeight: PPMetrics.Size.minimumTapTarget)
        }
        .padding(.horizontal, PPMetrics.screenMargin)
        .padding(.top, PPMetrics.itemGap)
        .background(.bar)
    }
}

// MARK: - Previews

private struct ReconcileSessionPreview: View {
    static let likely = SessionMatchCandidate(
        title: "Wednesday range · 18:20",
        detail: "Studio holds 29 shots from a launch monitor",
        likelihood: .likely,
        evidence: [
            .init(label: "Shot spacing matches", value: "29 of 29"),
            .init(label: "Largest disagreement", value: "41 ms",
                  spokenValue: "41 milliseconds")
        ]
    )

    static let unlikely = SessionMatchCandidate(
        title: "Wednesday lesson · 16:05",
        detail: "12 shots, face-on cameras",
        likelihood: .unlikely
    )

    @State private var selected: SessionMatchCandidate.ID? = likely.id

    var body: some View {
        NavigationStack {
            ReconcileSessionView(
                candidates: [Self.likely, Self.unlikely],
                selectedCandidateID: selected,
                shotCount: 41,
                coverageNotice: "Shots 30 to 41 have no launch monitor record. "
                    + "They will arrive as video only.",
                onSelect: { selected = $0 },
                onReview: {},
                onSendAsNewSession: {}
            )
        }
        .preferredColorScheme(.dark)
    }
}

#Preview("B5 · Studio has part of this session already") {
    ReconcileSessionPreview()
}
