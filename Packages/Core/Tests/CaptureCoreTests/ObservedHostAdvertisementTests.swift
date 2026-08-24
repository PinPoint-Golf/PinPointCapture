//  ObservedHostAdvertisementTests.swift
//  ⚠ **Bytes seen on the wire, not bytes this repository invented.**
//
//  Every other discovery test in this suite builds an advertisement with the same
//  code that reads it, which proves the two halves agree with each other and
//  nothing about whether either agrees with PinPointStudio. These are the TXT
//  records of three consecutive real `_ppcp._tcp` registrations held open by
//  PinPointStudio and observed from this machine on **24 August 2026** with
//  `make browse` — at 22:13, 22:16 and 22:21 BST, one instance seen each time.
//
//  ⛔ **Every guard in `PpcpBrowser.browse` is re-run here against those exact
//  strings**, because each of them is a `continue` — an advertisement that fails
//  any one of them is dropped in silence, and 3.6a means that silence is
//  indistinguishable from an empty network. A `pv` this build could not parse
//  would take the whole reconnection path down and look exactly like a host that
//  was not switched on.
//
//  ⚠ **`rn` is a counting fixture (`03 04 05 …`), not a CSPRNG.** This is
//  PinPointStudio's *test* advertiser. ⛔ Nothing here measures a shipping host's
//  entropy, and `RV` 3.4a's rotation quality is NOT demonstrated by these values.
//
//  ⛔ **The resolver is expected to REFUSE all three and that is the pass
//  condition.** The `K_id` behind these `rid`s is the fixture's, not a pairing
//  this device holds, so 3.4c correctly declines to offer them. What these tests
//  establish is that a real host advertisement *parses* and *reaches* the
//  resolver — the discovery half — and nothing whatever about resolution
//  succeeding or about the dial.
//
//  ────────────────────────────────────────────────────────────────────────────
//  ⛔ **FINDING, REPORTED AND NOT RESOLVED — the instance name did not track
//  `rid`.** Four registrations across two separate advertising windows; three
//  distinct `rid` values; one unchanging instance name:
//
//      at      observed rn         observed rid        on the wire     3.2a derives
//      22:13   030405060708090a    9b95b9279f73bb93    PPCP-11121314   PPCP-9B95B927
//      22:16   0c0d0e0f10111213    b952ce9ff35815e9    PPCP-11121314   PPCP-B952CE9F
//      22:21   0203040506070809    a3be617e11db0ba4    PPCP-11121314   PPCP-A3BE617E
//      22:25   030405060708090a    9b95b9279f73bb93    PPCP-11121314   PPCP-9B95B927
//
//  The last column is `ppcp_rv_instance_name` — the shared C reference both ends
//  are built on — run against each observed `rid`, and it is asserted below so
//  the discrepancy cannot quietly stop being one.
//
//  ⚠ **The deterministic-RNG account explains half of this and not the half that
//  matters.** The 22:25 sample is in a *new* window and reproduces 22:13 byte for
//  byte, which is exactly what a counting fixture reseeded from the same start
//  would do — so repetition across restarts is fully explained. What it does not
//  explain is 22:13 → 22:16 → 22:21, where `rid` took three different values
//  **inside** the advertiser's own rotation and the name did not move at all. A
//  deterministic RNG yields a deterministic `rid` and therefore a deterministic
//  name *derived from that rid*; it cannot yield a changing `rid` under a
//  constant derived name.
//
//  ⛔ **This suite does NOT assert that the wire is wrong**, because the
//  specification is closed, lives in another repository, and a clause `3.2d` has
//  been cited for the name being deliberately stable — which this repository does
//  not implement and cannot read. It records both sides and leaves the question
//  to the maintainer. Nothing in the reconnection path depends on the answer:
//  `ReconnectCoordinator` never compares, persists or dials on an instance name.
//  ────────────────────────────────────────────────────────────────────────────

import Foundation
import Testing
import CPPCP
@testable import CaptureCore

@Suite("RV §3 — a real PinPointStudio advertisement, as observed")
struct ObservedHostAdvertisementTests {

    /// One registration, verbatim, deliberately not built from a constructor.
    private struct Sample {
        let at: String
        let rn: String
        let rid: String
        /// What the instance was actually called on the wire.
        let observedName: String
        /// What `ppcp_rv_instance_name` derives from `rid` (3.2a).
        let derivedName: String
    }

    private static let txtvers = "1"
    private static let pv = "1.0"
    private static let role = "host"

