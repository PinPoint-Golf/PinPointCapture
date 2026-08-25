//
//  RememberedStudiosView.swift
//  B3a — Remembered Studios.
//
//  ⛔ **`RV` 7.4b's *individually revocable*, which this application has never
//  actually offered.** `PairingSecretStore.pairings()` and `revoke(_:)` were both
//  written under D7, both correct, and **neither had a caller** — the same shape
//  `RendezvousTeardownTests` was written to warn about, and the conformance
//  document asserted the clause as met throughout. This screen is the caller.
//
//  ⚠ **It matters more now than when 7.4b was a MUST.** Erratum E57 (25 August
//  2026) made 7.4b a SHOULD, and named the edge: what it removes is any
//  requirement that a means of revoking *exists*, while 7.4a gives a persisted
//  pairing **no expiry**. A conformant peer may therefore hold a pairing its user
//  can neither see nor end, for ever. This application declines 7.4b's *opt-in*
//  half — pairing now remembers by default (#96) — which is exactly why it must
//  keep the other half rather than let it lapse with the requirement.
//
//  ⛔ **Forgetting is the deliberate act, so it is spelled out and confirmed.**
//  Not a swipe alone: a swipe is a gesture a user discovers, and the whole point
//  of the reversed default is that this is the control they are looking for.
//
//  ⚠ **`displayName` is untrusted text** (4.4d) — it came from a code before
//  anything was authenticated, and `PpcpPairingCode` has already escaped and
//  truncated it. It names a row so a user knows what they are removing; it is
//  never an identifier, and the identity is `sessionId`.
//
//  ⚠ **The network name is a hint offered to a person, never an instruction**
//  (7.4h, erratum E26). There is no passphrase in the store and no field for one,
//  and this device does not rejoin a network on its own (6a).
//
//  Spec: `RV` §7.4, errata E26, E56, E57. Issue #96.
//

import SwiftUI
import CaptureCore

public struct RememberedStudiosView: View {

    /// Newest first — `PairingSecretStore.pairings()` already sorts.
    private let pairings: [StoredPairing]
    private let onForget: (StoredPairing) -> Void
    private let onDone: () -> Void

    /// The pairing a confirmation is open for. ⛔ Held by `sessionId` rather than
    /// by index: the list is re-read after every removal.
    @State private var confirming: StoredPairing?

    public init(pairings: [StoredPairing],
                onForget: @escaping (StoredPairing) -> Void,
                onDone: @escaping () -> Void = {}) {
        self.pairings = pairings
        self.onForget = onForget
        self.onDone = onDone
    }

    public var body: some View {
        List {
            if pairings.isEmpty {
                emptySection
            } else {
                Section {
                    ForEach(pairings) { pairing in
                        row(for: pairing)
                    }
                } header: {
                    EyebrowLabel("Studios this phone can reconnect to")
                } footer: {
                    // §7.4's own words, in a golfer's. ⛔ The cost is stated
                    // rather than assumed away.
                    Text("Each of these can be reconnected to without a new code. "
                         + "Anyone with this phone's storage keeps that access "
                         + "until it is forgotten here.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("Remembered Studios")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone)
            }
        }
        .confirmationDialog(
            confirming.map { "Forget \(Self.name(of: $0))?" } ?? "",
            isPresented: Binding(get: { confirming != nil },
                                 set: { if $0 == false { confirming = nil } }),
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                if let confirming { onForget(confirming) }
                confirming = nil
            }
            Button("Keep", role: .cancel) { confirming = nil }
        } message: {
            // ⚠ 7.4d — revocation is honoured immediately by this side and the
            // other end's handshake then fails. Said plainly, because the remedy
            // (scan a new code) is the thing the user needs to know.
            Text("The next session will need a new pairing code from Studio.")
        }
    }

    // MARK: - Rows

    private func row(for pairing: StoredPairing) -> some View {
        HStack(spacing: PPMetrics.itemGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.name(of: pairing))
                    .font(.ppRowLabel)
                    .foregroundStyle(Color(.label))
                Text(detail(for: pairing))
                    .font(.ppFootnote)
                    .foregroundStyle(Color(.secondaryLabel))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Forget") { confirming = pairing }
                .font(.ppSupporting)
                .foregroundStyle(Color.ppError)
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Forget \(Self.name(of: pairing))"))
        }
        .frame(minHeight: PPMetrics.Size.minimumTapTarget)
        // ⚠ The swipe as well as the button — one for the user who knows the
        // gesture, one for the user who is looking for the control.
        .swipeActions(edge: .trailing) {
            Button("Forget", role: .destructive) { confirming = pairing }
        }
    }

    private var emptySection: some View {
        Section {
            InfoCard("Pair with Studio once and it will appear here, so the next "
                     + "session needs no code.",
                     title: "No Studios remembered")
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Text

    /// ⚠ 4.4d — untrusted, and it may be absent entirely (guided pairing carries
    /// no name across the bootstrap connection, 11.10a).
    private static func name(of pairing: StoredPairing) -> String {
        pairing.displayName ?? "A Studio"
    }

    /// "Remembered 25 Aug · network PinPoint-Bay3".
    private func detail(for pairing: StoredPairing) -> String {
        let day = pairing.savedAt.formatted(.dateTime.day().month(.abbreviated))
        guard let network = pairing.networkName else { return "Remembered \(day)" }
        return "Remembered \(day) · network \(network)"
    }
}

// MARK: - Previews

#Preview("B3a · Remembered Studios") {
    NavigationStack {
        RememberedStudiosView(
            pairings: [
                StoredPairing(sessionId: "8f14e45f-ceea-467a-9f2a-1b2c3d4e5f60",
                              displayName: "Bay 3 — Mac Studio",
                              counterpartPeerId: "peer-1",
                              networkName: "PinPoint-Bay3",
                              savedAt: Date(timeIntervalSince1970: 1_756_000_000)),
                StoredPairing(sessionId: "1c383cd3-0b0f-4a1f-8f1e-2a3b4c5d6e7f",
                              displayName: nil,
                              counterpartPeerId: nil,
                              networkName: nil,
                              savedAt: Date(timeIntervalSince1970: 1_755_000_000))
            ],
            onForget: { _ in })
    }
    .preferredColorScheme(.dark)
}

#Preview("B3a · Nothing remembered") {
    NavigationStack {
        RememberedStudiosView(pairings: [], onForget: { _ in })
    }
    .preferredColorScheme(.dark)
}
