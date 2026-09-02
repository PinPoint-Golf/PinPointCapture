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
    /// ⛔ **There was no way to arm from here.** Once onboarding was done a
    /// disarm was one-way: the only `arm()` call in the app was A7's *Start a
    /// session*, so a cold C1 stayed cold until the app was reinstalled.
    private let onArm: () -> Void
    /// How many transients have been heard but not promoted. ⚠ The difference
    /// between "the microphone is working and nothing was a shot" and "the
    /// microphone is dead" is the whole value of showing it.
    private let candidateCount: Int
    /// Surfaced rather than swallowed — a session that failed to open is the one
    /// thing §9.2 says the UI must not be quiet about.
    private let recordingError: String?
    /// ⛔ **Why *Arm* will not work**, when it will not. Same rule as
    /// ``recordingError`` and it was not being shown at all: `capabilityError`
    /// has existed since D4 and nothing on this screen read it, so a device that
    /// could not warm up presented a live-looking button that did nothing.
    private let capabilityError: String?
    /// Reaches the framing check from here. ⚠ `nil` where the route is not
    /// wired; the row is then absent rather than dead.
    private let onCheckFraming: (() -> Void)?
    /// A DEBUG instrument, laid out directly beneath the telemetry rail.
    ///
    /// ⛔ **A SLOT, because a screen-level overlay could not be positioned.** The
    /// ring counters were floated over this screen with a hand-tuned top inset
    /// and were in the wrong place four times: on the chips, on the golfer, on
    /// the telemetry rail — whose rows are full width, which is what made a
    /// left-hand offset useless — and finally in the middle of the frame on a
    /// phone taller than the simulator the inset was measured on. An absolute
    /// offset cannot be right on every device, and there is no reason to compute
    /// one: laid out here, it is under the rail by construction.
    ///
    /// ⚠ `nil` in a release build, so the designed screen keeps its shape — which
    /// is what the overlay was protecting, and it still is.
    private let debugAccessory: AnyView?

    /// ⛔ **What the reconnection sweep is doing, as C1 says it** (#97). `RV` §3
    /// runs on every foreground and `AppModel` has published
    /// `isSearchingForHost`, `reconnectSilence` and `reconnectDiagnosis` since
    /// D7 — with nothing anywhere rendering them, so a device quietly looking for
    /// its Studio looked identical to one that had given up.
    ///
    /// ⚠ **A UI type, not `Silence`.** The platform value carries sweeps and
    /// nanoseconds; a chip on a camera screen carries a sentence.
    enum HostSearch: Equatable {
        /// Browsing now, and nothing has come back yet. ⛔ 3.6a — not an error,
        /// and never coloured as one. ⚠ **No elapsed time on this one**: the
        /// first sweep has not completed, so `Silence.searchedForNs` does not
        /// exist yet and any number here would be invented.
        case looking
        /// Sweeps have come back empty. Still looking, and says how long.
        case notFound(seconds: Int)
        /// Nothing is held, so no browse is performed and none would help.
        case nothingHeld
        /// Something answered and refused, or could not be reached.
        case diagnosis(String)
    }

    /// `nil` while a link is up — the chip names the host instead.
    private let hostSearch: HostSearch?
    /// The remembered Studio being looked for, when exactly one is held. ⚠ 4.4d —
    /// untrusted display text, shown and never compared.
    private let searchingForName: String?

    /// ⛔ Ending a session is confirmed, because it cannot be undone: arming
    /// again opens a new one, and the two do not merge.
    @State private var isConfirmingEnd = false

    @Environment(\.livePreview) private var livePreview

    init(capture: CaptureStatus,
         hostLink: HostLink,
         session: Session,
         lastShot: Shot?,
         now: Date = Date(),
         onOpenHost: @escaping () -> Void,
         onOpenSession: @escaping () -> Void,
         onReplayLastShot: @escaping () -> Void,
         onDisarm: @escaping () -> Void,
         onArm: @escaping () -> Void = {},
         candidateCount: Int = 0,
         recordingError: String? = nil,
         hostSearch: HostSearch? = nil,
         searchingForName: String? = nil,
         capabilityError: String? = nil,
         onCheckFraming: (() -> Void)? = nil,
         debugAccessory: AnyView? = nil) {
        self.capabilityError = capabilityError
        self.onCheckFraming = onCheckFraming
        self.debugAccessory = debugAccessory
        self.hostSearch = hostSearch
        self.searchingForName = searchingForName
        self.onArm = onArm
        self.candidateCount = candidateCount
        self.recordingError = recordingError
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
            // The real camera, supplied by the composition root.
            livePreview.makeView(previewCaption)
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

                // ⛔ Directly under the rail, on every device, with no number to
                // get wrong. Left-aligned and hugging its content.
                if let debugAccessory {
                    HStack(spacing: 0) {
                        debugAccessory
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, PPMetrics.screenMargin)
                    .padding(.top, PPMetrics.itemGap)
                }

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
                Image(systemName: chipSymbol)
                    .font(.ppSupporting.weight(.semibold))
                    .foregroundStyle(chipTone == .neutral ? Color(.secondaryLabel) : chipTone.foreground)
                // ⛔ **The NAME on top, the STATE underneath — one shape in every
                // state** (Mark, 25 August 2026: the chip overlapped badly). It
                // read "PinPointStudio has not appeared" over "looked for 45s",
                // which wraps to three lines on any Studio with a real name and
                // swallows the top of the screen. The name is the identity and
                // belongs on its own line; what the app is doing about it is a
                // measurement, so it goes in the mono line with the number —
                // which is exactly the shape the connected state already had.
                VStack(alignment: .leading, spacing: 1) {
                    Text(hostChipTitle)
                        .font(.ppSupporting.weight(.semibold))
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let detail = chipDetail {
                        Text(detail)
                            .ppMeasuredDetail()
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                // ⚠ **Layout priority, not a fixed ceiling.** This was
                // `maxWidth: 168`, which truncates a name that would fit
                // perfectly well on a wider screen. Giving the chip a lower
                // priority than the capture pill lets it take whatever is left
                // and truncate only when it must — on any device.
                .layoutPriority(-1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, chipDetail == nil ? 9 : 7)
            .frame(minHeight: PPMetrics.Size.minimumTapTarget)
            .background(Color(.secondarySystemBackground).opacity(0.7), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Host, \(hostChipTitle)"))
        .accessibilityValue(Text(chipDetail ?? hostLink.state.title))
        .accessibilityHint(Text("Opens the host panel"))
    }

    /// ⛔ **Blue while looking, never orange.** 3.6a — a silent network is a
    /// normal quiet Tuesday, not a degradation, and the one state that IS a
    /// problem (something answered and refused) is the only one that warns.
    private var chipTone: StatusTone {
        switch hostSearch {
        case .looking, .notFound: .progress
        case .nothingHeld, nil: CaptureScreenStyle.tone(for: hostLink.state)
        case .diagnosis: .warning
        }
    }

    private var chipSymbol: String {
        switch hostSearch {
        case .looking, .notFound: "antenna.radiowaves.left.and.right"
        case .nothingHeld: "iphone"
        case .diagnosis: "exclamationmark.triangle.fill"
        case nil: CaptureScreenStyle.symbol(for: hostLink.state,
                                            transport: hostLink.transport)
        }
    }

    private var hostTone: StatusTone { CaptureScreenStyle.tone(for: hostLink.state) }

    private var hostChipTitle: String {
        switch hostSearch {
        case .looking, .notFound, .diagnosis:
            CaptureScreenStyle.shortHostName(searchingForName) ?? "Studio"
        case .nothingHeld:
            "On your own"
        case nil:
            CaptureScreenStyle.shortHostName(hostLink.hostName) ?? "No host"
        }
    }

    /// ⚠ Mono, because every one of these is a measurement or a state, never a
    /// name — the same rule the telemetry rail and B3 follow.
    private var chipDetail: String? {
        switch hostSearch {
        case .looking: "looking…"
        case .notFound(let seconds): "not found · \(seconds)s"
        case .nothingHeld: "no Studio paired"
        case .diagnosis: "refused"
        case nil: nil
        }
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
            if let recordingError {
                errorBanner(recordingError)
            }
            // ⛔ Before the shot rows: a device that cannot arm has nothing to
            // say about shots, and this is the sentence that explains the button.
            if capture.state != .armed, let capabilityError {
                errorBanner(capabilityError)
            }
            if let lastShot {
                lastShotRow(lastShot)
            } else if capture.state == .armed {
                // ⛔ Not simply omitted. A missing row looks the same whether the
                // microphone is listening or dead, and those are the two things a
                // golfer on a tripod most needs told apart.
                noShotsYetRow
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
            // ⚠ No caption. A tile labelled "LAST SHOT" implies an image that
            // is coming; nothing generates thumbnails yet (E1.2).
            ShotThumbnailPlaceholder(side: 74)

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

            if capture.state == .armed {
                // ⚠ Red because it is destructive, not because anything is wrong.
                // Red only ever appears when there is something to stop.
                //
                // ⛔ **"End session", and it was "Disarm"** (Mark, 25 August 2026).
                // The word described the camera; what the button does is close the
                // Session — `AppModel.disarm()` stamps `session.end`, and the next
                // Arm mints a **new** one. So a golfer who read "Disarm" as a pause
                // between buckets had silently split their round in two and could
                // not merge it back. Name the consequence, and confirm it.
                Button(role: .destructive) { isConfirmingEnd = true } label: {
                    Text("End session")
                        .font(.ppRowLabel.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
                }
                .accessibilityHint(Text("Closes this session and stops retaining shots"))
                .confirmationDialog("End this session?",
                                    isPresented: $isConfirmingEnd,
                                    titleVisibility: .visible) {
                    Button("End session", role: .destructive, action: onDisarm)
                    Button("Keep capturing", role: .cancel) { }
                } message: {
                    Text(endSessionSummary)
                }
            } else {
                // ⛔ **Reachable setup, and it was not** (#97). Folding placement
                // into the framing check made both onboarding-only, so from the
                // second session onwards a golfer who re-placed the phone — which
                // is every session — had nowhere to check it, and nowhere to go
                // when arming would not work.
                if let onCheckFraming {
                    Button(action: onCheckFraming) {
                        Text("Check framing")
                            .font(.ppRowLabel.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
                    }
                    .tint(Color(.label))
                    .accessibilityHint(Text("Re-checks placement, framing and light"))
                }

                if hostControlsCapture {
                    // ⭐ **THE HOST'S BUTTON, NOT THIS ONE** (2 Sept 2026).  With
                    // Studio linked, its Capture/Stop arms and disarms every
                    // phone in the bay — with two or three of them nobody walks
                    // round tapping each.  So there is nothing to press here;
                    // the line says who has the button.  *End session* above
                    // stays as the local override (REQ-STATE-1).
                    Text("\(hostShortName) controls capture")
                        .font(.ppRowLabel.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
                        .accessibilityLabel(Text("Capture is controlled by \(hostShortName)"))
                } else {
                    Button(action: onArm) {
                        Text("Capture")
                            .font(.ppRowLabel.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
                    }
                    .tint(Color.ppAccent)
                    .accessibilityHint(Text("Starts retaining shots on this device"))
                }
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: PPMetrics.Radius.card))
    }

    /// Whether a host holds this device's Capture button.  `.lost` hands it
    /// back: a host that is gone cannot arm anything, and a golfer stranded on
    /// a cold camera with no button is the #97 shape again.
    private var hostControlsCapture: Bool {
        switch hostLink.state {
        case .connected, .weak, .resyncing: true
        case .none, .pairing, .lost: false
        }
    }

    private var hostShortName: String {
        CaptureScreenStyle.shortHostName(hostLink.hostName) ?? "Studio"
    }

    /// What the confirmation says is about to be closed.
    ///
    /// ⛔ **It names what is in the session, not what the button does.** "This
    /// cannot be undone" is a warning; "41 shots · 22 minutes" is the thing a
    /// golfer needs in order to know whether they meant to.
    private var endSessionSummary: String {
        let shots = session.shots.count == 1 ? "1 shot" : "\(session.shots.count) shots"
        let minutes = Int((now.timeIntervalSince(session.start) / 60).rounded())
        let length = minutes < 1 ? "just started" : (minutes == 1 ? "1 minute" : "\(minutes) minutes")
        return "\(shots) · \(length). Arming again starts a new session — "
            + "the two are not merged. Everything already captured is kept."
    }

    /// Armed, listening, nothing promoted yet.
    private var noShotsYetRow: some View {
        HStack(spacing: 14) {
            ShotThumbnailPlaceholder(side: 74)

            VStack(alignment: .leading, spacing: 4) {
                Text("No shots yet")
                    .font(.ppRowLabel.weight(.semibold))
                    .foregroundStyle(Color(.label))
                Text(candidateCount == 0
                     ? "Listening for impacts"
                     : "\(candidateCount) sound\(candidateCount == 1 ? "" : "s") heard, "
                       + "none confirmed")
                    .font(.ppSupporting)
                    .foregroundStyle(Color(.secondaryLabel))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// ⛔ §9.2 — capture failing is the one thing that must not be quiet.
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: PPMetrics.itemGap) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StatusTone.error.foreground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // ⚠ The title says what is true of the RING.  While it is armed
                // and retaining, whatever went wrong is somewhere else -- the
                // host, a stream, the microphone -- and "nothing is being
                // recorded" over a ring at 238 fps was a lie (2 Sept 2026).
                Text(capture.state == .armed ? "Recording continues on this phone"
                                             : "Nothing is being recorded")
                    .font(.ppRowLabel.weight(.semibold))
                    .foregroundStyle(Color(.label))
                Text(message)
                    .font(.ppSupporting)
                    .foregroundStyle(Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(PPMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StatusTone.error.background, in: .rect(cornerRadius: PPMetrics.Radius.card))
        .accessibilityElement(children: .combine)
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