    private static let samples = [
        Sample(at: "22:13", rn: "030405060708090a", rid: "9b95b9279f73bb93",
               observedName: "PPCP-11121314", derivedName: "PPCP-9B95B927"),
        Sample(at: "22:16", rn: "0c0d0e0f10111213", rid: "b952ce9ff35815e9",
               observedName: "PPCP-11121314", derivedName: "PPCP-B952CE9F"),
        Sample(at: "22:21", rn: "0203040506070809", rid: "a3be617e11db0ba4",
               observedName: "PPCP-11121314", derivedName: "PPCP-A3BE617E"),
        // ⚠ A second advertising window, and a byte-for-byte repeat of 22:13 —
        // the counting fixture reseeded. Kept because it is the evidence that
        // the RNG really is deterministic, which is what makes the *changing*
        // `rid` under a constant name the part that needs an answer.
        Sample(at: "22:25", rn: "030405060708090a", rid: "9b95b9279f73bb93",
               observedName: "PPCP-11121314", derivedName: "PPCP-9B95B927")
    ]

    @Test("⛔ `pv = 1.0` parses — an unparseable one would silently kill reconnection")
    func theVersionRangeParses() {
        // 3.3d/3.3e (E25) — `pv` is a RANGE, and a bare `LOW` means `LOW-LOW`.
        let ranges = PpcpVersionRange.parse(Self.pv)
        #expect(ranges?.count == 1)
        #expect(ranges?.first?.major == 1)
        #expect(ranges?.first?.lowMinor == 0)
        #expect(ranges?.first?.highMinor == 0)

        // ⛔ The actual guard in `browse`, against the MAJOR this build speaks.
        #expect(PpcpVersionRange.advertises(Self.pv, major: PpcpLibrary.wireMajor))
    }

    @Test("`role = host` is the role (b) dials — 3.5e")
    func theRoleIsHost() {
        #expect(DiscoveryRole(rawValue: Self.role) == .host)
        #expect(Self.txtvers == "1")
    }

    @Test("⛔ Every observed `rn` and `rid` is exactly eight bytes of hex — 3.3a's widths")
    func theHexFieldsAreTheStatedWidth() throws {
        for sample in Self.samples {
            let rn = try #require(DiscoveryResolver.hexField(sample.rn, bytes: 8),
                                  "rn at \(sample.at)")
            let rid = try #require(DiscoveryResolver.hexField(sample.rid, bytes: 8),
                                   "rid at \(sample.at)")
            #expect(rn.count == 8)
            #expect(rid.count == 8)
        }
    }

    @Test("⛔ 3.4c — every observed instance is REFUSED against a pairing that is not its own")
    func anUnresolvableInstanceIsRefused() throws {
        // A pairing this device might hold, which is not the fixture's.
        let keys = try RendezvousKeys(psk: Data(repeating: 0x5A, count: 16),
                                      sid: Data(repeating: 0x5B, count: 16))
        for sample in Self.samples {
            let rn = try #require(DiscoveryResolver.hexField(sample.rn, bytes: 8))
            let rid = try #require(DiscoveryResolver.hexField(sample.rid, bytes: 8))
            // ⛔ `nil` is the PASS. This is the refusal (b) relies on to keep a
            // stranger's host off the screen.
            #expect(DiscoveryResolver.resolve(rid: rid, rn: rn,
                                              against: [keys.identityKey]) == nil,
                    "sample at \(sample.at) must not resolve")
            // ⚠ And with nothing held at all, which is `noPairingsHeld`'s premise.
            #expect(DiscoveryResolver.resolve(rid: rid, rn: rn, against: []) == nil)
        }
    }

    @Test("⛔ FINDING — the observed name is stable while `rid` rotates, and 3.2a derives it from `rid`")
    func theInstanceNameDidNotTrackTheRid() throws {
        // Every registration was called the same thing on the wire…
        #expect(Set(Self.samples.map(\.observedName)).count == 1)
        // …across three distinct `rid` values (four samples, one an exact
        // reseeded repeat of another).
        #expect(Set(Self.samples.map(\.rid)).count == 3)
        #expect(Self.samples.count == 4)

        for sample in Self.samples {
            // ⛔ `ppcp_rv_instance_name` — the shared C reference — against the
            // `rid` that was actually published alongside that name.
            var bytes = [UInt8](try #require(
                DiscoveryResolver.hexField(sample.rid, bytes: 8)))
            var name = [CChar](repeating: 0, count: Int(PPCP_RV_INSTANCE_NAME_MAX))
            #expect(ppcp_rv_instance_name(&bytes, &name) == PPCP_OK)
            let derived = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                                 as: UTF8.self)
            #expect(derived == sample.derivedName)
            // ⚠ Recorded, not judged. See the FINDING block at the top of this
            // file: which of the two is correct is the maintainer's call and
            // needs a clause this repository cannot read.
            #expect(derived != sample.observedName,
                    "the wire and 3.2a disagree about this instance's name")
        }
    }
}
