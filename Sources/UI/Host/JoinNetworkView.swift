//
//  JoinNetworkView.swift
//  B4 — Join the studio network? (sheet content)
//
//  Shown when the scanned pairing code carries an SSID and passphrase
//  (REQ-DISC-4). The app *removes* the network problem instead of diagnosing it.
//
//  ⚠ The loss of internet is stated plainly, in the list, before the user
//  commits — because it is the thing they notice ten minutes later and blame on
//  the app.
//
//  This is sheet *content*. Detents, the grabber and the 28pt corners belong to
//  whoever presents it.
//

import SwiftUI

public struct JoinNetworkView: View {

    /// The network named in the pairing code — "PinPoint-Bay3".
    private let ssid: String
    /// A studio network is normally local only. Stated either way.
    private let providesInternet: Bool

    private let onJoin: () -> Void
    private let onStayOnCurrentNetwork: () -> Void

    public init(
        ssid: String,
        providesInternet: Bool = false,
        onJoin: @escaping () -> Void,
        onStayOnCurrentNetwork: @escaping () -> Void
    ) {
        self.ssid = ssid
        self.providesInternet = providesInternet
        self.onJoin = onJoin
        self.onStayOnCurrentNetwork = onStayOnCurrentNetwork
    }

    public var body: some View {
        List {
            Section {
                header
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: PPMetrics.itemGap,
                                      leading: PPMetrics.screenMargin,
                                      bottom: PPMetrics.groupGap,
                                      trailing: PPMetrics.screenMargin))

            Section {
                TelemetryRow("Network", ssid)
                TelemetryRow("Internet", internetValue,
                             tone: providesInternet ? nil : .warning,
                             spokenValue: spokenInternetValue)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) { actions }
    }

    private var header: some View {
        VStack(spacing: PPMetrics.itemGap) {
            Image(systemName: "wifi")
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.ppWarning)
                .accessibilityHidden(true)

            Text("Join the studio network?")
                .font(.ppScreenHeading)
                .foregroundStyle(Color(.label))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            // One literal so the SSID stays bold in the sentence.
            Text("The code you scanned includes a network. Joining **\(ssid)** keeps the link stable and off the guest Wi-Fi.")
                .font(.ppSupporting)
                .foregroundStyle(Color(.secondaryLabel))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// ⚠ Verbatim: "No — local only". The em dash is the design's.
    private var internetValue: String {
        providesInternet ? "Yes" : "No \u{2014} local only"
    }

    private var spokenInternetValue: String {
        providesInternet ? "Yes" : "No, local only"
    }

    private var actions: some View {
        VStack(spacing: PPMetrics.itemGap) {
            Button("Join network", action: onJoin)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)

            // Inherits the app accent — no hand-applied tint on a stock control.
            Button("Stay on current Wi-Fi", action: onStayOnCurrentNetwork)
                .buttonStyle(.borderless)
                .font(.ppRowLabel.weight(.semibold))
                .frame(maxWidth: .infinity,
                       minHeight: PPMetrics.Size.minimumTapTarget)
        }
        .padding(.horizontal, PPMetrics.screenMargin)
        .padding(.top, PPMetrics.itemGap)
        .background(.bar)
    }
}

// MARK: - Previews

#Preview("B4 · Join the studio network?") {
    JoinNetworkView(
        ssid: "PinPoint-Bay3",
        onJoin: {},
        onStayOnCurrentNetwork: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("B4 · Presented as a sheet") {
    Color(.systemBackground)
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            JoinNetworkView(
                ssid: "PinPoint-Bay3",
                onJoin: {},
                onStayOnCurrentNetwork: {}
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(PPMetrics.Radius.sheet)
        }
        .preferredColorScheme(.dark)
}
