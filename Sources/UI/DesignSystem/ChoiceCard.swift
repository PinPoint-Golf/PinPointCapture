//
//  ChoiceCard.swift
//  PinPointCapture design system
//

import SwiftUI

/// A large, selectable card: title, description, and optional evidence chips.
/// Selected state is a 2pt accent border, an accent wash, and a filled
/// checkmark.
///
/// Used on **A3** ("In a studio, with a host" / "At a range, on my own") and on
/// **B5** for the two reconciliation candidates.
///
/// The two A3 cards carry equal visual weight and equal copy length by design —
/// standalone is the normal case, not the consolation prize. Do not make the
/// host option look like the recommended one.
///
/// Selection is a *routing* choice and always reversible, so this is a plain
/// tappable card rather than a `Toggle` or a `Picker` row.
public struct ChoiceCard: View {

    private let title: String
    private let description: String
    private let chips: [String]
    private let isSelected: Bool
    private let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - title: the option, as a phrase the user would say.
    ///   - description: one or two sentences of consequence — what choosing this
    ///     actually does.
    ///   - chips: short evidence phrases rendered as ``StatusChip``s. They pick
    ///     up the accent tone when the card is selected. Keep to two or three.
    ///   - isSelected: drives border, wash and checkmark.
    ///   - action: selects this card.
    public init(
        title: String,
        description: String,
        chips: [String] = [],
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.description = description
        self.chips = chips
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: PPMetrics.itemGap) {
                HStack(alignment: .firstTextBaseline, spacing: PPMetrics.itemGap) {
                    Text(title)
                        .font(.ppCardTitle)
                        .foregroundStyle(Color(.label))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.ppAccent)
                        .opacity(isSelected ? 1 : 0)
                        .accessibilityHidden(true)
                }

                Text(description)
                    .font(.ppSupporting)
                    .foregroundStyle(Color(.secondaryLabel))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if !chips.isEmpty {
                    ChipFlowLayout(spacing: 8) {
                        ForEach(chips, id: \.self) { chip in
                            StatusChip(chip, tone: isSelected ? .accent : .neutral)
                        }
                    }
                }
            }
            .padding(PPMetrics.cardPadding + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.ppAccentWash : Color(.secondarySystemBackground),
                in: .rect(cornerRadius: PPMetrics.Radius.choiceCard)
            )
            .overlay {
                RoundedRectangle(cornerRadius: PPMetrics.Radius.choiceCard)
                    .strokeBorder(
                        isSelected ? Color.ppAccent : Color.clear,
                        lineWidth: PPMetrics.selectedBorderWidth
                    )
            }
            .contentShape(.rect(cornerRadius: PPMetrics.Radius.choiceCard))
        }
        .buttonStyle(.plain)
        .frame(minHeight: PPMetrics.Size.minimumTapTarget)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(spokenValue))
        .accessibilityHint(Text("Chooses this option. You can switch whenever you like."))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var spokenValue: String {
        ([description] + chips).joined(separator: ". ")
    }
}

// MARK: - Chip wrapping

/// Lays chips out left to right, wrapping onto a new line when the proposed
/// width runs out.
///
/// It exists only because chip rows must survive the largest Dynamic Type sizes;
/// it is deliberately `fileprivate` and is **not** a general-purpose flow layout
/// for the app to adopt. If you need one elsewhere, ask whether a `List` row or
/// a `Menu` would do the job instead.
private struct ChipFlowLayout: Layout {

    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.replacingUnspecifiedDimensions().width
        let rows = arrange(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height } +
            spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let candidate = current.indices.isEmpty
                ? size.width
                : current.width + spacing + size.width
            if !current.indices.isEmpty && candidate > maxWidth {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = candidate
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview("ChoiceCard — A3") {
    @Previewable @State var selection = 0

    return VStack(alignment: .leading, spacing: PPMetrics.itemGap) {
        Text("Where are you today?").font(.ppLargeTitle)
        Text("This only changes what happens next. You can switch whenever you like.")
            .font(.ppSupporting)
            .foregroundStyle(Color(.secondaryLabel))
            .padding(.bottom, 8)

        ChoiceCard(
            title: "In a studio, with a host",
            description: "Pair with PinPoint Studio. Shots are correlated as you hit them and the video follows across the network.",
            chips: ["Scan a code to pair", "Wi-Fi or cable"],
            isSelected: selection == 0
        ) { selection = 0 }

        ChoiceCard(
            title: "At a range, on my own",
            description: "Capture and review here. The session is complete on the device and goes to Studio later — tonight, or next week.",
            chips: ["No network needed", "Nothing is lost"],
            isSelected: selection == 1
        ) { selection = 1 }

        InfoCard(
            "A host that appears mid-session is picked up automatically. A host that disappears is not a problem — capture carries on either way.",
            systemImage: "info.circle"
        )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(PPMetrics.screenMargin)
    .background(Color(.systemBackground))
    .preferredColorScheme(.dark)
}
