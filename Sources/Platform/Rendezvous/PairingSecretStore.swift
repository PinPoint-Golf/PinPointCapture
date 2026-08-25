//  PairingSecretStore.swift
//  `PPCP-RV` §7.2c / §7.4 — where a pairing's key material lives, and what it
//  takes to keep it.
//
//  ⛔ **A file this app owns, and NOT the Keychain** — *erratum E56, 25 August
//  2026, which made 7.2c a SHOULD.* It was the Keychain until then, because 7.2c
//  was a MUST. Two things were wrong with that. The specification was deciding
//  how a consuming application spends a platform permission, which its own §1.3
//  lists as out of scope; and `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` —
//  the class this file used — is **unreadable while the phone is locked**, so
//  the reconnection sweep read nothing and reported *no pairings held*, which is
//  a different statement and an untrue one.
//
//  ⛔ **`isExcludedFromBackup`, and it is re-applied on every write.** This is
//  the whole of what keeps 7.4c's *not transferable* true, and it is load-bearing
//  in a way the Keychain made free: `ThisDeviceOnly` used to stop a pairing
//  riding an encrypted backup onto a second phone, and ordinary app storage does
//  not. An atomic write replaces the inode, so the flag does not survive one —
//  hence `exclude(_:)` after each save rather than once at creation.
//
//  ⛔ **`completeUntilFirstUserAuthentication`, deliberately not `complete`.**
//  `.complete` would reintroduce the exact locked-device failure E56 was raised
//  over. This class is readable after the first unlock following a boot, which is
//  what a peer that reconnects in the background needs.
//
//  ⚠ **What this gives up, stated rather than assumed away.** The file is
//  readable by this app and by anything that can read its container. `RV` §7.4's
//  own words — *possession of the device's storage is possession of continuing
//  access* — were written when this was a keychain and should be read at the
//  stronger meaning now. 7.4b's opt-in, visible, individually revocable
//  persistence is what remains, and it is now the load-bearing control rather
//  than the weaker half of a pair.
//
//  ⛔ **`PRK`, never `psk`** (5.1c). The pairing secret from the code is used once,
//  to derive, and is never written down: every key a session needs re-expands
//  from `PRK`, and a persisted `psk` would be a second copy of the thing a
//  photograph of the code already compromises.
//
//  ⛔ **7.4f is enforced here and not remembered elsewhere.** A pairing from a
//  code whose `mu` exceeded 1 is session-scoped, because every peer that scanned
//  that code holds identical key material — `save` refuses it and takes the
//  predicate from `ppcp_rv_may_persist` rather than re-deriving it.
//
//  ⚠ **7.4b — opt-in, visible, individually revocable.** The three are one
//  requirement: a store that persisted by default, or that could not list what it
//  held, or that could only be cleared wholesale, would meet none of it. Hence
//  `save(_:consent:)`, `pairings()` and `revoke(_:)`.
//
//  Spec: `RV` §5.1c, §7.2b–d, §7.4, erratum E56. Plan D7.

import Foundation
import CaptureCore

/// One persisted pairing, as a screen sees it.
///
/// ⛔ Carries no key material. 7.2b keeps a derived key out of a log, a crash
/// report and a diagnostic export, and a list a screen renders is on the way to
/// all three.
public struct StoredPairing: Sendable, Hashable, Identifiable {
    /// The Session the pairing was established for — `RV` 4.3e's canonical UUID
    /// text, which is `Session.id`.
    public let sessionId: String
    /// 4.4d — untrusted display text from the code, kept only to show which
    /// pairing a user is revoking. ⛔ **Never an identifier and never a key**: the
    /// identity is `sessionId`.
    public let displayName: String?
    /// 7.4c — the counterpart `Peer.id` learned **inside** the authenticated
    /// channel. `nil` until a `hello` has arrived on it.
    public let counterpartPeerId: String?
    /// `RV` 7.4h (erratum E26) — the **network name** from the code that created
    /// this pairing, and nothing else from it.
    ///
    /// ⛔ **The passphrase is never here and there is no field for it.** A network
    /// name is broadcast by the access point and is not a secret; a passphrase is,
    /// which is exactly where E26 puts the line. 4.4c otherwise forbids retaining
    /// any of a decoded payload, and 7.4h scopes that to this one field.
    ///
    /// ⛔ **It is a hint offered to the USER, never an instruction to rejoin.** 6a
    /// is unchanged: this peer does not join a network on its own, and holding no
    /// passphrase it could not. Without it §7.4's whole workflow failed at the one
    /// venue it was written for — a range with its own network, where a persisted
    /// pairing was useless because the device could no longer name the network the
    /// host is on (F-D7-3).
    public let networkName: String?
    public let savedAt: Date

    public var id: String { sessionId }
}

