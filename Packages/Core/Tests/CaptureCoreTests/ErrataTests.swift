//  ErrataTests.swift
//  The `libppcp` L17 errata this application had to adopt, asserted rather than
//  assumed.
//
//  ⚠ Each of these is a clause that changed under a working implementation. The
//  point of a test per erratum is that "adopted" is otherwise a claim in a commit
//  message.
//
//  Spec: `RV` 3.3d/3.3e (E25), 5.3a1 (E21); `ENC` 6g (E7). Plan S5, L17.

import Foundation
import Testing
import CPPCP
@testable import CaptureCore

@Suite("L17 errata — RV 3.3d/3.3e, 5.3a1, ENC 6g")
struct ErrataTests {

    // MARK: E25 — one range syntax for `pv` and `detail.supported`

    @Test("A bare version is the range LOW-LOW, and a range spans its minors")
    func rangeParses() throws {
        let bare = try #require(PpcpVersionRange("1.0"))
        #expect(bare.major == 1 && bare.lowMinor == 0 && bare.highMinor == 0)
        #expect(bare.text == "1.0")
        #expect(bare.contains(major: 1, minor: 0))
        #expect(bare.contains(major: 1, minor: 1) == false)

        // 3.3d — "both endpoints inclusive, and the range denotes every MINOR
        // between them: `1.0-1.2` is `1.0`, `1.1`, `1.2`".
        let span = try #require(PpcpVersionRange("1.0-1.2"))
        for minor in 0...2 { #expect(span.contains(major: 1, minor: minor)) }
        #expect(span.contains(major: 1, minor: 3) == false)
        #expect(span.contains(major: 2, minor: 0) == false)
        #expect(span.text == "1.0-1.2")
    }

    @Test("Several MAJORs are several ranges, most preferred first")
    func severalMajors() throws {
        let ranges = try #require(PpcpVersionRange.parse("2.0-2.1,1.4-1.6"))
        #expect(ranges.count == 2)
        #expect(ranges[0].major == 2, "most preferred first")
        #expect(ranges[1].contains(major: 1, minor: 5))
        #expect(PpcpVersionRange.advertises("2.0-2.1,1.4-1.6", major: 1))
        #expect(PpcpVersionRange.advertises("2.0-2.1,1.4-1.6", major: 3) == false)
    }

    /// ⛔ 3.3d — "a reader that cannot parse a range ignores that advertisement
    /// rather than guessing". Every one of these must be `nil`, because the
    /// alternative is a browser offering a peer it cannot speak to.
    @Test("An unparseable pv is ignored, never guessed at")
    func refusesWhatIsNotARange() {
        for bad in ["", "1", "1.", ".0", "1.0-", "-1.0", "1.0-2.0", "1.2-1.0",
                    "1.0-1.1-1.2", "one.zero", "1.0,", "+1.0", "1.00", "01.0",
                    "1.0 - 1.2"] {
            #expect(PpcpVersionRange.parse(bad) == nil, "\(bad) parsed")
            #expect(PpcpVersionRange.advertises(bad, major: 1) == false, "\(bad)")
        }
        // 3.3d — endpoints share a MAJOR, so `1.0-2.0` above is refused rather
        // than read as spanning two.
        #expect(PpcpVersionRange("1.0-2.0") == nil)
    }

    /// ⛔ **The advertisement this device publishes must itself be a valid
    /// range, and before E25 it was not** (F-S5-5). `pv` defaulted to
    /// `PpcpLibrary.wireVersion`, which is the wire token `ppcp/1.0`; 3.3d makes
    /// each endpoint `MAJOR.MINOR`, so a conformant browser was required to
    /// ignore this peer's record entirely. Nothing before E25 could have caught
    /// it, because the syntax was defined nowhere.
    @Test("This peer's own pv parses as a range, and the wire token does not")
    func ownAdvertisementIsARange() throws {
        let ranges = try #require(PpcpVersionRange.parse(PpcpLibrary.wireVersionRange))
        #expect(ranges.count == 1)
        #expect(ranges[0].major == PpcpLibrary.wireMajor)
        #expect(ranges[0].contains(major: PpcpLibrary.wireMajor,
                                   minor: PpcpLibrary.wireMinor))

