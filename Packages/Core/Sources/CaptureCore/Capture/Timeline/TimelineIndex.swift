//  TimelineIndex.swift
//  E1.5 — one timeline across every source a Session carries.
//
//  ⚠ **Adapted from PinPointStudio's `src/Buffer/timeline_index.h`, and
//  deliberately not a copy.** That file solves the same shape on a desktop:
//  many sources at different rates, merged onto one timeline, a bounded window
//  extracted around an event. Four things are decided differently here, and each
//  is a decision rather than a simplification:
//
//  ⛔ **A value type, merged at query time — NOT a seqlock ring.** PPS runs a
//  merger thread with live subscribers, so its index is a power-of-two ring of
//  `std::atomic` generations. PPC's consumers ask at extraction time — a
//  `capture_request`, or a mint — and every source already retains its own
//  history (`FragmentRing.fragments`, `MotionMetadataSource.samples`,
//  `CandidateAudioRetention`). Merging twenty fragments and a handful of records
//  on demand costs nothing, and the alternative puts four producers on four
//  queues into one structure. `FragmentRing` is already a lock-free value type
//  for exactly this reason; this must not become the one Core type with a memory
//  model.
//
//  ⛔ **Nanoseconds.** PPS's `IndexEntry.timestamp_us` is too coarse here: 150 fps
//  is 6.67 ms per frame and REQ-EXP-2's exposure corrections need nanoseconds on
//  a monotonic base.
//
//  ⛔ **An entry is an INTERVAL, not an instant.** PPS indexes events; PPC's
//  indexable units are spans — a fragment covers one, an interruption *is* one.
//  `CORE` §5.1 makes intervals half-open, and an instant is the degenerate case.
//
//  ⛔ **`reorder_window_us` is not carried.** It encodes a multi-camera desktop
//  assumption. Here camera and microphone share a timebase and CT-I4 asserts
//  *zero* relations, so intra-device reordering is a smaller and different
//  problem.
//
//  Spec: `CORE` §5.1 (half-open intervals), §5.11 (per-kind continuity), §5.14,
//  §8.4 (extraction semantics); `CONF` CT-I10, CT-I11.

import Foundation

// MARK: - What one source contributed

/// One indexable unit of one source: the interval it covers, and what it
/// asserts about that interval.
public struct TimelineEntry: Sendable, Hashable {

    /// ⛔ **The reason this type exists rather than a bare interval.**
    ///
    /// An index of data alone would still leave holes to be *inferred*, and
    /// today's inference conflates three different causes: a real interruption
    /// (7.3d), a fragment whose bytes failed to write, and an encoder stall.
    /// `InterruptionRecord` already carries the first with its interval, and
    /// E1.1's `fragmentsDroppedWriteFailed` counts the second — so the true
    /// cause is knowable, and throwing it away is a choice nobody should make
    /// twice.
    public enum Presence: Sendable, Hashable {
        /// The source captured this interval and the bytes exist.
        case data
        /// ⚠ Nothing was captured, and the reason is `CORE` §5.14's open
        /// registry — `not_retained`, `outside_buffer`, and so on. ⛔ 5.11c3:
        /// deliberate non-retention is an absent segment, **never** a gap.
        case absent(reason: String)
        /// `CORE` 7.3d — the platform took the capture away and gave it back.
        case interruption(kind: InterruptionRecord.Kind, recovered: Bool)
    }

    /// The Stream's `source_id`. ⛔ Not the Stream id: 5.3/I4 put two Sources on
    /// one clock by naming the same `Timebase.id`, and coverage is a property of
    /// the source that produced it.
    public var sourceId: String
    /// `CORE` §5.11 `kind` — see `PpcpStreamKind`.
    public var kind: String
    /// Monotonic within one recording run, for loss detection only (I2).
    public var sequence: UInt64
    public var startNs: Int64
    /// **Exclusive** — `CORE` §5.1 intervals are half-open, so abutting units
    /// share a boundary without overlapping (5.14e).
    public var endNs: Int64
    public var byteCount: Int
    public var presence: Presence

