//  Rendezvous.swift
//  The `PPCP-RV` §5 key material, as Swift sees it.
//
//  ⚠ This file is thin on purpose. Every byte of arithmetic below happens in
//  `libppcp` (work package L12), which is the whole point of plan A5: the
//  derivation is specified once, tested once against the `RV` §10 vectors, and
//  the two applications bind to the same symbols rather than each growing an
//  HKDF. What Swift adds is a type that cannot be misused and a `Data` at each
//  end — nothing that could disagree with the C.
//
//  ⛔ `import CPPCP` is a C target, not a platform framework. `LayerPurityTests`
//  permits it by name and forbids everything it ever did; if that ever reads as
//  a loophole, read plan A5 again — substituting `libppcp` for these types is
//  the reason this package was kept platform-free in the first place.
//
//  ⛔ What is NOT here, and never will be (plan A7, A8): TLS, sockets, discovery,
//  storage. `libppcp` produces `K_tls` and the PSK identity; `Sources/Platform`
//  holds the socket. `RV` 5.2i is explicit that compliance on the device is
//  demonstrated by observed handshake, not by an API assertion.

import Foundation
import CPPCP

/// A call into `libppcp` that did not return `PPCP_OK`.
///
/// ⛔ `RV` 7.2b — the message comes from `ppcp_result_str`, which the library
/// documents as "stable, human-readable, and safe to log: no result code carries
/// payload". Nothing else about a failed derivation may be reported.
public struct PpcpLibraryError: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: Int32
    public let name: String

    init(_ result: ppcp_result) {
        self.code = Int32(result.rawValue)
        self.name = String(cString: ppcp_result_str(result))
    }

    public var description: String { "libppcp: \(name)" }
}

/// ⚠ Package-wide rather than file-private: `Ppcp/LinkBind.swift` calls into the
/// same library and must fail the same way. One translation from a
/// `ppcp_result` to a Swift error, so a caller can never be handed a raw code.
func check(_ result: ppcp_result) throws {
    guard result == PPCP_OK else { throw PpcpLibraryError(result) }
}

/// Which `libppcp` is linked, and which wire version it speaks.
///
/// ⚠ Two different things, deliberately not derived from one another: the wire
/// version is the protocol's (`CORE` §10.1) and the library version is this
/// build's. The About box wants both — a bug report that names one without the
/// other cannot be reproduced.
public enum PpcpLibrary {
    public static var version: String { String(cString: ppcp_library_version()) }
    public static var wireVersion: String { String(cString: ppcp_wire_version()) }
}

public extension PpcpKeyLengths {
    // ⚠ The same numbers, asked of the library rather than restated. `RV` §8
    // warns that getting a PSK parameter wrong "produces a handshake failure
    // with no useful diagnostic, indistinguishable from a key mismatch"; a
    // length that drifted from the C side would land exactly there, so the test
    // suite compares these two rather than trusting that 32 is still 32.
    //
    // ⛔ They are also the only reason anything outside this file needs to know
    // `CPPCP` exists — the import stays confined to one file, which is what
    // makes the layer-purity allowance a single line rather than a policy.
    static var libraryTlsKey: Int { Int(PPCP_RV_KEY_BYTES) }
    static var libraryPskIdentity: Int { Int(PPCP_RV_PSK_IDENTITY_BYTES) }
    static var libraryRandomBytes: Int { Int(PPCP_RV_RN_BYTES) }
}

// MARK: - Derivation (RV §5.1)

/// `PRK`, `K_tls` and `K_id`, derived from a scanned pairing code.
///
/// ```
/// PRK   = HKDF-Extract(salt = sid, IKM = psk)
/// K_tls = HKDF-Expand(PRK, "ppcp1 tls-psk",       32)
/// K_id  = HKDF-Expand(PRK, "ppcp1 rendezvous-id", 32)
/// ```
///
/// ⚠ The secret in the code is **never** used directly as a protocol key
/// (`RV` §5.1). Domain separation is what lets `rid` be published in the clear on
/// a range's multicast network without revealing anything about the handshake
/// key: `K_id` cannot complete a handshake, and observing millions of `rid`
/// values says nothing about `K_tls`.
///
/// ⛔ `RV` 5.1a/5.1b: each key has exactly one use and no other. ⛔ `RV` 7.2b: no
/// member of this type may reach a log, a crash report or a diagnostic export.
public struct RendezvousKeys: Sendable, CustomStringConvertible {
    /// `RV` 5.1c — this, and never the original `psk`, is what a peer persists.
    /// ⛔ 7.4f additionally forbids persisting it at all when the code's `mu`
    /// exceeded 1; that decision is D7's, and `libppcp` has the predicate.
    public let prk: Data
    /// `RV` 5.1a — the TLS external pre-shared key, and nothing else.
    public let tlsKey: Data
    /// `RV` 5.1b — the resolvable identifiers of §3.4 and §5.3, and nothing else.
    public let identityKey: Data

