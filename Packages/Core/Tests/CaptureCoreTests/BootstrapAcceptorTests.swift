//  BootstrapAcceptorTests.swift
//  `PPCP-RV` §11.5–§11.7 with a real curve, in milliseconds, on the host.
//
//  ⛔ **WHAT THIS FILE CANNOT SEE, STATED FIRST SO THE GREEN TICK IS NOT
//  MISREAD.** Trap 2 — `bs_accept` sent only after `pk_i` arrives — changes
//  **nothing on the wire**. Both peers still exchange five well-formed frames in
//  §11.5's order, both still derive the same `Z`, both still display the same six
//  digits, and every assertion below still passes. `RT-20b(ii)` is the only thing
//  that catches it, and only via `ppcp-relay --probe order-acceptor`, which
//  withholds `bs_reveal` and checks that `pk_a` had **already arrived**. The
//  ordering test in this file (`trap 2 — bs_accept is emitted on receiving
//  bs_offer`) is a **weaker mirror of that probe, not a substitute for it**: it
//  observes the acceptor from inside the same process, where the trap would be
//  visible, and the relay observes it from the wire, where it would not be. Both
//  are worth having and only one of them is evidence for RT-20b.
//
//  ⚠ **`import CryptoKit` here and NOT in `Sources/CaptureCore`.** `CA1` puts
//  X25519 in the application, and `LayerPurityTests` holds Core's imports to
//  `Foundation`, `Observation` and `CPPCP` — so the seam is exercised here with
//  the same primitive the device layer uses, and Core stays platform-free. The
//  purity suite scans `Sources/` only, deliberately.
//
//  ⚠ **The initiator below is `libppcp`'s own engine, not a second
//  implementation.** `CA2` puts the exchange in the library once; driving it from
//  both ends in one process is how §11.5's order table gets exercised without
//  this repository owning a copy of it. The independent check is the relay.
//
//  Spec: `RV` §10.4, §11.3–§11.7, §11.9, §11.11. Plan D11. RT-21, RT-23, RT-24c.

import Foundation
import CryptoKit
import Testing
import CPPCP
@testable import CaptureCore

// MARK: - The §11.11 seam, with a real curve

/// `CA1` / 11.11 — the same shape the device layer implements, over `CryptoKit`.
///
/// ⛔ 11.11f's **throw** half: `sharedSecretFromKeyAgreement` raises for a
/// small-order public key rather than returning zeros, and that throw becomes
/// `invalid_key` — never a transport error, and `agreements` below is what proves
/// it is never retried (trap 7).
final class CryptoKitTestAgreement: BootstrapKeyAgreement {
    private let priv: Curve25519.KeyAgreement.PrivateKey
    /// How many times the curve was asked. ⛔ For trap 7: after a rejected key
    /// this must stay at 1.
    private(set) var agreements = 0

    init(privateKey: Data? = nil) throws {
        priv = try privateKey.map { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }
            ?? Curve25519.KeyAgreement.PrivateKey()
    }

    var publicKey: Data { priv.publicKey.rawRepresentation }

    func withSharedSecret<T>(peerPublicKey: Data,
                             _ body: (UnsafeRawBufferPointer) throws -> T) throws -> T {
        guard peerPublicKey.count == 32 else {
            throw BootstrapAgreementFailure.wrongKeyLength(peerPublicKey.count)
        }
        agreements += 1
        let key: SymmetricKey
        do {
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
            let shared = try priv.sharedSecretFromKeyAgreement(with: peer)
            // 11.11h1's mitigation: derive into a type documented to zero and let
            // `SharedSecret` go out of scope at once.
            key = SymmetricKey(data: shared)
        } catch {
            throw BootstrapAgreementFailure.invalidKey     // 11.6b, 11.11f
        }
        return try key.withUnsafeBytes { try body($0) }
    }
}

// MARK: - The counterpart: libppcp's engine driven as the initiator

/// Not a peer under test — the *other* end, so §11.5's five frames actually
/// cross. Same engine, opposite role.
final class TestInitiator {
    private var engine = ppcp_bs_engine()
    let agreement: CryptoKitTestAgreement
    private(set) var digits: BootstrapDigits?
    private(set) var pairingSid: String?
    private(set) var pairingPrk: Data?
    private(set) var abortReason: BootstrapAbortReason?

    init(agreement: CryptoKitTestAgreement, v: UInt8 = 1) {
        self.agreement = agreement
        _ = agreement.publicKey.withUnsafeBytes {
            ppcp_bs_engine_init(&engine, PPCP_BS_ROLE_INITIATOR, v,
                                $0.bindMemory(to: UInt8.self).baseAddress)
        }
    }

    deinit { ppcp_bs_engine_wipe(&engine) }

    /// `bs_offer` — `ct` only, never `pk_i` (11.5b).
    func start() -> Data {
        var step = ppcp_bs_step()
        _ = ppcp_bs_engine_start(&engine, &step)
        return Self.out(step) ?? Data()
    }

