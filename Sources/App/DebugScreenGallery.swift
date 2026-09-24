//  DebugScreenGallery.swift
//  Jump straight to any designed screen from the command line.
//
//      xcrun devicectl device process launch --device <udid> \
//          org.pinpointstudio.capture -- -ppcpScreen B3 -ppcpHostState lost
//
//  ⚠ DEBUG ONLY. The whole file compiles out of a release build, so there is no
//  route into it from a shipped app.
//
//  This exists because verifying every screen otherwise means a tap per screen
//  by a human holding the phone. ⚠ Since #121 the app is one status screen and
//  a settings sheet; the S-cases render each status state from fixtures.
//
//  Argument parsing is via UserDefaults, which reads `-key value` launch
//  arguments for free — no hand-rolled argv walking.

#if DEBUG

import SwiftUI
import CaptureCore

enum DebugLaunch {
    /// `-ppcpScreen S1`. Nil in normal use, and the app boots normally.
    static var screenID: String? {
        UserDefaults.standard.string(forKey: "ppcpScreen")?.uppercased()
    }

    /// `-ppcpRingStats 1` — render E1.1's counter overlay on a cold status screen.
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
        // B3a — `RV` 7.4b's revocation list (#96). ⚠ Fixtures, not the real
        // store: this gallery must not read or write a pairing.
        case "B3A": RememberedStudiosView(
                        pairings: DebugLaunch.rememberedStudios,
                        onForget: { _ in })
        case "B4": JoinNetworkView(ssid: "PinPoint-Bay3", onJoin: {},
                                   onStayOnCurrentNetwork: {})
        case "B6": LocalNetworkBlockedView(onOpenSettings: {}, onTryAgain: {})

        // The status screen (#121), one case per state it can show.
        case "S1": status(.connected(name: "Bay 3 — Mac Studio", transport: .cable),
                          .recording)
        case "S2": status(.connected(name: "Bay 3 — Mac Studio", transport: .wifi), .warm)
        case "S3": status(.searching(name: "Bay 3 — Mac Studio"), .idle)
        case "S4": status(.notFound(seconds: 45), .idle)
        case "S5": status(.notPaired, .idle)
        case "S6": status(.lost(name: "Bay 3 — Mac Studio"), .recording)
        case "S7": status(.pairing(name: "Bay 3 — Mac Studio"), .arming)
        case "S8": status(.diagnosis("Bay 3 — Mac Studio refused this phone's pairing."),
                          .idle)
        case "S9": status(.disconnected, .idle)
        // Cold, and unable to capture — the state a simulator is always in.
        case "S10": StatusScreen(connection: .searching(name: nil), recording: .idle,
                                 problem: "Camera and microphone access are both needed. "
                                     + "Settings — PinPointCapture.",
                                 onOpenSystemSettings: {}, onOpenSettings: {})
        case "SET": SettingsView(connectedHostName: "Bay 3 — Mac Studio", isLinked: true,
                                 onPair: {}, onOpenRememberedStudios: {},
                                 onDisconnect: {}, onOpenMicToBallDistance: {},
                                 onDone: {})

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
                description: Text("Try S1–S10, SET, B2, B2A, B3A, B4, B6, D9 or D14.")
            )
        }
    }

    private func status(_ connection: StatusScreen.Connection,
                        _ recording: StatusScreen.Recording) -> some View {
        StatusScreen(connection: connection, recording: recording,
                     onOpenSettings: {},
                     debugAccessory: DebugLaunch.forcesRingStats
                        ? AnyView(RingStatsOverlay(stats: RingStats(), expectedFPS: 240,
                                                   isLive: false))
                        : nil)
            .toolbar(.hidden, for: .navigationBar)
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
