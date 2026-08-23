//  DebugScreenGallery.swift
//  Jump straight to any designed screen from the command line.
//
//      xcrun devicectl device process launch --device <udid> \
//          org.pinpointstudio.capture -- -ppcpScreen B3 -ppcpHostState lost
//
//  ⚠ DEBUG ONLY. The whole file compiles out of a release build, so there is no
//  route into it from a shipped app.
//
//  This exists because verifying sixteen screens otherwise means sixteen taps by
//  a human holding the phone. It is also the seed of the review mode
//  REQ-STANDALONE-6 requires: Apple expects a reviewer to be able to walk the
//  full path without a host present, and a screen selector is most of that.
//
//  Argument parsing is via UserDefaults, which reads `-key value` launch
//  arguments for free — no hand-rolled argv walking.

#if DEBUG

import SwiftUI
import CaptureCore

enum DebugLaunch {
    /// `-ppcpScreen A6`. Nil in normal use, and the app boots normally.
    static var screenID: String? {
        UserDefaults.standard.string(forKey: "ppcpScreen")?.uppercased()
    }

    /// `-ppcpConformPort 51423`, for the D9 harness screen.
    static var conformPort: UInt16? {
        let value = UserDefaults.standard.integer(forKey: "ppcpConformPort")
        return value > 0 && value <= Int(UInt16.max) ? UInt16(value) : nil
    }

    /// `-ppcpHostState lost`, for the four B3 states and C1's host chip.
    static var hostState: HostLinkState {
        switch UserDefaults.standard.string(forKey: "ppcpHostState")?.lowercased() {
        case "pairing": .pairing
        case "weak": .weak
        case "lost": .lost
        case "resyncing", "back": .resyncing
        case "none": .none
        default: .connected
        }
    }

    static var link: HostLink {
        switch hostState {
        case .connected: PreviewFixtures.connected
        case .weak: PreviewFixtures.weak
        case .lost: PreviewFixtures.lost
        case .resyncing: PreviewFixtures.resyncing
        case .pairing: PreviewFixtures.pairing
        case .none: HostLink(state: .none)
        }
    }

    /// The transfer queue each B3 state is designed around.
    ///
    /// ⚠ Not `PreviewFixtures.transferQueue` — that carries C3's numbers, and
    /// feeding it to B3 makes the Connected state report a backlog when the design
    /// says `nothing`. The whole point of Connected is that there is nothing
    /// waiting; a queue there reads as Weak wearing the wrong colour.
    static var queue: TransferQueue {
        switch hostState {
        case .connected, .pairing, .none:
            TransferQueue()
        case .weak:
            TransferQueue(pendingShotIDs: (0..<3).map { _ in UUID() },
                          bytesRemaining: 71_000_000, totalShots: 3)
        case .lost:
            TransferQueue(pendingShotIDs: (0..<6).map { _ in UUID() },
                          bytesRemaining: 118_000_000, totalShots: 6)
        case .resyncing:
            TransferQueue(pendingShotIDs: (0..<6).map { _ in UUID() },
                          bytesRemaining: 61_000_000,
                          currentShotOrdinal: 3, totalShots: 6)
        }
    }

    static let reconciliationCandidates: [SessionMatchCandidate] = [
        SessionMatchCandidate(
            title: "Wednesday range · 18:20",
            detail: "Studio holds 29 shots from a launch monitor",
            likelihood: .likely,
            evidence: [
                .init(label: "Shot spacing matches", value: "29 of 29"),
                .init(label: "Largest disagreement", value: "41 ms",
                      spokenValue: "41 milliseconds")
            ]
        ),
        SessionMatchCandidate(
            title: "Wednesday lesson · 16:05",
            detail: "12 shots, face-on cameras",
            likelihood: .unlikely
        )
    ]
}

