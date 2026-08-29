//  WiredPresenceTests.swift
//  The wired presence record, byte for byte.
//
//  ⚠ **These bytes are a contract with another repository**, fixed as C3 in
//  `PinPointStudio/docs/implementation/wired_transport_impl_plan.md` before either
//  side was written. The host's reader is developed against the same table, so a
//  fixture that merely round-trips through this encoder would prove nothing about
//  the pair. Every assertion here is on literal bytes for that reason.
//
//  ⚠ In `Packages/Core` rather than the app target because none of it needs a
//  socket, a simulator or `Network.framework` — `swift test` runs it in
//  milliseconds. What only a simulator can answer (that the listener binds
//  loopback and nothing else) is in `Tests/WiredPresenceListenerTests.swift`.

import Foundation
import Testing
@testable import CaptureCore

@Suite("Wired presence record (C3)")
struct WiredPresenceTests {

    /// `RV` §10.2's identity, which is deliberately **not** valid UTF-8 — 5.3f
    /// forbids transcoding, text validation and truncation, and this is the value
    /// 5.4b2 recorded completing a handshake on the device.
    static let identityA = Data(hex: "010f1e2d3c4b5a6978b355ada60b4b5aa8")
    /// ⛔ A second identity chosen to end in `0x00`. A drawn identity never
    /// contains one (5.3a1/E21 rejection-samples them away, because several TLS
    /// stacks take a PSK identity's length with `strlen`) — but the *encoder* must
    /// not be the thing that depends on that. If this survives, no length is ever
    /// being taken with `strlen` on the way to the wire.
    static let identityB = Data(hex: "01ffeeddccbbaa99887766554433221100")

    // MARK: The record

    /// The whole of C3 in one fixture: the key set, the key order, a present
    /// `dl`, two `peers` entries and their inner key order.
    @Test("Two pairings encode to exactly the agreed bytes")
    func twoPairingRecordIsExact() throws {
        let record = try WiredPresence(
            displayLabel: "Mark's iPhone",
            peers: [WiredPresence.Peer(port: 50000, pskIdentity: Self.identityA),
                    WiredPresence.Peer(port: 49152, pskIdentity: Self.identityB)])

        // ⛔ `ENC` 4e order, bytewise over the ENCODED key: `dl` (62 64 6c) sorts
        // before `pv` (62 70 76). C3 originally said `pv, role, dl, peers`, which
        // the deterministic writer refuses outright — the contract was amended
        // rather than the writer talked out of it.
        let expected =
            "a4"                                   // map(4)
            + "62" + "646c"                        // "dl"
            + "6d" + "4d61726b2773206950686f6e65"  //   "Mark's iPhone"
            + "62" + "7076"                        // "pv"
            + "63" + "312e30"                      //   "1.0"
            + "64" + "726f6c65"                    // "role"
            + "67" + "63617074757265"              //   "capture"
            + "65" + "7065657273"                  // "peers"
            + "82"                                 // array(2)
            + "a2"                                 //   map(2)
            + "64" + "706f7274" + "19c350"         //   "port": 50000
            + "6c" + "70736b5f6964656e74697479"    //   "psk_identity":
            + "51" + Self.identityA.hex            //     bytes(17)
            + "a2"                                 //   map(2)
            + "64" + "706f7274" + "19c000"         //   "port": 49152
            + "6c" + "70736b5f6964656e74697479"    //   "psk_identity":
            + "51" + Self.identityB.hex            //     bytes(17)

        #expect(try record.encoded().hex == expected)
    }

