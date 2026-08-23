//
//  HostPanelView.swift
//  B3 — Host panel, four live states.
//
//  The content of the sheet opened from the C1 host chip. There is no tab bar in
//  this app: capture is the root and the host lives in here.
//
//  ⚠ **One layout carries all four states.** The colour and the sentence change;
//  the structure does not. A glance from the mat must never require re-reading,
//  so the status card reserves the height of the longest explanation and the
//  telemetry list is always exactly five rows. Transitions animate colour and
//  copy only — nothing reflows.
//
//  ⚠ **In `lost` the first telemetry row is `Capture — still armed`, above the
//  error.** That ordering is the priority rule made visible (§9.2, REQ-RES-1)
//  and must not be rearranged to put the failure first. Capture status never
//  turns red.
//
//  The 4-way segmented control below the nav row is **not present in the
//  shipped app**. It exists only so a reviewer can flip states, and is gated
//  behind ``HostPanelView/reviewerControlsDefault`` (DEBUG only).
//

import SwiftUI
import CaptureCore

public struct HostPanelView: View {

    // MARK: State in

    private let link: HostLink
    /// ⚠ Read first in the `lost` state. Capture never stops for a host problem.
    private let capture: CaptureStatus
    private let queue: TransferQueue?
    private let storage: StorageHeadroom?
    /// Progress of the shot currently in flight, 0...1 — the `61%` in
    /// "shot 3 of 6 · 61%".
    private let currentTransferProgress: Double?
    /// Drives "PinPoint Studio 0.9.4 · session started 18:20".
    private let sessionStart: Date?
    /// The value on the *Send video over* row — "Wi-Fi and cable".
    private let videoTransportSummary: String
    /// Reconnection backoff, for the `lost` state's "Retrying" row.
    private let retryIntervalSeconds: Double
    /// ⚠ Whether the measured figure came from a cold run. `nil` where nothing
    /// has measured.
    private let measuredMethod: MeasuredCapability.Method?
    /// A8's permanent route. B3 is the app's settings sheet.
    private let onOpenMicToBallDistance: (() -> Void)?

    // MARK: Reviewer controls

    /// ⚠ Ships **off**. The segmented state switcher is a review device, not a
    /// real control — no shipped build lets a golfer choose the host's state.
    public static var reviewerControlsDefault: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private let reviewerControlsEnabled: Bool
    /// Supplied only by the reviewer walkthrough. `nil` in the shipped app, and
    /// the switcher is hidden when it is `nil` regardless of the flag.
    private let onSelectReviewState: ((HostLinkState) -> Void)?

    // MARK: Actions out

