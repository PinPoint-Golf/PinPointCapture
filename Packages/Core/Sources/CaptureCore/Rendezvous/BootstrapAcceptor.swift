//  BootstrapAcceptor.swift
//  `PPCP-RV` §11.5–§11.7 — this device as the **acceptor** of a guided pairing.
//
//  ⛔⛔ **TRAP 2 IS THIS FILE'S REASON TO EXIST, AND IT IS INVISIBLE.**
//  11.5c: `bs_accept` carries `pk_a` **having seen only a commitment to
//  `pk_i`**, and it is emitted **on receiving `bs_offer` and never later**.
//  Sending it after `pk_i` arrives saves a round trip, reads as an obvious
//  optimisation, and **destroys the security of the entire path**: an interposer
//  then chooses its key *after* seeing the honest one and grinds candidates until
//  both legs display the same six digits — 2²⁰ trials, seconds of work. ⛔
//  **Nothing on the wire changes and no static test in this repository can see
//  it.** `ppcp-relay --probe order-acceptor` is the only thing that can, and it
//  can only because it withholds `bs_reveal` and checks `pk_a` already arrived.
//
//  **How this file is built so the trap is unreachable rather than merely
//  avoided.** `pk_a` is taken at construction, before any frame exists, and
//  `libppcp` returns `bs_accept` **in the same call** that consumes `bs_offer`.
//  There is no state here in which a `pk_i` has been seen and a `bs_accept` has
//  not been sent, so there is no code that could be reordered into the trap.
//  That is CA2's argument arriving where it matters: four of the nine traps live
//  in the exchange, and one implementation of them is one place to get them
//  right. **This file writes no frame and decodes no CBOR.**
//
//  ⛔ **TRAP 8 — THIS FILE NEVER COMPARES THE DIGITS AND OFFERS NO CALL THAT
//  WOULD** (11.1d). The comparison has value *only* because it crosses a channel
//  the attacker is not on, and the only such channel is a person looking at two
//  screens. `digits` hands them to a screen; `affirm(on:)` takes a decision a
//  person made. A peer that matched them in software, or accepted the
//  counterpart's `bs_confirm` as standing in for its own user (11.7c), would pass
//  every static test in the document and authenticate nothing.
//
//  ⛔ **TRAP 6 — nothing is held that has not been earned** (11.6f as amended by
//  E51, 11.5g). A peer computes the whole chain the moment it holds `Z` —
//  `BK`, `K_c`, the digits, `sid`, `PRK`, `K_tls`, `K_id` — and 11.3e allows
//  sixty seconds of that before either user has affirmed and the pairing exists
//  at all. So on **every** exit path the engine is wiped: on success the pairing
//  is moved out and the engine erased as it goes, on failure everything goes
//  including the `PRK` for a pairing that will never exist. **Computing is not
//  holding.**
//
//  ⛔ **TRAP 7 — a failed key agreement is an ATTACK SIGNAL, not a transport
//  error, and it is never retried** (11.6b, 11.11f). See
//  `BootstrapKeyAgreement`; there is no loop around `agree` in this file and none
//  may be added.
//
//  ⚠ **The counterpart's `bs_confirm` may arrive before this side has been handed
//  `Z`**, because `Z` is supplied asynchronously to the socket. The frame is **in
//  order on the wire** and `libppcp` holds it and verifies once `K_c` exists. ⛔
//  Do **not** re-implement ordering around it: a state machine written here that
//  rejected it as out-of-order would be a second, disagreeing implementation of
//  §11.5's order table.
//
//  Spec: `RV` §11.5, §11.6, §11.7, 11.3e, 11.9a, 11.9c, §11.11. Plan D11.

import Foundation
import CPPCP

// MARK: - The six digits (11.7)

/// `RV` 11.7a — `sas_raw` as a big-endian `UInt32` modulo 1 000 000, rendered as
/// **exactly six decimal digits with leading zeros**. `000042` is a valid string
/// and MUST be shown as six characters.
///
/// ⛔ 11.7f — these are a function of two ephemeral keys and are **meaningless
/// outside the attempt that produced them**. They are not reused, not cached and
/// not shown again after the attempt ends; `BootstrapAcceptor.digits` returns
/// `nil` outside the comparison window and the value is gone from memory the
/// moment the handshake ends. Whoever renders them drops them with the screen.
///
/// ⛔ 7.2b / 11.7f — `description` says nothing, so a stray log line cannot leak
/// the value an attacker is trying to steer.
public struct BootstrapDigits: Sendable, Equatable, CustomStringConvertible {