    /// C3: *"`dl` is omitted entirely when absent — never `null`."*
    ///
    /// ⚠ Asserted on the map head as well as on the key, because a four-key head
    /// with three keys written is the shape a `null` would have arrived as.
    ///
    /// ⛔ **This case alone could not have caught the ordering defect, and that is
    /// why the labelled fixture above exists.** `pv, role, peers` is already
    /// `ENC` 4e order, so an unlabelled record encodes identically whether the
    /// writer is enforcing 4e or emitting keys as written. The two fixtures are a
    /// pair; neither is redundant.
    @Test("An absent label is omitted, not null")
    func absentLabelIsOmitted() throws {
        let record = try WiredPresence(
            displayLabel: nil,
            peers: [WiredPresence.Peer(port: 50000, pskIdentity: Self.identityA)])

        let expected =
            "a3"                                   // map(3), NOT map(4)
            + "62" + "7076" + "63" + "312e30"
            + "64" + "726f6c65" + "67" + "63617074757265"
            + "65" + "7065657273"
            + "81"                                 // array(1)
            + "a2"
            + "64" + "706f7274" + "19c350"
            + "6c" + "70736b5f6964656e74697479"
            + "51" + Self.identityA.hex

        // ⚠ Byte equality is the assertion, not a substring search for `646c`
        // ("dl") or `f6` (CBOR `null`): hex text is not byte-aligned, and both of
        // those strings occur *inside* other fields' hex by coincidence —
        // "psk_identity" alone contains `5f6964…`. A naive `contains` here passes
        // and fails for reasons that have nothing to do with the record.
        #expect(try record.encoded().hex == expected)
    }

    /// ⚠ An empty label is an absent one, not `dl: ""` — a third state C3 gives
    /// no meaning to.
    @Test("An empty label is an absent label")
    func emptyLabelIsAbsent() throws {
        let record = try WiredPresence(
            displayLabel: "",
            peers: [WiredPresence.Peer(port: 1, pskIdentity: Self.identityA)])
        #expect(record.displayLabel == nil)
        #expect(try record.encoded().hex.hasPrefix("a3"))
    }

    // MARK: The identity — `RV` 5.3f

    /// ⛔ **17 octets, on the wire exactly as registered**, including octets no
    /// text encoding would survive. This is the assertion the whole design rests
    /// on: the host offers these bytes back in its `ClientHello`, and the
    /// listener accepts only the identity it registered.
    @Test("A 17-byte identity crosses unchanged, non-UTF-8 bytes and all")
    func identityIsNotTranscoded() throws {
        // Neither of these is decodable as UTF-8; if either were, this test would
        // be measuring something weaker than it claims.
        #expect(String(data: Self.identityA, encoding: .utf8) == nil)
        #expect(String(data: Self.identityB, encoding: .utf8) == nil)

        for identity in [Self.identityA, Self.identityB] {
            let record = try WiredPresence(
                displayLabel: nil,
                peers: [WiredPresence.Peer(port: 65535, pskIdentity: identity)])
            let bytes = try record.encoded()
            // `0x51` is the CBOR head for a 17-byte string, and the 17 octets
            // after it are the identity with nothing done to them.
            let head = try #require(bytes.range(of: Data([0x51]) + identity))
            #expect(bytes.count - head.upperBound == 0, "the identity is the tail")
        }
    }

    /// The same, but for an identity the **real** path drew rather than one
    /// written down: `RendezvousCredentials` over the `RV` §10 vectors.
    @Test("An identity from the live draw reaches the record intact")
    func drawnIdentityReachesTheRecord() throws {
        let keys = try RendezvousKeys(psk: RvVectors.psk, sid: RvVectors.sid)
        let identity = try RendezvousCredentials(keys: keys,
                                                 randomBytes: { _ in RvVectors.rn2 })
            .nextPskIdentity()
        #expect(identity.count == PpcpKeyLengths.pskIdentity)
        // 5.3a — `0x01 ‖ rn2(8) ‖ tag(8)`, and `rn2` is where the vector says.
        #expect(identity.prefix(9) == Data([0x01]) + RvVectors.rn2)

        let bytes = try WiredPresence(
            displayLabel: nil,
            peers: [WiredPresence.Peer(port: 5000, pskIdentity: identity)]).encoded()
        #expect(bytes.range(of: Data([0x51]) + identity) != nil)
    }

    // MARK: `peers` is per listener, not per host (C5)

