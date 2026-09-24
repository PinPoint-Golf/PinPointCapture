//  RootView.swift
//  The app shell.
//
//  ⛔ **ONE SCREEN (#121).** PPC is a camera on a tripod that PPS drives over
//  PPCP, so the root is `StatusScreen` — connection and recording, readable from
//  the mat — and everything else is a sheet behind its ⚙. The design pack's
//  capture stack (C1 preview, C2 replay, C3 library), onboarding (A1–A7) and
//  the host panel (B1, B3, B5) are in `Mothballed/`, with what reinstating each
//  one needs.
//
//  Every screen in the app is presented from here. Screens themselves own no
//  navigation — they take Core values and hand back closures — so this file is
//  the whole routing surface.

import SwiftUI
import CaptureCore

/// Pushed inside the settings sheet.
enum SettingsRoute: Hashable {
    /// B3a — `RV` 7.4b's revocation list (#96).
    case rememberedStudios
    /// A8 — the microphone-to-ball distance (D7). It feeds every Candidate's
    /// `tof_correction`, so it survives the cut.
    case micToBallDistance
}

/// Modally presented screens.
enum AppSheet: Identifiable {
    /// Behind the ⚙.
    case settings
    /// B1a — scanning a `ppcp:` code (`RV` §4). ⛔ The `failure` is carried on the
    /// case because 4.2b/4.4a/4.4b are three different sentences and the screen
    /// has to know which one it is showing.
    case scanPairingCode(failure: ScanPairingCodeView.Failure?)
    /// B4, when a scanned pairing code carries a network.
    case joinNetwork(ssid: String)
    /// B6, inferred from a connection failure — never from a permission query.
    case localNetworkBlocked
    /// B2 — the handshake, while it is happening.
    case pairing

    var id: String {
        switch self {
        case .settings: "settings"
        case .scanPairingCode: "scanPairingCode"
        case .joinNetwork: "joinNetwork"
        case .localNetworkBlocked: "localNetworkBlocked"
        case .pairing: "pairing"
        }
    }
}

struct RootView: View {
    @State private var model = AppModel()
    /// ⛔ Backgrounding suspends the socket. E3.5 owns reconnecting; this level
    /// owns not lying about it in the meantime.
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsPath: [SettingsRoute] = []
    @State private var sheet: AppSheet?
    /// The SSID whose configuration was just removed, if any (`RV` 6b). ⚠ Not a
    /// failure and not an error — it is the sentence that makes "left in the
    /// user's control" true rather than merely technically so.
    @State private var leftNetwork: String?
    /// ⛔ **What became of the pairing, and the sentence B2 shows for it** (#96).
    /// `nil` until the handshake settles — a screen that reported on a pairing
    /// before one existed would be guessing. `RootView` maps the platform
    /// outcome onto the UI one; `PairingView` never sees `RendezvousCoordinator`.
    @State private var remembered: PairingView.Remembered?
    /// The Session whose pairing was just written, so B2's *Forget* has something
    /// to revoke. ⚠ Not the code and not the keys — `RV` 4.4c releases those.
    @State private var rememberedSessionId: String?
    /// B3a's list. ⚠ Re-read from the store rather than mutated in place: the
    /// store is the truth and a stale screen here is a screen that offers to
    /// forget something already gone.
    @State private var rememberedStudios: [StoredPairing] = []
    private let rendezvous = RendezvousCoordinator()
    /// Held only between the consent sheet and the resumed walk. ⛔ `RV` 4.4c —
    /// the payload is not retained after the pairing it establishes has ended.
    @State private var pendingCode: String?

