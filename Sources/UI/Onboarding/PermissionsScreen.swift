//
//  PermissionsScreen.swift
//  PinPointCapture — onboarding A4
//

import SwiftUI

/// **A4 What it needs.** Four permissions, each shown as what it *buys the user*
/// — never as an API name.
///
/// ⚠ The order is the design, not an accident:
/// - **Camera** and **microphone** first, because both are obvious and both are
///   refused by nobody who wants to film a golf swing.
/// - **Local network last**, and framed as a host choice with its own button, so
///   that a refusal reads as a decision about hosts rather than a broken app
///   (REQ-DISC-6). Capture needs camera and microphone only — refusing local
///   network costs a golfer a network, not a session.
/// - **Motion** last of the four cards, because it improves things rather than
///   enabling them.
///
/// Audio retention (REQ-PRIV-2, OPEN-2) is surfaced *here*, inline under the
/// microphone, and not buried in Settings: a continuously open microphone in a
/// lesson deserves an up-front answer.
public struct PermissionsScreen: View {

    private let permissions: Permissions
    private let audioRetention: AudioRetention
    private let onChangeAudioRetention: () -> Void
    private let onAllowLocalNetwork: () -> Void
    private let onContinue: () -> Void

    /// - Parameters:
    ///   - permissions: platform-neutral readiness (REQ-PORT-13), never raw
    ///     platform permission results.
    ///   - audioRetention: the user-visible setting shown under the microphone.
    ///   - onChangeAudioRetention: opens the retention choice.
    ///   - onAllowLocalNetwork: triggers the local-network prompt. Deliberately
    ///     a separate, explicit action rather than something that fires on
    ///     appear.
    ///   - onContinue: continues into A5. There is no *skip*: continuing without
    ///     local network is a supported outcome, not a way past this screen.
    public init(
        permissions: Permissions,
        audioRetention: AudioRetention,
        onChangeAudioRetention: @escaping () -> Void,
        onAllowLocalNetwork: @escaping () -> Void,
        onContinue: @escaping () -> Void
    ) {
        self.permissions = permissions
        self.audioRetention = audioRetention
        self.onChangeAudioRetention = onChangeAudioRetention
        self.onAllowLocalNetwork = onAllowLocalNetwork
        self.onContinue = onContinue
    }

    public var body: some View {
        List {
            Section {
                PermissionHeaderRow(
                    systemImage: "camera",
                    name: "Camera",
                    state: permissions.camera,
                    benefit: "Focus, exposure, white balance and stabilisation stay locked while armed, so measurements hold across a session."
                )
            } header: {
                Text("Four permissions, and what each one is actually for.")
                    .font(.ppSupporting)
                    .foregroundStyle(Color(.secondaryLabel))
                    .textCase(nil)
                    .padding(.bottom, PPMetrics.itemGap)
            }

            Section {
                PermissionHeaderRow(
                    systemImage: "mic",
                    name: "Microphone",
                    state: permissions.microphone,
                    benefit: "The sound of impact gives every shot an exact time, and lines two shots up on impact rather than on clip start."
                )

                // REQ-PRIV-2 / OPEN-2. The default below is the design's proposal
                // for confirmation, not a decision — see `AudioRetention`.
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Audio kept")
                            .font(.ppSupporting.weight(.semibold))
                            .foregroundStyle(Color(.label))
                        Text(audioRetention.displayText)
                            .ppMeasuredDetail()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Audio kept"))
                    .accessibilityValue(Text(audioRetention.displayText))

                    Spacer(minLength: PPMetrics.itemGap)

                    Button("Change", action: onChangeAudioRetention)
                        .buttonStyle(.borderless)
                        .font(.ppRowLabel.weight(.semibold))
                        .accessibilityHint(Text("Changes how much audio is kept with each shot."))
                }
                .frame(minHeight: PPMetrics.Size.minimumTapTarget)
            }

            Section {
                PermissionHeaderRow(
                    systemImage: "wifi",
                    name: "Local network",
                    state: permissions.localNetwork,
                    benefit: "To reach your Studio host directly. Only a host you have paired with can receive video, ever."
                )

                if permissions.localNetwork != .allowed {
                    Button("Allow local network", action: onAllowLocalNetwork)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.minimumTapTarget)
                        .listRowInsets(EdgeInsets(
                            top: 0,
                            leading: PPMetrics.cardPadding,
                            bottom: PPMetrics.cardPadding,
                            trailing: PPMetrics.cardPadding
                        ))
                }
            }

            Section {
                PermissionHeaderRow(
                    systemImage: "gyroscope",
                    name: "Motion",
                    state: permissions.motion,
                    benefit: "How the device is tilted, and which way is down. Improves how views line up."
                )
            } footer: {
                Text("No analytics, ever. Nothing leaves this device unless you send it.")
                    .font(.ppFootnote)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .padding(.top, PPMetrics.itemGap)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("What it needs")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom) {
            Button("Continue", action: onContinue)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
                .padding(.horizontal, PPMetrics.screenMargin)
                .padding(.bottom, PPMetrics.itemGap)
                .background(.bar)
        }
    }
}

// MARK: - Row

/// Icon, name, right-aligned readiness, and one sentence of *benefit*.
///
/// ⚠ The sentence says what the user gets. It never names the API, the
/// framework, or the platform prompt.
private struct PermissionHeaderRow: View {

    let systemImage: String
    let name: String
    let state: PermissionState
    let benefit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: PPMetrics.itemGap) {
                Image(systemName: systemImage)
                    .font(.ppRowLabel)
                    .foregroundStyle(Color.ppAccent)
                    .frame(width: PPMetrics.Size.rowGlyph, alignment: .leading)
                    .accessibilityHidden(true)

                Text(name)
                    .font(.ppRowLabel.weight(.semibold))
                    .foregroundStyle(Color(.label))

                Spacer(minLength: PPMetrics.itemGap)

                Text(state.displayText)
                    .font(.ppSupporting.weight(.semibold))
                    .foregroundStyle(tone.foreground)
                    .multilineTextAlignment(.trailing)
            }

            Text(benefit)
                .font(.ppSupporting)
                .foregroundStyle(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: PPMetrics.Size.minimumTapTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text("\(state.displayText). \(benefit)"))
    }

    /// Colour never carries the meaning on its own — the state is also spelled
    /// out in words, both on screen and in the VoiceOver value.
    private var tone: StatusTone {
        switch state {
        case .allowed: .accent
        case .denied: .error
        case .notRequested, .unknown: .neutral
        }
    }
}

#Preview("A4 — before local network") {
    NavigationStack {
        PermissionsScreen(
            permissions: PreviewFixtures.permissionsBeforeNetwork,
            audioRetention: .aroundImpactOnly,
            onChangeAudioRetention: {},
            onAllowLocalNetwork: {},
            onContinue: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("A4 — local network refused") {
    NavigationStack {
        PermissionsScreen(
            permissions: Permissions(
                camera: .allowed,
                microphone: .allowed,
                localNetwork: .denied,
                motion: .allowed
            ),
            audioRetention: .aroundImpactOnly,
            onChangeAudioRetention: {},
            onAllowLocalNetwork: {},
            onContinue: {}
        )
    }
    .preferredColorScheme(.dark)
}