    /// Feed what the acceptor sent back; returns what to send next.
    func feed(_ bytes: Data) -> Data {
        var pending = bytes
        var reply = Data()
        while !pending.isEmpty {
            var step = ppcp_bs_step()
            var consumed = 0
            let rc = pending.withUnsafeBytes {
                ppcp_bs_engine_recv(&engine, $0.bindMemory(to: UInt8.self).baseAddress,
                                    $0.count, &consumed, &step)
            }
            if rc != PPCP_OK { break }
            if consumed > 0 { pending.removeFirst(consumed) } else { break }
            reply.append(handle(step))
        }
        return reply
    }

    /// Stands in for a person at the far end. ⛔ Only legitimate because this is
    /// the *counterpart*, not the peer under test — 11.1d forbids a conformant
    /// peer doing this, which is why `ppcp-relay --peer` says the same of itself.
    func affirm() -> Data {
        var step = ppcp_bs_step()
        guard ppcp_bs_engine_affirm(&engine, &step) == PPCP_OK else { return Data() }
        return handle(step)
    }

    private func handle(_ step: ppcp_bs_step) -> Data {
        var reply = Self.out(step) ?? Data()
        switch step.event {
        case PPCP_BS_EV_NEED_SECRET:
            let peerPk = withUnsafeBytes(of: step.peer_pk) { Data($0) }
            var next = ppcp_bs_step()
            let ok = (try? agreement.withSharedSecret(peerPublicKey: peerPk) { z in
                ppcp_bs_engine_supply_secret(&engine, z.bindMemory(to: UInt8.self).baseAddress,
                                             &next)
            }) ?? PPCP_ERR_INVALID
            if ok == PPCP_OK { reply.append(handle(next)) }
        case PPCP_BS_EV_COMPARE:
            var raw: UInt32 = 0
            if ppcp_bs_engine_sas(&engine, &raw) == PPCP_OK { digits = BootstrapDigits(value: raw) }
        case PPCP_BS_EV_PAIRED:
            var cp = ppcp_bs_pairing()
            if ppcp_bs_engine_take_pairing(&engine, &cp) == PPCP_OK {
                var text = [CChar](repeating: 0, count: Int(PPCP_RV_SESSION_ID_CHARS))
                _ = withUnsafeBytes(of: &cp.sid) {
                    ppcp_rv_sid_to_session_id($0.bindMemory(to: UInt8.self).baseAddress, &text)
                }
                pairingSid = String(decoding: text.prefix(while: { $0 != 0 })
                    .map { UInt8(bitPattern: $0) }, as: UTF8.self)
                pairingPrk = withUnsafeBytes(of: cp.keys.prk) { Data($0) }
            }
        case PPCP_BS_EV_ABORTED:
            abortReason = BootstrapAbortReason(step.rc)
        default:
            break
        }
        return reply
    }

    private static func out(_ step: ppcp_bs_step) -> Data? {
        step.has_out ? withUnsafeBytes(of: step.out) { Data($0.prefix(Int(step.out_len))) } : nil
    }
}

// MARK: - Helpers

enum BS {
    static func hex(_ s: String) -> Data {
        var d = Data(); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return d
    }
    static func hex(_ d: some ContiguousBytes) -> String {
        d.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
    }
    /// One `ENC` §3 frame with channel 255, written by `libppcp` (CA6 — a
    /// separate write path that never consults `ppcp_channel_validate`).
    static func frame(_ f: ppcp_bs_frame) -> Data {
        var f = f
        var out = [UInt8](repeating: 0, count: 128)
        var n = 0
        _ = ppcp_bs_frame_write(&f, &out, out.count, &n)
        return Data(out.prefix(n))
    }
    static func offer(ct: Data, v: UInt8 = 1) -> Data {
        var f = ppcp_bs_frame()
        f.ty = PPCP_BS_OFFER
        f.v = v
        withUnsafeMutableBytes(of: &f.ct) { ct.copyBytes(to: $0.bindMemory(to: UInt8.self)) }
        return frame(f)
    }
    static func reveal(pk: Data) -> Data {
        var f = ppcp_bs_frame()
        f.ty = PPCP_BS_REVEAL
        withUnsafeMutableBytes(of: &f.pk) { pk.copyBytes(to: $0.bindMemory(to: UInt8.self)) }
        return frame(f)
    }
    static func commit(_ pk: Data) -> Data {
        var ct = [UInt8](repeating: 0, count: 32)
        pk.withUnsafeBytes { ppcp_rv_bs_commit($0.bindMemory(to: UInt8.self).baseAddress, &ct) }
        return Data(ct)
    }
    /// The `ty` of a written frame, read back through `libppcp`.
    static func type(of bytes: Data) -> ppcp_bs_type? {
        var f = ppcp_bs_frame(); var n = 0
        let rc = bytes.withUnsafeBytes {
            ppcp_bs_frame_read($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &f, &n)
        }
        return rc == PPCP_OK ? f.ty : nil
    }
    static func pk(of bytes: Data) -> Data? {
        var f = ppcp_bs_frame(); var n = 0
        let rc = bytes.withUnsafeBytes {
            ppcp_bs_frame_read($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &f, &n)
        }
        guard rc == PPCP_OK else { return nil }
        return withUnsafeBytes(of: f.pk) { Data($0) }
    }
    static func action(_ name: String = "affirm-the-numbers-match") -> BootstrapWindow.UserAction {
        BootstrapWindow.UserAction(control: name)!
    }
    static let t0: Int64 = 1_000_000_000
}

