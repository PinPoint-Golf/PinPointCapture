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

import SwiftUI

public struct PairingView: View {

    private let link: HostLink
    /// The capture format the host accepted, for the "Capability agreed" detail.
    private let agreedMode: VideoMode?
    /// The self-classified viewpoint reported to the host.
    private let viewpoint: Viewpoint?
    /// True once the camera has warmed and locked focus, exposure, white
    /// balance and stabilisation.
    private let isCameraLocked: Bool
    private let onCancel: () -> Void

    public init(
        link: HostLink,
        agreedMode: VideoMode? = nil,
        viewpoint: Viewpoint? = nil,
        isCameraLocked: Bool = false,
        onCancel: @escaping () -> Void
    ) {
        self.link = link
        self.agreedMode = agreedMode
        self.viewpoint = viewpoint
        self.isCameraLocked = isCameraLocked
        self.onCancel = onCancel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PPMetrics.groupGap) {
                header
                steps
                whyTheWait
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PPMetrics.screenMargin)
            .padding(.vertical, PPMetrics.groupGap)
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) {
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity,
                       minHeight: PPMetrics.Size.primaryButton)
                .padding(.horizontal, PPMetrics.screenMargin)
                .padding(.top, PPMetrics.itemGap)
                .background(.bar)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: PPMetrics.itemGap / 2) {
            EyebrowLabel("Pairing", tone: .accent)

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
            ProgressRow(
                "Private channel open",
                detail: "TLS-PSK from the code you scanned",
                state: .done
            )
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