    private let onDone: () -> Void
    /// The full-width action, whose title is ``HostLinkState/actionTitle``.
    private let onPrimaryAction: () -> Void
    private let onOpenConnectionLog: (() -> Void)?
    private let onExportDiagnostics: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        link: HostLink,
        capture: CaptureStatus,
        queue: TransferQueue? = nil,
        storage: StorageHeadroom? = nil,
        currentTransferProgress: Double? = nil,
        sessionStart: Date? = nil,
        videoTransportSummary: String = "Wi-Fi and cable",
        retryIntervalSeconds: Double = 2,
        reviewerControlsEnabled: Bool = HostPanelView.reviewerControlsDefault,
        onSelectReviewState: ((HostLinkState) -> Void)? = nil,
        measuredMethod: MeasuredCapability.Method? = nil,
        onDone: @escaping () -> Void,
        onPrimaryAction: @escaping () -> Void,
        onOpenConnectionLog: (() -> Void)? = nil,
        onExportDiagnostics: (() -> Void)? = nil,
        onOpenMicToBallDistance: (() -> Void)? = nil
    ) {
        self.measuredMethod = measuredMethod
        self.onOpenMicToBallDistance = onOpenMicToBallDistance
        self.link = link
        self.capture = capture
        self.queue = queue
        self.storage = storage
        self.currentTransferProgress = currentTransferProgress
        self.sessionStart = sessionStart
        self.videoTransportSummary = videoTransportSummary
        self.retryIntervalSeconds = retryIntervalSeconds
        self.reviewerControlsEnabled = reviewerControlsEnabled
        self.onSelectReviewState = onSelectReviewState
        self.onDone = onDone
        self.onPrimaryAction = onPrimaryAction
        self.onOpenConnectionLog = onOpenConnectionLog
        self.onExportDiagnostics = onExportDiagnostics
    }

    // MARK: - Body

    public var body: some View {
        List {
            if let onSelectReviewState, reviewerControlsEnabled {
                reviewerSwitcher(onSelect: onSelectReviewState)
            }
            statusSection
            telemetrySection
            settingsSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("Host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone)
            }
        }
        .safeAreaInset(edge: .bottom) { primaryAction }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: link.state)
    }

    // MARK: - The reviewer-only state switcher

    /// ⚠ Not in the shipped app. A `Picker` + `.pickerStyle(.segmented)`,
    /// never a hand-rolled pill row.
    private func reviewerSwitcher(
        onSelect: @escaping (HostLinkState) -> Void
    ) -> some View {
        Section {
            Picker("Host state", selection: Binding(
                get: { link.state },
                set: { onSelect($0) }
            )) {
                Text("Connected").tag(HostLinkState.connected)
                Text("Weak").tag(HostLinkState.weak)
                Text("Lost").tag(HostLinkState.lost)
                Text("Back").tag(HostLinkState.resyncing)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Text("Reviewer state switcher"))
            .accessibilityHint(Text("Not present in the shipped app."))
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: PPMetrics.screenMargin,
                                  bottom: PPMetrics.itemGap,
                                  trailing: PPMetrics.screenMargin))
    }

    // MARK: - Status card

    private var tone: StatusTone { link.state.tone }

    private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: PPMetrics.itemGap / 2) {
                HStack(spacing: PPMetrics.itemGap - 4) {
                    Image(systemName: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(tone.foreground)
                        .accessibilityHidden(true)

                    Text(link.state.title)
                        .font(.ppCardTitle)
                        .foregroundStyle(Color(.label))
                        .contentTransition(.opacity)
                }

                // A host name is something the user already knows — not mono.
                Text(link.hostName ?? "No host")
                    .font(.ppRowLabel.weight(.semibold))
                    .foregroundStyle(Color(.label))

                Text(subLine)
                    .font(.ppFootnote)
                    .foregroundStyle(Color(.secondaryLabel))

                explanation
                    .padding(.top, PPMetrics.itemGap / 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, PPMetrics.itemGap / 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(spokenStatus))
        }
    }

    /// The explanation sentence, in a container sized to the **longest** of the
    /// four sentences. This is what stops the panel reflowing when the state
    /// changes: the sentence swaps, the box does not move.
    private var explanation: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Self.switchableStates, id: \.self) { state in
                Text(state.explanation)
                    .font(.ppSupporting)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hidden()
                    .accessibilityHidden(true)
            }
            Text(link.state.explanation)
                .font(.ppSupporting)
                .foregroundStyle(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
        }
    }

    /// "PinPoint Studio 0.9.4 · protocol PPCP 1.0 · session started 18:20".
    private var subLine: String {
        var parts: [String] = []
        if let version = link.hostVersion { parts.append(version) }
        if let sessionStart {
            parts.append("session started \(HostFormat.timeOfDay(sessionStart))")
        }
        return parts.joined(separator: " · ")
    }

    private var spokenStatus: String {
        var spoken = link.state.title
        if let description = tone.accessibilityDescription {
            spoken += ", \(description)"
        }
        if let name = link.hostName { spoken += ". \(name)" }
        spoken += ". \(link.state.explanation)"
        return spoken
    }

    // MARK: - Telemetry

    private var telemetrySection: some View {
        Section {
            // ⚠ Identified by *position*, not by label. Every state has the same
            // five rows, so row one stays row one and only its text and tint
            // change — the list never inserts, removes or reorders.
            ForEach(Array(telemetry.enumerated()), id: \.offset) { _, line in
                TelemetryRow(line.label, line.value,
                             tone: line.tone, spokenValue: line.spokenValue)
            }
        }
        .contentTransition(.opacity)
    }

    /// Exactly five rows in every state — the list never changes length.
    ///
    /// ⚠ In `lost` the first row is capture state, not the error.
    private var telemetry: [HostTelemetryLine] {
        switch link.state {
        case .connected: connectedTelemetry
        case .weak:      weakTelemetry
        case .lost:      lostTelemetry
        case .resyncing: resyncingTelemetry
        case .pairing:   pairingTelemetry
        case .none:      noHostTelemetry
        }
    }

    private var connectedTelemetry: [HostTelemetryLine] {
        [
            HostTelemetryLine.clockOffset(link.clock),
            HostTelemetryLine("Drift", link.clock?.driftText ?? "—"),
            HostTelemetryLine("Checked on last impact",
                              HostFormat.residual(link.clock?.lastImpactResidualMilliseconds),
                              tone: .accent),
            HostTelemetryLine("Waiting to send", HostFormat.queue(queue)),
            HostTelemetryLine("Temperature", capture.thermal.displayName)
        ]
    }

    private var weakTelemetry: [HostTelemetryLine] {
        [
            HostTelemetryLine.clockOffset(link.clock),
            HostTelemetryLine("Last impact",
                              HostFormat.residual(link.clock?.lastImpactResidualMilliseconds),
                              tone: .warning),
            HostTelemetryLine("Waiting", HostFormat.queue(queue)),
            HostTelemetryLine("Throughput",
                              HostFormat.throughput(link.throughputMbitPerSecond),
                              tone: .warning,
                              spokenValue: HostFormat.spokenThroughput(link.throughputMbitPerSecond)),
            HostTelemetryLine("Temperature", capture.thermal.displayName,
                              tone: capture.thermal > .nominal ? .warning : nil)
        ]
    }

    /// ⚠ Row one is capture, in accent, above the error. Do not rearrange.
    private var lostTelemetry: [HostTelemetryLine] {
        let sinceDrop = link.gap?.shotsInGap ?? queue?.pendingShotIDs.count ?? 0
        return [
            HostTelemetryLine("Capture",
                              capture.state == .armed ? "still armed"
                                                      : capture.state.displayName,
                              tone: .accent),
            HostTelemetryLine("Shots since the drop", "\(sinceDrop)"),
            HostTelemetryLine("Waiting", HostFormat.queue(queue)),
            HostTelemetryLine("Retrying", HostFormat.retry(retryIntervalSeconds)),
            HostTelemetryLine("Storage left", HostFormat.storage(storage))
        ]
    }

    private var resyncingTelemetry: [HostTelemetryLine] {
        [
            HostTelemetryLine.clockOffset(link.clock),
            HostTelemetryLine("Sending",
                              HostFormat.sending(queue, progress: currentTransferProgress),
                              tone: .progress),
            HostTelemetryLine("Gap reported to host", HostFormat.gap(link.gap),
                              spokenValue: HostFormat.spokenGap(link.gap)),
            HostTelemetryLine("Shots in the gap", HostFormat.shotsInGap(link.gap),
                              tone: .accent),
            HostTelemetryLine("Temperature", capture.thermal.displayName)
        ]
    }

    private var pairingTelemetry: [HostTelemetryLine] {
        [
            HostTelemetryLine("Exchanges", HostFormat.exchanges(link.clock),
                              tone: .progress),
            HostTelemetryLine.clockOffset(link.clock),
            HostTelemetryLine("Drift", link.clock?.driftText ?? "—"),
            HostTelemetryLine("Waiting to send", HostFormat.queue(queue)),
            HostTelemetryLine("Temperature", capture.thermal.displayName)
        ]
    }

    private var noHostTelemetry: [HostTelemetryLine] {
        [
            HostTelemetryLine("Capture",
                              capture.state == .armed ? "still armed"
                                                      : capture.state.displayName,
                              tone: .accent),
            HostTelemetryLine("Held here", HostFormat.queue(queue)),
            // ⛔ `HostFormat.fps` printed "0.0 fps" before anything measured — a
            // measurement claim of zero, sitting in a column of real ones. And
            // where there *is* a figure, say which kind it is: a three-second
            // cold sample is not `CORE` 5.8b's sustained rate.
            HostTelemetryLine("Measured", measuredText),
            HostTelemetryLine("Storage left", HostFormat.storage(storage)),
            HostTelemetryLine("Temperature", capture.thermal.displayName)
        ]
    }

    private var measuredText: String {
        guard capture.achievedFPS > 0 else { return "not measured yet" }
        let fps = HostFormat.fps(capture.achievedFPS)
        switch measuredMethod {
        case .sustained: return "\(fps) · sustained"
        case .coldSample: return "\(fps) · cold sample"
        case nil: return fps
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        Section {
            // A trailing *value*, so `LabeledContent` — not a custom two-column row.
            LabeledContent("Send video over") {
                Text(videoTransportSummary)
                    .font(.ppRowLabel)
                    .foregroundStyle(Color(.secondaryLabel))
            }
            .frame(minHeight: PPMetrics.Size.minimumTapTarget)
            .accessibilityElement(children: .combine)

            // ⚠ A8, finally reachable. Built, persisted, feeding every
            // Candidate's `tof_correction`, and with nothing in the app that
            // navigated to it.
            if let onOpenMicToBallDistance {
                HostDisclosureRow(title: "Phone to ball", action: onOpenMicToBallDistance)
            }

            // ⛔ Disabled and *told*. These were live rows wired to `{}` — a
            // control that silently no-ops teaches a user the app is broken,
            // where one that says why teaches them it is unfinished.
            HostDisclosureRow(title: "Connection log",
                              action: onOpenConnectionLog ?? {})
                .disabled(onOpenConnectionLog == nil)
            HostDisclosureRow(title: "Export a diagnostic bundle",
                              action: onExportDiagnostics ?? {})
                .disabled(onExportDiagnostics == nil)
        } footer: {
            if onOpenConnectionLog == nil && onExportDiagnostics == nil {
                Text("The connection log and the diagnostic bundle are not built yet.")
            }
        }
    }

    // MARK: - The full-width action, tinted to the state

    private var primaryAction: some View {
        Button(link.state.actionTitle, action: onPrimaryAction)
            .buttonStyle(.bordered)
            .controlSize(.large)
            // The tint is the state, so it cannot be inherited from the app
            // accent: red for a lost host, orange for weak, blue for catching up.
            .tint(tone.foreground)
            .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
            .padding(.horizontal, PPMetrics.screenMargin)
            .padding(.top, PPMetrics.itemGap)
            .background(.bar)
            .contentTransition(.opacity)
    }

    /// The four states a reviewer can flip between, and the four whose
    /// explanations the status card reserves height for.
    static let switchableStates: [HostLinkState] = [.connected, .weak, .lost, .resyncing]
}