    /// - Parameters:
    ///   - psk: the pairing secret, 16 or 32 raw bytes (`RV` 7.2a: at least 128
    ///     bits from a CSPRNG — the publisher's obligation, not this one's).
    ///   - sid: the 16 raw bytes of the session UUID, used as the HKDF salt.
    public init(psk: Data, sid: Data) throws {
        var keys = ppcp_rv_keys()
        try check(sid.withUnsafeBytes { sidBytes in
            psk.withUnsafeBytes { pskBytes in
                ppcp_rv_derive(sidBytes.bindMemory(to: UInt8.self).baseAddress, sid.count,
                               pskBytes.bindMemory(to: UInt8.self).baseAddress, psk.count,
                               &keys)
            }
        })
        self.prk = withUnsafeBytes(of: keys.prk) { Data($0) }
        self.tlsKey = withUnsafeBytes(of: keys.k_tls) { Data($0) }
        self.identityKey = withUnsafeBytes(of: keys.k_id) { Data($0) }
    }

    /// `RV` 5.1c — reconnecting from a persisted pairing re-derives from `PRK`.
    public init(persistedPrk: Data) throws {
        guard persistedPrk.count == PpcpKeyLengths.tlsKey else {
            throw TransportError.invalidKeyLength(persistedPrk.count)
        }
        var keys = ppcp_rv_keys()
        try check(persistedPrk.withUnsafeBytes { prkBytes in
            ppcp_rv_derive_from_prk(prkBytes.bindMemory(to: UInt8.self).baseAddress, &keys)
        })
        self.prk = withUnsafeBytes(of: keys.prk) { Data($0) }
        self.tlsKey = withUnsafeBytes(of: keys.k_tls) { Data($0) }
        self.identityKey = withUnsafeBytes(of: keys.k_id) { Data($0) }
    }

    public var description: String { "RendezvousKeys(redacted)" }  // `RV` 7.2b
}

// MARK: - Credentials (RV §5.3)

/// Credentials that mint a **fresh** PSK identity for every connection.
///
/// `RV` 5.3a: `0x01 || rn2 || HMAC-SHA256(K_id, "ppcp1 psk-id" || rn2)[0..7]`,
/// with `rn2` eight CSPRNG bytes per connection. ⚠ The rotation is the point.
/// The identity travels in the clear in the `ClientHello`, so anything stable in
/// it is a tracking beacon — `RV` §5.3's own commentary describes Draft 1 putting
/// `sid` there and a persisted pairing then reusing it on every reconnection for
/// the life of the pairing, linking a user across two venues by a fixed sixteen
/// bytes. Nothing stable crosses (5.3e).
public struct RendezvousCredentials: PpcpCredentials {
    public let tlsKey: Data
    private let identityKey: Data
    private let randomBytes: @Sendable (Int) -> Data

    /// - Parameter randomBytes: ⚠ injectable **only** so the `RV` §10.2 vector can
    ///   be reproduced with its stated `rn2`. The default is
    ///   `SystemRandomNumberGenerator`, which is the platform CSPRNG.
    ///   ⛔ RT-12 is a *review* row because entropy quality produces no observable
    ///   difference on the wire — a peer using a predictable secret completes
    ///   exactly the same handshake as one using a good secret. Anything passed
    ///   here in shipping code must be read as carefully as the key itself.
    public init(keys: RendezvousKeys,
                randomBytes: @escaping @Sendable (Int) -> Data = RendezvousCredentials.systemRandom) {
        self.tlsKey = keys.tlsKey
        self.identityKey = keys.identityKey
        self.randomBytes = randomBytes
    }

    public static let systemRandom: @Sendable (Int) -> Data = { count in
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        while bytes.count < count {
            withUnsafeBytes(of: generator.next()) { bytes.append(contentsOf: $0) }
        }
        return Data(bytes.prefix(count))
    }

    public func nextPskIdentity() throws -> Data {
        let rn2 = randomBytes(Int(PPCP_RV_RN_BYTES))
        guard rn2.count == Int(PPCP_RV_RN_BYTES) else {
            throw TransportError.invalidIdentityLength(rn2.count)
        }
        var identity = [UInt8](repeating: 0, count: Int(PPCP_RV_PSK_IDENTITY_BYTES))
        try check(identityKey.withUnsafeBytes { keyBytes in
            rn2.withUnsafeBytes { rnBytes in
                ppcp_rv_psk_identity(keyBytes.bindMemory(to: UInt8.self).baseAddress,
                                     rnBytes.bindMemory(to: UInt8.self).baseAddress,
                                     &identity)
            }
        })
        // ⛔ `RV` 5.3f — returned as bytes. No transcoding, no UTF-8 validation,
        // no truncation, here or anywhere downstream of here.
        return Data(identity)
    }
}
