//
//  StatusTone.swift
//  PinPointCapture design system
//
//  The one colour rule that carries the design:
//
//      Green is the only brand tint; orange, red and blue appear only in their
//      system meanings. CAPTURE STATUS NEVER TURNS RED — red is reserved for
//      the host and for destructive actions, because capture continuing is the
//      product's core promise.
//

import SwiftUI

/// The semantic colour role shared by every design-system component.
///
/// Pick the tone from *what the value means*, never from what looks good:
///
/// - ``neutral`` — plain information. No opinion. `On device`, `Lens · locked`.
/// - ``accent`` — retained, synced, in Studio, confirmed, primary action.
///   Green is the app tint and the **only** brand colour.
/// - ``warning`` — degraded but still capturing: weak link, marginal light,
///   partial launch-monitor coverage. Never blocks the user.
/// - ``error`` — the host is gone, a permission is blocked, or the action is
///   destructive (Disarm). **Never** used for capture state.
/// - ``progress`` — something is in flight: sending, catching up, resyncing.
public enum StatusTone: String, Sendable, CaseIterable {
    case neutral
    case accent
    case warning
    case error
    case progress

    /// Foreground colour for text and symbols in this tone.
    public var foreground: Color {
        switch self {
        case .neutral:  Color(.secondaryLabel)
        case .accent:   .ppAccent
        case .warning:  .ppWarning
        case .error:    .ppError
        case .progress: .ppProgress
        }
    }

    /// Background wash for chips and cards in this tone.
    public var background: Color {
        switch self {
        case .neutral:  Color(.tertiarySystemFill)
        case .accent:   .ppAccentWash
        case .warning:  Color.ppWarning.opacity(0.14)
        case .error:    Color.ppError.opacity(0.14)
        case .progress: Color.ppProgress.opacity(0.14)
        }
    }

    /// Border colour, used by selected/emphasised containers.
    public var border: Color {
        self == .neutral ? Color(.separator) : foreground
    }

    /// The word VoiceOver appends so a tone is not conveyed by colour alone.
    ///
    /// Colour is never the only carrier of meaning: every component that uses a
    /// tone also puts this into its accessibility label.
    public var accessibilityDescription: String? {
        switch self {
        case .neutral:  nil
        case .accent:   nil
        case .warning:  String(localized: "Warning", comment: "VoiceOver tone")
        case .error:    String(localized: "Problem", comment: "VoiceOver tone")
        case .progress: String(localized: "In progress", comment: "VoiceOver tone")
        }
    }
}