    /// 0…999 999.
    public let value: UInt32

    public init?(value: UInt32) {
        guard value < 1_000_000 else { return nil }
        self.value = value
    }

    /// 11.7a — exactly six characters, leading zeros included.
    public var text: String { String(format: "%06u", value) }

    /// 11.7d — **both peers group them identically**, `313 164`. The grouping is
    /// part of making comparison the obvious act rather than a decoration: two
    /// screens that group differently are two strings a tired operator will
    /// compare wrongly.
    public var grouped: String {
        let s = text
        let cut = s.index(s.startIndex, offsetBy: 3)
        return "\(s[s.startIndex..<cut]) \(s[cut...])"
    }

    public var description: String { "BootstrapDigits(redacted)" }
}

// MARK: - Why an attempt ended (11.4's rc table)

/// `RV` §11.4's abort reason codes, which are the whole vocabulary — 11.4g
/// forbids `bs_abort` carrying anything beyond `rc`: no message, no diagnostic
/// string, no peer name.
///
/// ⛔ 11.4f — **a user's refusal and a failed confirmation MAC are the same code**
/// and are indistinguishable to the counterpart. There is no separate case for
/// either and none may be added. ⚠ And the reasoning is the opposite of the
/// obvious one (E37): an interposed attacker **cannot fail this MAC** — it holds
/// `Z` on both legs, therefore `K_c` on both, and forges both correctly and
/// trivially, which is what winning the comparison means. A MAC failure is
/// evidence that no such attacker is present and that something else is wrong,
/// overwhelmingly an implementation disagreement of the `PRK`-divergence class.
/// **The MAC is not the authentication check. The comparison is.**
public enum BootstrapAbortReason: UInt32, Sendable, Equatable, CaseIterable {
    /// 11.4e — `v` not implemented.
    case unsupportedVersion = 1
    /// 11.5d — the revealed `pk` does not hash to the `ct` that was committed.
    case commitmentMismatch = 2
    /// 11.6b — the key agreement failed or produced an all-zero `Z`. ⛔ An attack
    /// signal, never a transport error, never retried.
    case invalidKey = 3
    /// 11.4f — the user declined, **or** a confirmation MAC did not verify.
    case rejected = 4
    /// 11.3e.
    case timeout = 5
    /// 11.3c / 11.3d — no window open, or one attempt already running.
    case windowClosed = 6
    /// 11.4c / 11.4c1.
    case malformed = 7

    init?(_ c: ppcp_bs_reason) { self.init(rawValue: UInt32(c.rawValue)) }

    var c: ppcp_bs_reason { ppcp_bs_reason(UInt32(rawValue)) }

    /// ⛔ **11.9c, and it is unusual for a specification to state — which is why
    /// it is a value on the reason rather than a decision a screen makes.**
    ///
    /// Every other failure in `RV` is a network problem, and users learn from
    /// those that retrying is what one does. A mismatch is the **one** signal
    /// this path produces that an attack is under way, and a dialogue whose
    /// reflex is *try again* converts a one-shot bound into an unbounded one by
    /// way of the operator's muscle memory.
    public var advice: BootstrapAbortAdvice {
        switch self {
        // 11.9c names these two: a mismatch (the user said the numbers differ,
        // or the revealed key did not match its commitment) and a MAC failure.
        case .rejected, .commitmentMismatch:
            return .doNotRetry
        // ⛔ 11.6b's retry prohibition is explicit and stronger than 11.9c's:
        // "MUST NOT treat such a failure as a transport error and MUST NOT retry
        // it", because a retry loop eats 3.7b's single-attempt bound.
        case .invalidKey:
            return .doNotRetry
        // ⚠ 11.9c does not name `malformed`, and this is a **choice, stated as
        // one**. Suppressing an invited retry for a junk frame costs a user one
        // extra tap on a control they can still reach; inviting one where the
        // cause was an active party on the link costs the bound. The asymmetry
        // decides it, not the clause.
        case .malformed:
            return .doNotRetry
        // 11.9d1 — a second attempt is *guaranteed* to fail identically, because
        // 11.4h has the initiator offer the highest `v` it implements and forbids
        // proposing lower. So the honest answer is the pairing code on the FIRST
        // abort, not the second, and 11.4e requires the user be told the
        // counterpart needs a newer version rather than given a generic failure.
        case .unsupportedVersion:
            return .offerThePairingCode
        // 11.9c — "a timeout or a closed connection carries no such implication
        // and may be reported as the ordinary failure it is".
        case .timeout, .windowClosed:
            return .ordinaryFailure
        }
    }
}

