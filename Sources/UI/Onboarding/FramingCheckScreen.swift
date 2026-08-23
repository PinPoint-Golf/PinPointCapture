//
//  FramingCheckScreen.swift
//  PinPointCapture — onboarding A6
//

import SwiftUI
import CaptureCore

/// **A6 Framing check.** The screen that prevents a wasted session
/// (REQ-SETUP-1, REQ-LIGHT-2).
///
/// The checklist updates continuously while this screen is visible: the pose box,
/// the three boolean checks, and the light row recomputed from achieved exposure
/// and ISO. Pose detection here is *framing validation*, not analysis
/// (REQ-SETUP-3).
///
/// ⚠ **A warning never blocks arming.** It states the consequence in plain words
/// and offers the trade — *Use 120 fps* for a brighter frame, or *Arm anyway*
/// and accept a noisier shaft. Nothing on this screen disables the primary
/// action.
///
/// The preview area is a placeholder: the `Platform` layer does not exist yet
/// and no capture type may cross into the UI (REQ-PORT-3).
public struct FramingCheckScreen: View {

    private let framing: FramingStatus
    private let onUse120fps: () -> Void
    private let onArm: () -> Void

    /// - Parameters:
    ///   - framing: recomputed continuously while this screen is on screen.
    ///   - onUse120fps: re-enumerates formats at the lower rate and re-runs the
    ///     check. Offered only while a lower frame rate would actually buy light.
    ///   - onArm: arms regardless of what the checklist says.
    public init(
        framing: FramingStatus,
        onUse120fps: @escaping () -> Void,
        onArm: @escaping () -> Void
    ) {
        self.framing = framing
        self.onUse120fps = onUse120fps
        self.onArm = onArm
    }

    /// ⛔ The composition root supplies the real camera; a designer looking at a
    /// `#Preview` gets the placeholder. This screen names no capture type.
    @Environment(\.livePreview) private var livePreview

    public var body: some View {
        List {
            Section {
                livePreviewArea
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                headingRow
                    .listRowInsets(EdgeInsets(
                        top: PPMetrics.itemGap,
                        leading: PPMetrics.rowPadding,
                        bottom: PPMetrics.itemGap,
                        trailing: PPMetrics.rowPadding
                    ))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                // ⛔ Three rows nobody can answer yet. They were rendering a
                // fixture's `true` — a green tick for a check that had never run,
                // on the screen whose entire purpose is preventing a wasted
                // session. `.notChecked` is neutral, never orange: an absent
                // check is not a degradation.
                CheckRow(title: "In frame at address",
                         state: framing.inFrameAtAddress,
                         consequence: Self.poseNotConnected)
                CheckRow(title: "Club still in frame at the top",
                         state: framing.inFrameAtTop,
                         consequence: Self.poseNotConnected)
                CheckRow(title: "Device is steady",
                         state: framing.isSteady,
                         consequence: Self.steadyNotConnected)

                if let light = framing.light {
                    CheckRow(
                        title: lightTitle,
                        state: light.verdict == .good ? .pass : .fail,
                        measurement: light.measurementText,
                        // ⚠ Third line, not concatenated into the measurement:
                        // the consequence sentences are verbatim design copy.
                        provenance: light.provenanceText,
                        consequence: light.consequenceText
                    )
                } else {
                    CheckRow(title: "Light",
                             state: .notChecked,
                             consequence: "The self-test did not report an exposure "
                                        + "on this device, so the light has not been assessed.")
                }
            } footer: {
                if framing.hasAnyRealCheck == false {
                    Text("Nothing has been checked yet.")
                        .font(.ppSupporting)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: PPMetrics.itemGap) {
                if offersLowerFrameRate {
                    Button("Use 120 fps", action: onUse120fps)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
                        .accessibilityHint(Text("Drops to 120 fps for a brighter frame, then checks the framing again."))
                }

                Button(armTitle, action: onArm)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
            }
            .padding(.horizontal, PPMetrics.screenMargin)
            .padding(.bottom, PPMetrics.itemGap)
            .background(.bar)
        }
    }

    // MARK: - The live preview

    /// The real camera, from the composition root.
    ///
    /// ⛔ **No detection box.** The old placeholder drew an accent-stroked frame
    /// labelled "Golfer · in frame" over a flat fill — a pose overlay for a pose
    /// detector that does not exist (E8.2). Drawing one over a *live* image would
    /// be worse than drawing it over a placeholder, because it would look real.
    private var livePreviewArea: some View {
        livePreview.makeView("CAMERA PREVIEW")
            .frame(height: 380)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Camera preview"))
    }

    /// Why three rows cannot answer. Stated once.
    static let poseNotConnected =
        "Pose detection is not connected yet, so this has not been checked."
    static let steadyNotConnected =
        "Motion sensing is not connected yet, so this has not been checked."

    private var headingRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: PPMetrics.itemGap) {
            Text("Framing check")
                .font(.ppScreenHeading)
                .foregroundStyle(Color(.label))
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: PPMetrics.itemGap)

