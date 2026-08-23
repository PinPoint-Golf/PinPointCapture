//
//  MicToBallDistanceView.swift
//  A8 — How far is the phone from the ball?
//
//  ⚠ **The number on screen is milliseconds, not metres.** A golfer has no
//  intuition for what 1.5 m does to a timestamp and a very good one for "4 ms
//  earlier"; the distance is the input and the correction is the consequence, and
//  showing both is what makes the setting mean something.
//
//  ⛔ **It says the sigma is an estimate, because it is.** `CORE` §5.9 separates
//  surveyed geometry from an estimate and "the difference is the whole point of
//  carrying a sigma at all". Nothing here has been near a tape measure, so the
//  screen says "± 0.3 m, your estimate" rather than presenting a number as a
//  measurement — which is A12 applied to the one figure a user supplies.
//
//  ⛔ **In-screen controls, no dialogs.** Presets a person can judge against
//  something, and a stepper for the rest. A slider would invite false precision
//  in a value whose uncertainty is 20 %.
//
//  ⚠ It takes effect on the **next** arm. A Session whose Candidates were
//  corrected by two different distances is individually honest and collectively
//  incomparable, and the footer says so.
//
//  Spec: `CORE` §5.9, §5.12d, §8.1d; I29. Decision: Mark, 23 August 2026. Plan D7.

import SwiftUI
import CaptureCore

public struct MicToBallDistanceView: View {

    @Binding private var distance: MicToBallDistance
    private let wasChosen: Bool
    private let isSessionOpen: Bool
    private let onDone: () -> Void

    public init(distance: Binding<MicToBallDistance>,
                wasChosen: Bool = false,
                isSessionOpen: Bool = false,
                onDone: @escaping () -> Void = {}) {
        _distance = distance
        self.wasChosen = wasChosen
        self.isSessionOpen = isSessionOpen
        self.onDone = onDone
    }

    public var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: PPMetrics.itemGap / 2) {
                    Text(correctionText)
                        .font(.ppScreenHeading)
                        .foregroundStyle(Color(.label))
                        .monospacedDigit()
                    Text(sigmaText)
                        .font(.ppSupporting)
                        .foregroundStyle(Color(.secondaryLabel))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                EyebrowLabel("The correction applied to every shot")
            } footer: {
                Text("Sound takes about 3 ms to travel a metre. Without this, every "
                     + "impact is timed late by that much — most of a frame at 150 fps.")
            }
            .listRowBackground(Color.clear)

            Section {
                ForEach(MicToBallDistance.presets, id: \.metres) { preset in
                    Button {
                        distance = MicToBallDistance(metres: preset.metres,
                                                     provenance: .estimated)
                    } label: {
                        HStack {
                            Text(preset.label)
                                .foregroundStyle(Color(.label))
                            Spacer()
                            Text(Self.metresText(preset.metres))
                                .foregroundStyle(Color(.secondaryLabel))
                                .monospacedDigit()
                            if abs(distance.metres - preset.metres) < 0.01 {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.ppAccent)
                            }
                        }
                    }
                }
            } header: {
                EyebrowLabel("Microphone to ball")
            }

            Section {
                Stepper(value: Binding(
                    get: { distance.metres },
                    set: { distance = MicToBallDistance(metres: $0,
                                                        provenance: .estimated) }),
                        in: MicToBallDistance.permittedMetres, step: 0.1) {
                    LabeledContent("Exact distance",
                                   value: Self.metresText(distance.metres))
                }
            } footer: {
                // ⛔ A12 — the default is a guess and the screen never lets it read
                // as anything else.
                Text(wasChosen
                     ? "Your estimate. It is recorded with each session so a "
                       + "measurement can replace it later."
                     : "Not set — using the default of "
                       + "\(Self.metresText(MicToBallDistance.defaultMetres)), which is "
                       + "an assumption and not a measurement.")
            }

            if isSessionOpen {
                Section {
                    Text("Takes effect on the next arm. Changing it mid-session would "
                         + "leave two different corrections in one record.")
                        .font(.ppSupporting)
                        .foregroundStyle(Color.ppWarning)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("Distance to the ball")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
                .padding(.horizontal, PPMetrics.screenMargin)
                .padding(.top, PPMetrics.itemGap)
                .background(.bar)
        }
    }

    /// "Impact timed 4.4 ms earlier".
    private var correctionText: String {
        String(format: "Impact timed %.1f ms earlier", distance.correctionMilliseconds)
    }

    /// ⛔ The dispersion, in the same units, and labelled as an estimate (I29).
    private var sigmaText: String {
        String(format: "± %.1f ms — your estimate, not a measurement",
               distance.sigmaMilliseconds)
    }

    private static func metresText(_ metres: Double) -> String {
        String(format: "%.1f m", metres)
    }
}

#Preview("A8 · Distance to the ball") {
    @Previewable @State var distance = MicToBallDistance()
    return NavigationStack {
        MicToBallDistanceView(distance: $distance, wasChosen: false, isSessionOpen: true)
    }
    .preferredColorScheme(.dark)
}