/// What a screen is allowed to offer after an abort — `RV` 11.9c and 11.9d1.
public enum BootstrapAbortAdvice: Sendable, Equatable {
    /// The ordinary failure it is. *Try again* is a reasonable next step, and
    /// 11.9b still requires that the retry come from a **further explicit user
    /// action** rather than from the screen reopening the window itself.
    case ordinaryFailure
    /// ⛔ *"The numbers did not match — do not retry until you know why."* The
    /// affirmative next step is **not** offered.
    case doNotRetry
    /// 11.9d1 / 11.4e — the counterpart needs a newer version of the
    /// application. Offer §4's pairing code, which is REQUIRED of every
    /// implementation (2a) and does not depend on multicast.
    case offerThePairingCode
}

// MARK: - What a completed exchange yields (11.6e)

/// `RV` 11.6e — and **11.1a is the point of its shape**: from here the pairing is
/// *indistinguishable* from one established by a scanned code, so §5, §7.4 and
/// §7.5 apply verbatim and are unchanged by §11. These are exactly the values the
/// pairing-code path already hands the embedding.
///
/// ⛔ 11.5g — an instance of this exists **only** where this side has affirmed
/// **and** the counterpart's MAC has verified. Until then a peer holds nothing
/// and MUST NOT persist, advertise, or offer anything derived from the exchange.
public struct BootstrapPairing: Sendable, CustomStringConvertible {
    /// 11.6d / 4.3e — `sid`, a derived version-4 UUID, in `Session.id`'s
    /// canonical lowercase text form.
    public let sessionId: String
    /// 11.6e — `PRK`, `K_tls` and `K_id`, §5.1's derivation taken verbatim.
    public let keys: RendezvousKeys

    public var description: String { "BootstrapPairing(redacted)" }  // 7.2b
}

// MARK: - The acceptor

/// This device driving `libppcp`'s §11.5 exchange as the acceptor.
///
/// ⚠ **Not `Sendable`, deliberately.** It holds a C engine by value and one
/// attempt's key material; it belongs to exactly one actor for the life of the
/// attempt. 11.3d allows **at most one attempt at a time**, so there is nothing
/// to gain from making it shareable and a real risk in doing so.
public final class BootstrapAcceptor {

    // MARK: Bounds (11.3e)

    /// 11.3e — an attempt that has not reached the comparison within 30 seconds
    /// is aborted.
    ///
    /// ⚠ **The reading, stated because the clause can be read two ways.** 11.3e
    /// says *"an attempt that has not reached 11.5f within 30 seconds is aborted,
    /// and one awaiting a user's affirmation is aborted after 60"*. A peer reaches
    /// 11.5f when it sends `bs_confirm`, which is when its user affirms — so read
    /// literally the two bounds contradict. The only consistent reading is that
    /// the 30 seconds bound everything up to the point where only the users
    /// remain, and the 60 then bound the wait for this device's own. That is what
    /// is implemented. Both are SHOULDs; 3.7b's 180-second window is the MUST and
    /// it binds regardless, and `BootstrapWindow` already holds it.
    public static let exchangeTimeoutNs: Int64 = 30 * 1_000_000_000
    /// 11.3e — awaiting this device's own user (11.7c).
    public static let affirmationTimeoutNs: Int64 = 60 * 1_000_000_000

    /// The largest bootstrap frame, taken from `libppcp`'s own step buffer rather
    /// than written down here — `PPCP_BS_MAX_FRAME`, and §11's vocabulary is
    /// CLOSED (11.10a) so it never grows.
    public static var maximumFrameBytes: Int {
        MemoryLayout.size(ofValue: ppcp_bs_step().out)
    }

