//
//  SessionLibraryScreen.swift
//  PinPointCapture — C3 Session library.
//
//  ⚠ THIS IS A STORE, NOT A CACHE (REQ-SESS-3). Every row carries its own sync
//  state because the device is where the session lives; the host is somewhere it
//  has also been sent. Nothing unconfirmed is ever evicted (REQ-SESS-4).
//
//  ⚠ `In Studio` MEANS CONFIRMED BY THE HOST — never merely uploaded. That is
//  why the chips are three words rather than icons: a golfer glancing at this
//  list from the mat has to read a *state*, and a coloured glyph cannot say
//  whether the host has it.
//
//  ⚠ *Pause* on the banner is the USER-LEVEL pause. Backpressure is automatic,
//  separate, and never surfaces as this button.
//
//  *Export the whole session* writes the same schema as the wire format
//  (REQ-STANDALONE-2, REQ-OFF-1) — the button is surfaced here, the writing is
//  not this screen's business.
//

import SwiftUI
import CaptureCore

struct SessionLibraryScreen: View {

    private let session: Session
    /// ⛔ Optional. There is no transfer (E3.4), and an empty queue rendered as a
    /// paused one is a progress bar for work nobody is doing.
    private let transferQueue: TransferQueue?
    private let hostName: String?
    /// The bundles actually on this phone.
    private let recordedBundles: [RecordedBundle]

    private let onSelectShot: (Shot) -> Void
    /// User-level pause / resume of the bulk transfer.
    private let onPauseTransfer: () -> Void
    private let onOpenMicToBallDistance: (() -> Void)?

    init(session: Session,
         transferQueue: TransferQueue?,
         hostName: String?,
         recordedBundles: [RecordedBundle] = [],
         onSelectShot: @escaping (Shot) -> Void,
         onPauseTransfer: @escaping () -> Void,
         onOpenMicToBallDistance: (() -> Void)? = nil) {
        self.session = session
        self.transferQueue = transferQueue
        self.hostName = hostName
        self.recordedBundles = recordedBundles
        self.onSelectShot = onSelectShot
        self.onPauseTransfer = onPauseTransfer
        self.onOpenMicToBallDistance = onOpenMicToBallDistance
    }

