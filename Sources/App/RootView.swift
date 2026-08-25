//  RootView.swift
//  The app shell.
//
//  ⛔ THERE IS NO TAB BAR. The capture screen is the app root; the host chip on C1
//  opens the host sheet, and *Session · n* opens the library. A camera-first app
//  should not carry a tab bar over a full-bleed preview.
//
//  Every screen in the app is presented from here. Screens themselves own no
//  navigation — they take Core values and hand back closures — so this file is
//  the whole routing surface.

import SwiftUI
import CaptureCore

/// Pushed destinations. Sheets are separate, because a sheet is a presentation
/// decision rather than a place in a stack.
enum AppRoute: Hashable {
    case sessionLibrary
    case replay(Shot)
    /// A8 — the microphone-to-ball distance (D7). ⚠ A push rather than a sheet:
    /// it is a setting a golfer returns to, not a decision blocking a flow.
    case micToBallDistance
    /// B3a — `RV` 7.4b's revocation list (#96). ⚠ A push for the same reason A8
    /// is one: a setting, returned to, not a step in a flow.
    case rememberedStudios
}

/// Modally presented screens.
enum AppSheet: Identifiable {
    /// B3, from the C1 host chip.
    case hostPanel
    /// B1, modal from A7 or from the host sheet.
    case connectHost
    /// B1a — scanning a `ppcp:` code (`RV` §4). ⛔ The `failure` is carried on the
    /// case because 4.2b/4.4a/4.4b are three different sentences and the screen
    /// has to know which one it is showing.
    case scanPairingCode(failure: ScanPairingCodeView.Failure?)
    /// B4, when a scanned pairing code carries a network.
    case joinNetwork(ssid: String)
    /// B6, inferred from a connection failure — never from a permission query.
    case localNetworkBlocked
    /// B5, before anything is merged.
    case reconcileSession
    /// A8, presented from onboarding — which cannot push an `AppRoute`.
    case micToBallDistance
    /// B2 — the handshake, while it is happening.
    case pairing

    var id: String {
        switch self {
        case .hostPanel: "hostPanel"
        case .connectHost: "connectHost"
        case .scanPairingCode: "scanPairingCode"
        case .joinNetwork: "joinNetwork"
        case .localNetworkBlocked: "localNetworkBlocked"
        case .reconcileSession: "reconcileSession"
        case .micToBallDistance: "micToBallDistance"
        case .pairing: "pairing"
        }
    }
}

struct RootView: View {
    @State private var model = AppModel()
    /// ⛔ Backgrounding suspends the socket. E3.5 owns reconnecting; this level
    /// owns not lying about it in the meantime.
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [AppRoute] = []
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
    /// The stored pairing behind the link that is currently up, if there is one
    /// — what puts *Forget this Studio* on B3's status card beside its name.
    ///
    /// ⚠ Read when the panel opens rather than computed per render: it is a file
    /// read, and SwiftUI would repeat it on every layout pass.
    @State private var rememberedForCurrentLink: StoredPairing?
    private let rendezvous = RendezvousCoordinator()
    /// Held only between the consent sheet and the resumed walk. ⛔ `RV` 4.4c —
    /// the payload is not retained after the pairing it establishes has ended.
    @State private var pendingCode: String?