// MARK: - Screen-local model

/// One telemetry line. Screen-local: this is B3's row list, not a shared type.
private struct HostTelemetryLine {
    let label: String
    let value: String
    var tone: StatusTone?
    var spokenValue: String?

    init(_ label: String, _ value: String,
         tone: StatusTone? = nil, spokenValue: String? = nil) {
        self.label = label
        self.value = value
        self.tone = tone
        self.spokenValue = spokenValue
    }

    /// "−3.184 ms ± 0.21", spoken as words. REQ-SYNC-1: offset **and** rate, so
    /// this row never appears without a drift row beside it.
    static func clockOffset(_ clock: ClockAgreement?) -> HostTelemetryLine {
        guard let clock else { return HostTelemetryLine("Clock offset", "—") }
        return HostTelemetryLine("Clock offset", clock.offsetText,
                                 spokenValue: HostFormat.spokenOffset(clock))
    }
}

// MARK: - Screen-local formatting

/// Formatting for B3's telemetry. Screen-local by design: none of this is a
/// general-purpose helper, and Core owns every format that is shared.
enum HostFormat {

    static func timeOfDay(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    static func timeWithSeconds(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .second(.twoDigits)
        )
    }

    /// "0.4 ms".
    static func residual(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "not yet" }
        return String(format: "%.1f ms", milliseconds)
    }

    /// "3 shots · 71 MB", or "nothing" when the queue has drained.
    static func queue(_ queue: TransferQueue?) -> String {
        guard let queue, !queue.pendingShotIDs.isEmpty else { return "nothing" }
        let count = queue.pendingShotIDs.count
        let megabytes = Int((Double(queue.bytesRemaining) / 1_000_000).rounded())
        let shots = count == 1 ? "1 shot" : "\(count) shots"
        return "\(shots) · \(megabytes) MB"
    }

    /// "4.1 Mbit/s".
    static func throughput(_ mbitPerSecond: Double?) -> String {
        guard let mbitPerSecond else { return "—" }
        return String(format: "%.1f Mbit/s", mbitPerSecond)
    }

    static func spokenThroughput(_ mbitPerSecond: Double?) -> String? {
        guard let mbitPerSecond else { return nil }
        return String(format: "%.1f megabits per second", mbitPerSecond)
    }

    /// "every 2 s".
    static func retry(_ seconds: Double) -> String {
        seconds == seconds.rounded()
            ? "every \(Int(seconds)) s"
            : String(format: "every %.1f s", seconds)
    }

    /// "38 sessions".
    static func storage(_ storage: StorageHeadroom?) -> String {
        guard let storage else { return "—" }
        return storage.estimatedSessions == 1
            ? "1 session"
            : "\(storage.estimatedSessions) sessions"
    }

    /// "shot 3 of 6 · 61%".
    static func sending(_ queue: TransferQueue?, progress: Double?) -> String {
        guard let queue, let current = queue.currentShotOrdinal else { return "nothing" }
        let head = "shot \(current) of \(queue.totalShots)"
        guard let progress else { return head }
        return "\(head) · \(Int((progress * 100).rounded()))%"
    }

    /// "14:38:12 → 14:44:03". REQ-STATE-5: the gap is reported explicitly.
    static func gap(_ gap: GapWindow?) -> String {
        guard let gap else { return "none" }
        return "\(timeWithSeconds(gap.start)) → \(timeWithSeconds(gap.end))"
    }

    static func spokenGap(_ gap: GapWindow?) -> String? {
        guard let gap else { return nil }
        return "\(timeWithSeconds(gap.start)) to \(timeWithSeconds(gap.end))"
    }

    /// "6, all retained" — nothing captured during a gap is ever dropped
    /// (REQ-SESS-4).
    static func shotsInGap(_ gap: GapWindow?) -> String {
        guard let gap, gap.shotsInGap > 0 else { return "none" }
        return "\(gap.shotsInGap), all retained"
    }

    /// "14 of 20 exchanges".
    static func exchanges(_ clock: ClockAgreement?) -> String {
        guard let clock else { return "—" }
        return "\(clock.exchangesCompleted) of \(clock.exchangesExpected) exchanges"
    }

    /// "149.6 fps".
    static func fps(_ value: Double) -> String {
        "\(VideoMode.fpsText(value)) fps"
    }

    /// "minus 3.184 milliseconds, plus or minus 0.21" — symbols do not read
    /// aloud, so every value with one gets a spoken form.
    static func spokenOffset(_ clock: ClockAgreement) -> String {
        let sign = clock.offsetMilliseconds < 0 ? "minus " : ""
        return String(format: "%@%.3f milliseconds, plus or minus %.2f",
                      sign, abs(clock.offsetMilliseconds),
                      clock.offsetSigmaMilliseconds)
    }
}

