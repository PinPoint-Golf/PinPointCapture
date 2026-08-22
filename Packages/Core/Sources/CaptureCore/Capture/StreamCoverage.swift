//  StreamCoverage.swift
//  I36 / `CORE` §5.11.1 — how a `continuous` Stream accounts for its whole open
//  interval, and how a `preview` Stream sheds what it could not deliver.
//
//  I36, verbatim: "On a `continuous` Stream in a Session asserted `complete`, the
//  announced stream-anchored Captures — present and `absent` alike — and their
//  declared gaps account for its whole open interval. Time unaccounted for
//  **between** announced Captures is a defect, not a dropout, in any Session."
//
//  ⛔ **The defect CT-I36 (a) describes is made unconstructible here, not
//  checked.** A segment's start is never a parameter: it is always the instant
//  the previous segment ended, held in `accountedThroughNs` and advanced only by
//  producing a segment. So "remove one segment from the middle without declaring
//  a gap" — the case the test removes by hand from a fixture — cannot be produced
//  by this type at all, and 5.14e's no-overlap rule comes free from the same
//  fact. A caller who wants to skip a span has exactly one way to say so, and it
//  is an `absent` segment with a reason.
//
//  ⚠ **The two ways of accounting for empty time are not interchangeable**
//  (5.11c2). `gaps` mean data was **lost** inside a segment that otherwise
//  exists; an `absent` segment means **nothing was captured** for that span.
//  5.11c3 settles the case people get wrong: deliberate non-retention is an
//  `absent` segment with `absent_reason: not_retained`, **never** a gap.
//
//  Spec: `CORE` §5.11 (5.11b–5.11e, 5.11f–5.11m), §5.14 (5.14d, 5.14e);
//  `CONF` CT-I11, CT-I27, CT-I36, CT-I36a.

import Foundation
import CPPCP

/// Accounting for one `continuous` Stream, in the Stream's own timebase.
///
/// ⚠ 5.11e: the *window length* of each Capture is "the producing peer's alone,
/// appears nowhere in the spec (I14), and cannot be negotiated in `ppcp/1.0`".
/// So this type takes an end instant per segment and never a policy.
public struct StreamCoverage: Sendable, Hashable {

    public enum CoverageError: Error, Sendable, Equatable {
        /// 5.11b — stream-anchored Captures belong only on a `continuous` Stream,
        /// and `ppcp_capture_validate_in_stream` refuses `{stream: true}` on a
        /// `shot_windowed` one (CT-I27's second assertion).
        case streamIsNotContinuous(String)
        /// A segment must end after the last one did. Equal is permitted and
        /// means an empty segment, which nothing needs; earlier would overlap
        /// (5.14e) or run backwards.
        case segmentEndsBeforeItStarts(startNs: Int64, endNs: Int64)
        /// I11 — a gap lies inside its Capture's own interval.
        case gapOutsideSegment(gap: Range<Int64>, segment: Range<Int64>)
        /// 5.11j / 8.1i — a preview Capture is never announced `transfer: pending`.
        case previewMayNotBePending
    }

    public let streamId: String
    public let timebaseId: String
    public let isPreview: Bool
    public let openedAtNs: Int64

    /// The instant through which this Stream is accounted for. Every segment
    /// starts here, so nothing between `openedAt` and here is unaccounted.
    public private(set) var accountedThroughNs: Int64
    public private(set) var segmentCount: Int

    public init(stream: PpcpStreamRecord) throws {
        guard stream.continuity == .continuous else {
            throw CoverageError.streamIsNotContinuous(stream.id)
        }
        self.streamId = stream.id
        self.timebaseId = stream.timebaseId
        self.isPreview = stream.kind == PpcpStreamKind.preview
        self.openedAtNs = stream.openedAtNs
        self.accountedThroughNs = stream.openedAtNs
        self.segmentCount = 0
    }

    /// Time not yet accounted for, as of `now`.
    ///
    /// ⚠ 5.11c1 — a non-empty tail is **not** a defect in a Session asserted
    /// `partial` or `unknown`: there it is the declared incompleteness (CT-I36
    /// case (c)). It is a defect only where the Session claims `complete`
    /// (case (d)). This type reports the tail; the assertion about the Session is
    /// the recorder's, because only it knows what the Session claims.
    public func unaccountedNs(asOf now: Int64) -> Range<Int64>? {
        guard now > accountedThroughNs else { return nil }
        return accountedThroughNs..<now
    }