    // MARK: Results

    /// One transition of the engine.
    ///
    /// ⚠ **Not `Equatable`, and that is 7.2b rather than an omission.** An
    /// `Event` can carry a `BootstrapPairing`, and an equality operator over key
    /// material is a comparison somebody eventually writes in non-constant time.
    /// The accessors below are what a caller matches on.
    public struct Step: Sendable {
        /// Bytes to put on the bootstrap connection, in order.
        public let outgoing: Data?
        /// What the embedding must now do, if anything.
        public let event: Event?
        /// 11.5h on success, 11.9a on any abort — the connection is finished
        /// with. It is not reused, not upgraded in place and not held open.
        public let closeConnection: Bool
    }

    public enum Event: Sendable {
        /// ⛔ 11.7b/11.7c — **display these to a person and ask whether they
        /// MATCH.** Do not compare them here (11.1d). Do not pre-select the
        /// affirmative control (11.7d).
        case compare(BootstrapDigits)
        /// 11.5g — this side affirmed **and** the counterpart's MAC verified.
        /// Only now does the pairing exist.
        case paired(BootstrapPairing)
        /// The attempt is over and nothing survives it (11.9a).
        case aborted(BootstrapAbortReason)

        public var comparedDigits: BootstrapDigits? {
            if case .compare(let d) = self { return d }
            return nil
        }
        public var pairing: BootstrapPairing? {
            if case .paired(let p) = self { return p }
            return nil
        }
        public var abortReason: BootstrapAbortReason? {
            if case .aborted(let r) = self { return r }
            return nil
        }
    }


    public enum Failure: Error, Sendable, Equatable {
        /// The engine refused the call in the state it is in — a terminal engine
        /// asked to do more, which 11.9b's "one attempt per engine" makes the
        /// correct answer rather than a bug.
        case notInThatState
        /// 11.11a — `pk` is 32 octets.
        case publicKeyLength(Int)
    }

    // MARK: Stored

    /// ⚠ **CA8's residual risk lives here and is accepted by the maintainer**:
    /// the engine embeds `ppcp_rv_bootstrap` and `ppcp_bs_pairing` by value, so
    /// key material sits in *this* object's memory for the handshake's duration.
    /// The API cannot force the erasure; `wipe()` and `deinit` are what discharge
    /// it, and every exit path below goes through one of them.
    private var engine = ppcp_bs_engine()
    /// ⛔ 11.11h — dropped on `wipe()` so the platform's hold on the private
    /// scalar ends with the attempt (11.11h1 bounds what that can guarantee).
    private var agreement: (any BootstrapKeyAgreement)?
    private var inbox = Data()
    private let startedAtNs: Int64
    private var comparisonReachedAtNs: Int64?
    private var affirmedAtNs: Int64?
    private var finished = false

    /// - Parameters:
    ///   - agreement: §11.11's supplier. ⛔ A **fresh** one per attempt (11.5a).
    ///   - startedAtNs: when the attempt began, for 11.3e. Core owns no clock.
    ///   - v: the bootstrap format version this peer implements, 1…255 (11.4h1).
    ///     ⚠ 11.4h1 has an acceptor **echo** the `v` it received or abort with
    ///     `unsupported_version`; it never substitutes one. `libppcp` does that,
    ///     and this parameter is what it is checked against.
    public init(agreement: any BootstrapKeyAgreement,
                startedAtNs: Int64,
                v: UInt8 = UInt8(PPCP_BS_VERSION)) throws {
        let pk = agreement.publicKey
        guard pk.count == Int(PPCP_RV_BS_KEY_BYTES) else {
            throw Failure.publicKeyLength(pk.count)
        }
        self.agreement = agreement
        self.startedAtNs = startedAtNs
        // ⛔ **`pk_a` IS FIXED HERE, BEFORE ANY FRAME EXISTS.** 11.5c, trap 2.
        // By the time an offer arrives this peer's key is already chosen, so no
        // reordering of the code below can produce an acceptor that chose after
        // seeing `pk_i`.
        var e = ppcp_bs_engine()
        let rc = pk.withUnsafeBytes { raw in
            ppcp_bs_engine_init(&e, PPCP_BS_ROLE_ACCEPTOR, v,
                                raw.bindMemory(to: UInt8.self).baseAddress)
        }
        guard rc == PPCP_OK else {
            ppcp_bs_engine_wipe(&e)
            throw PpcpLibraryError(rc)
        }
        engine = e
    }