    @Test("Every held pairing gets its own entry, with its own port")
    func onePeerEntryPerListener() throws {
        let identities = (0..<3).map { i in
            Data([0x01] + [UInt8](repeating: UInt8(0xa0 + i), count: 16))
        }
        let record = try WiredPresence(
            displayLabel: nil,
            peers: try zip([49152, 49153, 49154] as [UInt16], identities).map {
                try WiredPresence.Peer(port: $0, pskIdentity: $1)
            })
        // ⚠ Built rather than searched for, for the reason given in
        // `absentLabelIsOmitted`: hex text is not byte-aligned and `contains`
        // finds matches that straddle two fields.
        var expected =
            "a3"
            + "62" + "7076" + "63" + "312e30"
            + "64" + "726f6c65" + "67" + "63617074757265"
            + "65" + "7065657273"
            + "83"                                  // array(3) — one per listener
        for (port, identity) in zip(["19c000", "19c001", "19c002"], identities) {
            expected += "a2" + "64" + "706f7274" + port
                + "6c" + "70736b5f6964656e74697479" + "51" + identity.hex
        }
        #expect(try record.encoded().hex == expected)
    }

    /// C3's ceiling, refused on this side rather than left for the host to refuse.
    @Test("Sixteen entries encode; seventeen are refused")
    func sixteenIsTheCeiling() throws {
        func peers(_ n: Int) throws -> [WiredPresence.Peer] {
            try (0..<n).map { i in
                try WiredPresence.Peer(port: UInt16(20000 + i),
                                       pskIdentity: Data([0x01] + [UInt8](repeating: 0x7f, count: 16)))
            }
        }
        let full = try WiredPresence(displayLabel: "iPhone", peers: peers(16))
        let bytes = try full.encoded()
        #expect(bytes.hex.contains("90"))           // array(16)
        // ⚠ And it still fits the host's 4096-byte cap with room to spare, which
        // is the only reason 16 is a safe ceiling to have agreed.
        #expect(bytes.count <= WiredPresence.maxRecordBytes)
        #expect(bytes.count < 800)

        #expect(throws: WiredPresence.Failure.tooManyPeers(17)) {
            _ = try WiredPresence(displayLabel: nil, peers: peers(17))
        }
    }

    // MARK: What is refused

    @Test("A record with no listener in it is not emitted")
    func emptyRecordIsRefused() {
        #expect(throws: WiredPresence.Failure.noPeers) {
            _ = try WiredPresence(displayLabel: "iPhone", peers: [])
        }
    }

    @Test("An identity that is not 17 octets is refused, not padded")
    func identityLengthIsExact() {
        #expect(throws: WiredPresence.Failure.invalidIdentityLength(16)) {
            _ = try WiredPresence.Peer(port: 5000,
                                       pskIdentity: Data(repeating: 0x01, count: 16))
        }
        #expect(throws: WiredPresence.Failure.invalidIdentityLength(18)) {
            _ = try WiredPresence.Peer(port: 5000,
                                       pskIdentity: Data(repeating: 0x01, count: 18))
        }
    }

    /// ⚠ Port `0` means "the listener never bound". Publishing it would send the
    /// host to a port nothing is on.
    @Test("Port zero is refused")
    func portZeroIsRefused() {
        #expect(throws: WiredPresence.Failure.invalidPort) {
            _ = try WiredPresence.Peer(port: 0, pskIdentity: Self.identityA)
        }
    }

    /// ⚠ Refused, never truncated — and the caller's answer to a refusal is to
    /// omit `dl`, not to shorten it. `dl` is display text and nothing keys on it.
    @Test("An absurd label is refused rather than truncated")
    func longLabelIsRefused() {
        let label = String(repeating: "a", count: WiredPresence.maxLabelBytes + 1)
        #expect(throws: WiredPresence.Failure.labelTooLong(label.utf8.count)) {
            _ = try WiredPresence(displayLabel: label,
                                  peers: [WiredPresence.Peer(port: 1,
                                                             pskIdentity: Self.identityA)])
        }
    }

    /// C3's other cap, from the reader's side: a full record must stay well
    /// inside the 4096 bytes the host is willing to read.
    @Test("A worst-case record fits the host's read cap")
    func worstCaseFitsTheCap() throws {
        let label = String(repeating: "é", count: WiredPresence.maxLabelBytes / 2)
        let record = try WiredPresence(
            displayLabel: label,
            peers: try (0..<WiredPresence.maxPeers).map { i in
                try WiredPresence.Peer(port: UInt16(60000 + i),
                                       pskIdentity: Data([0x01] + [UInt8](repeating: 0xff, count: 16)))
            })
        #expect(try record.encoded().count <= WiredPresence.maxRecordBytes)
    }
}