// MARK: - The suite

@Suite("RV §11.5–§11.7 — the acceptor")
struct BootstrapAcceptorTests {

    // MARK: The whole exchange

    @Test("11.5 — five frames, and both ends reach the same six digits and the same PRK")
    func fullExchange() throws {
        let initiator = TestInitiator(agreement: try CryptoKitTestAgreement())
        let acceptor = try BootstrapAcceptor(agreement: try CryptoKitTestAgreement(),
                                             startedAtNs: BS.t0)

        // 1. bs_offer -> 2. bs_accept
        var steps = acceptor.feed(initiator.start(), atNs: BS.t0)
        let accept = try #require(steps.compactMap(\.outgoing).first)
        #expect(BS.type(of: accept) == PPCP_BS_ACCEPT)

        // 3. bs_reveal, then both derive
        steps = acceptor.feed(initiator.feed(accept), atNs: BS.t0)
        let acceptorDigits = try #require(steps.compactMap(\.event?.comparedDigits).first)
        let initiatorDigits = try #require(initiator.digits)

        // ⛔ The digits are compared HERE by a test, which is a thing a test may
        // do and a peer may not (11.1d). Neither implementation compared them.
        #expect(acceptorDigits == initiatorDigits)
        #expect(acceptorDigits.text.count == 6)          // 11.7a

        // 4. each user affirms its own end (11.7c)
        var wire = acceptor.feed(initiator.affirm(), atNs: BS.t0).compactMap(\.outgoing)
        let after = acceptor.affirm(on: BS.action(), atNs: BS.t0)
        wire.append(contentsOf: after.compactMap(\.outgoing))
        for frame in wire { _ = initiator.feed(frame) }

        let pairing = try #require(after.compactMap(\.event?.pairing).first)
        #expect(pairing.sessionId == initiator.pairingSid)          // 11.6d
        #expect(pairing.keys.prk == initiator.pairingPrk)           // 11.6e — the row that matters
        // 11.5h — the connection is closed once both MACs have verified.
        #expect(after.contains { $0.closeConnection })
        // 11.6f — nothing ephemeral survives.
        #expect(acceptor.isFinished)
        #expect(acceptor.digits == nil)
    }

    // MARK: ⛔ Trap 2 — the clause the whole property rests on

    @Test("⛔ 11.5c / trap 2 — bs_accept is emitted on receiving bs_offer, carrying pk_a, with no pk_i in sight")
    func acceptIsEmittedBlind() throws {
        let agreement = try CryptoKitTestAgreement()
        let pkA = agreement.publicKey
        let acceptor = try BootstrapAcceptor(agreement: agreement, startedAtNs: BS.t0)

        // Only `bs_offer` — a commitment, and nothing else. `pk_i` is never sent.
        let pkI = try CryptoKitTestAgreement().publicKey
        let steps = acceptor.feed(BS.offer(ct: BS.commit(pkI)), atNs: BS.t0)

        // ⛔ The reply exists, it is `bs_accept`, and it carries this peer's own
        // `pk_a` — produced by the SAME call that consumed the offer. An acceptor
        // carrying trap 2 would have replied with nothing here and waited for
        // `bs_reveal`, and every other test in this file would still pass.
        let accept = try #require(steps.compactMap(\.outgoing).first)
        #expect(BS.type(of: accept) == PPCP_BS_ACCEPT)
        #expect(BS.pk(of: accept) == pkA)
        #expect(steps.contains { $0.closeConnection } == false)

        // ⚠ And this is the half a static test cannot reach: that `pk_a` was
        // fixed BEFORE the offer arrived. It is true here by construction —
        // `pk_a` was read from the agreement before the acceptor existed — and
        // that construction is the defence, not this assertion.
        #expect(pkA == agreement.publicKey)
    }

