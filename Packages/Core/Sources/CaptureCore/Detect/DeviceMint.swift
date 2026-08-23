//  DeviceMint.swift
//  `CORE` §8.2i–j and §8.3 — promotion, the mint deadline, and the zero-host
//  regime, driven by `libppcp`'s Mint engine.
//
//  ⛔ **The promotion policy is this application's and the deadline is the
//  library's, and neither may move.** 8.3c keeps promotion policy out of the
//  specification — "which transients a detector believes are shots is detector
//  tuning" — and `CONF` §6 puts it outside conformance. 8.2i's deadline is
//  arithmetic over `issue_hold_ns` and `heartbeat_interval_ms`, which the
//  Session declared, and a second implementation of it here would drift.
//
//  ⚠ **I32 is the clause this file exists to honour.** With a host, after the
//  deadline, a peer mints only for a Candidate **its own promotion policy would
//  have promoted hostless**. Host silence is not a promotion: nothing obliges a
//  host to answer a Candidate it declined, so the silent branch is the one that
//  fires for every nomination the host rejected — and Draft 2 minted a Shot for
//  all of them, including ones the device's own detector never believed.
//
//  ⚠ **8.2i1 is the other one.** A peer that cannot express `t0` in
//  `Session.timebase_ref` — no `affine` relation, an `unrelated` one, or one past
//  its own policy — does not mint at all. The Candidate is retained with no Shot,
//  for ever, and that is a legal and honest state (I8). ⛔ A zero offset is never
//  substituted to make a Shot expressible (5.4b).
//
//  Spec: `CORE` §8.2i–l, §8.3a–h; `MSG` §7.2. Plan D5.

import Foundation
import CPPCP

/// Promotion, as a callback. ⛔ **Not a threshold**, here or in the library
/// (I14): the library holds no number and this type takes a closure, so the
/// decision stays with the detector that is supposed to take it.
public typealias PromotionPolicy = @Sendable (PpcpCandidate) -> Bool

/// The Mint engine: candidates in, Shots out, and the two clauses above between
/// them.
public final class DeviceMint: @unchecked Sendable {

    private let peer: DevicePeer
    private let storage: UnsafeMutableRawPointer
    private var mint: OpaquePointer?
    private let mintId: @Sendable () -> String
    private let promotion: PromotionPolicy

    /// Every Candidate this peer handed to the engine, by id — so the promotion
    /// callback, which receives a bare `ppcp_candidate`, can answer in terms of
    /// the Swift value with its classifier still attached.
    private var observed: [String: PpcpCandidate] = [:]
    /// Shot ids in the order the engine asked for them. ⚠ **This is how the
    /// embedding learns what was minted**, and it is a workaround: see F-D5-1.

    /// - Parameters:
    ///   - mintId: 8.3e — Shot ids are unique within the Session and SHOULD be
    ///     UUIDs. ⛔ The library has no random source (plan ground rule 8), so the
    ///     embedding mints them, exactly as it does `link_id` and the pairing
    ///     nonces. A peer MUST NOT mint an id in another peer's namespace.
    ///   - promotion: 8.3b/8.3c/I14 — the subset of its own Candidates this peer
    ///     believes. Called for a hostless promotion **and** for 8.2i's
    ///     would-have-promoted test, which is what makes I32 one policy rather
    ///     than two that can disagree.
    public init(peer: DevicePeer,
                mintId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
                promotion: @escaping PromotionPolicy) throws {
        self.peer = peer
        self.mintId = mintId
        self.promotion = promotion

        let size = ppcp_mint_sizeof()
        storage = .allocate(byteCount: size, alignment: MemoryLayout<UInt64>.alignment)
        var handle: OpaquePointer?
        let context = Unmanaged.passUnretained(self).toOpaque()
        do {
            // ⛔ `PPCP_ERR_INVALID` unless the peer declares **Mint**: 8.3d makes
            // issuing a Shot the Mint profile's, and a peer that minted without
            // declaring it fails `CONF` §1d. The refusal is the library's.
            try check(ppcp_mint_new(storage, size, try peer.handleForLive(), { ctx, out in
                guard let ctx, let out else { return PPCP_ERR_INVALID }
                let mint = Unmanaged<DeviceMint>.fromOpaque(ctx).takeUnretainedValue()
                return ppcp_id_set_z(out, mint.mintId())
            }, context, &handle))
            try check(ppcp_mint_set_promotion_policy(handle, { ctx, candidate in
                guard let ctx, let candidate else { return false }
                let mint = Unmanaged<DeviceMint>.fromOpaque(ctx).takeUnretainedValue()
                let id = ppcpString(candidate.pointee.id)
                guard let known = mint.observed[id] else {
                    // A Candidate the engine holds and this object does not is not
                    // a Candidate this peer nominated. ⛔ Declining is the safe
                    // answer: I32's whole point is that a peer promotes only what
                    // it believes, and it cannot believe something it never saw.
                    return false
                }
                return mint.promotion(known)
            }, context))
        } catch {
            // ⛔ **Nothing is deallocated here, and that is the fix for a double
            // free.** A class initialiser that throws AFTER every stored property
            // has a value still runs `deinit` — so a `catch` that released the
            // storage and a `deinit` that released it again freed the same pointer
            // twice, which libmalloc aborts on. Found by SIGABRT in the one test
            // that exercises a refused construction (`libppcp` refuses a Mint
            // engine on a peer that has not declared Mint, 8.3d).
            throw error
        }
        mint = handle
    }

