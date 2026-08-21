//
//  StatusChip.swift
//  PinPointCapture design system
//

import SwiftUI

/// A small pill carrying one short phrase in a ``StatusTone``.
///
/// Used for per-shot sync state on C3 (`In Studio` accent, `Sending 61%`
/// progress, `On device` neutral), for the evidence chips on A3's choice cards,
/// and for the `LIKELY` / `UNLIKELY` badges on B5.
///
/// **Three words, not icons.** A chip never takes a symbol: a golfer glancing at
/// the shot list from the mat has to read a *state*, and a coloured glyph does
/// not say whether the host has confirmed the shot. There is deliberately no
/// `systemImage` parameter and one must not be added.
///
/// `In Studio` means confirmed by the host, never merely uploaded.
public struct StatusChip: View {

    private let title: String
    private let tone: StatusTone

    /// - Parameters:
    ///   - title: the phrase, ideally two or three words. Sentence case, except
    ///     for the B5 badges which are upper case in the design.
    ///   - tone: the meaning. Note that no chip anywhere in the app is
    ///     ``StatusTone/error``-toned for capture state.
    public init(_ title: String, tone: StatusTone = .neutral) {
        self.title = title
        self.tone = tone
    }

    public var body: some View {
        Text(title)
            .font(.ppStatusChip)
            .foregroundStyle(tone == .neutral ? Color(.secondaryLabel) : tone.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tone.background, in: .rect(cornerRadius: PPMetrics.Radius.small))
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: Text {
        if let description = tone.accessibilityDescription {
            Text("\(title), \(description)")
        } else {
            Text(title)
        }
    }
}

#Preview("StatusChip") {
    VStack(alignment: .leading, spacing: 16) {
        HStack {
            StatusChip("In Studio", tone: .accent)
            StatusChip("Sending 61%", tone: .progress)
            StatusChip("On device")
        }
        HStack {
            StatusChip("LIKELY", tone: .accent)
            StatusChip("UNLIKELY")
        }
        HStack {
            StatusChip("Scan a code to pair", tone: .accent)
            StatusChip("Wi-Fi or cable", tone: .accent)
        }
        HStack {
            StatusChip("No network needed")
            StatusChip("Nothing is lost")
        }
        HStack {
            StatusChip("Queueing", tone: .warning)
            StatusChip("Host is gone", tone: .error)
        }
    }
    .padding(PPMetrics.screenMargin)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(.systemBackground))
    .preferredColorScheme(.dark)
}