    @Test("11.5d — a revealed pk that does not hash to ct is commitment_mismatch, and nothing is derived from it")
    func commitmentMismatch() throws {
        let agreement = try CryptoKitTestAgreement()
        let acceptor = try BootstrapAcceptor(agreement: agreement, startedAtNs: BS.t0)
        let honest = try CryptoKitTestAgreement().publicKey
        let substituted = try CryptoKitTestAgreement().publicKey

        _ = acceptor.feed(BS.offer(ct: BS.commit(honest)), atNs: BS.t0)
        let steps = acceptor.feed(BS.reveal(pk: substituted), atNs: BS.t0)

        let reason = try #require(steps.compactMap(\.event?.abortReason).first)
        #expect(reason == .commitmentMismatch)
        // ⛔ "It MUST NOT derive anything from a `pk_i` that failed this check."
        #expect(agreement.agreements == 0)
        #expect(acceptor.digits == nil)
        // ⛔ 11.9c — a mismatch is not reported in terms that invite a retry.
        #expect(reason.advice == .doNotRetry)
    }

    // MARK: ⛔ Trap 7 — a rejected key is an attack signal (RT-21, the throw half)

    @Test("⛔ 11.6b / 11.11f / trap 7 — a small-order pk_i is invalid_key, is not a transport error, and the curve is asked exactly once")
    func smallOrderKeyIsInvalidKeyAndIsNotRetried() throws {
        // RFC 7748 §6.1's small-order u-coordinates, the same three B14 measures.
        for raw in [String(repeating: "00", count: 32),
                    "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
                    "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"] {
            let agreement = try CryptoKitTestAgreement()
            let acceptor = try BootstrapAcceptor(agreement: agreement, startedAtNs: BS.t0)
            let bad = BS.hex(raw)

            // A well-formed commitment to the bad key, so 11.5d passes and the
            // failure lands where 11.6b puts it rather than one clause earlier.
            _ = acceptor.feed(BS.offer(ct: BS.commit(bad)), atNs: BS.t0)
            let steps = acceptor.feed(BS.reveal(pk: bad), atNs: BS.t0)

            let reason = try #require(steps.compactMap(\.event?.abortReason).first)
            #expect(reason == .invalidKey)
            // ⛔ TRAP 7 IN ONE NUMBER. A retry loop around a rejected key eats
            // 3.7b's single-attempt bound, which is what §11.8's whole argument
            // rests on. Asked once, and once only.
            #expect(agreement.agreements == 1)
            #expect(reason.advice == .doNotRetry)
            #expect(acceptor.isFinished)
            #expect(acceptor.digits == nil)
            // The counterpart is told `invalid_key` and nothing else (11.4g).
            let out = try #require(steps.compactMap(\.outgoing).first)
            #expect(BS.type(of: out) == PPCP_BS_ABORT)
        }
    }

    // MARK: ⛔ Trap 8 — the counterpart's confirmation is not this user's

    @Test("⛔ 11.7c / trap 8 — the counterpart's bs_confirm does not stand in for this device's own user")
    func counterpartConfirmDoesNotAffirm() throws {
        let initiator = TestInitiator(agreement: try CryptoKitTestAgreement())
        let acceptor = try BootstrapAcceptor(agreement: try CryptoKitTestAgreement(),
                                             startedAtNs: BS.t0)
        let accept = try #require(acceptor.feed(initiator.start(), atNs: BS.t0)
            .compactMap(\.outgoing).first)
        _ = acceptor.feed(initiator.feed(accept), atNs: BS.t0)

        // The far user affirms. Its `bs_confirm` arrives here.
        let steps = acceptor.feed(initiator.affirm(), atNs: BS.t0)

        // ⛔ No pairing. 11.5g needs BOTH: this side affirmed AND the
        // counterpart's MAC verified. A peer that paired on this frame alone
        // would authenticate whatever is on the other end.
        #expect(steps.compactMap(\.event?.pairing).isEmpty)
        #expect(acceptor.hasAffirmed == false)
        #expect(acceptor.isFinished == false)

