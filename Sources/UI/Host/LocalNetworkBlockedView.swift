//
//  LocalNetworkBlockedView.swift
//  B6 — iOS is blocking the local network.
//
//  The failure that otherwise makes the app look permanently broken. iOS
//  exposes no API to read local-network permission back, so this state is
//  **inferred from connection failure** and presented as this screen rather
//  than as a generic error (REQ-DISC-6).
//
//  ⚠ Copy order carries the design. The reassurance — "It has no effect on
//  capture — you can record all day like this" — comes *immediately*, before
//  the fix. A refusal must cost a golfer a network, not a session.
//

import SwiftUI
import CaptureCore

public struct LocalNetworkBlockedView: View {

    private let onOpenSettings: () -> Void
    private let onConnectByCable: () -> Void
    private let onCaptureAlone: () -> Void
    private let onTryAgain: () -> Void

    public init(
        onOpenSettings: @escaping () -> Void,
        onConnectByCable: @escaping () -> Void,
        onCaptureAlone: @escaping () -> Void,
        onTryAgain: @escaping () -> Void
    ) {
        self.onOpenSettings = onOpenSettings
        self.onConnectByCable = onConnectByCable
        self.onCaptureAlone = onCaptureAlone
        self.onTryAgain = onTryAgain
    }

    public var body: some View {
        List {
            // 1. The cause, and immediately the reassurance. Nothing between them.
            Section {
                VStack(alignment: .leading, spacing: PPMetrics.itemGap) {
                    Image(systemName: "wifi.slash")
                        .font(.largeTitle)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.ppError)
                        .accessibilityHidden(true)

                    Text("Without it the app cannot reach a host on Wi-Fi. It has no effect on capture — you can record all day like this.")
                        .font(.ppSupporting)
                        .foregroundStyle(Color(.secondaryLabel))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: PPMetrics.screenMargin,
                                      bottom: PPMetrics.groupGap,
                                      trailing: PPMetrics.screenMargin))

            // 2. The fix, with the exact path — never an API name.
            Section {
                InfoCard("Settings — PinPointCapture — turn on Local Network, then come back.",
                         title: "To fix it")
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: PPMetrics.screenMargin,
                                      bottom: PPMetrics.itemGap,
                                      trailing: PPMetrics.screenMargin))

            Section {
                HostDisclosureRow(title: "Open Settings",
                                  titleTone: .accent,
                                  action: onOpenSettings)
            }

            // 3. The two routes that do not need the permission at all.
            Section {
                HostDisclosureRow(title: "Connect by cable",
                                  detail: "Does not need this permission",
                                  action: onConnectByCable)
                HostDisclosureRow(title: "Capture on my own",
                                  detail: "Send to Studio later",
                                  action: onCaptureAlone)
            } header: {
                // The section header slot, wearing the eyebrow's face — this is
                // the header, not a hand-drawn label above the list.
                EyebrowLabel("Or carry on without it")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("iOS is blocking the local network")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom) {
            Button("Try again", action: onTryAgain)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
                .padding(.horizontal, PPMetrics.screenMargin)
                .padding(.top, PPMetrics.itemGap)
                .background(.bar)
        }
    }
}

// MARK: - Previews

#Preview("B6 · Local network blocked") {
    NavigationStack {
        LocalNetworkBlockedView(
            onOpenSettings: {},
            onConnectByCable: {},
            onCaptureAlone: {},
            onTryAgain: {}
        )
    }
    .preferredColorScheme(.dark)
}
