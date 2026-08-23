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

    var id: String {
        switch self {
        case .hostPanel: "hostPanel"
        case .connectHost: "connectHost"
        case .scanPairingCode: "scanPairingCode"
        case .joinNetwork: "joinNetwork"
        case .localNetworkBlocked: "localNetworkBlocked"
        case .reconcileSession: "reconcileSession"
        }
    }
}

struct RootView: View {
    @State private var model = AppModel()
    @State private var path: [AppRoute] = []
    @State private var sheet: AppSheet?
    /// 7.4b — persistence is opt-in, so the toggle starts **off**.
    @State private var persistPairing = false
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
        .preferredColorScheme(.dark)
    }

    private var onboarding: some View {
        OnboardingFlow(
            model: model,
            onConnectHost: { sheet = .connectHost },
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
                onDisarm: { model.disarm() }
            )
            // C1 is full-bleed. The preview is the screen; a nav bar over it would
            // cost exactly the area the golfer needs to be judged in.
            .toolbar(.hidden, for: .navigationBar)
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
                onSelectShot: { path.append(.replay($0)) },
                onPauseTransfer: { model.transferQueue.isPaused.toggle() },
                onExportSession: {}
            )

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
                    sessionStart: model.session.start,
                    // The reviewer switcher. Not present in a shipped build — it
                    // exists so all four states can be walked without a host.
                    onSelectReviewState: { model.hostLink = Self.link(for: $0) },
                    onDone: { self.sheet = nil },
                    onPrimaryAction: {},
                    onOpenConnectionLog: {},
                    onExportDiagnostics: {}
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(PPMetrics.Radius.sheet)

        case .connectHost:
            ConnectHostView(
                discoveredHostName: PreviewFixtures.hostName,
                discoveredHostDetail: "On this network · paired yesterday",
                onCancel: { self.sheet = nil },
                onConnectToDiscoveredHost: {
                    model.hostLink = PreviewFixtures.connected
                    self.sheet = nil
                },
                onEnterCode: { self.sheet = .scanPairingCode(failure: nil) },
                onUseCable: {},
                onCaptureWithoutHost: { self.sheet = nil }
            )

        case .scanPairingCode(let failure):
            NavigationStack {
                ScanPairingCodeView(
                    failure: failure,
                    // ⛔ 7.4f — the offer is withheld for a `mu > 1` code rather
                    // than shown and then refused.
                    mayPersist: persistPairing || failure == nil,
                    persistPairing: $persistPairing,
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

    /// The whole of `RV` §4.4 in one place: decode, expiry, the network, then the
    /// endpoints — in that order, because 4.3f puts the join **before** the walk.
    ///
    /// ⛔ Three failures, three screens, and none of them is a generic one.
    private func scan(_ uri: String) async {
        switch await rendezvous.scan(uri) {
        case .connected:
            // 7.4b — persisted only where the user asked and 7.4f permits.
            try? await rendezvous.persistPairing(consent: persistPairing)
            model.hostLink = HostLink(state: .pairing)
            sheet = nil
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
        case .noEndpointReachable(let tried, let blocked):
            // `RV` §8 — inferred from the symptom, never from a permission query.
            sheet = blocked ? .localNetworkBlocked
                            : .scanPairingCode(failure: .noEndpointReachable(triedCount: tried))
        }
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