// MARK: - Tone for a state

private extension HostLinkState {
    /// The one colour rule, applied. Delegates to the single mapping in
    /// `StatusTone+Domain.swift` — this must not grow a second opinion.
    var tone: StatusTone { StatusTone(self) }
}

// MARK: - Previews

/// Wraps the panel so the reviewer switcher has somewhere to write to.
private struct HostPanelPreview: View {
    @State var link: HostLink
    var queue: TransferQueue?
    var storage: StorageHeadroom?
    var transferProgress: Double?
    var thermal: ThermalState = .nominal

    var body: some View {
        NavigationStack {
            HostPanelView(
                link: link,
                capture: CaptureStatus(state: .armed, thermal: thermal,
                                       bufferSeconds: 10.0, achievedFPS: 149.6),
                queue: queue,
                storage: storage,
                currentTransferProgress: transferProgress,
                sessionStart: PreviewFixtures.at(18, 20, 0),
                reviewerControlsEnabled: true,
                onSelectReviewState: { state in
                    link = HostPanelPreview.fixture(for: state)
                },
                onDone: {},
                onPrimaryAction: {},
                onOpenConnectionLog: {},
                onExportDiagnostics: {}
            )
        }
        .preferredColorScheme(.dark)
    }

    static func fixture(for state: HostLinkState) -> HostLink {
        switch state {
        case .weak:      PreviewFixtures.weak
        case .lost:      PreviewFixtures.lost
        case .resyncing: PreviewFixtures.resyncing
        default:         PreviewFixtures.connected
        }
    }
}

