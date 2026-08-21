//
//  TelemetryRow.swift
//  PinPointCapture design system
//

import SwiftUI
import CaptureCore

/// A plain-language label on the left and a measured value, in SF Mono, on the
/// right. The spine of A7's five-row summary, B3's five-row telemetry list, and
/// B4's two-row network list.
///
/// Built on `LabeledContent`, so it lays out and reads to VoiceOver exactly as a
/// system row does, and it drops straight into a `List(.insetGrouped)`:
///
/// ```swift
/// List {
///     Section {
///         TelemetryRow("Clock offset", "−3.184 ms ± 0.21")
///         TelemetryRow("Drift", "18 ppm, filtered")
///         TelemetryRow("Checked on last impact", "0.4 ms", tone: .accent)
///         TelemetryRow("Waiting to send", "nothing")
///         TelemetryRow("Temperature", "nominal")
///     }
/// }
/// .listStyle(.insetGrouped)
/// ```
///
/// In Lost, the **first row is capture state** — `TelemetryRow("Capture",
/// "still armed", tone: .accent)` — not the error. That ordering is the priority
/// rule made visible and must not be rearranged.
public struct TelemetryRow: View {

    private let label: String
    private let value: String
    private let tone: StatusTone?
    private let accessibilityValueOverride: String?

    /// - Parameters:
    ///   - label: what the number is, in words. Not mono.
    ///   - value: the measurement. Always mono — see
    ///     ``SwiftUI/View/ppMeasuredValue(tone:)``.
    ///   - tone: optional tint for the value. `nil` leaves it in `.label`, which
    ///     is right for most rows; tint only when the number itself carries a
    ///     verdict (a good residual, a degraded one, a queue that is draining).
    ///   - spokenValue: what VoiceOver should say instead of `value`, for
    ///     strings that do not read aloud well. `"−3.184 ms ± 0.21"` becomes
    ///     `"minus 3.184 milliseconds, plus or minus 0.21"`.
    public init(
        _ label: String,
        _ value: String,
        tone: StatusTone? = nil,
        spokenValue: String? = nil
    ) {
        self.label = label
        self.value = value
        self.tone = tone
        self.accessibilityValueOverride = spokenValue
    }

    public var body: some View {
        LabeledContent {
            Text(value)
                .ppMeasuredValue(tone: tone)
                .multilineTextAlignment(.trailing)
        } label: {
            Text(label)
                .font(.ppRowLabel)
                .foregroundStyle(Color(.label))
        }
        .frame(minHeight: PPMetrics.Size.minimumTapTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(spokenValue))
    }

    private var spokenValue: String {
        var spoken = accessibilityValueOverride ?? value
        if let description = tone?.accessibilityDescription {
            spoken += ", \(description)"
        }
        return spoken
    }
}

#Preview("TelemetryRow — A7 summary") {
    NavigationStack {
        List {
            Section {
                TelemetryRow("Capture", "1080p · 150 fps")
                TelemetryRow("Measured, sustained", "149.6 fps · 0 drops", tone: .accent)
                TelemetryRow("Lens", "Wide · locked")
                TelemetryRow("Kept per shot", "3.0 s around impact")
                TelemetryRow("Room for", "about 40 sessions")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Ready to capture")
    }
    .preferredColorScheme(.dark)
}

#Preview("TelemetryRow — B3 states") {
    List {
        Section("Connected") {
            TelemetryRow("Clock offset", "−3.184 ms ± 0.21",
                         spokenValue: "minus 3.184 milliseconds, plus or minus 0.21")
            TelemetryRow("Drift", "18 ppm, filtered")
            TelemetryRow("Checked on last impact", "0.4 ms", tone: .accent)
        }
        Section("Lost — capture state comes first") {
            TelemetryRow("Capture", "still armed", tone: .accent)
            TelemetryRow("Shots since the drop", "6")
            TelemetryRow("Waiting to send", "6 shots · 118 MB", tone: .warning)
            TelemetryRow("Retrying", "every 2 s")
        }
        Section("Catching up") {
            TelemetryRow("Sending", "shot 3 of 6 · 61%", tone: .progress)
            TelemetryRow("Gap reported to host", "14:38:12 → 14:44:03")
        }
    }
    .listStyle(.insetGrouped)
    .preferredColorScheme(.dark)
}