    deinit { wipe() }

    // MARK: Reading

    /// 11.7e / 11.7f — the digits, and **only** between the comparison and the
    /// end of the attempt. `libppcp` refuses outside that window, which is why
    /// this is asked rather than remembered: 11.7e forbids showing any part of
    /// them before 11.5d completes and 11.7f forbids showing them again after.
    public var digits: BootstrapDigits? {
        guard !finished else { return nil }
        var raw: UInt32 = 0
        guard ppcp_bs_engine_sas(&engine, &raw) == PPCP_OK else { return nil }
        return BootstrapDigits(value: raw)
    }

    /// True once the attempt has ended, whatever the outcome. 11.9b: a second
    /// attempt is a **new** acceptor with a newly drawn keypair, and only after a
    /// further explicit user action.
    public var isFinished: Bool { finished }

    /// Whether this device's own user has affirmed (11.7c).
    public var hasAffirmed: Bool { affirmedAtNs != nil }

    // MARK: Driving

    /// Feed whatever arrived on the connection.
    ///
    /// ⚠ Partial frames are held and retried, which is `PPCP_ERR_TRUNCATED` —
    /// **do not** treat a short read as a protocol error.
    ///
    /// ⛔ The first well-formed `bs_offer` produces `bs_accept` **in the step this
    /// returns** (11.5c, trap 2). A first frame that is *not* a well-formed
    /// `bs_offer` produces a step with no `outgoing` and `closeConnection` true —
    /// 11.3c's close **without reply**, because something that has not
    /// demonstrated it speaks this protocol gets nothing to learn from.
    public func feed(_ bytes: Data, atNs nowNs: Int64) -> [Step] {
        guard !finished else { return [] }
        inbox.append(bytes)

        // Belt and braces, and it is not the real bound: `ppcp_bs_frame_read`
        // refuses a payload over `PPCP_BS_MAX_PAYLOAD` on the length alone, so a
        // stranger cannot make this grow. What it does catch is a peer that
        // dribbles seven bytes and stops — 11.3e's timeout is the answer to that,
        // and this keeps the buffer bounded until the timer fires.
        let cap = Self.maximumFrameBytes * 4
        if inbox.count > cap {
            inbox.removeAll(keepingCapacity: false)
            return abortInternally(.malformed)
        }

        var steps: [Step] = []
        while !finished && !inbox.isEmpty {
            var raw = ppcp_bs_step()
            var consumed = 0
            let rc = inbox.withUnsafeBytes { buf in
                ppcp_bs_engine_recv(&engine,
                                    buf.bindMemory(to: UInt8.self).baseAddress,
                                    buf.count, &consumed, &raw)
            }
            if rc == PPCP_ERR_TRUNCATED { break }        // read more, retry
            if rc != PPCP_OK {
                // The engine refuses in a terminal state. Nothing more is owed.
                break
            }
            if consumed > 0 { inbox.removeFirst(consumed) }

            steps.append(contentsOf: translate(raw, atNs: nowNs))
            if consumed == 0 { break }                   // no progress possible
        }
        return steps
    }

    /// ⛔ **THIS DEVICE'S OWN USER affirmed that the numbers match** (11.7c).
    ///
    /// A single affirmation at one end does not establish a pairing at the other,
    /// and a peer MUST NOT treat the arrival of the counterpart's `bs_confirm` as
    /// standing in for its own user's. The engine cannot tell a real affirmation
    /// from a synthesised one — that is what makes trap 8 a **review** row and not
    /// a test — so the affirmation is spelled as a `UserAction`, which has to name
    /// the control that was operated. That does not prove a human; it makes every
    /// path that claims one greppable, and there is exactly one.
    @discardableResult
    public func affirm(on action: BootstrapWindow.UserAction, atNs nowNs: Int64) -> [Step] {
        guard !finished, comparisonReachedAtNs != nil, affirmedAtNs == nil else { return [] }
        _ = action                                       // named for the record
        var raw = ppcp_bs_step()
        guard ppcp_bs_engine_affirm(&engine, &raw) == PPCP_OK else { return [] }
        affirmedAtNs = nowNs
        return translate(raw, atNs: nowNs)
    }

