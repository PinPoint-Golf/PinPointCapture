//
//  PairingView.swift
//  B2 — Pairing.
//
//  A few seconds of waiting, made legible rather than hidden behind a spinner.
//  Each step is a plain-language name anyone can read, with the number that
//  proves it is happening in mono underneath — a friendly register doing work.
//
//  ⚠ The mono detail reflects **real progress**. `14 of 20 exchanges` is the
//  actual exchange count from the sync burst (REQ-SYNC-2), never a fake
//  animation. The burst estimates offset **and rate** (REQ-SYNC-1) and the
//  estimate is filtered, never stepped (REQ-SYNC-3).
//
//  ⛔ **B2 has a settled state as of #96, and until then the screen simply
//  vanished.** The handshake completed, the sheet was dismissed, and the phone
//  said nothing — so the only way to know pairing had worked was to look at the
//  *other* machine. That was the first of the three UX findings from the 24
//  August integration test. The four rows stay on screen as the evidence, the
//  eyebrow turns to `CONNECTED`, and the screen states what became of the
//  pairing.
//
//  ⚠ **Departure from the design pack, taken deliberately.** `mockup v1` gives
//  B2 no completed state. It is the screen the user is already looking at when
//  the handshake lands, so a confirmation here costs no new route and no new
//  navigation.
//
//  ⛔ **`Remembered` is a UI type, not the platform one.** `RendezvousCoordinator`
//  owns `PersistOutcome`; this layer never imports Platform, and the presenting
//  layer maps between them.
//

import SwiftUI
import CaptureCore

public struct PairingView: View {

    private let link: HostLink
    /// The capture format the host accepted, for the "Capability agreed" detail.
    private let agreedMode: VideoMode?
    /// The self-classified viewpoint reported to the host.
    private let viewpoint: Viewpoint?
    /// True once the camera has warmed and locked focus, exposure, white
    /// balance and stabilisation.
    private let isCameraLocked: Bool
    /// What the transport actually negotiated. ⛔ `nil` before a link exists —
    /// this row asserted TLS-PSK unconditionally for its whole life, including on
    /// a screen no link was behind.
    private let securitySummary: String?
    /// A handshake that did not complete, shown in place rather than dismissed.
    private let failure: String?
    /// What became of the pairing once the link settled. ⛔ `nil` while the
    /// handshake is still running — the screen does not speculate about a
    /// pairing that does not exist yet.
    private let remembered: Remembered?
    private let onCancel: () -> Void
    /// ⛔ 7.4b — *individually revocable*, offered at the moment the user learns
    /// the Studio was kept. `nil` where there is nothing to forget.
    private let onForget: (() -> Void)?

    /// What the screen says about persistence — the three answers `RV` §7.4
    /// allows for a pairing that has just completed.
    ///
    /// ⚠ **A statement, never an offer.** Remembering is the default stance as of
    /// 25 August 2026 (#96), so by the time this screen renders the decision has
    /// been taken and acted on. What the user is given is the way back out.
    public enum Remembered: Sendable, Equatable {
        /// Kept. The next session needs no code.
        case remembered
        /// ⛔ 7.4f — the code pairs several devices, so every one of them holds
        /// identical key material and the pairing is session-scoped by
        /// construction. Nothing was refused; there was nothing to keep.
        case multiUseCode
        /// The store could not be written. ⚠ Said out loud: a phone that claims
        /// a remembered Studio and holds nothing reconnects to nothing, which is
        /// exactly how the 24 August test failed.
        case couldNotWrite
        /// ⛔ The user forgot it from this screen. ⚠ The **link is untouched** —
        /// 7.4d ends the pairing, not the session that is already up.
        case forgotten
    }

    public init(
        link: HostLink,
        securitySummary: String? = nil,
        agreedMode: VideoMode? = nil,
        viewpoint: Viewpoint? = nil,
        isCameraLocked: Bool = false,
        failure: String? = nil,
        remembered: Remembered? = nil,
        onCancel: @escaping () -> Void,
        onForget: (() -> Void)? = nil
    ) {
        self.link = link
        self.securitySummary = securitySummary
        self.agreedMode = agreedMode
        self.viewpoint = viewpoint
        self.isCameraLocked = isCameraLocked
        self.failure = failure
        self.remembered = remembered
        self.onCancel = onCancel
        self.onForget = onForget
    }