    var body: some View {
        Group {
            #if DEBUG
            if let id = DebugLaunch.screenID {
                // `-ppcpScreen A6` on the launch command line. Never reachable in
                // a release build — the whole gallery compiles out.
                DebugScreenGallery(screenID: id, model: model)
                    .task { model.refreshCapability() }
            } else if model.hasCompletedOnboarding {
                captureStack
            } else {
                onboarding
            }
            #else
            if model.hasCompletedOnboarding {
                captureStack
            } else {
                onboarding
            }
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
        // ⛔ **The injection, and it was missing.** `ArmedScreen` and
        // `FramingCheckScreen` read `\.livePreview` from the environment; with
        // nothing supplying one they silently fall back to `.placeholder` and
        // render exactly what they rendered before the seam existed. The whole
        // camera fix was a no-op on the device because of this line's absence —
        // a default that makes a missing wire *look* deliberate is precisely the
        // failure this pass was written to remove.
        .environment(\.livePreview, LivePreviewProvider { caption in
            // ⚠ A preview layer attached to a session that is not running is a
            // black rectangle, and "black screen" and "camera not running" look
            // identical on a tripod at two metres. Cold shows the caption.
            model.captureStatus.state == .cold
                ? AnyView(LiveCapturePreviewPlaceholder(caption: caption))
                : AnyView(CameraPreview(device: model.captureDevice,
                                        placeholderLabel: caption))
        })
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                Task { await model.linkDidEnterBackground() }
            case .active:
                // ⛔ **`RV` §3, and this is where (b) starts.** Foreground only,
                // and only with no link up: the coordinator reads what pairings
                // this device holds, browses for a host that resolves against one
                // of them (3.4b/3.4c), and dials it. No code, no pairing step.
                // ⚠ It does nothing at all on a device that has never paired.
                model.beginSearchingForHost()
            default:
                break
            }
        }
    }

    private var onboarding: some View {
        OnboardingFlow(
            model: model,
            onConnectHost: { sheet = .connectHost },
            // ⛔ Straight to B1a. The pairing step is B1 for this purpose, so
            // sending it through B1 again would be a screen presenting itself.
            onScanPairingCode: { sheet = .scanPairingCode(failure: nil) },
            // ⚠ Named from the LINK, not from the pairing store: this reports
            // what is connected right now, and a remembered Studio that is not
            // on the network is neither.
            hostName: model.hostLink.hostName,
            isPaired: model.link?.hasSettled == true,
            onOpenMicToBallDistance: { sheet = .micToBallDistance },
            onFinish: {}
        )
    }

    // MARK: Capture stack — C1 is the root

    private var captureStack: some View {
        NavigationStack(path: $path) {
            ArmedScreen(
                capture: model.captureStatus,
                hostLink: model.hostLink,
                session: model.session,
                lastShot: model.session.shots.last,
                onOpenHost: { sheet = .hostPanel },
                onOpenSession: { path.append(.sessionLibrary) },
                onReplayLastShot: {
                    guard let shot = model.session.shots.last else { return }
                    path.append(.replay(shot))
                },
                onDisarm: { model.disarm() },
                onArm: { model.arm() },
                candidateCount: model.candidateCount,
                recordingError: model.recordingError
            )
            .task {
                // ⚠ Warm before arming so C1 shows a live preview cold, and so
                // arming costs no AE/AF settling (REQ-STATE-2).
                model.warmUp()
                model.refreshHealth()
            }
            // C1 is full-bleed. The preview is the screen; a nav bar over it would
            // cost exactly the area the golfer needs to be judged in.
            .toolbar(.hidden, for: .navigationBar)
            #if DEBUG
            // ⛔ **E1.1's instrument, and debug builds only.** The exit criterion
            // is "twenty fragments, rolling, **at the claimed rate**" — the rate
            // clause cannot be read off a directory listing or a preview that
            // looks fine, and a device run without this produces an impression.
            //
            // ⚠ Here rather than in `DebugScreenGallery`: the gallery is selected
            // by a launch argument and REPLACES the app, so it cannot show a
            // running capture. The numbers are only interesting while armed.
            //
            // ⚠ Overlaid rather than added to `ArmedScreen`, so the designed
            // screen keeps the shape the handoff specifies and this cannot drift
            // into it. Tap to expand.
            .overlay(alignment: .topLeading) {
                if model.captureStatus.state == .armed || model.lastRunRingStats != nil {
                    RingStatsOverlay(
                        stats: model.captureStatus.state == .armed
                            ? model.ringStats
                            : (model.lastRunRingStats ?? RingStats()),
                        expectedFPS: model.activeMode?.fps,
                        isLive: model.captureStatus.state == .armed)
                    .padding(.leading, 12)
                    .padding(.top, 8)
                    .allowsHitTesting(true)
                }
            }
            #endif
            .navigationDestination(for: AppRoute.self, destination: destination(for:))
        }
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .sessionLibrary:
            SessionLibraryScreen(
                session: model.session,
                transferQueue: model.transferQueue,
                hostName: model.hostLink.hostName,
                recordedBundles: model.libraryRows(),
                onSelectShot: { path.append(.replay($0)) },
                onPauseTransfer: { model.transferQueue?.isPaused.toggle() },
                onOpenMicToBallDistance: { path.append(.micToBallDistance) }
            )

        case .rememberedStudios:
            // ⛔ B3a — `RV` 7.4b's *individually revocable*. `pairings()` and
            // `revoke(_:)` were written under D7 and had no caller until #96.
            RememberedStudiosView(
                pairings: rememberedStudios,
                onForget: { forget(sessionId: $0.sessionId) },
                onDone: { path.removeLast() })

        case .micToBallDistance:
            // ⚠ 8.1d — the setting Mark asked for on 23 August 2026. It reaches
            // every Candidate's `tof_correction` through `CandidateFactory`, and
            // it takes effect on the next arm rather than mid-session.
            MicToBallDistanceView(
                distance: $model.micToBallDistance,
                wasChosen: model.micToBallDistanceWasChosen,
                isSessionOpen: model.recording != nil,
                onDone: { path.removeLast() })

        case .replay(let shot):
            ReplayScreen(
                shot: shot,
                // ⛔ Stated by the caller, not defaulted. Nothing records video
                // (E1.1), and a screen that discovers this for itself is a
                // screen that will quietly start lying when one of them changes.
                hasVideo: false,
                // ⚠ REQ-STATE-4 / REQ-RES-1. Reviewing never disarms. The capture
                // status handed to C2 is the live one, which is why its title bar
                // can honestly say "still armed".
                capture: model.captureStatus,
                onDone: { path.removeLast() },
                onCompare: {},
                onStepFrame: { _ in },
                onTogglePlayback: {},
                onCycleSpeed: {},
                onSelectTool: { _ in }
            )
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(for sheet: AppSheet) -> some View {
        switch sheet {
        case .hostPanel:
            NavigationStack {
                HostPanelView(
                    link: model.hostLink,
                    capture: model.captureStatus,
                    queue: model.transferQueue,
                    storage: model.storage,
                    // nil while nothing is open — `subLine` omits the clause.
                    sessionStart: model.recording == nil ? nil : model.session.start,
                    // The reviewer switcher. ⛔ `#if DEBUG` at the call site too,
                    // so a release binary contains no path from the shell into
                    // `PreviewFixtures`.
                    onSelectReviewState: Self.reviewStateHandler(model),
                    measuredMethod: model.capability.measured?.method,
                    onDone: { self.sheet = nil },
                    // A real action in the `.none` state, and it did nothing.
                    onPrimaryAction: { self.sheet = .connectHost },
                    onOpenMicToBallDistance: {
                        self.sheet = nil
                        path.append(.micToBallDistance)
                    },
                    // ⛔ 7.4b — the several-Studios case. The single one a golfer
                    // actually has is the row below, on the status card.
                    onOpenRememberedStudios: {
                        self.sheet = nil
                        reloadRememberedStudios()
                        path.append(.rememberedStudios)
                    },
                    // ⛔ **Forget, where the Studio is named** (Mark, 25 August
                    // 2026). 4.4d — untrusted display text, so it names a row and
                    // is never an identifier; the identity is the `sessionId`.
                    rememberedHostName: rememberedForCurrentLink
                        .map { $0.displayName ?? "this Studio" },
                    onForgetHost: rememberedForCurrentLink.map { held in
                        {
                            forget(sessionId: held.sessionId)
                            rememberedForCurrentLink = nil
                        }
                    }
                )
                .task { refreshRememberedForCurrentLink() }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(PPMetrics.Radius.sheet)

        case .connectHost:
            ConnectHostView(
                // ⛔ **No invented host.** These were `PreviewFixtures.hostName`
                // and a hardcoded "paired yesterday", and tapping the row
                // assigned `PreviewFixtures.connected` — an app reporting a
                // paired Studio, a measured clock offset and a transfer queue
                // with no socket open anywhere. Discovery is E16.1; until it
                // exists there is no row.
                discoveredHostName: nil,
                discoveredHostDetail: nil,
                onCancel: { self.sheet = nil },
                onConnectToDiscoveredHost: {},
                onEnterCode: { self.sheet = .scanPairingCode(failure: nil) },
                // ⛔ The list belongs here too: this is the screen a golfer
                // reaches when the Studio they expected has not appeared.
                // ⚠ Offered only when something is held — a list of nothing is
                // not a destination.
                onOpenRememberedStudios: rememberedStudios.isEmpty ? nil : {
                    self.sheet = nil
                    path.append(.rememberedStudios)
                },
                onCode: { uri in Task { await scan(uri) } },
                onUseCable: {},
                onCaptureWithoutHost: { self.sheet = nil }
            )

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
                    onOpenSettings: {},
                    onConnectByCable: {},
                    onCaptureAlone: { self.sheet = nil },
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

        case .micToBallDistance:
            NavigationStack {
                MicToBallDistanceView(
                    distance: $model.micToBallDistance,
                    wasChosen: model.micToBallDistanceWasChosen,
                    isSessionOpen: model.recording != nil,
                    onDone: { self.sheet = nil })
            }

        case .reconcileSession:
            NavigationStack {
                ReconcileSessionView(
                    candidates: [],
                    shotCount: model.session.shots.count,
                    onSelect: { _ in },
                    onReview: { self.sheet = nil },
                    // ⛔ REQ-OFF-12. Never auto-merge; both outcomes are explicit.
                    onSendAsNewSession: { self.sheet = nil }
                )
            }
        }
    }

    // MARK: Rendezvous (RV §4, §6, §7.4)

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

    /// Matches the live link to the pairing it was established from.
    ///
    /// ⛔ **`HostLinkSession.sessionId` IS the stored pairing's key on both
    /// paths, and that is worth stating because 7.4e invites the opposite
    /// assumption.** A scanned code stores under `code.sessionId` and connects
    /// with it; `ReconnectCoordinator` hands back `ReconnectedHost.sessionId`,
    /// documented as *the Session the pairing was established for* — the held
    /// pairing's id, not a fresh one. 7.4e governs the `sid` **transmitted**
    /// inside the channel, which this app never reuses: `PpcpTransport` draws a
    /// fresh PSK identity per connection under 5.3a1.
    private func refreshRememberedForCurrentLink() {
        reloadRememberedStudios()
        guard let sessionId = model.link?.sessionId else {
            rememberedForCurrentLink = nil
            return
        }
        rememberedForCurrentLink = rememberedStudios
            .first { $0.sessionId == sessionId }
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

    /// ⛔ `nil` in a release build: no switcher, and no reachable fixture.
    private static func reviewStateHandler(_ model: AppModel) -> ((HostLinkState) -> Void)? {
        #if DEBUG
        { model.hostLink = link(for: $0) }
        #else
        nil
        #endif
    }

    /// Fixture link state for the reviewer switcher, so each state shows the
    /// telemetry the design specifies rather than an empty card.
    private static func link(for state: HostLinkState) -> HostLink {
        switch state {
        case .connected: PreviewFixtures.connected
        case .weak: PreviewFixtures.weak
        case .lost: PreviewFixtures.lost
        case .resyncing: PreviewFixtures.resyncing
        case .pairing: PreviewFixtures.pairing
        case .none: HostLink(state: .none)
        }
    }
}
