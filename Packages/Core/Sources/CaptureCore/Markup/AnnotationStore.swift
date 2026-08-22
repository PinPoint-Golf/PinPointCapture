//  AnnotationStore.swift
//  Where annotations converge, and how a drag reaches the wire without flooding
//  the channel that carries shot events.
//
//  ⛔ **The convergence rule is `libppcp`'s and there is not a second copy here.**
//  "Converges in both delivery orders" is a property of a *collection* and cannot
//  be asserted about a comparison function alone, which is why the store lives in
//  the library and both applications use the same one (ground rule 1).
//
//  ⛔ **`body` is stored and returned byte for byte** (5.18a). A peer that does
//  not understand a `format` round-trips it unchanged rather than dropping or
//  rewriting it — interpreting it is explicitly *not* the requirement.
//
//  Spec: `CORE` §5.18a, §5.18e, §5.18i; `MSG` §9.0. Plan D8.

import Foundation
import CPPCP

/// One current revision per `id`, with 5.18e applied on the way in.
public final class AnnotationStore: @unchecked Sendable {

    private let storage: UnsafeMutableRawPointer
    private var store: OpaquePointer?

    public init() throws {
        let size = ppcp_annotation_store_sizeof()
        storage = .allocate(byteCount: size, alignment: MemoryLayout<UInt64>.alignment)
        var handle: OpaquePointer?
        do {
            try check(ppcp_annotation_store_new(storage, size, &handle))
        } catch {
            storage.deallocate()
            throw error
        }
        store = handle
    }

    deinit { storage.deallocate() }

    /// Applies 5.18e.
    ///
    /// - Returns: whether the store **changed**. ⚠ `false` means the incoming
    ///   revision was superseded by what was already held and was ignored, which
    ///   is 9.0c's "lower is ignored" — not a failure, and not something to retry.
    @discardableResult
    public func observe(_ annotation: PpcpAnnotation) throws -> Bool {
        guard let store else { throw PpcpLibraryError(PPCP_ERR_INVALID) }
        var replaced = false
        try annotation.withValue { value in
            try check(ppcp_annotation_store_observe(store, value, &replaced))
        }
        return replaced
    }

    public var count: Int { store.map(ppcp_annotation_store_count) ?? 0 }

    public func annotation(id: String) -> PpcpAnnotation? {
        guard let store else { return nil }
        var key = ppcp_id()
        guard ppcp_id_set_z(&key, id) == PPCP_OK,
              let found = ppcp_annotation_store_find(store, &key) else { return nil }
        return PpcpAnnotation(found.pointee)
    }

    public var all: [PpcpAnnotation] {
        guard let store else { return [] }
        return (0..<ppcp_annotation_store_count(store)).compactMap { index in
            ppcp_annotation_store_at(store, index).map { PpcpAnnotation($0.pointee) }
        }
    }
}

// MARK: - Coalescing a drag

/// 5.18i — "a peer **coalesces** rapid revisions and sends the latest rather than
/// every intermediate".
///
/// ⚠ **The reason is the channel, not the bandwidth.** Each revision resends the
/// whole `body`, and `annotation` is on the **control** channel — the one carrying
/// `shot`, `candidate` and `readiness`. A finger dragging a swing-plane line
/// produces a continuous stream of edits, and an uncoalesced drag would put
/// hundreds of frames in front of the next shot event.
///
/// ⛔ It is a SHOULD in the specification and a MUST in this application, because
/// `CORE` 7.4d makes capture the thing that must not degrade and a saturated
/// control channel degrades everything behind it.
public struct AnnotationCoalescer: Sendable {

    /// How long a revision waits for a newer one to replace it. ⚠ Application
    /// tuning: 5.18i names no interval, and one written into the protocol would be
    /// a threshold I14 keeps out.
    public var quiescenceNs: Int64

    /// The pending edit per annotation `id`, with the instant it arrived.
    private var pending: [String: (annotation: PpcpAnnotation, atNs: Int64)] = [:]

    public init(quiescenceNs: Int64 = 120_000_000) {
        self.quiescenceNs = quiescenceNs
    }

    /// Offers an edit. ⛔ Nothing is returned to send: the newer revision replaces
    /// the older *before* either reaches a wire, which is what coalescing means.
    public mutating func offer(_ annotation: PpcpAnnotation, atNs: Int64) {
        pending[annotation.id] = (annotation, atNs)
    }

    /// The edits that have gone quiet, and are therefore due.
    ///
    /// - Parameter force: end of drag — send everything now rather than waiting
    ///   out the interval. A lifted finger is the strongest possible signal that
    ///   no newer revision is coming.
    public mutating func due(nowNs: Int64, force: Bool = false) -> [PpcpAnnotation] {
        let ready = pending.filter { force || nowNs - $0.value.atNs >= quiescenceNs }
        for key in ready.keys { pending.removeValue(forKey: key) }
        // Deterministic order, so two runs of the same drag produce the same frame
        // sequence and a test can assert on it.
        return ready.values.map(\.annotation).sorted { $0.id < $1.id }
    }

    public var pendingCount: Int { pending.count }
}

// MARK: - The device's own advisory anchor

public extension PpcpAnnotation {

    /// The impact fiducial as a **scrub target**.
    ///
    /// ⛔ **`provenance: device_advisory`, `kind: nav_anchor`, and it is never
    /// persisted or interpreted as phase data** (5.18c, 9.0d). The instant comes
    /// from a Shot's `t0`, which is where it is allowed to come from; what is
    /// forbidden is the other direction — this annotation feeding a Shot, a
    /// Candidate, a calibration or any computed quantity. There is no function
    /// anywhere in `CaptureCore` or `libppcp` that takes one and returns any of
    /// those, and CT-I37 is an assertion about exactly that absence.
    ///
    /// ⛔ **No `stream_id`** (5.18j): `nav_anchor` is not view-specific, so `at`
    /// is in `Session.timebase_ref` and the annotation renders on every view.
    static func navigationAnchor(id: String,
                                 sessionId: String,
                                 shotId: String,
                                 timebaseRef: String,
                                 atNs: Int64,
                                 authorPeerId: String,
                                 label: String = "impact",
                                 createdAtTimebaseId: String,
                                 createdAtNs: Int64) throws -> PpcpAnnotation {
        try PpcpAnnotation(id: id, sessionId: sessionId, shotId: shotId,
                           streamId: nil, timebaseId: timebaseRef, atNs: atNs,
                           authorPeerId: authorPeerId,
                           provenance: .deviceAdvisory, kind: .navAnchor,
                           format: "text/plain",
                           body: Data(label.utf8),
                           createdAtTimebaseId: createdAtTimebaseId,
                           createdAtNs: createdAtNs)
    }
}
