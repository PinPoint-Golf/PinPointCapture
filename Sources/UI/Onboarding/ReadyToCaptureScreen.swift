//
//  ReadyToCaptureScreen.swift
//  PinPointCapture — onboarding A7
//

import SwiftUI

/// **A7 Ready to capture.** Claimed and measured capability shown together, in
/// the one place a user will actually read them.
///
/// This is also the **receipt for the self-test** (REQ-CAP-1/2/3). `Capture` is
/// what the device was asked for; `Measured, sustained` is what it was caught
/// doing under thermal load. They are routinely different, and collapsing them
/// into one number is how a session ends up recorded at 120 fps with duplicated
/// frames while every log says 150.
///
/// Storage headroom appears here to pre-empt the low-space refusal (REQ-OFF-2) —
/// far better read now than at the moment the app declines to arm.
///
/// ⚠ "Not connected to a host" is a **normal** state and stays neutral. It is
/// not a failure, and the card must not take a warning or error tone.
public struct ReadyToCaptureScreen: View {

    private let capability: DeviceCapability
    private let storage: StorageHeadroom
    private let retainedSecondsPerShot: Double
    private let onStartSession: () -> Void
    private let onConnectHost: () -> Void

    /// - Parameters:
    ///   - capability: the claimed / measured pair. `measured` is the self-test
    ///     result; when it is absent the claimed best mode is shown alone rather
    ///     than a measurement being implied.
    ///   - storage: headroom, in sessions rather than in bytes.
    ///   - retainedSecondsPerShot: seconds of video kept around each impact.
    ///   - onStartSession: goes straight to capture, standalone.
    ///   - onConnectHost: presents host connection (B1) modally.
    public init(
        capability: DeviceCapability,
        storage: StorageHeadroom,
        retainedSecondsPerShot: Double,
        onStartSession: @escaping () -> Void,
        onConnectHost: @escaping () -> Void
    ) {
        self.capability = capability
        self.storage = storage
        self.retainedSecondsPerShot = retainedSecondsPerShot
        self.onStartSession = onStartSession
        self.onConnectHost = onConnectHost
    }

    public var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(
                        top: PPMetrics.itemGap,
                        leading: PPMetrics.rowPadding,
                        bottom: PPMetrics.groupGap,
                        trailing: PPMetrics.rowPadding
                    ))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                if let mode = displayMode {
                    TelemetryRow(
                        "Capture",
                        mode.displayName,
                        spokenValue: "\(mode.resolutionName) at \(fpsText(mode.fps)) frames per second"
                    )
                }

                if let measured = capability.measured {
                    TelemetryRow(
                        "Measured, sustained",
                        measured.displaySummary,
                        spokenValue: "\(fpsText(measured.achievedFPS)) frames per second, \(measured.droppedFrames) dropped"
                    )
                }

                if let mode = displayMode {
                    TelemetryRow(
                        "Lens",
                        "\(mode.lens.displayName) · locked",
                        spokenValue: "\(mode.lens.displayName), locked"
                    )
                }

                TelemetryRow(
                    "Kept per shot",
                    keptPerShotText,
                    spokenValue: "\(fpsText(retainedSecondsPerShot)) seconds around impact"
                )

                TelemetryRow(
                    "Room for",
                    storage.displayText,
                    spokenValue: storage.displayText
                )
            }

            Section {
                InfoCard(
                    "Not connected to a host. Everything is kept here until you send it.",
                    systemImage: "info.circle"
                )
                .listRowInsets(EdgeInsets(
                    top: PPMetrics.itemGap,
                    leading: PPMetrics.rowPadding,
                    bottom: PPMetrics.itemGap,
                    trailing: PPMetrics.rowPadding
                ))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: PPMetrics.itemGap) {
                Button("Start a session", action: onStartSession)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)

                Button("Connect a host first", action: onConnectHost)
                    .buttonStyle(.borderless)
                    .font(.ppRowLabel.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.minimumTapTarget)
                    .contentShape(.rect)
            }
            .padding(.horizontal, PPMetrics.screenMargin)
            .padding(.bottom, PPMetrics.itemGap)
            .background(.bar)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: PPMetrics.itemGap) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 38))
                .foregroundStyle(Color.ppAccent)
                .accessibilityHidden(true)

            Text("Ready to capture")
                .font(.ppLargeTitle)
                .foregroundStyle(Color(.label))
                .accessibilityAddTraits(.isHeader)

            Text("This is what the device will do. It is recorded with every shot, so Studio always knows what it received.")
                .font(.ppSupporting)
                .foregroundStyle(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Derived values

    /// The mode the self-test actually ran, falling back to the claimed best.
    private var displayMode: VideoMode? {
        capability.measured?.mode ?? capability.bestMode
    }

    private var keptPerShotText: String {
        String(format: "%.1f s around impact", retainedSecondsPerShot)
    }

    private func fpsText(_ value: Double) -> String {
        value == value.rounded()
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }
}

#Preview("A7 — Ready to capture") {
    NavigationStack {
        ReadyToCaptureScreen(
            capability: PreviewFixtures.capability,
            storage: PreviewFixtures.storage,
            retainedSecondsPerShot: 3.0,
            onStartSession: {},
            onConnectHost: {}
        )
    }
    .preferredColorScheme(.dark)
}