        // ⛔ The regression this exists to prevent: the token is not a range.
        #expect(PpcpVersionRange.parse(PpcpLibrary.wireVersion) == nil,
                "ppcp/1.0 must not read as a range — that was the defect")

        // And the record actually published carries the range.
        let advertisement = try DiscoveryAdvertisement(
            identityKey: Data(repeating: 0x2b, count: Int(PPCP_RV_KEY_BYTES)),
            rn: Data(repeating: 0x7c, count: Int(PPCP_RV_RN_BYTES)),
            mintedAtNs: 0)
        let pv = try #require(advertisement.txtRecord["pv"])
        #expect(PpcpVersionRange.parse(pv) != nil, "published pv was \(pv)")
        #expect(pv == "1.0")
    }

    // MARK: E21 — no octet of a PSK identity may be 0x00

    /// ⛔ **`RV` 5.3a1.** Several TLS stacks carry the identity as a C string and
    /// take its length with `strlen`, so an embedded zero truncates it and the
    /// handshake fails roughly one connection in sixteen — diagnosed at a range as
    /// a network fault. The draw is rejection sampling and this asserts the
    /// property it exists for.
    ///
    /// ⚠ The generator here is deliberately hostile: it returns a zero byte every
    /// other draw. A `nextPskIdentity` that did not re-draw would produce a
    /// zero-bearing identity almost immediately.
    @Test("A drawn identity never contains a zero octet, even from a nasty CSPRNG")
    func identityDrawRejectsZeroOctets() throws {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let nasty: @Sendable (Int) -> Data = { count in
            counter.calls += 1
            // Every other draw is all zeros; the rest are ordinary bytes.
            return counter.calls % 2 == 1
                ? Data(repeating: 0, count: count)
                : Data((0..<count).map { UInt8(($0 &* 7 &+ counter.calls) % 251 &+ 1) })
        }
        let keys = try RendezvousKeys(persistedPrk: Data(repeating: 0x5a, count: 32))
        let credentials = RendezvousCredentials(keys: keys, randomBytes: nasty)

        for _ in 0..<32 {
            let identity = try credentials.nextPskIdentity()
            #expect(identity.count == Int(PPCP_RV_PSK_IDENTITY_BYTES))
            // ⛔ The property. Not "usually", not "on average".
            #expect(identity.contains(0) == false,
                    "a zero octet reached a live PSK identity (RV 5.3a1)")
            // 5.3a — the leading byte is the version and never zero.
            #expect(identity.first == 0x01)
        }
        #expect(counter.calls > 32, "the hostile generator was never re-drawn from")
    }

    /// The library's own predicate agrees with the draw. ⚠ Asserted because the
    /// two are separate entry points and a fix to one is not a fix to the other.
    @Test("ppcp_rv_psk_identity_usable answers for a hand-built identity")
    func usablePredicate() {
        var good = [UInt8](repeating: 0x11, count: Int(PPCP_RV_PSK_IDENTITY_BYTES))
        good[0] = 0x01
        #expect(ppcp_rv_psk_identity_usable(&good))
        var bad = good
        bad[9] = 0
        #expect(ppcp_rv_psk_identity_usable(&bad) == false)
    }

    // MARK: E7 — the container a payload is framed in

    /// ⛔ `ENC` 6h forbids a receiver inferring the container, so a sender that
    /// omits it hands over a guess. These are the two this application produces.
    @Test("The media types this application declares are IANA types, not codecs")
    func mediaTypes() {
        #expect(PpcpMediaType.clip == "video/mp4")
        #expect(PpcpMediaType.audioEvidence == "audio/mp4")
        // ⚠ The distinction the erratum exists for: `hevc` is a codec and names
        // no container. H.264 alone is QuickTime, fragmented MP4 and Annex B.
        #expect(PpcpMediaType.clip.contains("/"))
        #expect(PpcpMediaType.clip != "hevc")
    }
}
