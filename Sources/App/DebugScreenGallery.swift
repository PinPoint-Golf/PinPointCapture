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

    /// `-ppcpRingStats 1` — render E1.1's counter overlay over a cold C1.
    ///
    /// ⛔ **A review affordance, and it exists because this overlay has been in
    /// the wrong place three times.** It only draws while armed or after a run,
    /// and a simulator has no camera to arm — so its position could not be
    /// checked without a phone, and it was placed by arithmetic instead. Same
    /// family as `-ppcpScreen`: DEBUG only, never reachable in a release build.
    static var forcesRingStats: Bool {
        UserDefaults.standard.bool(forKey: "ppcpRingStats")
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

    /// B3a's list (#96). ⛔ **Fixtures, never `PairingSecretStore.pairings()`** —
    /// a review screen that read the real store would show a reviewer somebody
    /// else's pairings, and one that wrote to it could forget a real one.
    static let rememberedStudios: [StoredPairing] = [
        StoredPairing(sessionId: "3f2504e0-4f89-41d3-9a0c-0305e82c3301",
                      displayName: "Bay 3 — Mac Studio",
                      counterpartPeerId: "peer:11121314",
                      networkName: "PinPoint-Bay3",
                      savedAt: Date(timeIntervalSince1970: 1_756_000_000)),
        StoredPairing(sessionId: "3f2504e0-4f89-41d3-9a0c-0305e82c3302",
                      displayName: "Studio — iMac",
                      counterpartPeerId: nil,
                      networkName: nil,
                      savedAt: Date(timeIntervalSince1970: 1_755_120_000))
    ]

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

        // The pairing STEP (onboarding), as distinct from B1 the screen.
        case "PAIR": PairStepScreen(onScanPairingCode: {}, onContinue: {}, onSkip: {})
        case "PAIRED": PairStepScreen(hostName: "Bay 3 — Mac Studio",
                                      isPaired: true,
                                      onScanPairingCode: {}, onContinue: {}, onSkip: {})
        case "B1": ConnectHostView(discoveredHostName: PreviewFixtures.hostName,
                                   discoveredHostDetail: "On this network · paired yesterday",
                                   onCancel: {}, onConnectToDiscoveredHost: {},
                                   onEnterCode: {}, onUseCable: {},
                                   onCaptureWithoutHost: {})
        case "B2": PairingView(link: PreviewFixtures.pairing,
                               agreedMode: PreviewFixtures.capability.bestMode,
                               viewpoint: PreviewFixtures.framingMarginalLight.viewpoint,
                               onCancel: {})
        // B2's settled state (#96) — the confirmation the app did not have.
        case "B2A": PairingView(link: PreviewFixtures.connected,
                                securitySummary: "TLS 1.2 · PSK",
                                agreedMode: PreviewFixtures.capability.bestMode,
                                viewpoint: PreviewFixtures.framingMarginalLight.viewpoint,
                                isCameraLocked: true,
                                remembered: .remembered,
                                onCancel: {}, onForget: {})
        case "B3": HostPanelView(link: DebugLaunch.link,
                                 capture: PreviewFixtures.armed,
                                 queue: DebugLaunch.queue,
                                 storage: model.storage,
                                 currentTransferProgress: DebugLaunch.hostState == .resyncing
                                     ? 0.61 : nil,
                                 sessionStart: PreviewFixtures.session.start,
                                 onSelectReviewState: { _ in },
                                 onDone: {}, onPrimaryAction: {},
                                 onOpenConnectionLog: {}, onExportDiagnostics: {},
                                 onOpenMicToBallDistance: {},
                                 onOpenRememberedStudios: {},
                                 // The single-Studio case, which is the one a
                                 // golfer has (#96).
                                 rememberedHostName: "Bay 3 — Mac Studio",
                                 onForgetHost: {})
        // B3a — `RV` 7.4b's revocation list (#96). ⚠ Fixtures, not the real
        // store: this gallery must not read or write a pairing.
        case "B3A": RememberedStudiosView(
                        pairings: DebugLaunch.rememberedStudios,
                        onForget: { _ in })
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

        // Cold, and unable to arm — the state a simulator is always in, and the
        // one a phone lands in when a permission is missing (#97).
        case "C1C": ArmedScreen(capture: CaptureStatus(state: .cold),
                                hostLink: HostLink(state: .none),
                                session: PreviewFixtures.session,
                                lastShot: nil,
                                onOpenHost: {}, onOpenSession: {}, onReplayLastShot: {},
                                onDisarm: {}, onArm: {},
                                hostSearch: .nothingHeld,
                                capabilityError: "Camera and microphone access are both "
                                    + "needed before this device can capture. "
                                    + "Settings — PinPointCapture.",
                                onCheckFraming: {})
        case "C1L": ArmedScreen(capture: PreviewFixtures.armed,
                                hostLink: HostLink(state: .none),
                                session: PreviewFixtures.session,
                                lastShot: PreviewFixtures.session.shots.last,
                                onOpenHost: {}, onOpenSession: {}, onReplayLastShot: {},
                                onDisarm: {}, onArm: {},
                                hostSearch: .looking, searchingForName: "Bay 3 — Mac Studio")
        case "C1N": ArmedScreen(capture: PreviewFixtures.armed,
                                hostLink: HostLink(state: .none),
                                session: PreviewFixtures.session,
                                lastShot: PreviewFixtures.session.shots.last,
                                onOpenHost: {}, onOpenSession: {}, onReplayLastShot: {},
                                onDisarm: {}, onArm: {},
                                hostSearch: .notFound(seconds: 45),
                                searchingForName: "Bay 3 — Mac Studio")
        case "C1A": ArmedScreen(capture: PreviewFixtures.armed,
                                hostLink: HostLink(state: .none),
                                session: PreviewFixtures.session,
                                lastShot: PreviewFixtures.session.shots.last,
                                onOpenHost: {}, onOpenSession: {}, onReplayLastShot: {},
                                onDisarm: {}, onArm: {},
                                hostSearch: .nothingHeld)
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
                                hasVideo: true,
                                capture: PreviewFixtures.armed,
                                onDone: {}, onCompare: {}, onStepFrame: { _ in },
                                onTogglePlayback: {}, onCycleSpeed: {},
                                onSelectTool: { _ in })
        case "C3": SessionLibraryScreen(session: PreviewFixtures.session,
                                        transferQueue: PreviewFixtures.transferQueue,
                                        hostName: PreviewFixtures.hostName,
                                        onSelectShot: { _ in }, onPauseTransfer: {})

        // ⛔ Not a designed screen. D9's conformance harness, which runs this
        // device's peer over a plaintext loopback socket against `ppcp-sim`.
        case "D9": ConformanceHarnessView(device: model.captureDevice,
                                          distance: model.micToBallDistance,
                                          port: DebugLaunch.conformPort)

        // ⛔ Not a designed screen. D14's torch, on the platform seam.
        case "D14": TorchHarnessView(model: model)

        default:
            ContentUnavailableView(
                "Unknown screen \"\(screenID)\"",
                systemImage: "questionmark.square.dashed",
                description: Text("Try A1–A7, B1–B6 (B2A, B3A), C1–C3, D9 or D14.")
            )
        }
    }
}