    /// The next segment, carrying data.
    ///
    /// - Parameter gaps: spans **inside** this segment where data was lost
    ///   (5.11c2). ⛔ Not for time deliberately not retained — that is
    ///   `shed(...)`.
    public mutating func segment(id: String,
                                 endingAtNs endNs: Int64,
                                 completeness: PpcpCaptureRecord.Completeness = .complete,
                                 gaps: [Range<Int64>] = [],
                                 summary: PpcpAchievedSummary? = nil,
                                 transfer: PpcpTransferState = .pending)
        throws -> PpcpCaptureRecord {
        let interval = try span(endingAt: endNs)
        for gap in gaps where gap.lowerBound < interval.lowerBound
            || gap.upperBound > interval.upperBound {
            throw CoverageError.gapOutsideSegment(gap: gap, segment: interval)
        }
        // 5.11j / 8.1i — on a preview Stream a present segment was delivered
        // live or it was not kept at all, so `pending` is the one state it can
        // never be in. The library refuses it too; refusing here names the rule.
        if isPreview, completeness != .absent, transfer == .pending {
            throw CoverageError.previewMayNotBePending
        }
        advance(to: endNs)
        return PpcpCaptureRecord(
            id: id,
            anchor: .segment(startNs: interval.lowerBound, endNs: interval.upperBound),
            streamId: streamId,
            timebaseId: timebaseId,
            completeness: completeness,
            gapsNs: gaps,
            achievedSummary: summary,
            transfer: transfer)
    }

    /// The next segment, carrying nothing — 5.11c2's second row.
    ///
    /// ⛔ `interval` is mandatory here and the library enforces it (5.14d): "an
    /// `absent` segment *with* an interval is how a peer states that a named span
    /// was not recorded", and one without says nothing at all.
    public mutating func absentSegment(id: String,
                                       endingAtNs endNs: Int64,
                                       reason: String) throws -> PpcpCaptureRecord {
        let interval = try span(endingAt: endNs)
        advance(to: endNs)
        return PpcpCaptureRecord(
            id: id,
            anchor: .segment(startNs: interval.lowerBound, endNs: interval.upperBound),
            streamId: streamId,
            timebaseId: timebaseId,
            completeness: .absent,
            absentReason: reason)
    }

    /// 5.11j / 5.11c3 — the span a preview Stream discarded rather than queued.
    ///
    /// ⛔ **Never a gap, and this is CT-I36a's first assertion.** Preview is
    /// live-only: "discard rather than queue; MUST NOT retain for later transfer
    /// or write to a bundle". What was discarded is announced as an `absent`
    /// segment with `absent_reason: not_retained`, which is a statement about
    /// policy, not about loss.
    public mutating func shed(id: String, endingAtNs endNs: Int64) throws -> PpcpCaptureRecord {
        try absentSegment(id: id, endingAtNs: endNs, reason: PpcpAbsentReason.notRetained)
    }

    private func span(endingAt endNs: Int64) throws -> Range<Int64> {
        guard endNs > accountedThroughNs else {
            throw CoverageError.segmentEndsBeforeItStarts(startNs: accountedThroughNs,
                                                          endNs: endNs)
        }
        return accountedThroughNs..<endNs
    }

    private mutating func advance(to endNs: Int64) {
        accountedThroughNs = endNs
        segmentCount += 1
    }
}

// MARK: - Stream kinds

/// `CORE` §5.11 `kind` — an open registry, spelled by the library.
///
/// ⚠ The per-kind continuity table of §5.11 is normative and is worth having in
/// reach: `video` is always `shot_windowed`; `preview`, `event` and `metadata`
/// are always `continuous`; `audio` is `shot_windowed` but windowed on a
/// *Candidate* rather than a Shot; `imu` and `wrist` may be either.
public enum PpcpStreamKind {
    public static let video = PPCP_STREAM_KIND_VIDEO
    public static let preview = PPCP_STREAM_KIND_PREVIEW
    public static let audio = PPCP_STREAM_KIND_AUDIO
    public static let imu = PPCP_STREAM_KIND_IMU
    public static let wrist = PPCP_STREAM_KIND_WRIST
    public static let event = PPCP_STREAM_KIND_EVENT
    public static let metadata = PPCP_STREAM_KIND_METADATA

    /// The continuity §5.11's table fixes for a kind, where it fixes one.
    ///
    /// ⚠ `nil` for `imu` and `wrist`, which the table leaves to the peer. A
    /// default there would be this application quietly deciding something the
    /// protocol deliberately did not.
    public static func continuity(for kind: String) -> PpcpStreamRecord.Continuity? {
        switch kind {
        case video, audio: .shotWindowed
        case preview, event, metadata: .continuous
        default: nil
        }
    }
}