public enum PairingSecretStore {

    public enum StoreError: Error, Sendable, Equatable {
        /// 7.4f — `mu > 1`. ⛔ Not a failure to work around: the pairing is
        /// session-scoped by construction and there is nothing to persist.
        case multiUseCodeMayNotBePersisted
        /// 7.4b — persistence is **opt-in**. A save with no consent is a bug in
        /// the caller, not a default to fill in.
        case consentNotGiven
        /// The store could not be read or written. ⚠ Never swallowed into
        /// "nothing is held": E56 exists because those two were confused.
        case storage(String)
    }

    // MARK: Saving

    /// Persists a pairing's `PRK`.
    ///
    /// - Parameter consent: 7.4b. ⛔ The user's, obtained on a screen that said
    ///   what it means — "possession of the device's storage is possession of
    ///   continuing access" (§7.4's own words).
    public static func save(code: PpcpPairingCode,
                            keys: RendezvousKeys,
                            displayName: String?,
                            consent: Bool) throws {
        guard consent else { throw StoreError.consentNotGiven }
        // ⛔ The library's predicate, not a re-reading of `mu`.
        guard code.mayPersistPairing else {
            throw StoreError.multiUseCodeMayNotBePersisted
        }
        // ⛔ 7.4h (erratum E26) — the **name** and never `wifi.k`. The passphrase
        // is not read here, is not passed on, and has nowhere to be stored.
        try write(sessionId: code.sessionId, prk: keys.prk, displayName: displayName,
                  counterpartPeerId: nil, networkName: code.network?.ssid)
    }

    /// `RV` 11.6e / 11.5g — a pairing established by **guided pairing** rather
    /// than by a scanned code.
    ///
    /// ⛔ **11.1a is why this is a second entrance and not a second mechanism.**
    /// From 11.6e onward the pairing is *indistinguishable* from one a code
    /// established: the same `PRK`, so §5, §7.4 and §7.5 apply verbatim and are
    /// unchanged by §11. What differs is only what may be *said* about it —
    /// `mayPersistPairing` has no meaning here because there is no code and no
    /// `mu` (7.4f), and there is no network to name because 11.10a forbids one
    /// crossing a bootstrap connection.
    ///
    /// ⛔ **5.1c is satisfied by construction**: there is no original secret to
    /// persist, only an ephemeral one that 11.6f has already erased. What is
    /// written is `PRK` and nothing else, exactly as the code path writes.
    ///
    /// ⚠ 7.4b — consent is still required and still starts off. A pairing the
    /// user did not ask to keep is one they cannot remember agreeing to.
    public static func save(guidedPairing pairing: BootstrapPairing,
                            displayName: String?,
                            consent: Bool) throws {
        guard consent else { throw StoreError.consentNotGiven }
        // ⛔ 11.10a — no `Peer.id`, no device or user name and no network crossed
        // the bootstrap connection, so there is nothing here to record for them.
        // `Peer.id` is first disclosed in `hello`, inside TLS, after the pairing
        // exists (7.6b), and `bind(sessionId:toCounterpart:)` is where it lands.
        try write(sessionId: pairing.sessionId, prk: pairing.keys.prk,
                  displayName: displayName, counterpartPeerId: nil,
                  networkName: nil)
    }

    /// 7.4c — records the counterpart identity once `hello` has disclosed it
    /// inside the authenticated channel. ⛔ A pairing scoped to nobody is a
    /// pairing scoped to anybody.
    public static func bind(sessionId: String, toCounterpart peerId: String) throws {
        guard let existing = try load(sessionId: sessionId) else { return }
        try write(sessionId: sessionId, prk: existing.prk,
                  displayName: existing.displayName, counterpartPeerId: peerId,
                  networkName: existing.networkName)
    }

    // MARK: Reading

    /// The `K_id` of every held pairing, for `RV` 3.4b's resolver.
    ///
    /// ⚠ Re-derived from `PRK` on each call rather than stored: 5.1c says a peer
    /// persists `PRK` and derives from it, and a second copy of `K_id` at rest is
    /// a second thing to leak for no gain.
    public static func identityKeys() throws -> [(sessionId: String, identityKey: Data)] {
        try pairings().compactMap { pairing in
            guard let held = try load(sessionId: pairing.sessionId) else { return nil }
            let keys = try RendezvousKeys(persistedPrk: held.prk)
            return (pairing.sessionId, keys.identityKey)
        }
    }

    /// The keys for one pairing, re-derived from its `PRK` (5.1c).
    public static func keys(forSession sessionId: String) throws -> RendezvousKeys? {
        guard let held = try load(sessionId: sessionId) else { return nil }
        return try RendezvousKeys(persistedPrk: held.prk)
    }

