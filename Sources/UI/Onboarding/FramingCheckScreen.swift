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

    public var body: some View {
        List {
            Section {
                previewPlaceholder
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
                CheckRow(
                    title: "In frame at address",
                    passes: framing.inFrameAtAddress
                )
                CheckRow(
                    title: "Club still in frame at the top",
                    passes: framing.inFrameAtTop
                )
                CheckRow(
                    title: "Device is steady",
                    passes: framing.isSteady
                )
                CheckRow(
                    title: lightTitle,
                    passes: framing.light.verdict == .good,
                    measurement: framing.light.measurementText,
                    consequence: framing.light.consequenceText
                )
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

    // MARK: - Preview placeholder

    /// Stands in for the live preview and the pose box drawn over it. Flat fill,
    /// accent-stroked detection box, and a label saying what it is.
    private var previewPlaceholder: some View {
        ZStack {
            Rectangle()
                .fill(Color(.secondarySystemBackground))

            VStack(spacing: PPMetrics.itemGap) {
                EyebrowLabel("Golfer · in frame", tone: .accent)

                RoundedRectangle(cornerRadius: PPMetrics.Radius.small)
                    .strokeBorder(Color.ppAccent, lineWidth: 1.5)
                    .overlay {
                        VStack(spacing: 4) {
                            EyebrowLabel("Camera preview")
                            Text("live, 1080p\(fpsText), locked")
                                .ppMeasuredDetail()
                        }
                        .padding(PPMetrics.cardPadding)
                    }
                    .frame(maxWidth: 220)
            }
            .padding(PPMetrics.screenMargin)
        }
        .frame(height: 380)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Camera preview"))
        .accessibilityValue(Text("Placeholder. The golfer is detected and in frame."))
    }

    private var headingRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: PPMetrics.itemGap) {
            Text("Framing check")
                .font(.ppScreenHeading)
                .foregroundStyle(Color(.label))
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: PPMetrics.itemGap)

            // REQ-SETUP-2: the device classifies its own viewpoint and reports
            // it. It is never a control the user has to set.
            EyebrowLabel(framing.viewpoint.displayText)
                .accessibilityLabel(Text("Viewpoint"))
                .accessibilityValue(Text(framing.viewpoint.displayText))
        }
    }

    // MARK: - Derived copy

    private var lightTitle: String {
        switch framing.light.verdict {
        case .good: "Light is good"
        case .marginal: "Light is marginal"
        case .insufficient: "Light is not enough"
        }
    }

    /// Dropping the frame rate only helps while light is the binding constraint.
    private var offersLowerFrameRate: Bool {
        framing.light.verdict != .good && framing.light.fps > 120
    }

    /// `Arm anyway` is the wording that goes with a warning. With nothing to
    /// warn about, "anyway" would be answering a question nobody asked.
    private var armTitle: String {
        framing.allChecksPass ? "Arm" : "Arm anyway"
    }

    private var fpsText: String {
        String(format: "%.0f", framing.light.fps)
    }
}

// MARK: - Row

/// One checklist item. A pass is an accent tick; anything else is an orange
/// warning — never red, because none of this stops capture.
private struct CheckRow: View {

    let title: String
    let passes: Bool
    var measurement: String?
    var consequence: String?

    private var tone: StatusTone { passes ? .accent : .warning }

    var body: some View {
        HStack(alignment: .top, spacing: PPMetrics.itemGap) {
            Image(systemName: passes ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(tone.foreground)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.ppRowLabel)
                    .foregroundStyle(Color(.label))

                if let measurement {
                    Text(measurement)
                        .ppMeasuredDetail()
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
        parts.append(passes ? "Passes" : (tone.accessibilityDescription ?? "Check"))
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
                inFrameAtAddress: true,
                inFrameAtTop: true,
                isSteady: true,
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
