//  LivePreviewProvider.swift
//  How a screen gets a live camera without knowing what a camera is.
//
//  ⛔ **The whole point is that `Sources/UI` names nothing from
//  `Sources/Platform`.** `Sources/` is a single compilation unit, so nothing
//  mechanical stops a view importing `AVFoundation` or naming
//  `AVFoundationCaptureDevice` — the layering here is convention plus
//  `LayerPurityTests`, and that test only guards *Core*. This seam is what keeps
//  the convention honest at the one place it was about to be broken.
//
//  A screen asks for "the live preview, captioned thus" and receives a view. The
//  composition root decides what that view is. `#Preview` blocks and the debug
//  gallery get the placeholder for free, because that is the default.
//
//  ⚠ Precedent: `ConformanceHarnessView(device:)` lives in `Sources/App` for the
//  same reason — App is the one layer entitled to know both sides.

import SwiftUI

/// Supplies the live camera preview to a screen that must not know how.
public struct LivePreviewProvider: Sendable {

    /// Caption in, a view out. The caption is what the preview is *standing in
    /// for*, and is shown when there is nothing live to show.
    public let makeView: @MainActor @Sendable (String) -> AnyView

    public init(makeView: @escaping @MainActor @Sendable (String) -> AnyView) {
        self.makeView = makeView
    }

    /// The default, and what every preview and gallery case renders.
    ///
    /// ⚠ Not a failure mode — a screen with no composition root above it is a
    /// screen being looked at by a designer, and a flat captioned surface is the
    /// right answer there.
    public static let placeholder = LivePreviewProvider { caption in
        AnyView(LiveCapturePreviewPlaceholder(caption: caption))
    }
}

public extension EnvironmentValues {
    /// ⛔ Defaults to the placeholder. A screen that forgets to be given one
    /// degrades to a labelled surface, never to a blank rectangle: "black screen"
    /// and "camera not running" look identical on a tripod at two metres.
    @Entry var livePreview: LivePreviewProvider = .placeholder
}
