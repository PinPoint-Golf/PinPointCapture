//
//  Colors.swift
//  PinPointCapture design system
//
//  Dark appearance only in this pass.
//

import SwiftUI
import CaptureCore

// MARK: - Brand and status tokens (asset catalogue)

public extension Color {

    /// `#30D158` — the app tint. Retained, synced, in Studio, primary actions.
    ///
    /// Also the project's accent colour asset: the app target must set
    /// `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = Accent`, which makes
    /// this the default tint for every system control. Prefer letting a control
    /// inherit the tint over applying `.tint(.ppAccent)` by hand.
    static var ppAccent: Color { Color("Accent") }

    /// `#FF9F0A` — degraded but still capturing: weak link, marginal light.
    static var ppWarning: Color { Color("Warning") }

    /// `#FF453A` — host gone, permission blocked, Disarm.
    ///
    /// Never used for capture state. See ``StatusTone``.
    static var ppError: Color { Color("Error") }

    /// `#5AA9FF` — in flight: sending, catching up, resyncing.
    static var ppProgress: Color { Color("Progress") }

    /// `rgba(48,209,88,0.14)` — selected card fill, accent chip backgrounds.
    ///
    /// The handoff quotes a 0.10–0.18 range; the asset sits in the middle of it.
    /// For a heavier or lighter wash use `Color.ppAccent.opacity(_:)` rather
    /// than adding another asset.
    static var ppAccentWash: Color { Color("AccentWash") }
}

// MARK: - Colours that are NOT tokens
//
// The handoff maps these to system semantic colours, and they are deliberately
// absent from Assets.xcassets. Use the system colour directly — it already
// carries the right dark-appearance value, tracks Increase Contrast, and needs
// no maintenance:
//
//   Background          #000000                    -> Color(.systemBackground)
//   Grouped background  #1C1C1E                    -> Color(.secondarySystemBackground)
//   Fill                rgba(120,120,128,.18–.32)  -> Color(.tertiarySystemFill) and family
//   Separator           rgba(84,84,88,0.6) @ 0.5px -> Color(.separator)
//   Label               #FFFFFF                    -> Color(.label)
//   Secondary label     rgba(235,235,245,0.6)      -> Color(.secondaryLabel)
//   Tertiary label      rgba(235,235,245,0.45)     -> Color(.tertiaryLabel)
//
// Do not add assets for any of the above.
