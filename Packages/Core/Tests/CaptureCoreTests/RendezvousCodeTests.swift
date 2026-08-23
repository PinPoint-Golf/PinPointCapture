//  RendezvousCodeTests.swift
//  `PPCP-RV` §4 and §3, against the vectors of §10 — RT-3, RT-6, RT-7, RT-8,
//  RT-9, RT-15.
//
//  ⚠ **Every expected value below is copied from `RV` §10 and not from this
//  application's output.** A test that asserted what the decoder happens to
//  produce would pass for a decoder that agrees only with itself, which is the
//  single-implementation trap `CONF` §2c names — and the pairing code is the one
//  part of the specification 4.1 says cannot be changed after release.

import Foundation
import Testing
import CPPCP
@testable import CaptureCore

/// `RV` §10.3.
private enum CodeVectors {
    /// The minimal code: `v = 1`, one endpoint, `mu = 1`, the §10.1 secret.
    static let minimal =
        "ppcp:pWF2AWJlcIGiYWhsMTkyLjE2OC4xLjIwYXAZHmxibXUBY3Bza1AAAQIDBAUGBwgJCgsMDQ4PY3NpZFA_JQTgT4lB05oMAwXoLDMB"
    /// Every optional field: `dn`, `exp` and a `wifi` block.
    static let full =
        "ppcp:qGF2AWJkbmVCYXkgM2JlcIGiYWhsMTkyLjE2OC4xLjIwYXAZHmxibXUBY2V4cBpqkCbAY3Bza1AAAQIDBAUGBwgJCgsMDQ4PY3NpZFA_JQTgT4lB05oMAwXoLDMBZHdpZmmjYWj0YWtsY29ycmVjdGhvcnNlYXNtUGluUG9pbnQtQmF5Mw"
    /// 4.3e — `sid` as `Session.id`.
    static let sessionId = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
    static let exp: UInt64 = 1_787_832_000
}

@Suite("RV §4 — the pairing code")
struct PairingCodeTests {

    /// RT-3. The §10.3 minimal vector, field by field.
    @Test func decodesTheMinimalVector() throws {
        let code = try PpcpPairingCode(uri: CodeVectors.minimal)
        #expect(code.version == 1)
        #expect(code.endpoints == [PeerEndpoint(host: "192.168.1.20", port: 7788)])
        #expect(code.sessionId == CodeVectors.sessionId)
        #expect(code.maxUses == 1)
        #expect(code.expiresAtUnixSeconds == nil)
        #expect(code.displayName == nil)
        #expect(code.network == nil)
        // 7.4f — `mu` is 1, so persistence is permitted.
        #expect(code.mayPersistPairing)
    }

