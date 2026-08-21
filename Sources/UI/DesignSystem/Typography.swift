//
//  Typography.swift
//  PinPointCapture design system
//
//  SF throughout; SF Mono for any number the user could not have guessed.
//
//  Every role below is built on a Dynamic Type text style, so all of it scales.
//  The HTML handoff's pixel sizes (34/26/18/16/14/13/12) are explicitly medium
//  fidelity and must never be reproduced as fixed point sizes.
//

import SwiftUI
import CaptureCore

public extension Font {

    /// A1's app name, C3's session title. 34pt bold in the HTML.
    ///
    /// Usually you do not need this: a screen heading is `.navigationTitle` with
    /// `.navigationBarTitleDisplayMode(.large)`, which is already this face.
    static var ppLargeTitle: Font { .largeTitle.bold() }

    /// A sheet or modal heading — B2's host name, B4's "Join the studio
    /// network?", B5's "Studio has part of this session already". 26–32pt bold.
    static var ppScreenHeading: Font { .title.bold() }

    /// A card's own title — A3's choice titles, B3's state title, B2's
    /// "Why the wait". 18–22pt semibold.
    static var ppCardTitle: Font { .title3.weight(.semibold) }

    /// The left-hand label of a list or telemetry row. 16–17pt.
    static var ppRowLabel: Font { .body }

    /// The sentence under a title. 14–15pt.
    static var ppSupporting: Font { .subheadline }

    /// Footnotes, disclaimers, disabled text. 13pt.
    static var ppFootnote: Font { .footnote }

    /// A measured value — see ``SwiftUI/View/ppMeasuredValue(tone:)``.
    /// 13–15pt semibold mono.
    static var ppMeasuredValue: Font { .body.weight(.semibold).monospaced() }

    /// The mono detail line under a ``ProgressRow`` title, and the small mono
    /// telemetry in the C1 rail. 12–13pt mono.
    static var ppMeasuredDetail: Font { .footnote.monospaced() }

    /// `PAIRING`, `THIS DEVICE`, `OR CARRY ON WITHOUT IT`.
    /// 11–13pt semibold mono, wide tracking, upper case.
    /// Applied for you by ``EyebrowLabel``.
    static var ppEyebrow: Font { .caption.weight(.semibold).monospaced() }

    /// `In Studio`, `Sending 61%`, `LIKELY`. 12pt semibold.
    /// Applied for you by ``StatusChip``.
    static var ppStatusChip: Font { .caption.weight(.semibold) }
}

public extension View {

    /// **Any number the user could not have guessed.**
    ///
    /// This is the load-bearing typographic distinction in the whole app. Clock
    /// offsets, residuals, drift, frame rates, timestamps, byte counts, shot
    /// counts, exposure and ISO — anything the device *measured* — is set in
    /// SF Mono so it reads as an instrument reading rather than as prose.
    ///
    /// Text the user already knows, or could have written themselves — a club
    /// name, a session name, a host name, a button title — is **not** mono.
    ///
    /// ```swift
    /// Text("−3.184 ms ± 0.21").ppMeasuredValue()            // offset: mono
    /// Text("149.6 fps · 0 drops").ppMeasuredValue()         // measured: mono
    /// Text("Wide · locked").ppMeasuredValue()               // enumerated: mono
    /// Text("Bay 3 — Mac Studio").font(.ppCardTitle)         // a name: not mono
    /// ```
    ///
    /// - Parameter tone: tints the value. Defaults to `nil`, which leaves it in
    ///   `.label`. Use ``StatusTone/accent`` for a good sync residual,
    ///   ``StatusTone/warning`` for a degraded one, and so on.
    func ppMeasuredValue(tone: StatusTone? = nil) -> some View {
        font(.ppMeasuredValue)
            .monospacedDigit()
            .foregroundStyle(tone.map(\.foreground) ?? Color(.label))
    }

    /// The smaller mono line that sits *underneath* a plain-language title —
    /// B2's `14 of 20 exchanges · offset −3.184 ms`, the C1 telemetry rail.
    ///
    /// Same rule as ``ppMeasuredValue(tone:)``: only for numbers the user could
    /// not have guessed.
    func ppMeasuredDetail(tone: StatusTone? = nil) -> some View {
        font(.ppMeasuredDetail)
            .monospacedDigit()
            .foregroundStyle(tone.map(\.foreground) ?? Color(.secondaryLabel))
    }
}

#Preview("Typography") {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Text("PinPointCapture").font(.ppLargeTitle)
            Text("Bay 3 — Mac Studio").font(.ppScreenHeading)
            Text("In a studio, with a host").font(.ppCardTitle)
            Text("Clock offset").font(.ppRowLabel)
            Text("Pair with PinPoint Studio. Shots are correlated as you hit them.")
                .font(.ppSupporting)
                .foregroundStyle(Color(.secondaryLabel))
            Text("No analytics, ever.")
                .font(.ppFootnote)
                .foregroundStyle(Color(.tertiaryLabel))

            Divider()

            Text("Numbers the user could not have guessed")
                .font(.ppFootnote)
                .foregroundStyle(Color(.tertiaryLabel))
            Text("−3.184 ms ± 0.21").ppMeasuredValue()
            Text("149.6 fps · 0 drops").ppMeasuredValue(tone: .accent)
            Text("1/1600 s · ISO 2200 · 150 fps").ppMeasuredValue(tone: .warning)
            Text("14 of 20 exchanges · offset −3.184 ms · drift 18 ppm")
                .ppMeasuredDetail()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PPMetrics.screenMargin)
    }
    .background(Color(.systemBackground))
    .preferredColorScheme(.dark)
}
