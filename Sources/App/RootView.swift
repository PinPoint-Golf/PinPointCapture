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

/// Pushed destinations. Sheets are separate, because a sheet is a presentation
/// decision rather than a place in a stack.
enum AppRoute: Hashable {
    case sessionLibrary
    case replay(Shot)
}

/// Modally presented screens.
enum AppSheet: Identifiable {
    /// B3, from the C1 host chip.
    case hostPanel
    /// B1, modal from A7 or from the host sheet.
    case connectHost
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

    var body: some View {
        Group {
            if model.hasCompletedOnboarding {
                captureStack
            } else {
                OnboardingFlow(
                    model: model,
                    onConnectHost: { sheet = .connectHost },
                    onFinish: {}
                )
            }
        }
        .sheet(item: $sheet, content: sheetContent(for:))
        .preferredColorScheme(.dark)
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
                onEnterCode: {},
                onUseCable: {},
                onCaptureWithoutHost: { self.sheet = nil }
            )

        case .joinNetwork(let ssid):
            JoinNetworkView(ssid: ssid,
                            onJoin: { self.sheet = nil },
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