        // ⚠ And the held frame is verified once this side does affirm — the
        // library holds it rather than rejecting it as out of order (it is in
        // order on the wire). Nothing here re-implements that.
        let after = acceptor.affirm(on: BS.action(), atNs: BS.t0)
        #expect(after.compactMap(\.event?.pairing).count == 1)
    }

    @Test("11.7c — declining is `rejected`, the same code a failed MAC gives (11.4f), and no pairing survives")
    func declining() throws {
        let initiator = TestInitiator(agreement: try CryptoKitTestAgreement())
        let acceptor = try BootstrapAcceptor(agreement: try CryptoKitTestAgreement(),
                                             startedAtNs: BS.t0)
        let accept = try #require(acceptor.feed(initiator.start(), atNs: BS.t0)
            .compactMap(\.outgoing).first)
        _ = acceptor.feed(initiator.feed(accept), atNs: BS.t0)

        let steps = acceptor.decline(on: BS.action("numbers-do-not-match"), atNs: BS.t0)
        let reason = try #require(steps.compactMap(\.event?.abortReason).first)
        #expect(reason == .rejected)
        #expect(reason.advice == .doNotRetry)                     // 11.9c
        #expect(acceptor.isFinished)
        #expect(acceptor.digits == nil)                           // 11.7f
        // The counterpart learns `rejected` and cannot tell it from a MAC
        // failure (11.4f), which is 7.7c on this path.
        for frame in steps.compactMap(\.outgoing) { _ = initiator.feed(frame) }
        #expect(initiator.abortReason == .rejected)
    }

    // MARK: 11.3c — the first frame

    @Test("11.3c — a first frame that is not a well-formed bs_offer closes WITHOUT REPLY")
    func firstFrameNotAnOffer() throws {
        let acceptor = try BootstrapAcceptor(agreement: try CryptoKitTestAgreement(),
                                             startedAtNs: BS.t0)
        // A perfectly well-formed frame — of the wrong type, out of order.
        let steps = acceptor.feed(BS.reveal(pk: try CryptoKitTestAgreement().publicKey),
                                  atNs: BS.t0)
        // ⛔ Nothing goes back. Something that has not demonstrated it speaks
        // this protocol gets nothing to learn from.
        #expect(steps.compactMap(\.outgoing).isEmpty)
        #expect(steps.contains { $0.closeConnection })
        #expect(acceptor.isFinished)
    }

    @Test("11.3c — a first frame of junk closes without reply, and a partial frame is held rather than refused")
    func firstFrameJunkAndPartial() throws {
        let a = try BootstrapAcceptor(agreement: try CryptoKitTestAgreement(), startedAtNs: BS.t0)
        #expect(a.feed(Data([0, 0, 0, 4, 255, 0, 0, 0, 0xff, 0xff, 0xff, 0xff]), atNs: BS.t0)
            .compactMap(\.outgoing).isEmpty)
        #expect(a.isFinished)

        // PPCP_ERR_TRUNCATED — read more and retry, do NOT treat as an error.
        let b = try BootstrapAcceptor(agreement: try CryptoKitTestAgreement(), startedAtNs: BS.t0)
        let whole = BS.offer(ct: BS.commit(try CryptoKitTestAgreement().publicKey))
        #expect(b.feed(whole.prefix(5), atNs: BS.t0).isEmpty)
        #expect(b.isFinished == false)
        let steps = b.feed(whole.dropFirst(5), atNs: BS.t0)
        #expect(BS.type(of: try #require(steps.compactMap(\.outgoing).first)) == PPCP_BS_ACCEPT)
    }

    // MARK: 11.7 — the digits

    @Test("11.7a — six decimal digits with leading zeros, and 11.7d's grouping")
    func digitRendering() {
        #expect(BootstrapDigits(value: 42)?.text == "000042")
        #expect(BootstrapDigits(value: 42)?.grouped == "000 042")
        #expect(BootstrapDigits(value: 435948)?.grouped == "435 948")
        #expect(BootstrapDigits(value: 999_999)?.text == "999999")
        #expect(BootstrapDigits(value: 1_000_000) == nil)
        // 7.2b — the value never reaches a log through `description`.
        #expect("\(BootstrapDigits(value: 435948)!)" == "BootstrapDigits(redacted)")
    }

    @Test("11.7e — no part of the digits exists before 11.5d completes")
    func noDigitsBeforeReveal() throws {
        let acceptor = try BootstrapAcceptor(agreement: try CryptoKitTestAgreement(),
                                             startedAtNs: BS.t0)
        #expect(acceptor.digits == nil)
        _ = acceptor.feed(BS.offer(ct: BS.commit(try CryptoKitTestAgreement().publicKey)),
                          atNs: BS.t0)
        // `bs_accept` has been sent; `pk_i` has not arrived. There is nothing to
        // compare and a progressive display would leak the value to whichever
        // side an attacker reached first.
        #expect(acceptor.digits == nil)
    }

    // MARK: 11.3e — the two timers

    @Test("11.3e — 30 seconds to the comparison, 60 more for this device's own user")
    func timeouts() throws {
        // (a) the exchange bound
        let a = try BootstrapAcceptor(agreement: try CryptoKitTestAgreement(), startedAtNs: BS.t0)
        _ = a.feed(BS.offer(ct: BS.commit(try CryptoKitTestAgreement().publicKey)), atNs: BS.t0)
        #expect(a.tick(nowNs: BS.t0 + 29_000_000_000).isEmpty)
        let expired = a.tick(nowNs: BS.t0 + 30_000_000_000)
        #expect(expired.compactMap(\.event?.abortReason).first == .timeout)
        // 11.9c — a timeout carries no implication of an attack and may be
        // reported as the ordinary failure it is.
        #expect(BootstrapAbortReason.timeout.advice == .ordinaryFailure)

        // (b) the affirmation bound, measured from the comparison
        let initiator = TestInitiator(agreement: try CryptoKitTestAgreement())
        let b = try BootstrapAcceptor(agreement: try CryptoKitTestAgreement(), startedAtNs: BS.t0)
        let accept = try #require(b.feed(initiator.start(), atNs: BS.t0)
            .compactMap(\.outgoing).first)
        let atCompare = BS.t0 + 20_000_000_000
        _ = b.feed(initiator.feed(accept), atNs: atCompare)
        #expect(b.tick(nowNs: atCompare + 59_000_000_000).isEmpty)
        #expect(b.tick(nowNs: atCompare + 60_000_000_000)
            .compactMap(\.event?.abortReason).first == .timeout)
    }

    // MARK: 11.6f / RT-23 — erasure on every exit path

    @Test("11.6f as amended by E51 / RT-23 — an aborted attempt leaves nothing, and a wiped acceptor answers nothing")
    func erasureOnEveryExitPath() throws {
        for end in ["abort", "decline", "timeout", "wipe"] {
            let initiator = TestInitiator(agreement: try CryptoKitTestAgreement())
            let acceptor = try BootstrapAcceptor(agreement: try CryptoKitTestAgreement(),
                                                 startedAtNs: BS.t0)
            let accept = try #require(acceptor.feed(initiator.start(), atNs: BS.t0)
                .compactMap(\.outgoing).first)
            // ⛔ Past this line the acceptor holds Z, BK, K_c, the digits, sid,
            // PRK, K_tls and K_id — for a pairing that does not exist and, on
            // every branch below, never will. Computing is not holding.
            _ = acceptor.feed(initiator.feed(accept), atNs: BS.t0)
            #expect(acceptor.digits != nil)

            switch end {
            case "abort":   _ = acceptor.abort(.malformed, atNs: BS.t0)
            case "decline": _ = acceptor.decline(on: BS.action(), atNs: BS.t0)
            case "timeout": _ = acceptor.tick(nowNs: BS.t0 + 200_000_000_000)
            default:        acceptor.wipe()
            }

            #expect(acceptor.isFinished, "\(end)")
            #expect(acceptor.digits == nil, "\(end)")
            #expect(acceptor.hasAffirmed == false, "\(end)")
            // 11.9b — one attempt per acceptor. A second is a NEW one with a
            // newly drawn keypair, after a further explicit user action.
            #expect(acceptor.feed(BS.reveal(pk: Data(repeating: 1, count: 32)),
                                  atNs: BS.t0).isEmpty, "\(end)")
            #expect(acceptor.affirm(on: BS.action(), atNs: BS.t0).isEmpty, "\(end)")
            acceptor.wipe()                              // idempotent
        }
    }

    // MARK: 11.9c — what a screen may offer

    @Test("11.9c / 11.9d1 — every abort reason carries its own advice, and the two that mean an attack invite nothing")
    func abortAdvice() {
        #expect(BootstrapAbortReason.rejected.advice == .doNotRetry)
        #expect(BootstrapAbortReason.commitmentMismatch.advice == .doNotRetry)
        #expect(BootstrapAbortReason.invalidKey.advice == .doNotRetry)
        #expect(BootstrapAbortReason.malformed.advice == .doNotRetry)
        #expect(BootstrapAbortReason.timeout.advice == .ordinaryFailure)
        #expect(BootstrapAbortReason.windowClosed.advice == .ordinaryFailure)
        // 11.9d1 — a second attempt is guaranteed to fail identically, so the
        // pairing code is offered on the FIRST abort, not the second.
        #expect(BootstrapAbortReason.unsupportedVersion.advice == .offerThePairingCode)
        // ⛔ 11.4f — there is no case that tells a user's refusal from a MAC
        // failure, and none may be added.
        #expect(BootstrapAbortReason.allCases.count == 7)
    }

    // MARK: The seam D10 left empty

    @Test("11.3c / 11.4c1 — the offer recogniser is libppcp's, and it agrees with the engine on the same bytes")
    func offerRecogniser() throws {
        let r = LibppcpOfferRecogniser()
        let pk = try CryptoKitTestAgreement().publicKey
        let offer = BS.offer(ct: BS.commit(pk))
        let payload = try #require({ () -> Data? in
            if case .envelope(let p) = BootstrapFirstFrame.classify(offer) { return p }
            return nil
        }())
        #expect(r.isWellFormedOffer(payload: payload))
        #expect(BootstrapFirstFrame.isWellFormedOffer(offer, using: r))

        // A `bs_reveal` is a well-formed frame and is not an offer.
        let reveal = BS.reveal(pk: pk)
        #expect(BootstrapFirstFrame.isWellFormedOffer(reveal, using: r) == false)
        // Junk, an empty payload, and a payload with a trailing byte.
        #expect(r.isWellFormedOffer(payload: Data()) == false)
        #expect(r.isWellFormedOffer(payload: Data([0xff, 0xff])) == false)
        #expect(r.isWellFormedOffer(payload: payload + Data([0x00])) == false)

        // ⚠ The two must agree, because the advertiser decides `close without
        // reply` vs `bs_abort / window_closed` on the recogniser and the engine
        // then decides everything after it.
        let acceptor = try BootstrapAcceptor(agreement: try CryptoKitTestAgreement(),
                                             startedAtNs: BS.t0)
        #expect(acceptor.feed(offer, atNs: BS.t0).compactMap(\.outgoing).isEmpty == false)
        let b = try BootstrapAcceptor(agreement: try CryptoKitTestAgreement(), startedAtNs: BS.t0)
        #expect(b.feed(reveal, atNs: BS.t0).compactMap(\.outgoing).isEmpty)

        // ⛔ D10's stand-in refused everything, which was 11.3c's correct answer
        // for a peer with no acceptor. It must not be what ships with one.
        #expect(BootstrapDecoderUnavailable().isWellFormedOffer(payload: payload) == false)
    }

    // MARK: §10.4 — the published vector, through this platform's curve

    @Test("§10.4 — sk_i, sk_a and Z reproduce on CryptoKit, and the acceptor derives 435948 from them")
    func publishedVector() throws {
        let skI = BS.hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")
        let skA = BS.hex("606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f")
        let agreementI = try CryptoKitTestAgreement(privateKey: skI)
        let agreementA = try CryptoKitTestAgreement(privateKey: skA)

        #expect(BS.hex(agreementI.publicKey)
                == "358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254")
        #expect(BS.hex(agreementA.publicKey)
                == "675dd574ed7789310b3d2e7681f3790b466c773b1521fecf36577958371ea52f")
        #expect(BS.hex(BS.commit(agreementI.publicKey))
                == "f32cd8e62f80f76adb4ba21971efbd10eb71aa6715d9e458f5422c1644357a3a")

        // The whole exchange over the vector's own keys.
        let initiator = TestInitiator(agreement: agreementI)
        let acceptor = try BootstrapAcceptor(agreement: agreementA, startedAtNs: BS.t0)
        let accept = try #require(acceptor.feed(initiator.start(), atNs: BS.t0)
            .compactMap(\.outgoing).first)
        let steps = acceptor.feed(initiator.feed(accept), atNs: BS.t0)

        let digits = try #require(steps.compactMap(\.event?.comparedDigits).first)
        #expect(digits.value == 435948)                        // 11.7a, post-E34
        #expect(digits.grouped == "435 948")

        _ = acceptor.feed(initiator.affirm(), atNs: BS.t0)
        let after = acceptor.affirm(on: BS.action(), atNs: BS.t0)
        let pairing = try #require(after.compactMap(\.event?.pairing).first)
        // ⛔ THE ROW THAT MATTERS. Two peers agreeing on six digits and
        // disagreeing here show a successful comparison and then fail TLS with
        // PSK_IDENTITY_NOT_FOUND, which looks exactly like 3.5d's platform limit.
        #expect(BS.hex(pairing.keys.prk)
                == "3e351aef1e5fe48411e969526b079830494d2cf13104d661694e897598ccf8c9")
        #expect(pairing.sessionId == "1cc4b886-e8bd-45e0-a3b2-07ae783bc56b")   // 11.6d
        #expect(BS.hex(pairing.keys.tlsKey)
                == "240b513437501f3ab8602b06b45cd84577f10f126bdc497d3cf797c9559856b0")
        #expect(BS.hex(pairing.keys.identityKey)
                == "9e8c8b155b89fcc9b70f4043ddaa607a7ff7acec20dc326f5c307661956a0bd9")
    }

    // MARK: RT-24c — the R-11 witness, which needs a curve

    @Test("⛔ RT-24c / 11.6c2 — X25519 is not contributory: a different pk_a yields a bit-identical Z, and only sas_raw separates the peers")
    func r11Witness() throws {
        let skI = BS.hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")
        let pkA = BS.hex("675dd574ed7789310b3d2e7681f3790b466c773b1521fecf36577958371ea52f")
        let pkAPrime = BS.hex("87abc1e84c4c5572d2b1e63c69f5617a215518cf6261eb5a0e7db49ddad34208")
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: skI)
        let pkI = priv.publicKey.rawRepresentation

        // ⛔ The one call that settles whether 11.6c2 is over-cautious. Clamping
        // forces every scalar to a multiple of 8, so a legitimate key plus a
        // small-order component agrees to the SAME non-zero Z. 11.6b does not
        // fire: the agreement succeeds and Z is not zero.
        func z(_ pk: Data) throws -> Data {
            let s = try priv.sharedSecretFromKeyAgreement(
                with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pk))
            return s.withUnsafeBytes { Data($0) }
        }
        let z1 = try z(pkA), z2 = try z(pkAPrime)
        #expect(pkA != pkAPrime)
        #expect(z1 == z2)
        #expect(BS.hex(z1) == "7c79d7b5f31b9aac367477f5f7c7a68b5c44cac28ed5c902a59ec48c02956a6a")
        #expect(z1.contains { $0 != 0 })            // non-zero, so 11.6b is silent

        // BK, sid and PRK are therefore IDENTICAL under the substitution. Only
        // `sas_raw`'s explicit `pk_i || pk_a` separates the two peers — which is
        // exactly why removing it is undetectable from outside.
        func derive(_ pkALeg: Data) -> ppcp_rv_bootstrap {
            var out = ppcp_rv_bootstrap()
            _ = z1.withUnsafeBytes { zb in
                pkI.withUnsafeBytes { ib in
                    pkALeg.withUnsafeBytes { ab in
                        ppcp_rv_bootstrap_derive(zb.bindMemory(to: UInt8.self).baseAddress, 1,
                                                 ib.bindMemory(to: UInt8.self).baseAddress,
                                                 ab.bindMemory(to: UInt8.self).baseAddress, &out)
                    }
                }
            }
            return out
        }
        var honest = derive(pkA)
        var substituted = derive(pkAPrime)
        #expect(honest.sas == 435948)
        #expect(substituted.sas == 485158)
        #expect(withUnsafeBytes(of: honest.prk) { Data($0) }
                == withUnsafeBytes(of: substituted.prk) { Data($0) })
        #expect(withUnsafeBytes(of: honest.sid) { Data($0) }
                == withUnsafeBytes(of: substituted.sid) { Data($0) })
        ppcp_rv_bootstrap_wipe(&honest)
        ppcp_rv_bootstrap_wipe(&substituted)
    }
}