    /// The user said the numbers do **not** match, or declined.
    ///
    /// ⛔ 11.4f — reported as `rejected`, the same code a failed MAC produces, and
    /// indistinguishable to the counterpart.
    @discardableResult
    public func decline(on action: BootstrapWindow.UserAction, atNs nowNs: Int64) -> [Step] {
        _ = action
        return abortInternally(.rejected, atNs: nowNs)
    }

    /// The embedding's own reasons — 11.3e's timers, 3.7b's window, a dropped
    /// connection.
    @discardableResult
    public func abort(_ reason: BootstrapAbortReason, atNs nowNs: Int64) -> [Step] {
        abortInternally(reason, atNs: nowNs)
    }

    /// 11.3e's two bounds. Core owns no clock, so a timer calls this.
    ///
    /// ⚠ Like `BootstrapWindow.tick`, this can **end** an attempt and can never
    /// start one.
    @discardableResult
    public func tick(nowNs: Int64) -> [Step] {
        guard !finished else { return [] }
        if let reached = comparisonReachedAtNs {
            if affirmedAtNs == nil, nowNs - reached >= Self.affirmationTimeoutNs {
                return abortInternally(.timeout, atNs: nowNs)
            }
            return []
        }
        if nowNs - startedAtNs >= Self.exchangeTimeoutNs {
            return abortInternally(.timeout, atNs: nowNs)
        }
        return []
    }

    /// ⛔ **11.6f — erase on every exit path, whether it succeeded or failed.**
    /// Idempotent, and safe on any path the embedding abandons: a dropped
    /// connection, a closed window, a user who walked away. On a failed handshake
    /// the erasure includes `PRK`, `K_tls`, `K_id` and `sid` where they were
    /// computed (E51) — a peer holds all of them from the moment it has `Z`, and
    /// until 11.5g is met that is a `PRK` for a pairing that does not exist and
    /// never will.
    public func wipe() {
        ppcp_bs_engine_wipe(&engine)
        agreement = nil
        inbox.removeAll(keepingCapacity: false)
        finished = true
    }

    // MARK: Internals

    private func abortInternally(_ reason: BootstrapAbortReason,
                                 atNs nowNs: Int64 = 0) -> [Step] {
        guard !finished else { return [] }
        var raw = ppcp_bs_step()
        guard ppcp_bs_engine_abort(&engine, reason.c, &raw) == PPCP_OK else {
            wipe()
            return [Step(outgoing: nil, event: .aborted(reason), closeConnection: true)]
        }
        return translate(raw, atNs: nowNs)
    }