    /// ⚠ The settled state is driven by the **outcome having arrived**, not by
    /// `link.state`: the pairing is what this screen is reporting on, and it is
    /// resolved a moment after the link is.
    private var hasSettled: Bool { remembered != nil }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PPMetrics.groupGap) {
                header
                steps
                failureNotice
                rememberedNotice
                if hasSettled == false { whyTheWait }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PPMetrics.screenMargin)
            .padding(.vertical, PPMetrics.groupGap)
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) { bottomAction }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: PPMetrics.itemGap / 2) {
            EyebrowLabel(hasSettled ? "Connected" : "Pairing", tone: .accent)

            // A host name is something the user already knows — not mono.
            Text(link.hostName ?? "Host")
                .font(.ppScreenHeading)
                .foregroundStyle(Color(.label))
                .accessibilityAddTraits(.isHeader)

            if let version = link.hostVersion {
                Text(version)
                    .font(.ppSupporting)
                    .foregroundStyle(Color(.secondaryLabel))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - The four handshake steps

    private var steps: some View {
        VStack(alignment: .leading, spacing: PPMetrics.itemGap + 4) {
            // ⛔ Was `.done` unconditionally with a hardcoded detail string —
            // a row asserting an encrypted channel on a screen that had no link
            // behind it at all. The detail is now what the handshake negotiated.
            ProgressRow(
                "Private channel open",
                detail: securitySummary,
                state: securitySummary == nil
                    ? (failure == nil ? .inProgress : .failed) : .done
            )
            // ⚠ "Agreed" overstates it: nothing consumes a host acceptance
            // message, so this row reflects the declaration **this device sent**.
            // It becomes a real agreement when a `hello_accept` capability reply
            // is read (E3.3's territory).
            ProgressRow(
                "Capability agreed",
                detail: capabilityDetail,
                state: agreedMode == nil ? .inProgress : .done
            )
            ProgressRow(
                "Matching clocks",
                detail: clockDetail,
                state: clockState
            )
            ProgressRow(
                "Camera warmed and locked",
                detail: isCameraLocked ? "Focus, exposure and white balance held" : nil,
                state: isCameraLocked ? .done : .pending
            )
        }
    }

    /// A handshake that failed, said in place. ⛔ B2 does not dismiss on failure:
    /// the four rows are the diagnosis, and dropping the user back to a scanner
    /// throws that away.
    @ViewBuilder
    private var failureNotice: some View {
        if let failure {
            InfoCard("The handshake did not complete. \(failure)",
                     systemImage: "exclamationmark.triangle.fill",
                     tone: .error)
        }
    }

    // MARK: - What became of the pairing (7.4)

    /// ⛔ Three outcomes, three sentences, and the cost stated rather than
    /// assumed away — *"possession of the device's storage is possession of
    /// continuing access"* is §7.4's own phrasing of it.
    @ViewBuilder
    private var rememberedNotice: some View {
        switch remembered {
        case .remembered:
            // ⚠ Just "Remembered" — the host name is the screen heading two
            // inches above, and repeating it wrapped the card title.
            InfoCard("The next session will not need a code. Anyone with this "
                     + "phone's storage keeps that access until you forget it.",
                     title: "Remembered",
                     systemImage: "checkmark.circle.fill",
                     tone: .accent)
        case .multiUseCode:
            // ⛔ 7.4f. Not a failure and not a setting: a multi-use code is a
            // group credential, and every device that scanned it holds the same
            // key material.
            InfoCard("This code can pair several devices, so the connection "
                     + "lasts for this session only. Ask Studio for a code of "
                     + "its own to be remembered.",
                     title: "Not remembered",
                     systemImage: "person.2.fill",
                     tone: .neutral)
        case .couldNotWrite:
            InfoCard("The connection is up, but this Studio could not be saved, "
                     + "so the next session will need a new code.",
                     title: "Not remembered",
                     systemImage: "exclamationmark.triangle.fill",
                     tone: .warning)
        case .forgotten:
            // ⚠ Present tense about the link, future about the pairing. Both
            // matter and they are different sentences.
            InfoCard("You are still connected. The next session will need a new "
                     + "pairing code from Studio.",
                     title: "Forgotten",
                     systemImage: "trash.fill",
                     tone: .neutral)
        case nil:
            EmptyView()
        }
    }

    // MARK: - The bottom action

    /// ⚠ *Cancel* while it is happening; *Done* once it has. ⛔ **Forget sits
    /// beside Done rather than replacing it** — the user came here to connect,
    /// and the way out of being remembered is secondary to that.
    @ViewBuilder
    private var bottomAction: some View {
        VStack(spacing: PPMetrics.itemGap / 2) {
            Button(hasSettled ? "Done" : "Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity,
                       minHeight: PPMetrics.Size.primaryButton)

            if remembered == .remembered, let onForget {
                Button("Forget this Studio", role: .destructive, action: onForget)
                    .font(.ppSupporting)
            }
        }
        .padding(.horizontal, PPMetrics.screenMargin)
        .padding(.top, PPMetrics.itemGap)
        .background(.bar)
    }

    /// "1080p150 accepted · view: DTL".
    private var capabilityDetail: String? {
        guard let agreedMode else { return nil }
        let format = "\(agreedMode.resolutionName)\(VideoMode.fpsText(agreedMode.fps))"
        guard let viewpoint else { return "\(format) accepted" }
        return "\(format) accepted · view: \(viewpoint.angle.displayName)"
    }

    /// "14 of 20 exchanges · offset −3.184 ms · drift 18 ppm".
    ///
    /// ⚠ The counts are the real burst counters, not a timer.
    private var clockDetail: String? {
        guard let clock = link.clock else { return nil }
        let exchanges = "\(clock.exchangesCompleted) of \(clock.exchangesExpected) exchanges"
        let sign = clock.offsetMilliseconds < 0 ? "\u{2212}" : ""
        let offset = String(format: "offset %@%.3f ms", sign, abs(clock.offsetMilliseconds))
        let drift = "drift \(Int(clock.driftPPM.rounded())) ppm"
        return "\(exchanges) · \(offset) · \(drift)"
    }

    private var clockState: ProgressRow.State {
        guard let clock = link.clock else { return .pending }
        if link.state == .lost { return .failed }
        return clock.exchangesCompleted >= clock.exchangesExpected ? .done : .inProgress
    }

    // MARK: - Why the wait

    private var whyTheWait: some View {
        InfoCard(
            "Twenty round trips get the two clocks agreeing to a fraction of a "
            + "frame. It is checked again against the sound of every shot.",
            title: "Why the wait"
        )
    }
}

// MARK: - Previews

#Preview("B2 · Pairing") {
    PairingView(
        link: PreviewFixtures.pairing,
        agreedMode: PreviewFixtures.capability.measured?.mode,
        viewpoint: PreviewFixtures.framingMarginalLight.viewpoint,
        onCancel: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("B2 · Connected and remembered") {
    PairingView(
        link: HostLink(
            state: .connected,
            hostName: PreviewFixtures.hostName,
            hostVersion: PreviewFixtures.hostVersion,
            clock: ClockAgreement(offsetMilliseconds: -3.184,
                                  offsetSigmaMilliseconds: 0.21,
                                  driftPPM: 18,
                                  exchangesCompleted: 20,
                                  exchangesExpected: 20)
        ),
        securitySummary: "TLS 1.2 · PSK",
        agreedMode: PreviewFixtures.capability.measured?.mode,
        viewpoint: PreviewFixtures.framingMarginalLight.viewpoint,
        isCameraLocked: true,
        remembered: .remembered,
        onCancel: {},
        onForget: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("B2 · Connected, multi-use code") {
    PairingView(
        link: HostLink(
            state: .connected,
            hostName: PreviewFixtures.hostName,
            hostVersion: PreviewFixtures.hostVersion,
            clock: ClockAgreement(offsetMilliseconds: -3.184,
                                  offsetSigmaMilliseconds: 0.21,
                                  driftPPM: 18,
                                  exchangesCompleted: 20,
                                  exchangesExpected: 20)
        ),
        securitySummary: "TLS 1.2 · PSK",
        agreedMode: PreviewFixtures.capability.measured?.mode,
        viewpoint: PreviewFixtures.framingMarginalLight.viewpoint,
        isCameraLocked: true,
        remembered: .multiUseCode,
        onCancel: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("B2 · Burst complete") {
    PairingView(
        link: HostLink(
            state: .pairing,
            hostName: PreviewFixtures.hostName,
            hostVersion: PreviewFixtures.hostVersion,
            clock: ClockAgreement(offsetMilliseconds: -3.184,
                                  offsetSigmaMilliseconds: 0.21,
                                  driftPPM: 18,
                                  exchangesCompleted: 20,
                                  exchangesExpected: 20)
        ),
        agreedMode: PreviewFixtures.capability.measured?.mode,
        viewpoint: PreviewFixtures.framingMarginalLight.viewpoint,
        isCameraLocked: true,
        onCancel: {}
    )
    .preferredColorScheme(.dark)
}
