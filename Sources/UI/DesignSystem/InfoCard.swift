//
//  InfoCard.swift
//  PinPointCapture design system
//

import SwiftUI
import CaptureCore

/// A grouped-background card carrying one sentence of explanation, optionally
/// with an SF Symbol, an eyebrow, or a short title.
///
/// Where it is used:
///
/// - **A1** — the capability card, eyebrow `THIS DEVICE`, accent tone.
/// - **A3** — the footnote about a host appearing mid-session, neutral.
/// - **A7** — "Not connected to a host. Everything is kept here until you send
///   it.", neutral, `info.circle` — deliberately *not* a warning.
/// - **B2** — "Why the wait", neutral, titled.
/// - **B5** — "Shots 30 to 41 have no launch monitor record.", warning.
/// - **B6** — "To fix it", neutral, titled.
///
/// Tone discipline: a card is ``StatusTone/warning`` only when something is
/// degraded but capture continues, and ``StatusTone/error`` only when the host
/// is gone or a permission is blocked. "No host" on A7 is a normal, expected
/// state and stays neutral.
public struct InfoCard: View {

    private let eyebrow: String?
    private let systemImage: String?
    private let title: String?
    private let message: String
    private let tone: StatusTone

    /// - Parameters:
    ///   - message: one sentence, in plain language. The whole point of the
    ///     component; everything else is optional.
    ///   - title: a short bold line above the message — B2's "Why the wait",
    ///     B6's "To fix it". Exposed to VoiceOver as a header.
    ///   - eyebrow: an upper-case mono label above the title — A1's
    ///     `THIS DEVICE`. Renders an ``EyebrowLabel``.
    ///   - systemImage: an SF Symbol name. Never a redrawn glyph.
    ///   - tone: colours the symbol, the eyebrow, the border and the background
    ///     wash.
    public init(
        _ message: String,
        title: String? = nil,
        eyebrow: String? = nil,
        systemImage: String? = nil,
        tone: StatusTone = .neutral
    ) {
        self.message = message
        self.title = title
        self.eyebrow = eyebrow
        self.systemImage = systemImage
        self.tone = tone
    }

    public var body: some View {
        HStack(alignment: .top, spacing: PPMetrics.itemGap) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(tone == .neutral ? Color(.secondaryLabel) : tone.foreground)
                    .frame(width: PPMetrics.Size.rowGlyph, alignment: .center)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let eyebrow {
                    EyebrowLabel(eyebrow, tone: tone)
                }
                if let title {
                    Text(title)
                        .font(.ppCardTitle)
                        .foregroundStyle(Color(.label))
                        .accessibilityAddTraits(.isHeader)
                }
                Text(message)
                    .font(.ppSupporting)
                    .foregroundStyle(Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(PPMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: .rect(cornerRadius: PPMetrics.Radius.card))
        .overlay {
            if tone != .neutral {
                RoundedRectangle(cornerRadius: PPMetrics.Radius.card)
                    .strokeBorder(tone.foreground.opacity(0.35), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(spokenLabel))
    }

    private var background: Color {
        tone == .neutral ? Color(.secondarySystemBackground) : tone.background
    }

    private var spokenLabel: String {
        [tone.accessibilityDescription, eyebrow, title, message]
            .compactMap { $0 }
            .joined(separator: ". ")
    }
}

#Preview("InfoCard") {
    ScrollView {
        VStack(spacing: PPMetrics.itemGap) {
            InfoCard(
                "iPhone 15 Pro — 1080p at up to 240 fps, wide and ultra-wide. Good for capture.",
                eyebrow: "This device",
                tone: .accent
            )
            InfoCard(
                "A host that appears mid-session is picked up automatically. A host that disappears is not a problem — capture carries on either way.",
                systemImage: "info.circle"
            )
            InfoCard(
                "Not connected to a host. Everything is kept here until you send it.",
                systemImage: "info.circle"
            )
            InfoCard(
                "Twenty round trips get the two clocks agreeing to a fraction of a frame. It is checked again against the sound of every shot.",
                title: "Why the wait"
            )
            InfoCard(
                "Shots 30 to 41 have no launch monitor record. They will arrive as video only.",
                systemImage: "exclamationmark.circle.fill",
                tone: .warning
            )
            InfoCard(
                "Settings — PinPointCapture — turn on Local Network, then come back.",
                title: "To fix it",
                systemImage: "wifi.slash",
                tone: .error
            )
        }
        .padding(PPMetrics.screenMargin)
    }
    .background(Color(.systemBackground))
    .preferredColorScheme(.dark)
}