    /// The secret in the code is never used as a protocol key: it reaches TLS only
    /// through `RV` §5.1, and the keys it derives are the §10.1 vectors.
    @Test func derivesTheSectionTenKeys() throws {
        let code = try PpcpPairingCode(uri: CodeVectors.minimal)
        let keys = try code.keys()
        #expect(keys.tlsKey.hex
                == "2b0c55242ac1075eef80f548a7b39976b1cc2b88fbb6d609e5f3cd20f36d7fd4")
        #expect(keys.identityKey.hex
                == "fd2d8fcfb1be76f83ca1d551e8d5ab34a2fbe3a76f048acb09c64c1d20646117")
    }

    /// RT-3, the vector `RV` §10.3 says "matters for 4.3b": with a display name
    /// present, `v` must still be the first key.
    @Test func decodesEveryOptionalField() throws {
        let code = try PpcpPairingCode(uri: CodeVectors.full)
        #expect(code.version == 1)
        #expect(code.displayName == "Bay 3")
        #expect(code.expiresAtUnixSeconds == CodeVectors.exp)
        #expect(code.network?.ssid == "PinPoint-Bay3")
        #expect(code.network?.passphrase == "correcthorse")
        #expect(code.network?.isHidden == false)
        #expect(code.endpoints.count == 1)
    }

    /// 4.2b — a `v` this application does not implement is reported as needing a
    /// newer application, and ⛔ never as a generic failure.
    ///
    /// The payload is `map(1) { "v": 2 }` — four octets, base64url `oWF2Ag`.
    @Test func aNewerVersionIsReportedAsSuch() {
        #expect(throws: PairingCodeError.requiresNewerApplication) {
            _ = try PpcpPairingCode(uri: "ppcp:oWF2Ag")
        }
    }

    /// 4.4b — a payload that will not decode is an invalid code, and no
    /// connection is attempted; 4.1c — an `https` code is not a pairing code at
    /// all, which is a different sentence to show a user.
    @Test func refusesWhatIsNotACode() {
        #expect(throws: PairingCodeError.invalidCode) {
            _ = try PpcpPairingCode(uri: "ppcp:!!!!not-base64url!!!!")
        }
        #expect(throws: PairingCodeError.notAPairingCode) {
            _ = try PpcpPairingCode(uri: "https://pinpoint.golf/pair?x=1")
        }
    }

    /// 4.4a / 4.4a1 — three outcomes, and the middle one is the whole point: a
    /// device with an untrustworthy clock **attempts the pairing** rather than
    /// being locked out, because the publisher enforces `exp` itself (7.3e).
    @Test func expiryDependsOnWhetherTheClockCanBeBelieved() throws {
        let code = try PpcpPairingCode(uri: CodeVectors.full)
        let before = CodeVectors.exp - 60
        let after = CodeVectors.exp + 60
        #expect(code.expiry(nowUnixSeconds: before, trust: .trusted) == .ok)
        #expect(code.expiry(nowUnixSeconds: after, trust: .trusted) == .expired)
        #expect(code.expiry(nowUnixSeconds: after, trust: .untrusted) == .possiblyExpired)
    }

    /// 7.4f — a pairing from a code whose `mu` exceeded 1 is **session-scoped**,
    /// because every peer that scanned that code holds identical key material.
    /// ⛔ The predicate is the library's; this asserts the application reads it.
    @Test func aMultiUseCodeMayNotBePersisted() throws {
        let uri = try Self.encode(maxUses: 3)
        let code = try PpcpPairingCode(uri: uri)
        #expect(code.maxUses == 3)
        #expect(code.mayPersistPairing == false)

        let single = try PpcpPairingCode(uri: try Self.encode(maxUses: 1))
        #expect(single.mayPersistPairing)
    }

    /// 4.4d — untrusted display text. A name carrying a bidirectional override
    /// renders as something else entirely next to a "connect?" button, so the
    /// scalars are stripped rather than escaped at the view layer, where one
    /// screen would remember and the next would not.
    @Test func displayNameIsStrippedOfControlAndFormatScalars() {
        let hostile = "Bay\u{202E}3\u{0007}"
        let cleaned = hostile.withCString { pointer in
            PpcpPairingCode.displayText(pointer, strlen(pointer))
        }
        #expect(cleaned == "Bay3")
    }

    /// Builds a code through the library's own encoder, so the bytes under test
    /// are the bytes a publisher would produce.
    private static func encode(maxUses: UInt64) throws -> String {
        var payload = ppcp_rv_payload()
        ppcp_rv_payload_init(&payload)
        try check(ppcp_rv_payload_add_endpoint(&payload, "192.168.1.20", 12, 7788))
        let psk = Data(hex: "000102030405060708090a0b0c0d0e0f")
        let sid = Data(hex: "3f2504e04f8941d39a0c0305e82c3301")
        try check(psk.withUnsafeBytes { p in
            sid.withUnsafeBytes { s in
                ppcp_rv_payload_set_secret(&payload,
                                           p.bindMemory(to: UInt8.self).baseAddress, psk.count,
                                           s.bindMemory(to: UInt8.self).baseAddress)
            }
        })
        try check(ppcp_rv_payload_set_max_uses(&payload, maxUses))
        // ⚠ `PPCP_RV_MAX_URI` is a macro over an expression and does not import
        // into Swift; the arithmetic is `rv.h`'s, restated here rather than
        // guessed, because a short buffer is `PPCP_ERR_NOSPACE` and not silence.
        let capacity = 5 + ((Int(PPCP_RV_MAX_PAYLOAD) + 2) / 3) * 4 + 1
        var out = [CChar](repeating: 0, count: capacity)
        var length = 0
        try check(ppcp_rv_uri_encode(&payload, &out, out.count, &length))
        return String(cString: out)
    }
}

@Suite("RV §3 — service discovery")
struct DiscoveryAdvertisementTests {

    /// §10.1's `K_id`.
    static let identityKey =
        Data(hex: "fd2d8fcfb1be76f83ca1d551e8d5ab34a2fbe3a76f048acb09c64c1d20646117")
    /// §10.2's advertisement nonce.
    static let rn = Data(hex: "a1b2c3d4e5f60718")

