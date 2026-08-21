//
//  CapturePlaceholders.swift
//  PinPointCapture — C1 / C2 / C3
//
//  ⚠ THE THREE SUBSTITUTION POINTS. Everything in this file is a flat stand-in
//  for imagery that does not exist yet, and every one of them is meant to be
//  deleted.
//
//  The `Platform` layer has not been written, and REQ-PORT-3 forbids an
//  AVFoundation type reaching a view in any case — so nothing here imports or
//  names a capture type. Each placeholder is a leaf view with no state, no
//  layout opinions beyond "fill what I am given", and a single caption. To wire
//  the real thing:
//
//    * `LiveCapturePreviewPlaceholder`  -> the platform preview view (C1)
//    * `ReplayFramePlaceholder`         -> the decoded frame at the playhead (C2)
//    * `ShotThumbnailPlaceholder`       -> the shot's stored thumbnail (C1, C3)
//
//  Swap the body of each; no call site changes, because no call site passes
//  anything a real implementation would not also want.
//

import SwiftUI

// MARK: - C1 live preview

/// The full-bleed live preview behind C1.
///
/// Fills whatever it is given and paints its own ground, so the caller can put
/// it at the bottom of a `ZStack` and `.ignoresSafeArea()` it without the
/// screen's controls having to know what is underneath them.
struct LiveCapturePreviewPlaceholder: View {

    /// `LIVE PREVIEW · ARMED` — the state the preview is standing in for.
    let caption: String

    var body: some View {
        PlaceholderSurface(
            caption: caption,
            gradient: [Color(red: 0.10, green: 0.11, blue: 0.10),
                       Color(red: 0.05, green: 0.055, blue: 0.05)]
        )
        .accessibilityHidden(true)
    }
}

// MARK: - C2 frame

/// The still frame under review on C2.
///
/// The caption is the *time* the frame sits at, never its index
/// (REQ-REPLAY-2) — `FRAME AT IMPACT − 0.0067 s`.
struct ReplayFramePlaceholder: View {

    let caption: String

    var body: some View {
        PlaceholderSurface(
            caption: caption,
            gradient: [Color(red: 0.067, green: 0.071, blue: 0.075),
                       Color(red: 0.067, green: 0.071, blue: 0.075)]
        )
        .accessibilityElement()
        .accessibilityLabel(Text("Frame under review"))
        .accessibilityValue(Text(caption))
    }
}

// MARK: - Shot thumbnail

/// The square thumbnail on C1's last-shot row (74pt) and C3's shot rows (50pt).
struct ShotThumbnailPlaceholder: View {

    let side: CGFloat
    var caption: String?

    var body: some View {
        RoundedRectangle(cornerRadius: PPMetrics.Radius.control, style: .continuous)
            .fill(Color(.tertiarySystemFill))
            .overlay {
                if let caption {
                    Text(caption)
                        .font(.ppEyebrow)
                        .foregroundStyle(Color(.tertiaryLabel))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                        .padding(4)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: PPMetrics.Radius.control, style: .continuous)
                    .strokeBorder(Color(.separator), lineWidth: PPMetrics.hairline)
            }
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

// MARK: - Shared surface

/// The flat, dashed-box-equivalent used by both large placeholders.
private struct PlaceholderSurface: View {

    let caption: String
    let gradient: [Color]

    var body: some View {
        LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom)
            .overlay {
                Text(caption)
                    .font(.ppEyebrow)
                    .tracking(0.8)
                    .foregroundStyle(Color(.tertiaryLabel).opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(PPMetrics.screenMargin)
            }
    }
}

#Preview("Placeholders") {
    VStack(spacing: PPMetrics.itemGap) {
        LiveCapturePreviewPlaceholder(caption: "LIVE PREVIEW · ARMED")
        ReplayFramePlaceholder(caption: "FRAME AT IMPACT \u{2212} 0.0067 s")
        HStack(spacing: PPMetrics.itemGap) {
            ShotThumbnailPlaceholder(side: 74, caption: "LAST\nSHOT")
            ShotThumbnailPlaceholder(side: 50)
            Spacer()
        }
    }
    .padding(PPMetrics.screenMargin)
    .background(Color(.systemBackground))
    .preferredColorScheme(.dark)
}