    var body: some View {
        Group {
            #if DEBUG
            if let id = DebugLaunch.screenID {
                // `-ppcpScreen S3` on the launch command line. Never reachable in
                // a release build — the whole gallery compiles out.
                DebugScreenGallery(screenID: id, model: model)
                    .task { model.refreshCapability() }
            } else {
                statusScreen
            }
            #else
            statusScreen
            #endif
        }
        .sheet(item: $sheet, content: sheetContent(for:))
        // ⛔ `RV` 6b — the second branch is "leaves the join in the user's
        // control", and control the user does not know they have is not
        // control. iOS removed this app's network configuration and cannot
        // reassociate whatever they were on before, so saying nothing would
        // leave them on no network wondering why.
        .alert("Studio network removed",
               isPresented: Binding(get: { leftNetwork != nil },
                                    set: { if !$0 { leftNetwork = nil } })) {
            Button("OK", role: .cancel) { leftNetwork = nil }
        } message: {
            Text(NetworkJoin.leftNetworkExplanation)
        }
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                Task { await model.linkDidEnterBackground() }
            case .active:
                // ⛔ **`RV` §3.** Foreground only, and only with no link up: the
                // coordinator reads what pairings this device holds, browses for
                // a host that resolves against one of them (3.4b/3.4c), and dials
                // it. It also raises the foreground flag and starts the wired
                // reconcile loop — see `AppModel.sceneDidBecomeActive()`.
                model.refreshPermissions()
                model.sceneDidBecomeActive()
            default:
                break
            }
        }
    }

    // MARK: The status screen — the app root

    private var statusScreen: some View {
        StatusScreen(
            connection: connectionStatus,
            recording: recordingStatus,
            problem: problem,
            onOpenSystemSettings: systemSettingsAction,
            onOpenSettings: {
                reloadRememberedStudios()
                settingsPath = []
                sheet = .settings
            },
            debugAccessory: ringStatsAccessory
        )
        .task { reloadRememberedStudios() }
        .task {
            // ⛔ **Enumerate first.** `AppModel.init` seeds `capability` with
            // `claimed: []`, so `activeMode` is nil — and warm, arm and preview
            // all refuse — until `refreshCapability()` runs.
            //
            // ⚠ The permission prompts are what onboarding's A4 used to ask for;
            // with onboarding gone they are asked here, once, on first launch.
            // Not under test: an app-hosted suite must not raise system dialogs.
            //
            // ⚠ **No `warmUp()` here any more.** With no host it held the camera
            // — and its privacy light — on indefinitely; arm and preview both
            // warm the camera themselves when the host asks.
            if AppModel.isUnderTest == false {
                await model.requestCapturePermissions()
            }
            model.refreshCapability()
            model.refreshHealth()
            // #122 — nothing is kept on the phone past its session; anything a
            // previous run left behind goes now.
            model.sweepLeftovers()
        }
    }

    /// `RV` §3 and the live link, as the status screen says it.
    ///
    /// ⚠ The link wins when there is one; the search is only described when
    /// there is nothing up.
    private var connectionStatus: StatusScreen.Connection {
        let name = model.hostLink.hostName
        if model.link != nil {
            switch model.hostLink.state {
            case .connected, .weak, .resyncing:
                return .connected(name: name, transport: model.hostLink.transport)
            case .lost:
                return .lost(name: name)
            case .pairing, .none:
                return .pairing(name: name)
            }
        }
        if model.stayDisconnected { return .disconnected }
        if let diagnosis = model.reconnectDiagnosis {
            return .diagnosis(diagnosis)
        }
        // ⛔ Not "no host": nothing is held, so no browse was performed and none
        // would help. `ReconnectOutcome.noPairingsHeld` is a different sentence
        // from "your Studio did not appear".
        if rememberedStudios.isEmpty { return .notPaired }
        if let silence = model.reconnectSilence {
            return .notFound(seconds: Int(Double(silence.searchedForNs) / 1_000_000_000))
        }
        // ⚠ A name only where exactly ONE is held: "Looking for Bay 3" is a
        // promise, and with three remembered Studios the sweep is not looking
        // for any particular one of them.
        return .searching(name: rememberedStudios.count == 1
                          ? rememberedStudios.first?.displayName : nil)
    }

    private var recordingStatus: StatusScreen.Recording {
        if model.captureStatus.state == .armed { return .recording }
        if model.isSettling { return .arming }
        return model.captureStatus.state == .warm ? .warm : .idle
    }

    /// The one sentence that stops this phone doing its job, if there is one.
    /// ⛔ Never read by the old C1 until #97, which is why *Arm* could sit there
    /// doing nothing with no explanation.
    private var problem: String? {
        if model.permissions.canCapture == false,
           model.permissions.camera != .notRequested,
           model.permissions.microphone != .notRequested {
            return "Camera and microphone access are both needed. "
                + "Settings — PinPointCapture."
        }
        return model.recordingError ?? model.capabilityError
    }

    /// Offered beside the problem only when the remedy is a permission.
    private var systemSettingsAction: (() -> Void)? {
        model.permissions.canCapture ? nil : { openSystemSettings() }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(for sheet: AppSheet) -> some View {
        switch sheet {
        case .settings:
            NavigationStack(path: $settingsPath) {
                SettingsView(
                    connectedHostName: model.link == nil ? nil : model.hostLink.hostName,
                    isLinked: model.link != nil,
                    // ⚠ Straight to B1a. B1 (discover / enter a code / cable)
                    // is mothballed; the code is the one route that works.
                    onPair: { self.sheet = .scanPairingCode(failure: nil) },
                    onOpenRememberedStudios: {
                        reloadRememberedStudios()
                        settingsPath.append(.rememberedStudios)
                    },
                    // ⛔ **Disconnect drops the LINK and keeps it dropped.** Not
                    // the pairing — that is *Forget* — and the wired loop would
                    // otherwise re-publish this phone within 2 s. 6b / 4.4c: the
                    // user ended this session, so the network this app
                    // configured goes and the decoded payload is released.
                    onDisconnect: {
                        self.sheet = nil
                        Task {
                            await model.disconnectAndStayDisconnected()
                            if let left = await rendezvous.endPairing() { leftNetwork = left }
                        }
                    },
                    onOpenMicToBallDistance: { settingsPath.append(.micToBallDistance) },
                    onDone: { self.sheet = nil })
                .navigationDestination(for: SettingsRoute.self) { route in
                    switch route {
                    case .rememberedStudios:
                        // ⛔ B3a — `RV` 7.4b's *individually revocable*.
                        RememberedStudiosView(
                            pairings: rememberedStudios,
                            onForget: { forget(sessionId: $0.sessionId) },
                            onDone: { settingsPath.removeLast() })
                    case .micToBallDistance:
                        // ⚠ 8.1d. It takes effect on the next arm rather than
                        // mid-session.
                        MicToBallDistanceView(
                            distance: $model.micToBallDistance,
                            wasChosen: model.micToBallDistanceWasChosen,
                            isSessionOpen: model.recording != nil,
                            onDone: { settingsPath.removeLast() })
                    }
                }
            }
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(PPMetrics.Radius.sheet)

        case .scanPairingCode(let failure):
            NavigationStack {
                // ⛔ The screen says nothing about remembering: `mu` is unknown
                // until the code is decoded, so B2 carries that sentence (#96).
                ScanPairingCodeView(
                    failure: failure,
                    onCode: { uri in Task { await scan(uri) } },
                    onCancel: { self.sheet = nil })
            }

        case .joinNetwork(let ssid):
            JoinNetworkView(ssid: ssid,
                            onJoin: {
                                // 6a — consent given; resume at the join, then the
                                // endpoint walk (4.3f).
                                guard let uri = pendingCode else { self.sheet = nil; return }
                                Task {
                                    _ = await rendezvous.continueAfterJoining(uri)
                                    self.sheet = nil
                                }
                            },
                            onStayOnCurrentNetwork: { self.sheet = nil })
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(PPMetrics.Radius.sheet)

        case .localNetworkBlocked:
            NavigationStack {
                LocalNetworkBlockedView(
                    onOpenSettings: { openSystemSettings() },
                    onTryAgain: { self.sheet = nil }
                )
            }

        case .pairing:
            NavigationStack {
                PairingView(
                    link: model.hostLink,
                    securitySummary: model.link?.securitySummary,
                    agreedMode: model.activeMode,
                    viewpoint: model.framing.viewpoint,
                    isCameraLocked: model.captureStatus.state != .cold,
                    failure: model.hostLinkError,
                    remembered: remembered,
                    // ⛔ **Cancel and Done are the same button and NOT the same
                    // act.** While the handshake is running this ends the session;
                    // once it has settled the user is finished with the screen and
                    // the link is the thing they came for. Tearing it down on
                    // *Done* would disconnect the Studio they just paired with.
                    onCancel: {
                        guard remembered == nil else {
                            self.sheet = nil
                            remembered = nil
                            rememberedSessionId = nil
                            return
                        }
                        self.sheet = nil
                        Task {
                            await model.disconnect(.cancelled)
                            // ⛔ 6b / 4.4c — the USER ended this session, so the
                            // network this app configured goes and the decoded
                            // payload (which carries the Wi-Fi passphrase) is
                            // released. ⚠ Only here, and deliberately not on the
                            // backgrounding path: that link is expected back, and
                            // removing the configuration would drop the phone off
                            // the studio network exactly when it is reconnecting.
                            // ⛔ This call did not exist until 25 August 2026, so
                            // none of it happened — finding F-D12-1.
                            if let left = await rendezvous.endPairing() {
                                // 6b is "leaves the join in the user's control",
                                // and that is only true if they are told they have
                                // it. iOS cannot reassociate their previous network.
                                leftNetwork = left
                            }
                        }
                    },
                    // ⛔ 7.4b — offered at the one moment the user is certain to
                    // learn the Studio was kept. ⚠ It revokes the pairing and
                    // leaves the *link* alone: this session is already up and
                    // forgetting is about the next one.
                    onForget: {
                        guard let rememberedSessionId else { return }
                        forget(sessionId: rememberedSessionId)
                        remembered = .forgotten
                    })
            }
            .interactiveDismissDisabled()
        }
    }

    // MARK: Rendezvous (RV §4, §6, §7.4)

    /// E1.1's ring counters, or `nil`. ⚠ Shown while armed, after a run, or when
    /// `-ppcpRingStats 1` forces it — the last of those exists because the
    /// overlay only draws while capturing, so a simulator could never show it and
    /// its placement was guessed instead of seen.
    private var ringStatsAccessory: AnyView? {
        #if DEBUG
        guard model.captureStatus.state == .armed
                || model.lastRunRingStats != nil
                || DebugLaunch.forcesRingStats else { return nil }
        return AnyView(
            RingStatsOverlay(
                stats: model.captureStatus.state == .armed
                    ? model.ringStats
                    : (model.lastRunRingStats ?? RingStats()),
                expectedFPS: model.activeMode?.fps,
                isLive: model.captureStatus.state == .armed)
        )
        #else
        nil
        #endif
    }

    /// The platform outcome as B2's sentence. ⛔ `RendezvousCoordinator.PersistOutcome`
    /// does not cross into `Sources/UI`; this is the seam.
    private static func remembered(from outcome: RendezvousCoordinator.PersistOutcome)
        -> PairingView.Remembered {
        switch outcome {
        case .remembered: .remembered
        case .notRememberedMultiUseCode: .multiUseCode
        case .couldNotWrite: .couldNotWrite
        }
    }

    /// 7.4b/7.4d — revocation, honoured immediately by this side. ⛔ The bytes go;
    /// there is no soft delete, and the other end's next handshake fails.
    private func forget(sessionId: String) {
        try? PairingSecretStore.revoke(sessionId: sessionId)
        reloadRememberedStudios()
    }

    /// ⚠ Re-read rather than mutated. `PairingSecretStore` is the truth, and a
    /// list held in a `@State` diverges from it the first time anything else
    /// writes.
    private func reloadRememberedStudios() {
        rememberedStudios = (try? PairingSecretStore.pairings()) ?? []
    }

    /// The whole of `RV` §4.4 in one place: decode, expiry, the network, then the
    /// endpoints — in that order, because 4.3f puts the join **before** the walk.
    ///
    /// ⛔ Three failures, three screens, and none of them is a generic one.
    private func scan(_ uri: String) async {
        switch await rendezvous.scan(uri) {
        case .connected:
            // ⛔ **Remembered by default as of 25 August 2026** (#96; `RV` 7.4b is
            // a SHOULD since erratum E57). ⚠ The outcome is *kept*, not discarded
            // into a `try?` as it was — a phone that reports a remembered Studio
            // while holding nothing reconnects to nothing, which is precisely how
            // the 24 August integration test failed.
            let outcome = await rendezvous.persistPairing()
            // ⛔ **Take the link.** This is where the socket used to be dropped:
            // the state was set to `.pairing`, the sheet dismissed, and the
            // handshaken transport left for `endPairing` to close. Ownership now
            // transfers to the peer engine, which is what the coordinator's own
            // comment has claimed since D7.
            guard let established = await rendezvous.takeEstablishedLink() else {
                sheet = .scanPairingCode(failure: .invalidCode)
                return
            }
            sheet = .pairing
            await model.connect(transport: established.transport,
                                sessionId: established.sessionId,
                                hostDisplayName: established.hostDisplayName)
            // ⛔ **B2 stays up and says so.** It used to be dismissed here, so a
            // successful pairing was silent and the only confirmation was on the
            // other machine — the first of the 24 August UX findings. A failure
            // still shows in place, which is why this is not an `else`.
            if model.link?.hasSettled == true {
                rememberedSessionId = established.sessionId
                remembered = Self.remembered(from: outcome)
            }
        case .needsANewerApplication:
            sheet = .scanPairingCode(failure: .needsANewerApplication)
        case .invalidCode:
            sheet = .scanPairingCode(failure: .invalidCode)
        case .expired:
            sheet = .scanPairingCode(failure: .expired)
        case .needsNetworkConsent(let network):
            // 6a — the consent is for the **specific** network, so the sheet names
            // it and the walk does not continue until it is given.
            pendingCode = uri
            sheet = .joinNetwork(ssid: network.ssid)
        case .couldNotJoinNetwork(let reason):
            sheet = .scanPairingCode(failure: .couldNotJoinNetwork(reason))
        case .hostRefusedTheCode:
            // ⛔ Never B6. The local network is demonstrably fine — the host
            // answered — so offering a permission remedy would be the same wrong
            // diagnosis in a different screen.
            sheet = .scanPairingCode(failure: .hostRefusedTheCode)
        case .noEndpointReachable(let tried, let blocked):
            // `RV` §8 — inferred from the symptom, never from a permission query.
            sheet = blocked ? .localNetworkBlocked
                            : .scanPairingCode(failure: .noEndpointReachable(triedCount: tried))
        }
    }
}