    /// RT-6. The §10.2 vector: `rid`, the TXT record and the instance name.
    @Test func reproducesTheSectionTenTwoAdvertisement() throws {
        let advertisement = try DiscoveryAdvertisement(
            identityKey: Self.identityKey, rn: Self.rn, role: .capture,
            protocolVersions: "1.0", mintedAtNs: 0)

        #expect(advertisement.rid.hex == "9b1d2df94b2cfa84")
        #expect(advertisement.instanceName == "PPCP-9B1D2DF9")
        #expect(advertisement.txtRecord == [
            "txtvers": "1", "pv": "1.0", "role": "capture",
            "rn": "a1b2c3d4e5f60718", "rid": "9b1d2df94b2cfa84"
        ])
    }

    /// 3.3a is a **closed** list and 3.3b names what must not appear. The
    /// assertion that matters is the negative one: nothing else is in the record.
    @Test func theRecordCarriesTheFiveKeysAndNothingElse() throws {
        let advertisement = try DiscoveryAdvertisement(
            identityKey: Self.identityKey, rn: Self.rn, mintedAtNs: 0)
        #expect(Set(advertisement.txtRecord.keys)
                == Set(["txtvers", "pv", "role", "rn", "rid"]))
        // 7.6a — `Peer.id` appears nowhere outside an authenticated channel.
        let joined = advertisement.txtRecord.values.joined() + advertisement.instanceName
        #expect(joined.contains("peer:") == false)
        // 3.3c — under 200 bytes so it fits a single response.
        #expect(advertisement.txtRecordBytes < 200)
    }

    /// 3.4a — regenerated on every registration and at least every 15 minutes.
    /// ⚠ The interval is the library's constant, not a number written here.
    @Test func theNonceRotatesWithinFifteenMinutes() throws {
        let advertisement = try DiscoveryAdvertisement(
            identityKey: Self.identityKey, rn: Self.rn, mintedAtNs: 0)
        #expect(DiscoveryAdvertisement.maximumNonceAgeNs == 900 * 1_000_000_000)
        #expect(advertisement.needsRotation(asOfNs: 899 * 1_000_000_000) == false)
        #expect(advertisement.needsRotation(asOfNs: 900 * 1_000_000_000))
    }

    /// 3.4b/3.4c — a discovered `rid` resolves against the pairing that produced
    /// it and **not** against any other, and an unresolvable one is a refusal to
    /// connect rather than a prompt.
    @Test func resolvesOnlyAgainstTheHoldingPairing() throws {
        let other = Data(hex: "00112233445566778899aabbccddeeff"
                         + "00112233445566778899aabbccddeeff")
        let advertisement = try DiscoveryAdvertisement(
            identityKey: Self.identityKey, rn: Self.rn, mintedAtNs: 0)

        #expect(DiscoveryResolver.resolve(rid: advertisement.rid, rn: Self.rn,
                                          against: [other, Self.identityKey]) == 1)
        #expect(DiscoveryResolver.resolve(rid: advertisement.rid, rn: Self.rn,
                                          against: [other]) == nil)
    }

    /// The two hexadecimal fields, parsed exactly at the width 3.3a states.
    @Test func hexFieldsAreParsedAtTheirStatedWidth() {
        #expect(DiscoveryResolver.hexField("a1b2c3d4e5f60718", bytes: 8) == Self.rn)
        #expect(DiscoveryResolver.hexField("a1b2c3d4e5f607", bytes: 8) == nil)
        #expect(DiscoveryResolver.hexField("zzzzzzzzzzzzzzzz", bytes: 8) == nil)
        #expect(DiscoveryResolver.hexField(nil, bytes: 8) == nil)
    }
}

@Suite("The microphone-to-ball distance")
struct MicToBallDistanceTests {

    /// 8.1d — ~2.9 ms per metre, and the correction is what gets **subtracted**
    /// from the raw onset. The arithmetic is asserted against the speed of sound
    /// rather than against a number this type produced.
    @Test func correctsByTheTimeSoundSpentInTheAir() {
        let setting = MicToBallDistance(metres: 2.0)
        let expected = 2.0 / AcousticTimeOfFlight.speedOfSoundMetresPerSecond * 1000
        #expect(abs(setting.correctionMilliseconds - expected) < 0.001)
        #expect(setting.timeOfFlight.correctionNs == 5_830_904)
    }

    /// I29 — value **and** sigma, or absent. A sigma of zero would be a point
    /// estimate of exactly the kind 5.4a refuses for clock offsets.
    @Test func everySettingCarriesADispersion() {
        for preset in MicToBallDistance.presets {
            let setting = MicToBallDistance(metres: preset.metres)
            #expect(setting.sigmaMetres > 0)
            #expect(setting.sigmaMilliseconds > 0)
        }
    }

    /// ⛔ A12 — the default is `estimated`, not `surveyed`. A user estimate and a
    /// rig measurement are different claims, and the wider sigma is what says so.
    @Test func aUserEstimateIsWiderThanASurvey() {
        let estimated = MicToBallDistance(metres: 1.5, provenance: .estimated)
        let surveyed = MicToBallDistance(metres: 1.5, provenance: .surveyed)
        #expect(MicToBallDistance().provenance == .estimated)
        #expect(estimated.sigmaMetres > surveyed.sigmaMetres)
        #expect(estimated.recordedForm["mic_to_ball_provenance"] == "estimated")
    }

    /// A `tof_correction` of half a second is not a plausible setting, and a peer
    /// that emitted one would corrupt a Session's arbitration rather than be
    /// merely wrong.
    @Test func theDistanceIsBounded() {
        #expect(MicToBallDistance(metres: -3).metres
                == MicToBallDistance.permittedMetres.lowerBound)
        #expect(MicToBallDistance(metres: 500).metres
                == MicToBallDistance.permittedMetres.upperBound)
    }

    /// The setting reaches a Candidate through `CandidateFactory`, and this is
    /// where the two meet: the factory takes exactly what the setting produces.
    @Test func feedsTheCandidateFactory() {
        let setting = MicToBallDistance(metres: 1.5)
        let tof = setting.timeOfFlight
        #expect(tof.distanceMetres == 1.5)
        #expect(tof.distanceSigmaMetres == setting.sigmaMetres)
    }
}