    public init(sourceId: String, kind: String, sequence: UInt64,
                startNs: Int64, endNs: Int64, byteCount: Int = 0,
                presence: Presence = .data) {
        self.sourceId = sourceId
        self.kind = kind
        self.sequence = sequence
        self.startNs = startNs
        self.endNs = endNs
        self.byteCount = byteCount
        self.presence = presence
    }

    public var intervalNs: Range<Int64> { startNs..<Swift.max(startNs, endNs) }

    public var carriesData: Bool {
        if case .data = presence { return true }
        return false
    }
}

// MARK: - A hole, and what explains it

/// An interval inside a source's covered span that carries no data.
///
/// ⛔ **A hole is not automatically a `gap`** (I11). A gap is loss *inside* a
/// segment that otherwise exists, and it is meaningful only on a `continuous`
/// Stream; video is `shot_windowed`, where a hole makes the Capture `partial`
/// and is reported as nothing else. This type says what was found and leaves
/// how to express it to the record builder, which knows the Stream's
/// continuity — the same division `FragmentRing` already draws.
public struct TimelineHole: Sendable, Hashable {

    public enum Cause: Sendable, Hashable {
        case interruption(kind: InterruptionRecord.Kind, recovered: Bool)
        case absent(reason: String)
        /// ⛔ **Nothing in the index accounts for this span, and saying so is the
        /// point.** The predecessor of this type asserted that every mid-window
        /// discontinuity was an interruption, because a ring evicts only from
        /// the front. That is good reasoning and it is still only an inference —
        /// a fragment whose bytes failed to write leaves an identical shape. An
        /// honest "unexplained" is worth more than a confident guess, and it is
        /// how a write failure becomes visible instead of being filed as a
        /// platform interruption.
        case unexplained
    }

    public var intervalNs: Range<Int64>
    public var cause: Cause

    public init(intervalNs: Range<Int64>, cause: Cause) {
        self.intervalNs = intervalNs
        self.cause = cause
    }
}

// MARK: - The index

/// Every source's units on one timeline.
///
/// ⚠ Insert order does not matter. Entries are held in a deterministic total
/// order — `(startNs, sourceId, sequence)` — so a merge of the same set always
/// produces the same sequence, whichever queue each source drained on.
public struct TimelineIndex: Sendable, Hashable {

    public private(set) var entries: [TimelineEntry] = []

    public init() {}

    public init(_ entries: [TimelineEntry]) {
        insert(contentsOf: entries)
    }

    public mutating func insert(_ entry: TimelineEntry) {
        let position = entries.firstIndex { Self.isOrderedBefore(entry, $0) } ?? entries.endIndex
        entries.insert(entry, at: position)
    }

    public mutating func insert(contentsOf newEntries: [TimelineEntry]) {
        guard newEntries.isEmpty == false else { return }
        entries.append(contentsOf: newEntries)
        entries.sort(by: Self.isOrderedBefore)
    }

    public mutating func removeAll() { entries.removeAll(keepingCapacity: true) }

    /// The whole interval the index knows about, across every source.
    public var coveredNs: Range<Int64>? {
        guard let first = entries.first else { return nil }
        let lower = first.startNs
        let upper = entries.reduce(first.endNs) { Swift.max($0, $1.endNs) }
        guard upper > lower else { return nil }
        return lower..<upper
    }

    /// ⛔ **`CORE` §8.4's question, finally askable**: what covered this
    /// interval, from every source?
    ///
    /// ⚠ Half-open at both ends (§5.1). An entry ending exactly at
    /// `requested.lowerBound` did not reach into the window, and one starting
    /// exactly at `requested.upperBound` is past it — `Range.overlaps` is
    /// already this rule and is used rather than restated.
    public func snapshot(_ requested: Range<Int64>) -> TimelineSnapshot {
        TimelineSnapshot(requestedNs: requested,
                         entries: entries.filter { $0.intervalNs.overlaps(requested) })
    }

    /// ⚠ A deterministic total order, so equal timestamps do not merge
    /// differently on two runs. PPS gets this from a `global_sequence` assigned
    /// by its single merger thread; there is no merger thread here, so the order
    /// comes from the data.
    static func isOrderedBefore(_ lhs: TimelineEntry, _ rhs: TimelineEntry) -> Bool {
        if lhs.startNs != rhs.startNs { return lhs.startNs < rhs.startNs }
        if lhs.sourceId != rhs.sourceId { return lhs.sourceId < rhs.sourceId }
        return lhs.sequence < rhs.sequence
    }
}