private func previewQueue(shots: Int, megabytes: Int,
                          currentShotOrdinal: Int? = nil,
                          totalShots: Int = 0) -> TransferQueue {
    TransferQueue(
        pendingShotIDs: (0..<shots).map { _ in UUID() },
        bytesRemaining: Int64(megabytes) * 1_000_000,
        currentShotOrdinal: currentShotOrdinal,
        totalShots: totalShots
    )
}

#Preview("B3 · Connected") {
    HostPanelPreview(link: PreviewFixtures.connected,
                     queue: nil,
                     storage: StorageHeadroom(estimatedSessions: 40,
                                              freeBytes: 40_000_000_000))
}

#Preview("B3 · Weak") {
    HostPanelPreview(link: PreviewFixtures.weak,
                     queue: previewQueue(shots: 3, megabytes: 71),
                     storage: StorageHeadroom(estimatedSessions: 39,
                                              freeBytes: 39_000_000_000),
                     thermal: .fair)
}

#Preview("B3 · Lost") {
    HostPanelPreview(link: PreviewFixtures.lost,
                     queue: previewQueue(shots: 6, megabytes: 118),
                     storage: StorageHeadroom(estimatedSessions: 38,
                                              freeBytes: 38_000_000_000))
}

#Preview("B3 · Back") {
    HostPanelPreview(link: PreviewFixtures.resyncing,
                     queue: previewQueue(shots: 6, megabytes: 118,
                                         currentShotOrdinal: 3, totalShots: 6),
                     storage: StorageHeadroom(estimatedSessions: 38,
                                              freeBytes: 38_000_000_000),
                     transferProgress: 0.61)
}

#Preview("B3 · Shipped (no reviewer switcher)") {
    NavigationStack {
        HostPanelView(
            link: PreviewFixtures.connected,
            capture: PreviewFixtures.armed,
            storage: PreviewFixtures.storage,
            sessionStart: PreviewFixtures.at(18, 20, 0),
            reviewerControlsEnabled: false,
            onDone: {},
            onPrimaryAction: {},
            onOpenConnectionLog: {},
            onExportDiagnostics: {}
        )
    }
    .preferredColorScheme(.dark)
}