// MARK: - 11.7d and 11.9c — the two UX MUSTs

@Suite("RV 11.7d / 11.9c — what a screen may offer")
struct GuidedPairingPromptTests {

    static func closed(_ reason: BootstrapWindow.CloseReason,
                       _ why: BootstrapAbortReason? = nil) -> BootstrapWindow.Close {
        BootstrapWindow.Close(reason: reason, atNs: 0, abortReason: why)
    }

    @Test("⛔ 11.7d — the prompt asks whether the numbers MATCH, not whether to trust or continue")
    func theQuestionIsMatch() {
        let p = GuidedPairingPrompt.compare(dl: "Bay 3")
        #expect(p.heading == "Do these numbers match?")
        // The words 11.7d rules out. A dialogue whose default is *Continue* is a
        // dialogue that authenticates whatever is on the other end.
        let forbidden = ["trust", "continue", "connect", "allow", "accept"]
        let lowered = p.heading.lowercased()
        for word in forbidden {
            #expect(lowered.contains(word) == false, "the heading must not say '\(word)'")
        }
        #expect(p.affirmative == "Yes, they match")
        #expect(p.dismissive == "They don't match")
        // ⚠ The digits are not interpolated into a sentence — they are rendered
        // at their own size and grouped by `BootstrapDigits.grouped`, because a
        // string in a sentence is a string somebody reformats and 11.7d requires
        // both peers to group identically.
        #expect(p.body.contains("313") == false)
    }