/// D14's torch, exercised without a host.
///
/// ⛔ **Not a feature and not a designed screen.** The plan's C1 gate is "the
/// torch toggles on a real iPhone", and until D15 answers `actuator_command`
/// there is nothing in this application that can command it — so the seam would
/// ship written and never once run. This is the same argument `-ppcpRingStats`
/// makes for the ring overlay: a thing that needs a phone to check, and no phone
/// path to check it with, gets checked by arithmetic instead.
///
/// ⚠ **What it is for is the readback.** 12.1c says the ack carries what the
/// torch is *actually* doing, and the only way to know whether `isTorchActive`
/// tells the truth is to watch the light and read the row at the same time.
///
///     xcrun devicectl device process launch --device <udid> \
///         org.pinpointstudio.capture -- -ppcpScreen D14
struct TorchHarnessView: View {
    @Bindable var model: AppModel
    @State private var lastOutcome: TorchOutcome?

    var body: some View {
        let capability = model.torchCapability()
        List {
            Section("CORE 5.19a — what this device declares") {
                LabeledContent("present", value: String(capability.present))
                LabeledContent("available", value: String(capability.available))
                LabeledContent("on/off", value: String(capability.supportsOnOff))
                // ⚠ 5.19c — "none" is a correct declaration, not a fault.
                LabeledContent("actuator",
                               value: capability.actuatorDeclaration.map {
                                   "\($0.id) · \($0.kind) · \($0.control.rawValue)"
                               } ?? "none (5.19c)")
            }

            Section("MSG 12.1 — command") {
                // ⛔ Warm first, or every command answers `no_actuator`:
                // AVFoundation only lights a torch belonging to a running
                // session, which is exactly what `setTorch` refuses to pretend
                // otherwise about.
                Button("Warm up the camera") { Task { await model.warmUp() } }
                Button("Torch on") { lastOutcome = model.setTorch(.on) }
                Button("Torch off") { lastOutcome = model.setTorch(.off) }
                LabeledContent("state", value: model.captureStatus.state.rawValue)
            }

            Section("MSG 12.1b/12.1c — the ack this would carry") {
                // ⚠ `.some`, because a `switch` over an Optional does not
                // match a bare case pattern.
                switch lastOutcome {
                case .some(.applied(let state)):
                    LabeledContent("verdict", value: "applied")
                    // ⛔ The achieved value, not the request.
                    LabeledContent("state.on", value: String(state.on))
                    LabeledContent("torchMode", value: String(state.modeIsOn))
                    if state.achievedDiffersFromMode {
                        Text("achieved differs from the switch position — CB4")
                            .foregroundStyle(.orange)
                    }
                case .some(.refused(let reason)):
                    LabeledContent("verdict", value: "refused")
                    LabeledContent("reason", value: reason.rawValue)
                case nil:
                    Text("nothing commanded yet").foregroundStyle(.secondary)
                }
            }

            Section("MSG 12.2a — a change nobody commanded") {
                // ⚠ Fed by the 1 Hz health tick, which since D16 starts at
                // `warmUp` rather than at `arm` (CR-02 §4a) — so "Warm up the
                // camera" above is enough to make this row live, and a blank
                // row while warm now means nothing has moved rather than that
                // nothing is looking.
                if let change = model.lastAutonomousTorchChange {
                    LabeledContent("state.on", value: String(change.state.on))
                    LabeledContent("observed at ns", value: String(change.observedAtNs))
                } else {
                    Text("none observed").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("D14 — torch")
    }
}

#endif
