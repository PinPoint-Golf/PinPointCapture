//
//  EyebrowLabel.swift
//  PinPointCapture design system
//

import SwiftUI
import CaptureCore

/// A small upper-case mono label with wide tracking, sitting above the thing it
/// names: `PAIRING` on B2, `THIS DEVICE` on A1's capability card,
/// `OR CARRY ON WITHOUT IT` on B6, `GOLFER · IN FRAME` on A6's detection box.
///
/// It is a *label for a region*, not a heading in the document outline, so it is
/// exposed to VoiceOver as plain text and the real heading next to it keeps the
/// `.isHeader` trait.
///
/// Inside a `List`, a plain `Section("…")` header already looks like this — use
/// the section header. Reach for `EyebrowLabel` only outside list structure.
public struct EyebrowLabel: View {

    private let text: String
    private let tone: StatusTone

    /// - Parameters:
    ///   - text: written in any case; it is upper-cased for display. VoiceOver
    ///     is given the string as you wrote it, so `"This device"` is spoken as
    ///     words rather than spelled out.
    ///   - tone: ``StatusTone/accent`` for `PAIRING`, ``StatusTone/neutral`` for
    ///     structural labels such as `OR CARRY ON WITHOUT IT`.
    public init(_ text: String, tone: StatusTone = .neutral) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(text.uppercased())
            .font(.ppEyebrow)
            .tracking(1.0)
            .foregroundStyle(tone == .neutral ? Color(.secondaryLabel) : tone.foreground)
            .accessibilityElement()
            .accessibilityLabel(Text(text))
    }
}

#Preview("EyebrowLabel") {
    VStack(alignment: .leading, spacing: PPMetrics.groupGap) {
        VStack(alignment: .leading, spacing: 6) {
            EyebrowLabel("Pairing", tone: .accent)
            Text("Bay 3 — Mac Studio").font(.ppScreenHeading)
            Text("PinPoint Studio 0.9.4 · protocol PPCP 1.0")
                .ppMeasuredDetail()
        }
        VStack(alignment: .leading, spacing: 6) {
            EyebrowLabel("This device", tone: .accent)
            Text("iPhone 15 Pro — 1080p at up to 240 fps, wide and ultra-wide. Good for capture.")
                .font(.ppSupporting)
        }
        EyebrowLabel("Or carry on without it")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(PPMetrics.screenMargin)
    .background(Color(.systemBackground))
    .preferredColorScheme(.dark)
}
