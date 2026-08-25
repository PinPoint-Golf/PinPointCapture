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
/// ⛔ **And the call that produced it** (#98). `ppcp_result_str` answers eleven
/// words — "output buffer too small" — that are true of about thirty call sites
/// in this package. That sentence reached a golfer's capture screen on 25 August
/// 2026 as the entire explanation of why nothing was being recorded, and finding
/// out which call it came from took a day of bisection that the call site's own
/// name would have answered immediately. `#function` and `#fileID` cost nothing
/// and are filled in by the compiler at each `check`.
public struct PpcpLibraryError: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: Int32
    public let name: String
    /// Where the failing call was made. ⚠ Never part of `==` — see below.
    public let site: String

    init(_ result: ppcp_result,
         function: String = #function, file: String = #fileID, line: Int = #line) {
        self.code = Int32(result.rawValue)
        self.name = String(cString: ppcp_result_str(result))
        // `#fileID` is "Module/File.swift"; the module is the same for every one
        // of these and only lengthens a line a user may end up reading.
        let fileName = file.split(separator: "/").last.map(String.init) ?? file
        self.site = "\(function), \(fileName):\(line)"
    }

    /// ⛔ **`code` alone.** Two failures of the same kind from two call sites are
    /// the same failure, and a comparison that said otherwise would make every
    /// existing `==` against a `PpcpLibraryError` depend on a line number — which
    /// is a test that breaks when a comment above it grows.
    public static func == (a: Self, b: Self) -> Bool { a.code == b.code }

    public func hash(into hasher: inout Hasher) { hasher.combine(code) }

    public var description: String { "libppcp: \(name) (\(site))" }
}

/// ⚠ Package-wide rather than file-private: `Ppcp/LinkBind.swift` calls into the
/// same library and must fail the same way. One translation from a
/// `ppcp_result` to a Swift error, so a caller can never be handed a raw code.
///
/// ⚠ The three defaulted parameters are filled in by the compiler at the *call
/// site*, which is the whole point — passing them explicitly would name this
/// function instead, and every error would say `check, Rendezvous.swift:63`.
func check(_ result: ppcp_result,
           function: String = #function, file: String = #fileID,
           line: Int = #line) throws {
    guard result == PPCP_OK else {
        throw PpcpLibraryError(result, function: function, file: file, line: line)
    }
}

/// Which `libppcp` is linked, and which wire version it speaks.
///
/// ⚠ Two different things, deliberately not derived from one another: the wire
/// version is the protocol's (`CORE` §10.1) and the library version is this
/// build's. The About box wants both — a bug report that names one without the
/// other cannot be reproduced.
public enum PpcpLibrary {
    public static var version: String { String(cString: ppcp_library_version()) }
    /// The wire version token, `ppcp/MAJOR.MINOR` — what `hello.versions` and
    /// `Peer.protocol_version` carry.
    ///
    /// ⛔ **Not what `pv` carries.** See `wireVersionRange`.
    public static var wireVersion: String { String(cString: ppcp_wire_version()) }

    /// `CORE` 10.1b's `MAJOR` and `MINOR`, from the library's own macros rather
    /// than by splitting a string.
    public static var wireMajor: Int { Int(PPCP_WIRE_VERSION_MAJOR) }
    public static var wireMinor: Int { Int(PPCP_WIRE_VERSION_MINOR) }

    /// `RV` 3.3d (erratum E25) — this peer's `pv`, as a **version range**.
    ///
    /// ⛔ **This is `1.0`, and it is NOT `ppcp/1.0`.** Found by adopting E25:
    /// `DiscoveryAdvertisement` defaulted `pv` to `PpcpLibrary.wireVersion`,
    /// which is the wire *token* `ppcp/1.0`. 3.3d says each endpoint of a range
    /// is `MAJOR.MINOR` as `CORE` 10.1b defines it, so `ppcp/1.0` is not a range
    /// at all and a conformant browser is required to **ignore** an
    /// advertisement carrying it. This peer was publishing a record another
    /// implementation must discard, and nothing before E25 could have said so —
    /// the syntax was defined nowhere, which is exactly why the erratum exists.
    /// F-S5-5.
    ///
    /// ⚠ The two are different strings deliberately: `hello` offers a token in
    /// preference order, a TXT record describes a supported range in a 200-byte
    /// budget (3.3e).
    public static var wireVersionRange: String { "\(wireMajor).\(wireMinor)" }
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

    /// ⛔ **`ppcp_rv_psk_identity_draw`, not `ppcp_rv_psk_identity`** — `RV` 5.3a1
    /// (erratum E21), and this is a live connection.
    ///
    /// **No octet of the identity may be `0x00`.** Several widely-used TLS stacks
    /// carry a PSK identity as a C string and take its length with `strlen`: an
    /// embedded zero truncates it, the server resolves nothing, and the handshake
    /// fails **intermittently** — roughly one connection in sixteen, because
    /// seventeen octets each have a 1-in-256 chance of being zero. At a driving
    /// range that is diagnosed as a network fault and never as this.
    ///
    /// The draw is rejection sampling: it re-draws `rn2` until neither it nor the
    /// computed tag contains a zero, at an average cost of 1.07 HMACs, and leaves
    /// `rn2` with more than 63 bits of entropy. ⚠ `ppcp_rv_psk_identity` is
    /// deliberately *not* fixed and stays reachable, because `RV` §10.2's test
    /// vector must still reproduce byte for byte from its stated `rn2`; it is
    /// simply the wrong entry point for a socket.
    public func nextPskIdentity() throws -> Data {
        var identity = [UInt8](repeating: 0, count: Int(PPCP_RV_PSK_IDENTITY_BYTES))
        var rn2 = [UInt8](repeating: 0, count: Int(PPCP_RV_RN_BYTES))
        // ⚠ The CSPRNG stays the embedding's, which is what makes the §10.2
        // vector reproducible and what `rv.h` asks for: a library calling
        // `rand()` would be the single point at which the whole model fails
        // silently. The library owns only the rejection rule.
        let source = randomBytes
        var context = RandomContext(draw: source)
        try withUnsafeMutablePointer(to: &context) { ctx in
            try check(identityKey.withUnsafeBytes { keyBytes in
                ppcp_rv_psk_identity_draw(
                    keyBytes.bindMemory(to: UInt8.self).baseAddress,
                    { raw, out, len in
                        guard let raw, let out else { return false }
                        let context = raw.assumingMemoryBound(to: RandomContext.self)
                        let bytes = context.pointee.draw(len)
                        guard bytes.count == len else { return false }
                        bytes.copyBytes(to: out, count: len)
                        return true
                    },
                    UnsafeMutableRawPointer(ctx), &rn2, &identity)
            })
        }
        // ⛔ `RV` 5.3f — returned as bytes. No transcoding, no UTF-8 validation,
        // no truncation, here or anywhere downstream of here.
        return Data(identity)
    }

    /// A box for the closure, so it survives the trip through a C `void *`.
    /// ⚠ A `@convention(c)` callback captures nothing, which is the whole reason
    /// this exists.
    private struct RandomContext {
        let draw: @Sendable (Int) -> Data
    }
}
