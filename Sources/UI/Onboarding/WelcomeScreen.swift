//
//  WelcomeScreen.swift
//  PinPointCapture — onboarding A1
//

import SwiftUI

/// **A1 Welcome.** The mark, the name, one line of description, and then the
/// only thing on this screen that is not decoration: what *this* device, the one
/// in the user's hand, was measured to be capable of.
///
/// ⚠ The capability card is populated from real format enumeration, never a
/// spec-sheet lookup (REQ-FPS-1, REQ-CAP-1/2). A device that will not clear the
/// host's ingest gate says so **here**, in these terms, rather than at arm time
/// when a lesson is already running.
public struct WelcomeScreen: View {

    private let capability: DeviceCapability
    private let onGetStarted: () -> Void
    private let onHavePairingCode: () -> Void

    /// - Parameters:
    ///   - capability: the enumerated formats of the device in hand. Its
    ///     ``DeviceCapability/summarySentence`` is the card copy.
    ///   - onGetStarted: continues into A2.
    ///   - onHavePairingCode: jumps straight to pairing (B1) for a user who
    ///     already has a code on screen in Studio.
    public init(
        capability: DeviceCapability,
        onGetStarted: @escaping () -> Void,
        onHavePairingCode: @escaping () -> Void
    ) {
        self.capability = capability
        self.onGetStarted = onGetStarted
        self.onHavePairingCode = onHavePairingCode
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: PPMetrics.groupGap) {
                Spacer(minLength: PPMetrics.groupGap)

                // Placeholder concentric-circle target, not a logo. SF Symbol,
                // never a redrawn path.
                Image(systemName: "target")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(Color.ppAccent)
                    .accessibilityHidden(true)

                VStack(spacing: PPMetrics.itemGap) {
                    Text("PinPointCapture")
                        .font(.ppLargeTitle)
                        .foregroundStyle(Color(.label))
                        .accessibilityAddTraits(.isHeader)

                    Text("A high-speed, time-synchronised capture source for PinPoint Studio. Set it on a tripod and it does the rest.")
                        .font(.ppSupporting)
                        .foregroundStyle(Color(.secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)

                InfoCard(
                    cardMessage,
                    eyebrow: "This device",
                    tone: clearsIngestGate ? .accent : .warning
                )

                Spacer(minLength: PPMetrics.groupGap)
            }
            .padding(.horizontal, PPMetrics.screenMargin)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: PPMetrics.itemGap) {
                Button("Get started", action: onGetStarted)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)

                // A plain green text action: a stock borderless button that
                // inherits the global accent tint. Never hand-rolled, never
                // re-tinted by hand.
                Button("I have a pairing code", action: onHavePairingCode)
                    .buttonStyle(.borderless)
                    .font(.ppRowLabel.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.minimumTapTarget)
                    .contentShape(.rect)
                    .accessibilityHint(Text("Skips ahead to pairing with a host."))
            }
            .padding(.horizontal, PPMetrics.screenMargin)
            .padding(.bottom, PPMetrics.itemGap)
            .background(.bar)
        }
    }

    // MARK: - The capability sentence

    /// `summarySentence` states what was enumerated; this states what it means.
    /// Both halves are needed: the numbers are the evidence, the verdict is the
    /// answer to the only question the user actually has.
    private var cardMessage: String {
        guard capability.bestMode != nil else { return capability.summarySentence }
        return capability.summarySentence + " " + verdictSentence
    }

    /// ⛔ REQ-CAP-5: the floor is *host ingest policy*, not a protocol constraint,
    /// so it lives in Core as a value a host could state — not as a constant in
    /// this view. See `HostIngestPolicy`.
    private var clearsIngestGate: Bool { capability.clearsGate() }

    private var verdictSentence: String { capability.verdictSentence() }
}

#Preview("A1 — Welcome") {
    WelcomeScreen(
        capability: PreviewFixtures.capability,
        onGetStarted: {},
        onHavePairingCode: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("A1 — below the ingest gate") {
    WelcomeScreen(
        capability: DeviceCapability(
            modelIdentifier: "iPhone10,4",
            modelName: "iPhone 8",
            claimed: [VideoMode(width: 1280, height: 720, fps: 60, lens: .wide)]
        ),
        onGetStarted: {},
        onHavePairingCode: {}
    )
    .preferredColorScheme(.dark)
}
