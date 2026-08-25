//  PairingSecretStoreTests.swift
//  `PPCP-RV` §7.4 / §7.2c — the store, exercised for the first time.
//
//  ⛔ **These tests could not be written before erratum E56.** The store was the
//  Keychain, `PairingSecretStore` appeared in zero test files, and the whole of
//  §7.4's behaviour was covered only through the `HeldPairings` seam in
//  `ReconnectCoordinatorTests` — which deliberately never touched the real
//  store. E56 moved the secrets to a file this app owns, so the store itself is
//  now ordinary testable code, and `freeze-readiness`'s "RT-15's Keychain half"
//  gap stops being blocked on a phone and a backup.
//
//  ⚠ **What these do NOT prove.** That `isExcludedFromBackup` actually keeps a
//  pairing out of an iCloud restore — that needs a device and a restore, and it
//  is issue #67's exit criterion. What is asserted here is that the flag is set
//  on the file we wrote, which is the half that a code change can break silently
//  and the half that used to be free when `ThisDeviceOnly` carried it.

import Foundation
import Testing
import CaptureCore
@testable import PinPointCapture

@Suite("RV §7.4 — the pairing store", .serialized)
struct PairingSecretStoreTests {

    /// The §10.3 minimal vector: `mu = 1`, so 7.4f permits persistence.
    private static let singleUse =
        "ppcp:pWF2AWJlcIGiYWhsMTkyLjE2OC4xLjIwYXAZHmxibXUBY3Bza1AAAQIDBAUGBwgJCgsMDQ4PY3NpZFA_JQTgT4lB05oMAwXoLDMB"
    /// The same vector with `mu = 3`. ⛔ 7.4f forbids persisting this one.
    private static let multiUse =
        "ppcp:pWF2AWJlcIGiYWhsMTkyLjE2OC4xLjIwYXAZHmxibXUDY3Bza1AAAQIDBAUGBwgJCgsMDQ4PY3NpZFA_JQTgT4lB05oMAwXoLDMB"
    /// The same vector with one byte of `sid` changed, so two pairings can be
    /// held at once. ⚠ `mu = 1` as well — this is a *second Studio*, not a second
    /// device sharing a code.
    private static let otherSingleUse =
        "ppcp:pWF2AWJlcIGiYWhsMTkyLjE2OC4xLjIwYXAZHmxibXUBY3Bza1AAAQIDBAUGBwgJCgsMDQ4PY3NpZFA_JQTgT4lB05oMAwXoLDMC"
    private static let sessionId = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
    private static let otherSessionId = "3f2504e0-4f89-41d3-9a0c-0305e82c3302"

    /// A fresh directory per case, so nothing leaks between them.
    private func withTemporaryStore(_ body: () throws -> Void) rethrows {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ppcp-store-\(UUID().uuidString)", isDirectory: true)
        PairingSecretStore.directoryOverride = dir
        defer {
            PairingSecretStore.directoryOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        try body()
    }

    // MARK: 7.4b — visible and individually revocable, and no longer opt-in

    /// ⛔ **Two halves of 7.4b, not three.** *Opt-in* is declined as of 25 August
    /// 2026 (#96), which erratum E57 makes the application's decision to take;
    /// what is asserted here is what this app still owes: it can list what it
    /// holds, and it can remove one without removing the rest.
    @Test func savesListsAndRevokesIndividually() throws {
        try withTemporaryStore {
            let code = try PpcpPairingCode(uri: Self.singleUse)
            try PairingSecretStore.save(code: code, keys: try code.keys(),
                                        displayName: "Bay 3")

            let held = try PairingSecretStore.pairings()
            #expect(held.count == 1)
            #expect(held.first?.sessionId == Self.sessionId)
            #expect(held.first?.displayName == "Bay 3")

            // 5.1c — the keys re-derive from the stored `PRK`.
            let keys = try PairingSecretStore.keys(forSession: Self.sessionId)
            #expect(keys != nil)
            #expect(keys?.prk == (try code.keys()).prk)

            try PairingSecretStore.revoke(sessionId: Self.sessionId)
            #expect(try PairingSecretStore.pairings().isEmpty)
        }
    }

    /// ⛔ **A pairing that completed is kept, and nothing has to ask for it**
    /// (#96). ⚠ This test is the inverse of the one it replaces — which asserted
    /// that a save without consent threw `consentNotGiven` — and it is here as
    /// the guard on the *default*, which is the whole of the change. `RV` 7.4b is
    /// a SHOULD since erratum E57, so declining its opt-in half is a decision the
    /// application is entitled to take and this is where the decision is pinned.
    @Test func savesWithoutBeingAsked() throws {
        try withTemporaryStore {
            let code = try PpcpPairingCode(uri: Self.singleUse)
            try PairingSecretStore.save(code: code, keys: try code.keys(),
                                        displayName: nil)
            #expect(try PairingSecretStore.pairings().count == 1)
        }
    }

    /// ⛔ 7.4b's *individually revocable*, at the scale that matters to `RV` 3.4b:
    /// forgetting one Studio must leave the others resolvable and must take the
    /// forgotten one out of the resolver's table entirely. ⚠ A revoke that
    /// removed the row but left a derivable `K_id` behind would keep dialling a
    /// host the user believes they have forgotten.
    @Test func forgettingOneLeavesTheOthersResolvable() throws {
        try withTemporaryStore {
            let first = try PpcpPairingCode(uri: Self.singleUse)
            let second = try PpcpPairingCode(uri: Self.otherSingleUse)
            try PairingSecretStore.save(code: first, keys: try first.keys(),
                                        displayName: "Bay 3")
            try PairingSecretStore.save(code: second, keys: try second.keys(),
                                        displayName: "Bay 4")
            #expect(try PairingSecretStore.identityKeys().count == 2)

            try PairingSecretStore.revoke(sessionId: Self.sessionId)

            let held = try PairingSecretStore.pairings()
            #expect(held.count == 1)
            #expect(held.first?.sessionId == Self.otherSessionId)
            #expect(held.first?.displayName == "Bay 4")
            // 3.4b resolves an advertised `rid` against these. The forgotten
            // pairing must not be among them.
            let identities = try PairingSecretStore.identityKeys()
            #expect(identities.count == 1)
            #expect(identities.contains { $0.sessionId == Self.sessionId } == false)
            #expect(try PairingSecretStore.keys(forSession: Self.sessionId) == nil)
        }
    }

    /// 7.4f — a pairing from a code whose `mu` exceeded 1 is session-scoped,
    /// because every peer that scanned that code holds identical key material.
    /// ⛔ Nothing reaches the file.
    @Test func refusesAMultiUseCode() throws {
        try withTemporaryStore {
            let code = try PpcpPairingCode(uri: Self.multiUse)
            #expect(code.mayPersistPairing == false)
            #expect(throws: PairingSecretStore.StoreError.multiUseCodeMayNotBePersisted) {
                try PairingSecretStore.save(code: code, keys: try code.keys(),
                                            displayName: nil)
            }
            #expect(try PairingSecretStore.pairings().isEmpty)
        }
    }

