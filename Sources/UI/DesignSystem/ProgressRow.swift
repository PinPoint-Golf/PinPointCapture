//
//  ProgressRow.swift
//  PinPointCapture design system
//

import SwiftUI

/// One step of a multi-step wait: a status glyph, a plain-language title, and a
/// mono detail line underneath carrying the engineering fact.
///
/// B2's four handshake rows are exactly this — the pattern is "a friendly
/// register doing work": the *name* of the step is readable by anyone, and the
/// number that proves it is happening sits below it in mono.
///
/// ```swift
/// ProgressRow("Private channel open", detail: "TLS-PSK from the code you scanned", state: .done)
/// ProgressRow("Capability agreed", detail: "1080p150 accepted · view: DTL", state: .done)
/// ProgressRow("Matching clocks", detail: "14 of 20 exchanges · offset −3.184 ms · drift 18 ppm", state: .inProgress)
/// ProgressRow("Camera warmed and locked", state: .pending)
/// ```
///
/// The detail line must reflect real progress — the exchange count is the actual
/// count, never a fake animation.
public struct ProgressRow: View {

    /// Where a step has got to.
    public enum State: String, Sendable, CaseIterable {
        /// Finished. `checkmark.circle.fill` in accent.
        case done
        /// Happening now. A system progress indicator.
        case inProgress
        /// Not started. A hollow circle in tertiary label.
        case pending
        /// Failed. `exclamationmark.circle.fill` in error.
        ///
        /// Only for the *host* handshake — a capture step never fails into red.
        case failed
    }

    private let title: String
    private let detail: String?
    private let state: State

    /// - Parameters:
    ///   - title: the step, in plain language. Never an API or protocol name.
    ///   - detail: the mono line underneath — the engineering fact that proves
    ///     the step. Optional; a pending step usually has none yet.
    ///   - state: see ``ProgressRow/State``.
    public init(_ title: String, detail: String? = nil, state: State) {
        self.title = title
        self.detail = detail
        self.state = state
    }

    public var body: some View {
        HStack(alignment: .top, spacing: PPMetrics.itemGap) {
            glyph
                .frame(width: PPMetrics.Size.rowGlyph, height: PPMetrics.Size.rowGlyph)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.ppRowLabel)
                    .foregroundStyle(state == .pending ? Color(.secondaryLabel) : Color(.label))
                if let detail {
                    Text(detail)
                        .ppMeasuredDetail()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, PPMetrics.rowPadding / 2)
        .frame(minHeight: PPMetrics.Size.minimumTapTarget, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(spokenValue))
    }

    @ViewBuilder
    private var glyph: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.ppAccent)
        case .inProgress:
            // The system indicator. It is the one place a spinner is correct,
            // and UIKit already suppresses its motion under Reduce Motion.
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
        case .pending:
            Image(systemName: "circle")
                .font(.title3)
                .foregroundStyle(Color(.tertiaryLabel))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.ppError)
        }
    }

    private var spokenState: String {
        switch state {
        case .done:       String(localized: "Done", comment: "ProgressRow state")
        case .inProgress: String(localized: "In progress", comment: "ProgressRow state")
        case .pending:    String(localized: "Waiting", comment: "ProgressRow state")
        case .failed:     String(localized: "Failed", comment: "ProgressRow state")
        }
    }

    private var spokenValue: String {
        if let detail {
            "\(spokenState). \(detail)"
        } else {
            spokenState
        }
    }
}

#Preview("ProgressRow — B2 handshake") {
    VStack(alignment: .leading, spacing: PPMetrics.groupGap) {
        VStack(alignment: .leading, spacing: 6) {
            EyebrowLabel("Pairing", tone: .accent)
            Text("Bay 3 — Mac Studio").font(.ppScreenHeading)
            Text("PinPoint Studio 0.9.4 · protocol PPCP 1.0").ppMeasuredDetail()
        }

        VStack(alignment: .leading, spacing: PPMetrics.itemGap) {
            ProgressRow("Private channel open",
                        detail: "TLS-PSK from the code you scanned",
                        state: .done)
            ProgressRow("Capability agreed",
                        detail: "1080p150 accepted · view: DTL",
                        state: .done)
            ProgressRow("Matching clocks",
                        detail: "14 of 20 exchanges · offset −3.184 ms · drift 18 ppm",
                        state: .inProgress)
            ProgressRow("Camera warmed and locked", state: .pending)
        }

        InfoCard(
            "Twenty round trips get the two clocks agreeing to a fraction of a frame. It is checked again against the sound of every shot.",
            title: "Why the wait"
        )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(PPMetrics.screenMargin)
    .background(Color(.systemBackground))
    .preferredColorScheme(.dark)
}
