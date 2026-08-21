//
//  ArmedScreen.swift
//  PinPointCapture — C1 Armed. The app root; there is no tab bar.
//
//  ⚠ THE BRIEF FOR THIS SCREEN IS TWO METRES. It is read from a tripod, at
//  arm's length and then some, by someone holding a club. So: one accent pill,
//  one host chip, one thumbnail, two buttons. Everything else on the screen is
//  the picture.
//
//  ⚠ CAPTURE STATUS NEVER TURNS RED. The armed pill stays accent whatever the
//  host is doing — a weak link, a lost host or a full queue does not stop
//  capture, and the pill is the promise that it has not. Red on this screen
//  belongs to the host chip and to *Disarm*, and nowhere else.
//
//  Arm/disarm is host-controlled when a host is present (REQ-STATE-1);
//  ``onDisarm`` is the local override.
//

import SwiftUI
import CaptureCore

struct ArmedScreen: View {

    private let capture: CaptureStatus
    private let hostLink: HostLink
    private let session: Session
    private let lastShot: Shot?
    private let now: Date

    /// Opens the B3 host sheet. Owned by the navigation layer, not by C1.
    private let onOpenHost: () -> Void
    /// Opens C3, the session library.
    private let onOpenSession: () -> Void
    /// Opens C2 on ``lastShot``. Reviewing never disarms (REQ-STATE-4).
    private let onReplayLastShot: () -> Void
    /// The local override of a host-controlled state (REQ-STATE-1).
    private let onDisarm: () -> Void

    init(capture: CaptureStatus,
         hostLink: HostLink,
         session: Session,
         lastShot: Shot?,
         now: Date = Date(),
         onOpenHost: @escaping () -> Void,
         onOpenSession: @escaping () -> Void,
         onReplayLastShot: @escaping () -> Void,
         onDisarm: @escaping () -> Void) {
        self.capture = capture
        self.hostLink = hostLink
        self.session = session
        self.lastShot = lastShot
        self.now = now
        self.onOpenHost = onOpenHost
        self.onOpenSession = onOpenSession
        self.onReplayLastShot = onReplayLastShot
        self.onDisarm = onDisarm
    }

    var body: some View {
        ZStack(alignment: .top) {
            // ⚠ Substitution point — see CapturePlaceholders.swift.
            LiveCapturePreviewPlaceholder(caption: previewCaption)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                statusRow
                    .padding(.horizontal, PPMetrics.screenMargin)
                    .padding(.top, PPMetrics.itemGap)

                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    telemetryRail
                }
                .padding(.horizontal, PPMetrics.screenMargin)
                .padding(.top, PPMetrics.groupGap)

                Spacer(minLength: PPMetrics.groupGap)

                bottomPanel
            }
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Status row

    /// One pill and one chip. Nothing else earns a place up here.
    private var statusRow: some View {
        HStack(alignment: .center, spacing: PPMetrics.itemGap) {
            capturePill
            Spacer(minLength: 0)
            hostChip
        }
    }