    @Test("⛔ 11.9c — a mismatch offers NO affirmative control at all")
    func aMismatchInvitesNothing() {
        for why in [BootstrapAbortReason.rejected,
                    .commitmentMismatch,
                    .invalidKey,
                    .malformed] {
            let p = GuidedPairingPrompt.ended(
                Self.closed(.attemptAbortedOrRejected, why))
            // ⛔ Not a disabled control and not one behind a confirmation — none.
            #expect(p.affirmative == nil, "\(why) must offer nothing affirmative")
            #expect(p.offersRetry == false, "\(why)")
            #expect(p.body.lowercased().contains("do not try again"), "\(why)")
        }
    }

    @Test("11.9c — a timeout or a closed connection is the ordinary failure it is")
    func anOrdinaryFailureMayInviteARetry() {
        for close in [Self.closed(.attemptAbortedOrRejected, .timeout),
                      Self.closed(.timedOut),
                      Self.closed(.userClosed)] {
            let p = GuidedPairingPrompt.ended(close)
            #expect(p.offersRetry, "\(close.reason) carries no implication of an attack")
            // ⚠ 11.9b still binds: this control starts a NEW attempt, it does not
            // reopen the window that closed.
            #expect(p.affirmative == "Open a new window")
        }
    }

    @Test("11.9d1 / 11.4e — an unsupported version offers the pairing code, and says why in terms a user can act on")
    func unsupportedVersionOffersTheCode() {
        let p = GuidedPairingPrompt.ended(
            Self.closed(.attemptAbortedOrRejected, .unsupportedVersion))
        #expect(p.offersThePairingCode)
        #expect(p.offersRetry == false, "a second attempt is guaranteed to fail identically")
        // 11.4e — "reports to its USER that the counterpart requires a newer
        // version of the application, not a generic failure".
        #expect(p.heading.lowercased().contains("newer version"))
    }

    @Test("A completed pairing is not reported as a failure, and offers no retry")
    func completionReadsAsCompletion() {
        let p = GuidedPairingPrompt.ended(Self.closed(.pairingCompleted))
        #expect(p.heading == "Paired")
        #expect(p.offersRetry == false)
        #expect(p.affirmative == nil)
    }
}