    var body: some View {
        List {
            Section {
                summaryLine
                if showsTransferBanner {
                    transferBanner
                }
            }

            Section("This session") {
                if session.shots.isEmpty {
                    InfoCard("No shots yet. Arm the device and hit one — every "
                             + "impact this phone hears is timed and kept here.",
                             systemImage: "waveform")
                } else {
                    ForEach(session.shots) { shot in
                        shotRow(shot)
                    }
                }
            }

            // ⛔ The sessions that are genuinely on disk, which nothing listed
            // before: `SessionStore.bundles()` had no caller outside its tests
            // while this screen rendered 41 invented shots.
            if recordedBundles.isEmpty == false {
                Section {
                    ForEach(recordedBundles) { bundle in
                        recordedBundleRow(bundle)
                    }
                } header: {
                    Text("Recorded on this phone")
                } footer: {
                    Text("These are the session files on this phone. Their shot "
                         + "counts and times are inside the bundle and are not "
                         + "read back yet, so only the file is described here.")
                }
            }

            Section {
                Button("Export the whole session") {}
                    .font(.ppRowLabel.weight(.semibold))
                    .frame(maxWidth: .infinity,
                           minHeight: PPMetrics.Size.minimumTapTarget)
                    // ⛔ Disabled and *told*, rather than silently doing nothing.
                    // A control that no-ops teaches a user the app is broken.
                    .disabled(true)
            } footer: {
                Text("Sending and exporting are not connected yet. Nothing is "
                     + "lost — the session is on this phone.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(session.name.isEmpty ? "Session" : session.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if let onOpenMicToBallDistance {
                // ⚠ A8's permanent route. C3 is the only pushed screen in the
                // capture stack with a nav bar, so it is the app's de facto
                // settings surface until the design pack grows one.
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onOpenMicToBallDistance) {
                        Image(systemName: "ruler")
                    }
                    .accessibilityLabel(Text("Phone to ball distance"))
                }
            }
        }
    }

    private func recordedBundleRow(_ bundle: RecordedBundle) -> some View {
        HStack(spacing: PPMetrics.itemGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bundle.displayTitle)
                    .font(.ppRowLabel)
                    .foregroundStyle(Color(.label))
                Text(bundle.displayDetail)
                    .ppMeasuredDetail()
            }
            Spacer(minLength: PPMetrics.itemGap)
            StatusChip("On device", tone: .neutral)
        }
        .frame(minHeight: PPMetrics.Size.minimumTapTarget)
        .accessibilityElement(children: .combine)
    }

    // MARK: Summary

    /// "41 shots · 18:20 to 19:36 · 12 still to send" — the counts are measured,
    /// so the line is mono-adjacent in register but stays plain: it is a
    /// sentence about the session, sitting under its name.
    private var summaryLine: some View {
        // ⚠ With no host there is nothing "still to send", and saying so implies
        // a queue rather than an absence.
        Text(session.displaySubtitle(hasHost: hostName != nil))
            .font(.ppSupporting)
            .foregroundStyle(Color(.secondaryLabel))
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: PPMetrics.screenMargin,
                                      bottom: PPMetrics.itemGap, trailing: PPMetrics.screenMargin))
            .accessibilityAddTraits(.isSummaryElement)
    }

    // MARK: Transfer banner

    private var showsTransferBanner: Bool {
        transferQueue.map { $0.pendingShotIDs.isEmpty == false } ?? false
    }

    @ViewBuilder
    private var transferBanner: some View {
        if let transferQueue {
            transferBannerBody(transferQueue)
        }
    }

    private func transferBannerBody(_ transferQueue: TransferQueue) -> some View {
        HStack(spacing: PPMetrics.itemGap) {
            Image(systemName: transferQueue.isPaused ? "pause.circle" : "arrow.down.circle")
                .font(.title3)
                .foregroundStyle(Color.ppAccent)

            VStack(alignment: .leading, spacing: 2) {
                Text(bannerTitle(transferQueue.isPaused))
                    .font(.ppSupporting.weight(.semibold))
                    .foregroundStyle(Color(.label))
                Text(transferQueue.displayDetail)
                    .ppMeasuredDetail()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button(transferQueue.isPaused ? "Resume" : "Pause", action: onPauseTransfer)
                .font(.ppSupporting.weight(.semibold))
                .buttonStyle(.borderless)
                .accessibilityHint(Text("Pauses sending yourself. Slow networks are handled without this."))
        }
        .padding(.vertical, 2)
        .frame(minHeight: PPMetrics.Size.minimumTapTarget)
        .listRowBackground(
            RoundedRectangle(cornerRadius: PPMetrics.Radius.card, style: .continuous)
                .fill(StatusTone.accent.background)
                .strokeBorder(Color.ppAccent.opacity(0.2), lineWidth: 1)
        )
    }

    private func bannerTitle(_ isPaused: Bool) -> String {
        guard let host = CaptureScreenStyle.shortHostName(hostName) else {
            return isPaused ? "Sending paused" : "Sending"
        }
        return isPaused ? "Sending to \(host) is paused" : "Sending to \(host)"
    }

    // MARK: Shot rows

    /// Thumbnail, plain-language title, measured detail, state chip.
    ///
    /// A practice swing arrives here reading "no impact" and stays `On device` —
    /// it is not worth the bandwidth, and that is a normal outcome rather than a
    /// failure, so its chip is neutral and never red.
    private func shotRow(_ shot: Shot) -> some View {
        Button {
            onSelectShot(shot)
        } label: {
            HStack(spacing: PPMetrics.itemGap) {
                // ⚠ Substitution point — see CapturePlaceholders.swift.
                ShotThumbnailPlaceholder(side: 50)

                VStack(alignment: .leading, spacing: 3) {
                    Text(shot.displayTitle)
                        .font(.ppRowLabel.weight(.semibold))
                        .foregroundStyle(Color(.label))
                    Text(shot.displayDetail)
                        .ppMeasuredDetail()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                StatusChip(shot.syncState.displayText,
                           tone: CaptureScreenStyle.tone(for: shot.syncState))
            }
            .padding(.vertical, 4)
            .frame(minHeight: PPMetrics.Size.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Opens the replay"))
    }
}

#Preview("C3 Session library") {
    NavigationStack {
        SessionLibraryScreen(
            session: PreviewFixtures.session,
            transferQueue: PreviewFixtures.transferQueue,
            hostName: PreviewFixtures.hostName,
            onSelectShot: { _ in },
            onPauseTransfer: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("C3 Session library · no host, nothing sending") {
    NavigationStack {
        SessionLibraryScreen(
            session: Session(name: "Wednesday range",
                             start: PreviewFixtures.at(18, 20, 0),
                             end: PreviewFixtures.at(19, 36, 0),
                             shots: PreviewFixtures.shots.map { shot in
                                 var copy = shot
                                 copy.syncState = .onDevice
                                 return copy
                             }),
            transferQueue: TransferQueue(),
            hostName: nil,
            onSelectShot: { _ in },
            onPauseTransfer: {}
        )
    }
    .preferredColorScheme(.dark)
}
