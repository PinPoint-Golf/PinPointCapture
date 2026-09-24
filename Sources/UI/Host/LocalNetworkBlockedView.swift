//
//  LocalNetworkBlockedView.swift
//  B6 — iOS is blocking the local network.
//
//  The failure that otherwise makes the app look permanently broken. iOS
//  exposes no API to read local-network permission back, so this state is
//  **inferred from connection failure** and presented as this screen rather
//  than as a generic error (REQ-DISC-6).
//
//  ⛔ **Online only (#121).** There is no capturing without a host any more, so
//  the old reassurance ("you can record all day like this") and the *Capture on
//  my own* route were false and are gone. What remains true: a cable does not
//  need this permission.
//

import SwiftUI
import CaptureCore

public struct LocalNetworkBlockedView: View {

    private let onOpenSettings: () -> Void
    /// `nil` hides the row. ⚠ There is no cable action to take from here — a
    /// wired link comes up by itself when the phone is plugged in — so the
    /// caller normally passes `nil` and the sentence below carries the advice.
    private let onConnectByCable: (() -> Void)?
    private let onTryAgain: () -> Void

    public init(
        onOpenSettings: @escaping () -> Void,
        onConnectByCable: (() -> Void)? = nil,
        onTryAgain: @escaping () -> Void
    ) {
        self.onOpenSettings = onOpenSettings
        self.onConnectByCable = onConnectByCable
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

                    Text("Without it this phone cannot reach Studio on Wi-Fi. A USB cable to the Mac does not need it.")
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

            // 3. The route that does not need the permission at all.
            if let onConnectByCable {
                Section {
                    HostDisclosureRow(title: "Connect by cable",
                                      detail: "Does not need this permission",
                                      action: onConnectByCable)
                } header: {
                    // The section header slot, wearing the eyebrow's face — this
                    // is the header, not a hand-drawn label above the list.
                    EyebrowLabel("Or carry on without it")
                }
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
            onTryAgain: {}
        )
    }
    .preferredColorScheme(.dark)
}