    /// ⚠ Accent when armed, neutral otherwise — never `.error`, in any state of
    /// the host link.
    private var capturePill: some View {
        HStack(spacing: 8) {
            ArmedPillDot(tone: captureTone, isLive: capture.state == .armed)
            Text(capture.state.displayName)
                .font(.ppSupporting.weight(.semibold))
                .foregroundStyle(captureTone == .accent ? Color.ppAccent : Color(.label))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(captureTone.background, in: .capsule)
        .overlay(Capsule().strokeBorder(captureTone.border.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Capture"))
        .accessibilityValue(Text(capture.state.displayName))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var captureTone: StatusTone {
        capture.state == .armed ? .accent : .neutral
    }

    /// The entry point to the B3 host sheet. C1 does not present it — it says so.
    private var hostChip: some View {
        Button(action: onOpenHost) {
            HStack(spacing: 8) {
                Image(systemName: CaptureScreenStyle.symbol(for: hostLink.state))
                    .font(.ppSupporting.weight(.semibold))
                    .foregroundStyle(hostTone == .neutral ? Color(.secondaryLabel) : hostTone.foreground)
                Text(hostChipTitle)
                    .font(.ppSupporting.weight(.semibold))
                    .foregroundStyle(Color(.label))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minHeight: PPMetrics.Size.minimumTapTarget)
            .background(Color(.secondarySystemBackground).opacity(0.7), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Host, \(hostChipTitle)"))
        .accessibilityValue(Text(hostLink.state.title))
        .accessibilityHint(Text("Opens the host panel"))
    }

    private var hostTone: StatusTone { CaptureScreenStyle.tone(for: hostLink.state) }

    private var hostChipTitle: String {
        CaptureScreenStyle.shortHostName(hostLink.hostName) ?? "No host"
    }

    // MARK: - Telemetry rail

    /// ⚠ Deliberately small. This is reassurance for whoever wants it and is
    /// meant to be ignorable by everyone else — it must never grow into the
    /// screen's subject. Every value here is measured, so every value is mono.
    private var telemetryRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            railRow("fps", CaptureScreenStyle.fpsText(capture.achievedFPS))
            railRow("buffer", CaptureScreenStyle.bufferText(capture.bufferSeconds))
            railRow("sync",
                    CaptureScreenStyle.residualText(residualMilliseconds),
                    tone: CaptureScreenStyle.residualTone(residualMilliseconds))
            railRow("heat",
                    capture.thermal.displayName,
                    tone: CaptureScreenStyle.tone(for: capture.thermal))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, PPMetrics.rowPadding)
        .background(Color(.secondarySystemBackground).opacity(0.72),
                    in: .rect(cornerRadius: PPMetrics.Radius.control))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Capture telemetry"))
    }

    private var residualMilliseconds: Double? {
        hostLink.clock?.lastImpactResidualMilliseconds
    }

    private func railRow(_ label: String, _ value: String, tone: StatusTone = .neutral) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.ppFootnote)
                .foregroundStyle(Color(.secondaryLabel))
            Spacer(minLength: 10)
            Text(value)
                .font(.ppMeasuredDetail)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(tone == .neutral ? Color(.label) : tone.foreground)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(accessibleValue(value, tone: tone)))
    }

    private func accessibleValue(_ value: String, tone: StatusTone) -> String {
        guard let description = tone.accessibilityDescription else { return value }
        return "\(value), \(description)"
    }

    // MARK: - Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: 18) {
            if let lastShot {
                lastShotRow(lastShot)
            }
            actionRow
        }
        .padding(.horizontal, PPMetrics.screenMargin)
        .padding(.top, 22)
        .padding(.bottom, PPMetrics.itemGap)
        .background {
            LinearGradient(
                stops: [.init(color: .black.opacity(0), location: 0),
                        .init(color: .black.opacity(0.72), location: 0.4),
                        .init(color: .black.opacity(0.72), location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        }
    }

    /// The last shot and its sync state — the third and last thing readable from
    /// two metres.
    private func lastShotRow(_ shot: Shot) -> some View {
        HStack(spacing: 14) {
            // ⚠ Substitution point — see CapturePlaceholders.swift.
            ShotThumbnailPlaceholder(side: 74, caption: "LAST\nSHOT")

            VStack(alignment: .leading, spacing: 4) {
                Text("Shot \(shot.displayTitle)")
                    .font(.ppRowLabel.weight(.semibold))
                    .foregroundStyle(Color(.label))
                Text(lastShotDetail(shot))
                    .font(.ppSupporting)
                    .foregroundStyle(Color(.secondaryLabel))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onReplayLastShot) {
                Image(systemName: "play.fill")
                    .font(.title3)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(Color(.label))
            .accessibilityLabel(Text("Replay the last shot"))
        }
        .accessibilityElement(children: .combine)
    }

    private func lastShotDetail(_ shot: Shot) -> String {
        let elapsed = CaptureScreenStyle.elapsedText(from: shot.impact, to: now)
        return "\(elapsed) · \(CaptureScreenStyle.lastShotPhrase(for: shot.syncState))"
    }

    private var actionRow: some View {
        HStack(spacing: PPMetrics.itemGap) {
            Button(action: onOpenSession) {
                Text("Session · \(session.shots.count)")
                    .font(.ppRowLabel.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
            }
            .tint(Color(.label))
            .accessibilityHint(Text("Opens the session library"))

            // ⚠ Red because it is destructive, not because anything is wrong.
            Button(role: .destructive, action: onDisarm) {
                Text("Disarm")
                    .font(.ppRowLabel.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
            }
            .accessibilityHint(Text("Stops retaining shots on this device"))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: PPMetrics.Radius.card))
    }

    private var previewCaption: String {
        "LIVE PREVIEW · \(capture.state.displayName.uppercased())"
    }
}

// MARK: - The pill dot

/// The one piece of motion on this screen: a slow pulse while the device is
/// retaining. Honours Reduce Motion by simply not moving — the dot and its
/// colour already carry the state, so nothing is lost when it is still.
private struct ArmedPillDot: View {

    let tone: StatusTone
    let isLive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        Circle()
            .fill(tone == .neutral ? Color(.secondaryLabel) : tone.foreground)
            .frame(width: 9, height: 9)
            .opacity(isDimmed ? 0.4 : 1)
            .animation(shouldPulse ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : nil,
                       value: isDimmed)
            .onAppear { isDimmed = shouldPulse }
            .accessibilityHidden(true)
    }

    private var shouldPulse: Bool { isLive && !reduceMotion }
}

#Preview("C1 Armed") {
    ArmedScreen(
        capture: PreviewFixtures.armed,
        hostLink: PreviewFixtures.connected,
        session: PreviewFixtures.session,
        lastShot: PreviewFixtures.shots.first,
        now: PreviewFixtures.at(19, 36, 14),
        onOpenHost: {},
        onOpenSession: {},
        onReplayLastShot: {},
        onDisarm: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("C1 Armed · host lost") {
    ArmedScreen(
        capture: PreviewFixtures.armed,
        hostLink: PreviewFixtures.lost,
        session: PreviewFixtures.session,
        lastShot: PreviewFixtures.shots[2],
        now: PreviewFixtures.at(19, 36, 14),
        onOpenHost: {},
        onOpenSession: {},
        onReplayLastShot: {},
        onDisarm: {}
    )
    .preferredColorScheme(.dark)
}