// MARK: - A frozen view of one interval

/// What the index held over one interval, with a per-source lane for each
/// source that contributed.
///
/// ⚠ **The lanes are PPS's optimisation, carried deliberately**
/// (`swing_window.h:78-96`). Its `entriesFor`, `frameCount` and
/// `interpolateImu` each scanned every entry in the window, and its fuser calls
/// the last one once per grid point per binding — so the cost became
/// `gridPoints × bindings × totalEntries`. Building the lanes once at
/// construction makes a per-source query one copy and a bracketing lookup a
/// binary search. Cheap to do now, and expensive to retrofit under callers.
public struct TimelineSnapshot: Sendable, Hashable {

    public let requestedNs: Range<Int64>
    /// Every overlapping entry, merged and ascending.
    public let entries: [TimelineEntry]

    /// Source id → that source's entries, in the snapshot's own ascending order.
    private let lanes: [String: [TimelineEntry]]

    init(requestedNs: Range<Int64>, entries: [TimelineEntry]) {
        self.requestedNs = requestedNs
        self.entries = entries
        self.lanes = Dictionary(grouping: entries, by: \.sourceId)
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The sources that contributed, in a stable order.
    public var sourceIds: [String] { lanes.keys.sorted() }

    public func entries(ofSource sourceId: String) -> [TimelineEntry] {
        lanes[sourceId] ?? []
    }

    /// Entries of one source that actually carry bytes.
    public func dataEntries(ofSource sourceId: String) -> [TimelineEntry] {
        entries(ofSource: sourceId).filter(\.carriesData)
    }

    /// The interval this source actually realised inside the request — its data
    /// clipped to what was asked for.
    ///
    /// ⚠ `nil` when the source carried no data here, which is `absent` and a
    /// *result* rather than a failure (I10, 8.4b).
    public func realisedNs(ofSource sourceId: String) -> Range<Int64>? {
        let data = dataEntries(ofSource: sourceId)
        guard let first = data.first, let last = data.last else { return nil }
        let lower = Swift.max(requestedNs.lowerBound, first.startNs)
        let upper = Swift.min(requestedNs.upperBound, data.reduce(last.endNs) {
            Swift.max($0, $1.endNs)
        })
        guard upper > lower else { return nil }
        return lower..<upper
    }

    /// Spans inside the realised interval that carry no data, each with what
    /// explains it.
    ///
    /// ⛔ The explanation is looked up, never assumed: a non-data entry
    /// overlapping the span names the cause, and a span nothing accounts for is
    /// `.unexplained` rather than being filed as an interruption.
    public func holes(ofSource sourceId: String) -> [TimelineHole] {
        let data = dataEntries(ofSource: sourceId)
        guard data.count > 0, let realised = realisedNs(ofSource: sourceId) else { return [] }

        var holes: [TimelineHole] = []
        var accountedThrough = data[0].endNs
        for entry in data.dropFirst() {
            defer { accountedThrough = Swift.max(accountedThrough, entry.endNs) }
            guard entry.startNs > accountedThrough else { continue }
            let span = Swift.max(accountedThrough, realised.lowerBound)
                ..< Swift.min(entry.startNs, realised.upperBound)
            guard span.isEmpty == false else { continue }
            holes.append(TimelineHole(intervalNs: span, cause: cause(of: span, in: sourceId)))
        }
        return holes
    }

    /// What the index says about a span that carries no data.
    ///
    /// ⚠ An interruption outranks an `absent` record where both overlap: 7.3d's
    /// gap is a statement about the platform taking the capture away, which is
    /// the more specific claim and the one a maintainer needs.
    private func cause(of span: Range<Int64>, in sourceId: String) -> TimelineHole.Cause {
        let explanations = entries(ofSource: sourceId)
            .filter { $0.carriesData == false && $0.intervalNs.overlaps(span) }
        for entry in explanations {
            if case .interruption(let kind, let recovered) = entry.presence {
                return .interruption(kind: kind, recovered: recovered)
            }
        }
        for entry in explanations {
            if case .absent(let reason) = entry.presence { return .absent(reason: reason) }
        }
        return .unexplained
    }
}
