//
//  Metrics.swift
//  PinPointCapture design system
//
//  Geometry from the handoff. Radii and control sizes are decisions; paddings
//  and gaps are starting points — layouts must flow with Dynamic Type rather
//  than be measured off the 393pt HTML.
//

import SwiftUI
import CaptureCore

public enum PPMetrics {

    // MARK: Corner radii

    public enum Radius {
        /// Timeline track and small chips.
        public static let small: CGFloat = 8
        /// Inline controls — segmented rows, speed pills, tool buttons.
        public static let control: CGFloat = 12
        /// Cards, list groups, buttons.
        public static let card: CGFloat = 14
        /// The large selectable cards on A3.
        public static let choiceCard: CGFloat = 18
        /// Top corners of a bottom sheet (B4). `.presentationCornerRadius(_:)`.
        public static let sheet: CGFloat = 28
    }

    // MARK: Control sizes
    //
    // These are floors, not suggestions. Do not shrink them to make a layout fit.

    public enum Size {
        /// **Every** tap target, without exception.
        public static let minimumTapTarget: CGFloat = 44
        /// Primary filled buttons (`.borderedProminent`).
        public static let primaryButton: CGFloat = 50
        /// C2's markup tool buttons — sized for a gloved hand.
        public static let markupTool: CGFloat = 48
        /// C2's single-frame step buttons — sized for a gloved hand.
        public static let frameStep: CGFloat = 54
        /// The play button on C2's transport.
        public static let transportPlay: CGFloat = 64
        /// Leading status glyph in a ``ProgressRow`` or permission card.
        public static let rowGlyph: CGFloat = 22
        /// Selection checkmark on a ``ChoiceCard``.
        public static let selectionMark: CGFloat = 24
    }

    // MARK: Spacing

    /// Screen margins. 20–24pt in the handoff.
    public static let screenMargin: CGFloat = 20
    /// Padding inside a card. 14–22pt.
    public static let cardPadding: CGFloat = 16
    /// Vertical padding inside a list row. 12–16pt.
    public static let rowPadding: CGFloat = 12
    /// Gap between items within one group. 10–16pt.
    public static let itemGap: CGFloat = 12
    /// Gap between groups. 20–30pt.
    public static let groupGap: CGFloat = 24
    /// Border width of a selected ``ChoiceCard``.
    public static let selectedBorderWidth: CGFloat = 2
    /// Hairline border on an unselected container.
    public static let hairline: CGFloat = 1 / 3
}
