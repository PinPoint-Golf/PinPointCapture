//
//  SettingsView.swift
//  Behind the ⚙ on the status screen (#121): the few things a person still has
//  to do to a phone that is otherwise set down and left.
//
//  ⚠ Rows only, each a closure. The screen owns no navigation — `RootView`
//  decides where each row goes, as it does for every other screen.
//

import SwiftUI
import CaptureCore

public struct SettingsView: View {

    /// The Studio this phone is linked to right now, or `nil`. ⚠ 4.4d — display
    /// text, shown and never compared.
    private let connectedHostName: String?
    private let isLinked: Bool
    private let onPair: () -> Void
    private let onOpenRememberedStudios: () -> Void
    private let onDisconnect: () -> Void
    private let onOpenMicToBallDistance: () -> Void
    private let onDone: () -> Void

    public init(connectedHostName: String?,
                isLinked: Bool,
                onPair: @escaping () -> Void,
                onOpenRememberedStudios: @escaping () -> Void,
                onDisconnect: @escaping () -> Void,
                onOpenMicToBallDistance: @escaping () -> Void,
                onDone: @escaping () -> Void) {
        self.connectedHostName = connectedHostName
        self.isLinked = isLinked
        self.onPair = onPair
        self.onOpenRememberedStudios = onOpenRememberedStudios
        self.onDisconnect = onDisconnect
        self.onOpenMicToBallDistance = onOpenMicToBallDistance
        self.onDone = onDone
    }

    public var body: some View {
        List {
            Section {
                HostDisclosureRow(title: "Pair with a Studio",
                                  detail: "Scan the code Studio shows",
                                  systemImage: "qrcode.viewfinder",
                                  action: onPair)
                HostDisclosureRow(title: "Remembered Studios",
                                  systemImage: "list.bullet",
                                  action: onOpenRememberedStudios)
                // ⚠ Only while linked: disconnecting nothing is not an action.
                if isLinked {
                    HostDisclosureRow(title: "Disconnect",
                                      detail: connectedHostName.map { "From \($0)" },
                                      systemImage: "bolt.horizontal.circle",
                                      titleTone: .error,
                                      action: onDisconnect)
                }
            } header: {
                EyebrowLabel("Studio")
            }

            Section {
                HostDisclosureRow(title: "Phone to ball",
                                  detail: "Microphone distance, for timing",
                                  systemImage: "ruler",
                                  action: onOpenMicToBallDistance)
            } header: {
                EyebrowLabel("Placement")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone)
            }
        }
    }
}

// MARK: - Previews

#Preview("Settings · linked") {
    NavigationStack {
        SettingsView(connectedHostName: "Bay 3 — Mac Studio", isLinked: true,
                     onPair: {}, onOpenRememberedStudios: {}, onDisconnect: {},
                     onOpenMicToBallDistance: {}, onDone: {})
    }
    .preferredColorScheme(.dark)
}