    deinit { storage.deallocate() }

    private func handle() throws -> OpaquePointer {
        guard let mint else { throw PpcpLibraryError(PPCP_ERR_INVALID) }
        return mint
    }

    /// Records a Candidate this peer nominated.
    ///
    /// ⚠ The 8.2i deadline is measured from the **Candidate's own instant**,
    /// converted into `Session.timebase_ref` — which is also 8.2i1's test.
    public func observe(own candidate: PpcpCandidate) throws {
        observed[candidate.id] = candidate
        let mint = try handle()
        try candidate.withValue { try check(ppcp_mint_observe_own(mint, $0)) }
    }

    /// A `shot` arrived. A pending Candidate it references is **answered**, and
    /// 8.2i's deadline no longer applies to it — "with no `shot` referencing it"
    /// is the whole condition.
    public func observe(shot: PpcpShot) throws {
        var value = shot.value
        try check(ppcp_mint_observe_shot(try handle(), &value))
    }

    /// Mints what is due and sends each `shot` immediately (8.2j).
    ///
    /// - Parameter nowRefNs: a reading of `Session.timebase_ref`, because that is
    ///   the frame both the deadline and `t0` live in.
    /// - Returns: the Shots minted by **this** call, so the caller can extract a
    ///   clip around each `t0`.
    ///
    /// ✅ **F-D5-1 closed** (`libppcp` `e52647e`). This used to reconstruct its
    /// answer by decoding the frames the engine had queued — `libppcp`'s own
    /// decoder over the peer's own bytes, through `drain_peek`, because Mint
    /// reported only *how many* it had minted while the host side had
    /// `ppcp_arbiter_shot_at`. `ppcp_mint_shot_at` is now the twin of that, so
    /// the peek, the frame walk, the `reported` set and the `mintedIds` list are
    /// all gone.
    ///
    /// ⚠ The window is `[countBefore, countBefore + minted)` — mint order, which
    /// `shot.h` fixes — and the pointers are valid only until the next pump, so
    /// each is copied out here.
    @discardableResult
    public func pump(nowRefNs: Int64) throws -> [PpcpShot] {
        let handle = try handle()
        let before = mintedCount
        var minted = 0
        try check(ppcp_mint_pump(handle, nowRefNs, &minted))
        guard minted > 0 else { return [] }
        return (before..<(before + minted)).compactMap { index in
            ppcp_mint_shot_at(handle, index).map { PpcpShot($0.pointee) }
        }
    }

    /// 8.2i / I32 — the Shot a Candidate of this peer's became, or `nil` where it
    /// has not been minted: answered by a host, declined by the promotion policy,
    /// or still inside its deadline. ⛔ Three different reasons and one answer,
    /// which is why `retainedCount` exists beside it.
    public func shot(forCandidate candidateId: String) throws -> PpcpShot? {
        var id = ppcp_id()
        try check(ppcp_id_set_z(&id, candidateId))
        return ppcp_mint_shot_for(try handle(), &id).map { PpcpShot($0.pointee) }
    }

    /// Candidates held with no Shot referencing them — declined by policy,
    /// answered by nobody, or **inexpressible in `timebase_ref`** (8.2i1). ⚠ I8:
    /// they are still evidence, and a consumer may re-derive `t0` later with a
    /// better clock.
    public var retainedCount: Int { mint.map(ppcp_mint_retained_count) ?? 0 }
    public var pendingCount: Int { mint.map(ppcp_mint_pending_count) ?? 0 }
    public var mintedCount: Int { mint.map(ppcp_mint_minted_count) ?? 0 }

}
