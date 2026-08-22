//  RendezvousTests.swift
//  `PPCP-RV` §10 through the real library, on the host, with no simulator.
//
//  ⚠ These vectors are the specification's own, and `RV` 9c makes reproducing
//  them a condition of claiming RV conformance. They are asserted here rather
//  than in the app target because the derivation has nothing to do with a
//  socket: `libppcp` computes it, `swift test` runs it in milliseconds, and the
//  app-target suite is left to the one thing only a simulator can answer.

import Foundation
import Testing
@testable import CaptureCore

@Suite("PPCP-RV derivation")
struct RendezvousTests {

    /// D0's proof of link: a call into the C library that returns something only
    /// the C library knows. If this fails to compile, the package dependency is
    /// wrong; if it fails to link, the target is.
    @Test("libppcp is linked and says which protocol it speaks")
    func theLibraryIsLinked() {
        #expect(PpcpLibrary.version.isEmpty == false)
        // `CORE` §10.1 — the wire version, which is the protocol's and not this
        // build's, and the two are deliberately not derived from one another.
        #expect(PpcpLibrary.wireVersion == "ppcp/1.0")
    }

    /// ⚠ The Swift-side constants and the C-side ones must be the same numbers,
    /// and the cheapest place to find out that they are not is here rather than
    /// in a handshake that fails with no useful diagnostic (`RV` §8 warns about
    /// exactly that class of failure).
    @Test("The byte lengths agree with the library's")
    func lengthsAgree() {
        #expect(PpcpKeyLengths.tlsKey == PpcpKeyLengths.libraryTlsKey)
        #expect(PpcpKeyLengths.pskIdentity == PpcpKeyLengths.libraryPskIdentity)
        #expect(PpcpKeyLengths.libraryRandomBytes == 8)
    }

    /// **RT-1** — `RV` §10.1 reproduces byte for byte.
    @Test("RV 10.1: PRK, K_tls and K_id reproduce byte for byte")
    func derivationVectors() throws {
        let keys = try RendezvousKeys(psk: RvVectors.psk, sid: RvVectors.sid)
        #expect(keys.prk.hex == "d8a961d30def2e84bd930aa64fe8c9583286281ae0f61baa0116a8220bf6bcf9")
        #expect(keys.tlsKey.hex == "2b0c55242ac1075eef80f548a7b39976b1cc2b88fbb6d609e5f3cd20f36d7fd4")
        #expect(keys.identityKey.hex == "fd2d8fcfb1be76f83ca1d551e8d5ab34a2fbe3a76f048acb09c64c1d20646117")
    }

    /// `RV` 5.1c — a persisted pairing holds `PRK` and re-derives from it, never
    /// the original `psk`. Both routes must land on the same two keys or a
    /// reconnection from storage fails a handshake for no visible reason.
    @Test("Re-deriving from a persisted PRK gives the same keys")
    func persistedPrkRoundTrips() throws {
        let fresh = try RendezvousKeys(psk: RvVectors.psk, sid: RvVectors.sid)
        let restored = try RendezvousKeys(persistedPrk: fresh.prk)
        #expect(restored.tlsKey == fresh.tlsKey)
        #expect(restored.identityKey == fresh.identityKey)
    }

    /// **RT-14, static half** — `RV` §10.2's PSK identity, with its stated `rn2`.
    @Test("RV 10.2: the 17-octet PSK identity reproduces byte for byte")
    func pskIdentityVector() throws {
        let keys = try RendezvousKeys(psk: RvVectors.psk, sid: RvVectors.sid)
        let credentials = RendezvousCredentials(keys: keys, randomBytes: { _ in RvVectors.rn2 })
        let identity = try credentials.nextPskIdentity()
        #expect(identity.count == 17)
        #expect(identity.hex == "010f1e2d3c4b5a6978b355ada60b4b5aa8")
        // ⛔ 5.3e — nothing stable across connections. `sid` in particular.
        #expect(identity.range(of: RvVectors.sid) == nil)
    }

    /// **RT-14, rotation half** — `RV` 5.3a: fresh per connection. The identity
    /// crosses in the clear in the `ClientHello`, so a stable one is a tracking
    /// beacon; this is the assertion that the default source is actually used.
    @Test("The identity differs on every connection")
    func identityRotates() throws {
        let keys = try RendezvousKeys(psk: RvVectors.psk, sid: RvVectors.sid)
        let credentials = RendezvousCredentials(keys: keys)
        var seen = Set<Data>()
        for _ in 0..<64 { seen.insert(try credentials.nextPskIdentity()) }
        #expect(seen.count == 64)
        // The version octet is the only stable byte, and 5.3a says so.
        #expect(seen.allSatisfy { $0.first == 0x01 })
    }

    /// ⛔ `RV` 7.2b — a derived key must not appear in a log, a crash report, an
    /// analytics event or a diagnostic export. The type therefore has nothing to
    /// say about itself.
    @Test("Derived keys never print themselves")
    func keysAreRedacted() throws {
        let keys = try RendezvousKeys(psk: RvVectors.psk, sid: RvVectors.sid)
        #expect("\(keys)" == "RendezvousKeys(redacted)")
        #expect("\(keys)".localizedCaseInsensitiveContains("2b0c55") == false)
    }

    /// A malformed input must come back as a named library result, not a crash
    /// and not a silently wrong key.
    @Test("A psk of the wrong width is refused by the library, by name")
    func shortSecretIsRefused() {
        #expect(throws: PpcpLibraryError.self) {
            _ = try RendezvousKeys(psk: Data([0x00, 0x01]), sid: RvVectors.sid)
        }
    }
}

/// `PPCP-RV` §10, as the specification states them.
enum RvVectors {
    /// §10.1 `sid` — also `Session.id` `3f2504e0-4f89-41d3-9a0c-0305e82c3301` (4.3e).
    static let sid = Data(hex: "3f2504e04f8941d39a0c0305e82c3301")
    /// §10.1 `psk`.
    static let psk = Data(hex: "000102030405060708090a0b0c0d0e0f")
    /// §10.2 `rn2` — the eight CSPRNG bytes of one connection's identity.
    static let rn2 = Data(hex: "0f1e2d3c4b5a6978")
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