/// Renders one designed screen in isolation, wrapped in whatever chrome it needs.
struct DebugScreenGallery: View {
    let screenID: String
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            screen
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var screen: some View {
        switch screenID {
        case "A1": WelcomeScreen(capability: model.capability,
                                 onGetStarted: {}, onHavePairingCode: {})
        case "A2": HowItWorksScreen(onContinue: {})
        case "A3": HostOrStandaloneScreen(selection: model.captureContext,
                                          onSelect: { model.captureContext = $0 },
                                          onContinue: {})
        case "A4": PermissionsScreen(permissions: model.permissions,
                                     audioRetention: model.audioRetention,
                                     onChangeAudioRetention: {},
                                     onAllowLocalNetwork: {},
                                     onContinue: {})
        case "A5": PlacementGuidanceScreen(onCheckFraming: {})
        case "A6": FramingCheckScreen(framing: model.framing,
                                      onUse120fps: {}, onArm: {})
        case "A7": ReadyToCaptureScreen(capability: model.capability,
                                        storage: model.storage,
                                        retainedSecondsPerShot: 3.0,
                                        onStartSession: {}, onConnectHost: {})

        case "B1": ConnectHostView(discoveredHostName: PreviewFixtures.hostName,
                                   discoveredHostDetail: "On this network · paired yesterday",
                                   onCancel: {}, onConnectToDiscoveredHost: {},
                                   onEnterCode: {}, onUseCable: {},
                                   onCaptureWithoutHost: {})
        case "B2": PairingView(link: PreviewFixtures.pairing,
                               agreedMode: PreviewFixtures.capability.bestMode,
                               viewpoint: PreviewFixtures.framingMarginalLight.viewpoint,
                               onCancel: {})
        case "B3": HostPanelView(link: DebugLaunch.link,
                                 capture: PreviewFixtures.armed,
                                 queue: DebugLaunch.queue,
                                 storage: model.storage,
                                 currentTransferProgress: DebugLaunch.hostState == .resyncing
                                     ? 0.61 : nil,
                                 sessionStart: PreviewFixtures.session.start,
                                 onSelectReviewState: { _ in },
                                 onDone: {}, onPrimaryAction: {},
                                 onOpenConnectionLog: {}, onExportDiagnostics: {})
        case "B4": JoinNetworkView(ssid: "PinPoint-Bay3", onJoin: {},
                                   onStayOnCurrentNetwork: {})
        case "B5": ReconcileSessionView(
                        candidates: DebugLaunch.reconciliationCandidates,
                        selectedCandidateID: DebugLaunch.reconciliationCandidates.first?.id,
                        shotCount: PreviewFixtures.session.shots.count,
                        coverageNotice: "Shots 30 to 41 have no launch monitor record. "
                            + "They will arrive as video only.",
                        onSelect: { _ in }, onReview: {}, onSendAsNewSession: {})
        case "B6": LocalNetworkBlockedView(onOpenSettings: {}, onConnectByCable: {},
                                           onCaptureAlone: {}, onTryAgain: {})

        case "C1": ArmedScreen(capture: PreviewFixtures.armed,
                               hostLink: DebugLaunch.link,
                               session: PreviewFixtures.session,
                               lastShot: PreviewFixtures.session.shots.last,
                               // ⚠ Fixed `now`, 12 s after the last shot's impact.
                               // Left at the real clock the fixture's timestamps sit
                               // in the future and "12 s ago" renders as "0 s ago".
                               now: PreviewFixtures.at(19, 36, 14),
                               onOpenHost: {}, onOpenSession: {},
                               onReplayLastShot: {}, onDisarm: {})
                    .toolbar(.hidden, for: .navigationBar)
        case "C2": ReplayScreen(shot: PreviewFixtures.shots[0],
                                capture: PreviewFixtures.armed,
                                onDone: {}, onCompare: {}, onStepFrame: { _ in },
                                onTogglePlayback: {}, onCycleSpeed: {},
                                onSelectTool: { _ in })
        case "C3": SessionLibraryScreen(session: PreviewFixtures.session,
                                        transferQueue: PreviewFixtures.transferQueue,
                                        hostName: PreviewFixtures.hostName,
                                        onSelectShot: { _ in }, onPauseTransfer: {},
                                        onExportSession: {})

        // ⛔ Not a designed screen. D9's conformance harness, which runs this
        // device's peer over a plaintext loopback socket against `ppcp-sim`.
        case "D9": ConformanceHarnessView(device: model.captureDevice,
                                          distance: model.micToBallDistance,
                                          port: DebugLaunch.conformPort)

        default:
            ContentUnavailableView(
                "Unknown screen \"\(screenID)\"",
                systemImage: "questionmark.square.dashed",
                description: Text("Try A1–A7, B1–B6, C1–C3 or D9.")
            )
        }
    }
}

#endif
