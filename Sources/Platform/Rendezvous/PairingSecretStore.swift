//  PairingSecretStore.swift
//  `PPCP-RV` §7.2c / §7.4 — where a pairing's key material lives, and what it
//  takes to keep it.
//
//  ⛔ **The Keychain, and only the Keychain** (7.2c: "secrets at rest are held in
//  the platform's protected storage where one exists"). Not `UserDefaults`, not a
//  file, not `@AppStorage`. `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is the
//  strongest class that still works for an app that has to reconnect on launch,
//  and `ThisDeviceOnly` is what stops a pairing riding an iCloud backup onto a
//  second phone — which 7.4c calls non-transferable in as many words.
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
//  Spec: `RV` §5.1c, §7.2b–d, §7.4. Plan D7.

import Foundation
import Security
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

    private static let service = "org.pinpointstudio.capture.ppcp.pairing"

    public enum StoreError: Error, Sendable, Equatable {
        /// 7.4f — `mu > 1`. ⛔ Not a failure to work around: the pairing is
        /// session-scoped by construction and there is nothing to persist.
        case multiUseCodeMayNotBePersisted
        /// 7.4b — persistence is **opt-in**. A save with no consent is a bug in
        /// the caller, not a default to fill in.
        case consentNotGiven
        case keychain(OSStatus)
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
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[CFString: Any]] else {
            throw StoreError.keychain(status)
        }
        return items.compactMap { item in
            guard let sessionId = item[kSecAttrAccount] as? String else { return nil }
            // ⚠ `kSecAttrLabel` carries the untrusted display name and
            // `kSecAttrComment` the counterpart id. Neither is key material and
            // neither is an identifier the store keys on.
            return StoredPairing(sessionId: sessionId,
                                 displayName: item[kSecAttrLabel] as? String,
                                 counterpartPeerId: item[kSecAttrComment] as? String,
                                 // 7.4h — `kSecAttrDescription`, and nothing in
                                 // this store holds a passphrase.
                                 networkName: item[kSecAttrDescription] as? String,
                                 savedAt: item[kSecAttrModificationDate] as? Date ?? .now)
        }
        .sorted { $0.savedAt > $1.savedAt }
    }

    // MARK: Revoking

    /// 7.4b/7.4d — revocation is honoured immediately by this side, and results
    /// in a failed handshake for the other. ⛔ There is no soft delete: the bytes
    /// go.
    public static func revoke(sessionId: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: sessionId
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    /// 7.2d — erases every pairing that was not persisted under 7.4. ⚠ Called
    /// when a session closes; a persisted pairing survives it by design.
    public static func revokeAll() throws {
        for pairing in try pairings() { try revoke(sessionId: pairing.sessionId) }
    }

    // MARK: The Keychain itself

    private struct Held {
        let prk: Data
        let displayName: String?
        /// 7.4h — carried so `bind` does not drop it on rewrite.
        let networkName: String?
    }

    private static func load(sessionId: String) throws -> Held? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: sessionId,
            kSecReturnData: true,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item = result as? [CFString: Any],
              let data = item[kSecValueData] as? Data else {
            throw StoreError.keychain(status)
        }
        return Held(prk: data, displayName: item[kSecAttrLabel] as? String,
                    networkName: item[kSecAttrDescription] as? String)
    }

    private static func write(sessionId: String, prk: Data, displayName: String?,
                              counterpartPeerId: String?,
                              networkName: String? = nil) throws {
        var attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: sessionId,
            kSecValueData: prk,
            // ⛔ 7.4c — not transferable. `ThisDeviceOnly` keeps it out of an
            // encrypted backup and off a restored second device; `WhenUnlocked`
            // is the strongest class an app that reconnects on launch can use.
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        if let displayName { attributes[kSecAttrLabel] = displayName }
        if let counterpartPeerId { attributes[kSecAttrComment] = counterpartPeerId }
        // 7.4h (E26) — the network NAME. ⛔ There is deliberately no branch here
        // for a passphrase: the field does not exist, so it cannot be filled in
        // by a later change that looked reasonable.
        if let networkName { attributes[kSecAttrDescription] = networkName }

        // Replace rather than update-or-add: a partial update that left an old
        // `PRK` behind would be a pairing that authenticates as something else.
        try? revoke(sessionId: sessionId)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }
}
