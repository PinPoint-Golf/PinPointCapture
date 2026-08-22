//  Shot.swift
//  `CORE` §5.13 — the canonical event, and §5.16 — the link that reconciles two
//  of them without merging either.
//
//  ⛔ **A Shot is never rewritten and two Shots are never combined** (I9, 8.5a).
//  There is no `merge`, no `supersede` and no `withdraw` anywhere in this file or
//  in `libppcp`, and `t0` has no setter at all (I7). The one amendment 5.13d
//  permits is *extending* the candidate list, which is
//  `ppcp_shot_attach_candidate` — additive, order-independent, and converging on
//  byte-identical output in either delivery order.
//
//  Spec: `CORE` §5.13, §5.16, §8.2e, §8.3a–h, §8.5; `MSG` §7.2, §9.3. Plan D5.

import Foundation
import CPPCP

/// `CORE` 5.13 `authority`.
public enum PpcpAuthority: Sendable, Hashable {
    case host, device

    var c: ppcp_authority {
        switch self {
        case .host: PPCP_AUTHORITY_HOST
        case .device: PPCP_AUTHORITY_DEVICE
        }
    }
}

/// One Shot.
///
/// ⚠ `t0` is in `Session.timebase_ref` (5.13c) and **never** in the nominating
/// Source's own timebase. 8.2i1 is the consequence a device meets: a peer that
/// cannot express `t0` there does not mint at all, and it certainly does not
/// substitute a zero offset to make it expressible (5.4b).
public struct PpcpShot: @unchecked Sendable, Hashable {
    public let id: String
    public let sessionId: String
    public let timebaseRefId: String
    public let t0Ns: Int64
    public let authority: PpcpAuthority
    public let issuedBy: String
    public private(set) var candidateIds: [String]
    public private(set) var captureIds: [String]

    var value: ppcp_shot

    /// - Parameter firstCandidateId: mandatory. 5.13 puts `candidates` at
    ///   cardinality 1..n, and 8.3a issues a Shot carrying **exactly one** in the
    ///   zero-host regime — so the constructor takes one and there is no way to
    ///   build a Shot with none.
    public init(id: String, sessionId: String, timebaseRefId: String, t0Ns: Int64,
                authority: PpcpAuthority, issuedBy: String,
                firstCandidateId: String) throws {
        var shot = ppcp_shot()
        var t0 = ppcp_instant()
        try check(ppcp_instant_make_z(&t0, timebaseRefId, t0Ns))
        try check(ppcp_shot_make(&shot, id, sessionId, &t0, authority.c, issuedBy,
                                 firstCandidateId))
        try check(ppcp_shot_validate(&shot))
        value = shot
        self.id = id
        self.sessionId = sessionId
        self.timebaseRefId = timebaseRefId
        self.t0Ns = t0Ns
        self.authority = authority
        self.issuedBy = issuedBy
        candidateIds = [firstCandidateId]
        captureIds = []
    }

    init(_ shot: ppcp_shot) {
        value = shot
        id = ppcpString(shot.id)
        sessionId = ppcpString(shot.session_id)
        timebaseRefId = ppcpString(shot.t0.tb)
        t0Ns = shot.t0.ns
        authority = shot.authority == PPCP_AUTHORITY_HOST ? .host : .device
        issuedBy = ppcpString(shot.issued_by)
        var value = shot
        candidateIds = withUnsafeBytes(of: &value.candidates) { raw in
            let base = raw.bindMemory(to: ppcp_id.self)
            return (0..<shot.candidate_count).map { ppcpString(base[$0]) }
        }
        captureIds = withUnsafeBytes(of: &value.captures) { raw in
            let base = raw.bindMemory(to: ppcp_id.self)
            return (0..<shot.capture_count).map { ppcpString(base[$0]) }
        }
    }

    /// 5.13 `captures` — the realisations of this Shot. The clip, and the audio
    /// window if one was retained.
    public mutating func add(captureId: String) throws {
        try check(ppcp_shot_add_capture(&value, captureId))
        captureIds.append(captureId)
    }

    /// 8.2e / 5.13d — a Candidate arriving **after** the Shot was issued
    /// attaches. ⛔ `t0` is not revised, and this cannot revise it: it takes a
    /// Candidate id, not an instant.
    public mutating func attach(candidateId: String) throws {
        var id = ppcp_id()
        try check(ppcp_id_set_z(&id, candidateId))
        try check(ppcp_shot_attach_candidate_id(&value, &id))
        if candidateIds.contains(candidateId) == false {
            candidateIds.append(candidateId)
            // The library keeps the list sorted by `id` so 5.13e's "additive and
            // order-independent" is byte-identical convergence rather than mere
            // set equality; the view here follows it.
            candidateIds.sort()
        }
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.t0Ns == b.t0Ns && a.candidateIds == b.candidateIds
            && a.captureIds == b.captureIds
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// `CORE` §5.16 — the link that reconciliation creates instead of a merge.
///
/// ⛔ 8.5f: an `arrival_pairing` link **MUST NOT** influence `t0` and MUST NOT be
/// turned into a `TimebaseRelation`. There is no function in `libppcp` that takes
/// a `ShotLink` and a relation, and CT-I25's static half is an assertion about
/// that absence.
public struct PpcpShotLink: @unchecked Sendable, Hashable {

    public enum Basis: Sendable, Hashable {
        /// 8.2l — both ends issued because the two messages crossed. Neither is
        /// withdrawn; a consumer MUST NOT count them as two events.
        case sharedCandidate
        /// 8.3f — a Shot minted during a link outage, reconciled on reconnect.
        case intervalAlignment
        case acousticCorrelation
        case sequenceAlignment
        case arrivalPairing
        case manual

        var wire: String {
            switch self {
            case .sharedCandidate: PPCP_LINK_SHARED_CANDIDATE
            case .intervalAlignment: PPCP_LINK_INTERVAL_ALIGNMENT
            case .acousticCorrelation: PPCP_LINK_ACOUSTIC_CORRELATION
            case .sequenceAlignment: PPCP_LINK_SEQUENCE_ALIGNMENT
            case .arrivalPairing: PPCP_LINK_ARRIVAL_PAIRING
            case .manual: PPCP_LINK_MANUAL
            }
        }
    }

    public let id: String
    public let localShotId: String
    public let foreignShotId: String
    public let basis: Basis
    public let confidence: Double

    var value: ppcp_shot_link

    public init(id: String, localShotId: String, foreignShotId: String,
                basis: Basis, confidence: Double,
                foreignSessionId: String? = nil) throws {
        var link = ppcp_shot_link()
        try check(ppcp_shot_link_make(&link, id, localShotId, foreignShotId,
                                      basis.wire, confidence))
        if let foreignSessionId {
            try check(ppcp_shot_link_set_foreign_session(&link, foreignSessionId))
        }
        try check(ppcp_shot_link_validate(&link))
        value = link
        self.id = id
        self.localShotId = localShotId
        self.foreignShotId = foreignShotId
        self.basis = basis
        self.confidence = confidence
    }

    /// 5.16e/f — `confirmed_by` is present if and only if `confirmed`, and the
    /// library refuses `observer` on a **retrospective** basis. ⛔ That refusal is
    /// the point: a retrospective match has no observer, and asserting one would
    /// dodge 8.5b's confirmation requirement.
    public mutating func confirm(by who: ppcp_confirmed_by) throws {
        try check(ppcp_shot_link_confirm(&value, who))
        try check(ppcp_shot_link_validate(&value))
    }

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