            // REQ-SETUP-2: the device classifies its own viewpoint and reports
            // it. ⛔ Hidden while nothing classifies it (E8.3) — an eyebrow
            // reading "DTL · Right-handed" on every device, whichever way it is
            // pointing, is a claim rather than a report.
            if let viewpoint = framing.viewpoint {
                EyebrowLabel(viewpoint.displayText)
                    .accessibilityLabel(Text("Viewpoint"))
                    .accessibilityValue(Text(viewpoint.displayText))
            }
        }
    }

    // MARK: - Derived copy

    private var lightTitle: String {
        switch framing.light?.verdict {
        case .good: "Light is good"
        case .marginal: "Light is marginal"
        case .insufficient: "Light is not enough"
        case nil: "Light"
        }
    }

    /// Dropping the frame rate only helps while light is the binding constraint,
    /// and only where there is a reading to say so.
    private var offersLowerFrameRate: Bool {
        guard let light = framing.light else { return false }
        return light.verdict != .good && light.fps > 120
    }

    /// `Arm anyway` is the wording that goes with a warning. With nothing to
    /// warn about, "anyway" would be answering a question nobody asked.
    private var armTitle: String {
        framing.allChecksPass ? "Arm" : "Arm anyway"
    }

}

// MARK: - Row

/// One checklist item. A pass is an accent tick; anything else is an orange
/// warning — never red, because none of this stops capture.
private struct CheckRow: View {

    let title: String
    /// ⛔ Three states. A `Bool` could not say "nobody looked", which is how this
    /// screen came to show a green tick for a check that had never run.
    let state: FramingStatus.Check
    var measurement: String?
    /// What kind of reading this is — "measured cold, over a few seconds".
    var provenance: String?
    var consequence: String?

    /// ⚠ `notChecked` is **neutral**, never orange. Orange means "degraded but
    /// still capturing" in this app's colour discipline; an absent check is not a
    /// degradation and must not borrow that meaning.
    private var tone: StatusTone {
        switch state {
        case .pass: .accent
        case .fail: .warning
        case .notChecked: .neutral
        }
    }

    private var symbol: String {
        switch state {
        case .pass: "checkmark.circle.fill"
        case .fail: "exclamationmark.circle.fill"
        case .notChecked: "circle.dashed"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: PPMetrics.itemGap) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tone.foreground)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.ppRowLabel)
                    .foregroundStyle(state == .notChecked
                                     ? Color(.secondaryLabel) : Color(.label))

                if let measurement {
                    Text(measurement)
                        .ppMeasuredDetail()
                }

                if let provenance {
                    Text(provenance)
                        .font(.ppSupporting)
                        .foregroundStyle(Color(.tertiaryLabel))
                }

                if let consequence {
                    Text(consequence)
                        .font(.ppSupporting)
                        .foregroundStyle(Color(.secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .frame(minHeight: PPMetrics.Size.minimumTapTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(spokenValue))
    }

    private var spokenValue: String {
        var parts: [String] = []
        switch state {
        case .pass: parts.append("Passes")
        case .fail: parts.append(tone.accessibilityDescription ?? "Check")
        case .notChecked: parts.append("Not checked")
        }
        if let measurement { parts.append(measurement) }
        if let consequence { parts.append(consequence) }
        return parts.joined(separator: ". ")
    }
}

#Preview("A6 — marginal light") {
    NavigationStack {
        FramingCheckScreen(
            framing: PreviewFixtures.framingMarginalLight,
            onUse120fps: {},
            onArm: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("A6 — everything passes") {
    NavigationStack {
        FramingCheckScreen(
            framing: FramingStatus(
                inFrameAtAddress: .pass,
                inFrameAtTop: .pass,
                isSteady: .pass,
                light: LightAssessment(
                    verdict: .good,
                    exposureSeconds: 1.0 / 2000.0,
                    iso: 400,
                    fps: 150
                ),
                viewpoint: Viewpoint(angle: .downTheLine, handedness: .rightHanded)
            ),
            onUse120fps: {},
            onArm: {}
        )
    }
    .preferredColorScheme(.dark)
}