    /// 7.4b — what a settings screen lists so each one can be revoked.
    public static func pairings() throws -> [StoredPairing] {
        try rows().map {
            StoredPairing(sessionId: $0.sessionId,
                          displayName: $0.displayName,
                          counterpartPeerId: $0.counterpartPeerId,
                          // 7.4h — the network NAME, and nothing in this store
                          // holds a passphrase.
                          networkName: $0.networkName,
                          savedAt: $0.savedAt)
        }
        .sorted { $0.savedAt > $1.savedAt }
    }

    // MARK: Revoking

    /// 7.4b/7.4d — revocation is honoured immediately by this side, and results
    /// in a failed handshake for the other. ⛔ There is no soft delete: the bytes
    /// go.
    public static func revoke(sessionId: String) throws {
        try mutate { $0.removeAll { $0.sessionId == sessionId } }
    }

    /// 7.2d — erases every pairing that was not persisted under 7.4. ⚠ Called
    /// when a session closes; a persisted pairing survives it by design.
    public static func revokeAll() throws {
        try mutate { $0.removeAll() }
    }

    // MARK: The file itself

    private struct Held {
        let prk: Data
        let displayName: String?
        /// 7.4h — carried so `bind` does not drop it on rewrite.
        let networkName: String?
    }

    /// One pairing as it sits on disk.
    ///
    /// ⚠ The field names are the on-disk format. Renaming one silently orphans
    /// every pairing already stored, which presents as "the phone forgot the
    /// host" — the failure E56 was raised over, reintroduced by a refactor.
    private struct Row: Codable {
        let sessionId: String
        let prk: Data
        let displayName: String?
        let counterpartPeerId: String?
        let networkName: String?
        let savedAt: Date
    }

    /// ⚠ Serialises read-modify-write. The Keychain did this for us; a file does
    /// not, and `bind` racing a `save` would drop one of the two.
    private static let lock = NSLock()

    /// ⚠ **Tests only, and internal rather than public for that reason.** The
    /// real store is one file in Application Support; a suite that wrote there
    /// would share it across every case and leak state between them.
    nonisolated(unsafe) internal static var directoryOverride: URL?

    private static var directory: URL {
        get throws {
            if let directoryOverride { return directoryOverride }
            let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil,
                                                   create: true)
            return base.appendingPathComponent("PPCP", isDirectory: true)
        }
    }

    private static var fileURL: URL {
        get throws { try directory.appendingPathComponent("pairings.json") }
    }

    /// ⛔ 7.4c — the one call that keeps a pairing off a restored second device.
    /// Applied to the directory once and to the file after **every** write,
    /// because an atomic write replaces the inode and the flag with it.
    private static func exclude(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static func rows() throws -> [Row] {
        lock.lock(); defer { lock.unlock() }
        return try rowsLocked()
    }

    private static func rowsLocked() throws -> [Row] {
        let url: URL
        do { url = try fileURL } catch { throw StoreError.storage("\(error)") }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            if data.isEmpty { return [] }
            return try JSONDecoder().decode([Row].self, from: data)
        } catch {
            // ⛔ Not `[]`. A store we cannot read is not a store that is empty,
            // and conflating the two is precisely what reported "no pairings
            // held" to a user who had one.
            throw StoreError.storage("\(error)")
        }
    }

    private static func mutate(_ change: (inout [Row]) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var rows = try rowsLocked()
        change(&rows)
        let url: URL
        do {
            let dir = try directory
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir,
                                                        withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            exclude(dir)
            url = try fileURL
        } catch { throw StoreError.storage("\(error)") }

        do {
            let data = try JSONEncoder().encode(rows)
            #if os(iOS)
            // ⛔ NOT `.completeFileProtection` — that is the locked-device
            // failure E56 was raised over. This class is readable after the
            // first unlock since boot, which is what a background reconnection
            // sweep needs.
            try data.write(to: url, options: [.atomic,
                                              .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: [.atomic])
            #endif
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
            exclude(url)
        } catch { throw StoreError.storage("\(error)") }
    }

    private static func load(sessionId: String) throws -> Held? {
        guard let row = try rows().first(where: { $0.sessionId == sessionId }) else {
            return nil
        }
        return Held(prk: row.prk, displayName: row.displayName,
                    networkName: row.networkName)
    }

    private static func write(sessionId: String, prk: Data, displayName: String?,
                              counterpartPeerId: String?,
                              networkName: String? = nil) throws {
        // Replace rather than update in place: a partial update that left an old
        // `PRK` behind would be a pairing that authenticates as something else.
        try mutate { rows in
            rows.removeAll { $0.sessionId == sessionId }
            rows.append(Row(sessionId: sessionId, prk: prk,
                            displayName: displayName,
                            counterpartPeerId: counterpartPeerId,
                            networkName: networkName,
                            savedAt: Date()))
        }
    }
}