    /// One C step to zero or more Swift steps.
    ///
    /// ⛔ `NEED_SECRET` never leaves this file. §11.11's boundary is *below* the
    /// derivation, so the acceptor computes `Z` and hands it straight back; the
    /// embedding above never sees `Z`, `pk_i` or anything else 11.11d keeps on
    /// this side.
    private func translate(_ raw: ppcp_bs_step, atNs nowNs: Int64) -> [Step] {
        let out: Data? = raw.has_out
            ? withUnsafeBytes(of: raw.out) { Data($0.prefix(Int(raw.out_len))) }
            : nil

        switch raw.event {
        case PPCP_BS_EV_NEED_SECRET:
            let peerPk = withUnsafeBytes(of: raw.peer_pk) { Data($0) }
            var steps: [Step] = []
            if out != nil || raw.close {
                steps.append(Step(outgoing: out, event: nil, closeConnection: raw.close))
            }
            steps.append(contentsOf: supplySecret(peerPublicKey: peerPk, atNs: nowNs))
            return steps

        case PPCP_BS_EV_COMPARE:
            comparisonReachedAtNs = nowNs
            guard let d = digits else {
                // The engine said COMPARE and then refused the digits, which
                // would be a library defect rather than a peer's doing. Abort
                // rather than show a screen with nothing on it.
                return abortInternally(.malformed, atNs: nowNs)
            }
            var steps: [Step] = []
            if out != nil { steps.append(Step(outgoing: out, event: nil, closeConnection: false)) }
            steps.append(Step(outgoing: nil, event: .compare(d), closeConnection: raw.close))
            return steps

        case PPCP_BS_EV_PAIRED:
            // ⛔ TRAP 6. Move the pairing out and erase the engine in the same
            // breath — `take_pairing` erases as it copies, and `wipe()` closes
            // every other door. Nothing that was ephemeral survives this line.
            var cp = ppcp_bs_pairing()
            let rc = ppcp_bs_engine_take_pairing(&engine, &cp)
            var steps: [Step] = []
            if out != nil { steps.append(Step(outgoing: out, event: nil, closeConnection: false)) }
            guard rc == PPCP_OK, let pairing = Self.pairing(from: &cp) else {
                Self.erase(&cp)
                wipe()
                steps.append(Step(outgoing: nil, event: .aborted(.malformed), closeConnection: true))
                return steps
            }
            Self.erase(&cp)
            wipe()
            // 11.5h — the bootstrap connection is closed once both MACs have
            // verified. It is not reused and not upgraded in place; the peers
            // reconnect under §5, in whichever direction 11.2b puts them.
            steps.append(Step(outgoing: nil, event: .paired(pairing), closeConnection: true))
            return steps

        case PPCP_BS_EV_ABORTED:
            let reason = BootstrapAbortReason(raw.rc) ?? .malformed
            wipe()
            return [Step(outgoing: out, event: .aborted(reason), closeConnection: true)]

        default:
            guard out != nil || raw.close else { return [] }
            if raw.close { wipe() }
            return [Step(outgoing: out, event: nil, closeConnection: raw.close)]
        }
    }

    /// ⛔ **11.11f's throw half, and trap 7 in four lines.** A `CryptoKit` throw
    /// and an all-zero `Z` are the same event; both are `invalid_key`; neither is
    /// a transport error; **neither is retried**. There is no loop here and none
    /// may be added — a retry loop eats 3.7b's single-attempt bound, which is what
    /// §11.8's whole argument rests on.
    private func supplySecret(peerPublicKey: Data, atNs nowNs: Int64) -> [Step] {
        guard let agreement else { return abortInternally(.invalidKey, atNs: nowNs) }
        var raw = ppcp_bs_step()
        do {
            let rc = try agreement.withSharedSecret(peerPublicKey: peerPublicKey) { z in
                ppcp_bs_engine_supply_secret(
                    &engine, z.bindMemory(to: UInt8.self).baseAddress, &raw)
            }
            // The library's half of 11.11f: an all-zero `Z` comes back here.
            guard rc == PPCP_OK else { return abortInternally(.invalidKey, atNs: nowNs) }
        } catch {
            return abortInternally(.invalidKey, atNs: nowNs)
        }
        return translate(raw, atNs: nowNs)
    }

    /// ⛔ 11.6f — the copy `take_pairing` handed out is erased the moment it has
    /// been read. `libppcp` erased its own as it copied; this is the other half,
    /// and it is on this side of the boundary because the struct is ours.
    private static func erase(_ cp: inout ppcp_bs_pairing) {
        _ = withUnsafeMutablePointer(to: &cp) {
            memset($0, 0, MemoryLayout<ppcp_bs_pairing>.size)
        }
    }

    private static func pairing(from cp: inout ppcp_bs_pairing) -> BootstrapPairing? {
        var text = [CChar](repeating: 0, count: Int(PPCP_RV_SESSION_ID_CHARS))
        let rc = withUnsafeBytes(of: cp.sid) { sid in
            ppcp_rv_sid_to_session_id(sid.bindMemory(to: UInt8.self).baseAddress, &text)
        }
        guard rc == PPCP_OK else { return nil }
        let sessionId = String(decoding: text.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                               as: UTF8.self)
        // 11.6e is §5.1 unchanged, so the keys are re-derived from `PRK` by the
        // one function the pairing-code path already uses — 11.1a's
        // indistinguishability expressed as shared code rather than as a claim.
        let prk = withUnsafeBytes(of: cp.keys.prk) { Data($0) }
        guard let keys = try? RendezvousKeys(persistedPrk: prk) else { return nil }
        return BootstrapPairing(sessionId: sessionId, keys: keys)
    }
}
