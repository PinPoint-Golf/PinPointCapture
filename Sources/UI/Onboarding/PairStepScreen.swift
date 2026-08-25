//
//  PairStepScreen.swift
//  B1, as the third step of onboarding — pair while you are still at the Mac.
//
//  ⛔ **This screen exists because of where the golfer is standing** (Mark, 25
//  August 2026, from a real setup). The pairing code is displayed on the Studio
//  screen, so scanning it means carrying the phone to the Mac. Onboarding used to
//  run the framing check first, which meant clamping the phone to a tripod at hip
//  height, getting the whole swing in frame — and then picking it up and losing
//  every bit of that. Pairing comes before the phone is set down, and the framing
//  check is the last thing a golfer touches.
//
//  ⚠ **It is not `ConnectHostView`, deliberately.** B1 is the screen for someone
//  who has an app and wants a host; this is a step in a sequence, and the two
//  differ in what they may assume. There is no Cancel here, because there is
//  nothing to cancel back to; the way past is *I am on my own today*, which is
//  not a "carry on anyway" out but a supported way to use the product
//  (REQ-STANDALONE-1, and UC-1 is the normal case).
//
//  ⚠ **The scan goes straight to the scanner**, not through B1. Listing the same
//  choices twice is what a screen-on-screen sheet would do; the composition root
//  presents `B1a` directly.
//
//  ⛔ **Paired is a STATE OF THIS SCREEN, not a route away from it.** When the
//  link settles the golfer is returned here and the screen says what happened,
//  because the next thing to do — walk over and set the phone down — is a
//  physical act this screen has to hand off deliberately rather than by
//  vanishing.
//

import SwiftUI
import CaptureCore

public struct PairStepScreen: View {

    /// The host link, when one has been established. ⛔ `nil` until it settles —
    /// this screen never claims a pairing that is still handshaking.
    private let hostName: String?
    private let isPaired: Bool
    private let onScanPairingCode: () -> Void
    private let onContinue: () -> Void
    private let onSkip: () -> Void

    public init(hostName: String? = nil,
                isPaired: Bool = false,
                onScanPairingCode: @escaping () -> Void,
                onContinue: @escaping () -> Void,
                onSkip: @escaping () -> Void) {
        self.hostName = hostName
        self.isPaired = isPaired
        self.onScanPairingCode = onScanPairingCode
        self.onContinue = onContinue
        self.onSkip = onSkip
    }

    public var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: PPMetrics.itemGap / 2) {
                    Text("Pair my phone")
                        .font(.ppScreenHeading)
                        .foregroundStyle(Color(.label))
                        .accessibilityAddTraits(.isHeader)
                    // ⛔ The whole reason this step is here, said plainly.
                    Text("Do this while you are still standing at the Mac. The "
                         + "code is on its screen, and you will not want to move "
                         + "the phone once it is set down.")
                        .font(.ppSupporting)
                        .foregroundStyle(Color(.secondaryLabel))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if isPaired {
                pairedSection
            } else {
                pairingSection
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { bottomAction }
    }

    // MARK: - Not paired yet

    private var pairingSection: some View {
        Section {
            HostDisclosureRow(
                title: "Scan a pairing code",
                detail: "Studio shows one under Devices — Add a device",
                systemImage: "qrcode.viewfinder",
                action: onScanPairingCode
            )
        } header: {
            EyebrowLabel("How to pair")
        } footer: {
            // 3.6b — the code is the reliable path and discovery is the
            // convenience. Said here so a network that drops multicast does not
            // read as a broken app.
            Text("A Studio is remembered once you pair with it, so this is the "
                 + "only time you will need a code.")
        }
    }

    // MARK: - Paired

    private var pairedSection: some View {
        Section {
            HStack(spacing: PPMetrics.itemGap) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.ppAccent)
                    .frame(width: PPMetrics.Size.rowGlyph)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(hostName ?? "Paired")
                        .font(.ppRowLabel.weight(.semibold))
                        .foregroundStyle(Color(.label))
                    Text("Remembered — the next session will not need a code.")
                        .font(.ppFootnote)
                        .foregroundStyle(Color(.secondaryLabel))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: PPMetrics.Size.minimumTapTarget)
            .accessibilityElement(children: .combine)
        } footer: {
            Text("Now carry the phone over and set it down.")
        }
    }

    // MARK: - The bottom action

    /// ⚠ Two different bottom bars for two different moments, and the skip is
    /// **not** offered once a link is up: it would read as a way to undo the
    /// pairing, which it is not.
    @ViewBuilder
    private var bottomAction: some View {
        VStack(spacing: PPMetrics.itemGap / 2) {
            if isPaired {
                Button("Set it down", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
            } else {
                Button("I am on my own today", action: onSkip)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
                    .accessibilityHint(Text("Capture on this device only. "
                                            + "You can pair with Studio later."))
            }
        }
        .padding(.horizontal, PPMetrics.screenMargin)
        .padding(.bottom, PPMetrics.itemGap)
        .background(.bar)
    }
}

// MARK: - Previews

#Preview("B1 · Pair my phone") {
    NavigationStack {
        PairStepScreen(onScanPairingCode: {}, onContinue: {}, onSkip: {})
    }
    .preferredColorScheme(.dark)
}

#Preview("B1 · Paired") {
    NavigationStack {
        PairStepScreen(hostName: "Bay 3 — Mac Studio",
                       isPaired: true,
                       onScanPairingCode: {}, onContinue: {}, onSkip: {})
    }
    .preferredColorScheme(.dark)
}