    /// 7.4c — the counterpart identity is recorded once `hello` has disclosed it
    /// inside the authenticated channel, and binding it must not drop the rest
    /// of the row. ⚠ `bind` rewrites; the `PRK` and the network name survive it.
    @Test func bindRecordsTheCounterpartWithoutLosingTheRow() throws {
        try withTemporaryStore {
            let code = try PpcpPairingCode(uri: Self.singleUse)
            let keys = try code.keys()
            try PairingSecretStore.save(code: code, keys: keys,
                                        displayName: "Bay 3")
            try PairingSecretStore.bind(sessionId: Self.sessionId,
                                        toCounterpart: "peer:abc")

            let held = try PairingSecretStore.pairings()
            #expect(held.count == 1)
            #expect(held.first?.counterpartPeerId == "peer:abc")
            #expect(held.first?.displayName == "Bay 3")
            #expect(try PairingSecretStore.keys(forSession: Self.sessionId)?.prk == keys.prk)
        }
    }

    // MARK: 5.1c / 7.2b — what is on disk

    /// ⛔ **`PRK`, never `psk`.** The pairing secret from the code is used once,
    /// to derive, and is never written down — a persisted `psk` would be a
    /// second copy of the thing a photograph of the code already compromises.
    @Test func theFileHoldsThePrkAndNotThePairingSecret() throws {
        try withTemporaryStore {
            let code = try PpcpPairingCode(uri: Self.singleUse)
            let keys = try code.keys()
            try PairingSecretStore.save(code: code, keys: keys,
                                        displayName: nil)

            let url = PairingSecretStore.directoryOverride!
                .appendingPathComponent("pairings.json")
            let raw = try Data(contentsOf: url)

            // The §10.1 `psk` — 000102030405060708090a0b0c0d0e0f — must not be
            // anywhere in the file, in raw or base64 form.
            let psk = Data((0...15).map { UInt8($0) })
            #expect(raw.range(of: psk) == nil)
            #expect(raw.range(of: Data(psk.base64EncodedString().utf8)) == nil)
            // The `PRK` is there, which is what makes the absence above a real
            // assertion rather than a test of an empty file.
            #expect(raw.range(of: Data(keys.prk.base64EncodedString().utf8)) != nil)
        }
    }

    /// ⛔ 7.4c — *not transferable*, and after E56 this one flag is the whole of
    /// what keeps it true. An atomic write replaces the inode, so the flag has to
    /// be re-applied on every write; this asserts it survived one.
    @Test func theFileIsExcludedFromBackup() throws {
        try withTemporaryStore {
            let code = try PpcpPairingCode(uri: Self.singleUse)
            try PairingSecretStore.save(code: code, keys: try code.keys(),
                                        displayName: nil)
            // A second write, because the flag surviving the FIRST write proves
            // less than it looks: the failure mode is an atomic replace dropping
            // it on a later save.
            try PairingSecretStore.bind(sessionId: Self.sessionId,
                                        toCounterpart: "peer:abc")

            let url = PairingSecretStore.directoryOverride!
                .appendingPathComponent("pairings.json")
            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true)
        }
    }

    /// ⛔ *Erratum E56.* A store that cannot be read is **not** a store that is
    /// empty. Conflating the two is what reported "no pairings held" to a user
    /// who had one, and it is the defect the erratum was raised over.
    @Test func anUnreadableStoreThrowsRatherThanReadingAsEmpty() throws {
        try withTemporaryStore {
            let dir = PairingSecretStore.directoryOverride!
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
            try Data("this is not json".utf8)
                .write(to: dir.appendingPathComponent("pairings.json"))

            #expect(throws: (any Error).self) {
                _ = try PairingSecretStore.pairings()
            }
        }
    }

    /// 7.2d — `revokeAll` erases everything the store holds.
    @Test func revokeAllEmptiesTheStore() throws {
        try withTemporaryStore {
            let code = try PpcpPairingCode(uri: Self.singleUse)
            try PairingSecretStore.save(code: code, keys: try code.keys(),
                                        displayName: nil)
            #expect(try PairingSecretStore.pairings().count == 1)
            try PairingSecretStore.revokeAll()
            #expect(try PairingSecretStore.pairings().isEmpty)
        }
    }
}
