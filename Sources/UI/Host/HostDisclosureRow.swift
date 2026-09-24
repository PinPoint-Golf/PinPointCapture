//  HostDisclosureRow.swift
//  A list row that reads as a system disclosure row, shared by the host screens.
//
//  ⚠ Lifted out of `ConnectHostView.swift` (#121) when B1 was mothballed:
//  B6 and the settings sheet still use it.

import SwiftUI

/// A list row that reads as a system disclosure row.
///
/// The design system asks for `NavigationLink` here, but these screens do not
/// own navigation — the action is surfaced as a closure and the destination is
/// wired by the presenting layer, so this is a `Button` wearing the same chrome.
struct HostDisclosureRow: View {
    let title: String
    var detail: String?
    var systemImage: String?
    var titleTone: StatusTone = .neutral
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: PPMetrics.itemGap) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.body)
                        .foregroundStyle(Color(.secondaryLabel))
                        .frame(width: PPMetrics.Size.rowGlyph)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.ppRowLabel)
                        .foregroundStyle(titleTone == .neutral
                                         ? Color(.label) : titleTone.foreground)
                        .multilineTextAlignment(.leading)
                    if let detail {
                        Text(detail)
                            .font(.ppFootnote)
                            .foregroundStyle(Color(.secondaryLabel))
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: PPMetrics.Size.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(detail.map { "\(title). \($0)" } ?? title))
        .accessibilityAddTraits(.isButton)
    }
}
