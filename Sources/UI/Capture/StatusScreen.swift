//
//  StatusScreen.swift
//  The whole app, as a person standing two metres away sees it (#121).
//
//  PPC is a camera on a tripod, connected to PPS and left alone; PPS drives it
//  over PPCP. So this screen answers two questions and nothing else — *is it
//  connected?* and *is it recording?* — in type large enough to read from the
//  mat. Everything a person still has to do (pair, forget, disconnect, the
//  microphone distance) is behind the ⚙.
//
//  ⛔ **No video.** The camera's picture goes to Studio as the PPCP `preview`
//  Stream; drawing it here as well would cost heat and battery on a phone that
//  nobody is looking at. The design-pack C1 this replaces is in `Mothballed/`.
//
//  ⚠ Like every screen here it takes values and hands back closures, so the
//  debug gallery can render each state without a host.
//

import SwiftUI
import CaptureCore

public struct StatusScreen: View {

    /// Where this phone is with Studio.
    public enum Connection: Equatable, Sendable {
        /// No pairing is held, so there is nothing to look for.
        case notPaired
        /// Browsing, nothing back yet. ⛔ 3.6a — not an error, never coloured as
        /// one. `name` only when exactly one Studio is held: "Looking for Bay 3"
        /// is a promise, and with three held the sweep is not looking for any one.
        case searching(name: String?)
        /// Sweeps have come back empty; still looking, and says for how long.
        case notFound(seconds: Int)
        /// Something answered and refused, or could not be reached.
        case diagnosis(String)
        /// A link is up and the handshake or `session_open` is still to come.
        case pairing(name: String?)
        case connected(name: String?, transport: HostLinkTransport?)
        /// The link is up and heartbeats have lapsed.
        case lost(name: String?)
        /// Settings → Disconnect, and staying that way until asked.
        case disconnected
    }

    /// What the camera is doing, which is the host's decision, not this screen's.
    public enum Recording: Equatable, Sendable {
        case idle
        case warm
        /// Armed, and waiting for the first frames to prove it (the settle).
        case arming
        case recording
    }

    private let connection: Connection
    private let recording: Recording
    /// A sentence that stops this phone doing its job — a missing permission,
    /// no usable camera format, a recording that failed. `nil` when all is well.
    private let problem: String?
    /// Offered with `problem` when the remedy is in iOS Settings.
    private let onOpenSystemSettings: (() -> Void)?
    private let onOpenSettings: () -> Void
    /// DEBUG instruments (E1.1's ring counters). `nil` in a release build.
    private let debugAccessory: AnyView?

    public init(connection: Connection,
                recording: Recording,
                problem: String? = nil,
                onOpenSystemSettings: (() -> Void)? = nil,
                onOpenSettings: @escaping () -> Void,
                debugAccessory: AnyView? = nil) {
        self.connection = connection
        self.recording = recording
        self.problem = problem
        self.onOpenSystemSettings = onOpenSystemSettings
        self.onOpenSettings = onOpenSettings
        self.debugAccessory = debugAccessory
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: PPMetrics.groupGap * 2) {
                Spacer(minLength: 0)
                StatusBlock(tone: connectionTone,
                            title: connectionTitle,
                            detail: connectionDetail)
                StatusBlock(tone: recordingTone,
                            title: recordingTitle,
                            detail: nil)
                if let problem {
                    VStack(alignment: .leading, spacing: PPMetrics.itemGap) {
                        Text(problem)
                            .font(.title3)
                            .foregroundStyle(Color.ppWarning)
                            .fixedSize(horizontal: false, vertical: true)
                        if let onOpenSystemSettings {
                            Button("Open Settings", action: onOpenSystemSettings)
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                        }
                    }
                }
                Spacer(minLength: 0)
                if let debugAccessory { debugAccessory }
            }
            .padding(.horizontal, PPMetrics.screenMargin * 2)
            .padding(.vertical, PPMetrics.groupGap)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.title2)
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(width: PPMetrics.Size.minimumTapTarget,
                           height: PPMetrics.Size.minimumTapTarget)
            }
            .accessibilityLabel("Settings")
            .padding(PPMetrics.itemGap)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Connection

    private var connectionTitle: String {
        switch connection {
        case .notPaired: "Not paired"
        case .searching: "Looking for Studio"
        case .notFound: "Studio not found"
        case .diagnosis: "Studio did not answer"
        case .pairing: "Connecting"
        case .connected: "Connected"
        case .lost: "Studio is gone"
        case .disconnected: "Disconnected"
        }
    }

    private var connectionDetail: String? {
        switch connection {
        case .notPaired:
            "Tap ⚙ to pair with Studio."
        case .searching(let name):
            name
        case .notFound(let seconds):
            "Still looking · \(seconds) s"
        case .diagnosis(let sentence):
            sentence
        case .pairing(let name), .lost(let name):
            name
        case .connected(let name, let transport):
            [name, transport?.displayName].compactMap { $0 }.joined(separator: " · ")
        case .disconnected:
            "Tap ⚙ to connect again."
        }
    }

    /// ⚠ Red is the host's colour and only the host's (`StatusTone`): a gone
    /// Studio or a refusal. Looking is not a fault.
    private var connectionTone: StatusTone {
        switch connection {
        case .connected: .accent
        case .pairing, .searching: .progress
        case .notFound, .notPaired, .disconnected: .neutral
        case .diagnosis, .lost: .error
        }
    }

    // MARK: Recording

    private var recordingTitle: String {
        switch recording {
        case .idle: "Idle"
        case .warm: "Ready"
        case .arming: "Starting"
        case .recording: "Recording"
        }
    }

    /// ⛔ Capture status never turns red (`StatusTone`).
    private var recordingTone: StatusTone {
        switch recording {
        case .idle, .warm: .neutral
        case .arming: .progress
        case .recording: .accent
        }
    }
}

/// A dot, a word readable from the mat, and at most one line under it.
private struct StatusBlock: View {
    let tone: StatusTone
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PPMetrics.cardPadding) {
            Circle()
                .fill(tone == .neutral ? Color(.tertiaryLabel) : tone.foreground)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 44, weight: .bold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(Color(.label))
                if let detail, detail.isEmpty == false {
                    Text(detail)
                        .font(.title2)
                        .foregroundStyle(Color(.secondaryLabel))
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#Preview("Connected · recording") {
    StatusScreen(connection: .connected(name: "Bay 3 — Mac Studio", transport: .cable),
                 recording: .recording, onOpenSettings: {})
}

#Preview("Not paired") {
    StatusScreen(connection: .notPaired, recording: .idle, onOpenSettings: {})
}

#Preview("Permission missing") {
    StatusScreen(connection: .searching(name: nil), recording: .idle,
                 problem: "Camera and microphone access are both needed.",
                 onOpenSystemSettings: {}, onOpenSettings: {})
}
