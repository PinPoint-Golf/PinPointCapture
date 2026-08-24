//  CaptureSessionRecorder.swift
//  One hostless Session, recorded into a `PPCPBNDL` — the composition D3 left
//  open and D4 closes.
//
//  ⚠ **The ordering is `ENC` §7 and it is not this file's to choose.** The writer
//  refuses a payload frame before `session_manifest` (7c), so every clip is held
//  until `close()` and written after the manifest. That is why an assembled
//  Capture arrives here with a *provider* for its bytes rather than the bytes: at
//  1080p150 a session's clips are a gigabyte, and holding them in memory to
//  satisfy a frame-ordering rule would be the wrong trade in the wrong layer.
//  `CaptureCore` opens no file (ground rule 8); the provider closes over one.
//
//  ⛔ **A hostless bundle records no `arm` and no `disarm`** (7.3b): they are
//  conferred by **Live** and with nobody controlling there is no command to
//  record. It still records `readiness`, because 7.3c confers that through
//  **Capture**. Neither rule is remembered here — `ppcp_peer_arm` refuses a peer
//  that is not `role: host`, and the writer refuses an `arm` after a hostless
//  `session_open`.
//
//  ⛔ **A preview Capture never reaches the bundle** (5.11j, CT-I36a). It is
//  refused by `SessionBundleWriter.announce(_:isPreview:)`, so this type has no
//  preview path to get wrong.
//
//  Spec: `CORE` §5.11, §5.14, §7.3, §9; `ENC` §7; `CONF` CT-I36, CT-S4 (1).

import Foundation

/// Records one Session's Captures into a bundle, in the order `ENC` §7 requires.
public final class CaptureSessionRecorder: @unchecked Sendable {

    public enum RecorderError: Error, Sendable, Equatable {
        /// `close()` has run; the bundle is finished (`ENC` 7e).
        case closed
        /// I36 / 5.11c — a `continuous` Stream would be left with time accounted
        /// for by neither a Capture nor a gap, in a Session asserting `complete`.
        /// ⛔ CT-I36 case (d). Assert `partial` or account for the tail.
        case coverageIncomplete(streamId: String, unaccountedNs: Range<Int64>)
    }

    /// A Capture whose bytes are fetched only when the payload is written.
    public typealias ClipProvider = @Sendable () throws -> Data

    private let writer: SessionBundleWriter
    private let sessionId: String
    private var streamIds: [String] = []
    private var announced: [PpcpCaptureRecord] = []
    private struct HeldPayload {
        var captureId: String
        var clip: ClipProvider
        var frames: PpcpAchievedFrames?
    }
    private var pendingPayloads: [HeldPayload] = []
    private var coverage: [String: StreamCoverage] = [:]
    private var isClosed = false

    /// ⛔ **E1.5 — the one timeline, across every source this Session carries.**
    ///
    /// `coverage` above is a dictionary of *independent* per-Stream accounts:
    /// each knows what it accounted for and none of them can see the others. So
    /// the question `CORE` §8.4's extraction semantics assume — "what covered
    /// this interval, from every source?" — had nowhere to be asked. This index
    /// is where. It carries video fragments, audio windows, IMU batches and
    /// interruptions on one nanosecond timeline, so a hole in one source can be
    /// explained by a record from another.
    ///
    /// ⛔ **Durable records ONLY — interruptions and declared absences.** A live
    /// source's coverage must NOT accumulate here, and the reason is I10: the
    /// ring evicts, and an index that kept every fragment ever written would go
    /// on asserting coverage for bytes that are long gone. What is held here is
    /// what has no other home — an interruption is a transient event that would
    /// otherwise be written to the bundle and forgotten. Live coverage is merged
    /// at query time from whichever source still owns it, in
    /// `timeline(over:mergingLive:)`.
    private var timeline = TimelineIndex()

    /// Which `source_id` each open Stream belongs to, so an entry can be
    /// attributed without the caller repeating it.
    private var sourceOfStream: [String: String] = [:]

    public private(set) var shotCount: UInt64 = 0
    public private(set) var candidateCount: UInt64 = 0

    /// `CORE` §9 — declaration, then `session_open`. Both go in before anything
    /// else, and the library refuses them out of order.
    public init(writer: SessionBundleWriter,
                declaration: PpcpDeclaration,
                session: PpcpSessionRecord) throws {
        self.writer = writer
        self.sessionId = session.id
        try writer.record(declaration: declaration)
        try writer.open(session: session)
    }

    /// `MSG` §5.1 — `stream_open`. A `continuous` Stream also starts its coverage
    /// account, from `opened_at` (5.11c).
    public func open(stream: PpcpStreamRecord) throws {
        try ensureOpen()
        try writer.open(stream: stream)
        streamIds.append(stream.id)
        sourceOfStream[stream.id] = stream.sourceId
        if stream.continuity == .continuous {
            coverage[stream.id] = try StreamCoverage(stream: stream)
        }
    }

    // MARK: The merged timeline (E1.5)

    /// Record a durable timeline fact — something with no other home, which a
    /// later query could not reconstruct.
    ///
    /// ⛔ **Not for a live source's coverage.** A `FragmentRing`'s entries
    /// describe what it holds *now*; put them here and they outlive their own
    /// eviction. Pass those to `timeline(over:mergingLive:)` instead.
    ///
    /// ⚠ `sourceId` rather than `streamId` deliberately: 5.3/I4 put two Sources
    /// on one clock by naming the same `Timebase.id`, and coverage is a property
    /// of the source that produced the bytes.
    public func indexDurable(_ entries: [TimelineEntry]) {
        timeline.insert(contentsOf: entries)
    }

    /// ⛔ **What covered this interval, from every source** (`CORE` §8.4).
    ///
    /// This is the whole point of E1.5, and the question that had nowhere to be
    /// asked: `coverage` is a dictionary of independent per-Stream accounts and
    /// none of them can see the others. Ask this around a `t0` and the answer
    /// names every source that contributed, what each realised, and — for a
    /// source with a hole — whether an interruption recorded against *another*
    /// Stream explains it.
    ///
    /// - Parameter live: coverage from sources that own their own history, as
    ///   of right now — `ring.timelineEntries(sourceId:)` and its equivalents.
    ///   ⚠ Passed per query rather than accumulated, so a fragment that has
    ///   rolled out of the ring stops being claimed the moment it is gone.
    public func timeline(over interval: Range<Int64>,
                         mergingLive live: [TimelineEntry] = []) -> TimelineSnapshot {
        guard live.isEmpty == false else { return timeline.snapshot(interval) }
        var merged = timeline
        merged.insert(contentsOf: live)
        return merged.snapshot(interval)
    }

    /// `CORE` 7.3c — `readiness`, whenever `settled` changes.
    public func report(_ readiness: ReadinessMeasurement, streamIds: [String] = []) throws {
        try ensureOpen()
        try writer.record(readiness: try readiness.ppcpReadiness(), streamIds: streamIds)
    }

    /// `CORE` 7.3d — the interruption and its gap.
    public func record(_ interruption: InterruptionRecord) throws {
        try ensureOpen()
        try writer.record(interruption)

        // ⛔ **On the timeline as well as in the bundle, and this is the fix
        // E1.5 exists for.** An interruption used to be written and forgotten,
        // so a hole in the video had to be *inferred* from a missing fragment —
        // an inference that reads a disk write failure as a platform
        // interruption, because both leave the same shape. Indexed here, the
        // hole is explained by the record that actually caused it.
        //
        // ⚠ An empty `streamIds` means every open capture Stream (7.3d), so the
        // gap is attributed to all of their sources rather than to none.
        let affected = interruption.streamIds.isEmpty ? streamIds : interruption.streamIds
        indexDurable(affected.compactMap { streamId in
            guard let sourceId = sourceOfStream[streamId] else { return nil }
            return TimelineEntry(
                sourceId: sourceId,
                kind: PpcpStreamKind.event,
                // ⚠ Sequence is for loss detection within a source's own units
                // (I2); an interruption is not one of them, so it carries none
                // rather than a number that would look like one.
                sequence: 0,
                startNs: interruption.intervalNs.lowerBound,
                endNs: interruption.intervalNs.upperBound,
                presence: .interruption(kind: interruption.kind,
                                        recovered: interruption.recovered))
        })
    }

    /// Announce a shot- or candidate-anchored Capture, and queue its payload.
    ///
    /// - Parameter clip: `nil` for an `absent` Capture. ⛔ Supplying one anyway
    ///   would be a payload for a Capture that asserts it has none.
    public func announce(_ assembly: CaptureAssembly, clip: ClipProvider? = nil) throws {
        try ensureOpen()
        try writer.announce(assembly.record)
        announced.append(assembly.record)
        guard assembly.record.completeness != .absent, let clip else { return }
        pendingPayloads.append(HeldPayload(captureId: assembly.record.id, clip: clip,
                                           frames: assembly.achievedFrames))
    }

    /// Announce the next segment of a `continuous` Stream.
    ///
    /// ⚠ Build it through the Stream's own `StreamCoverage` (`segment`,
    /// `absentSegment`, `shed`) — that is what makes a hole between segments
    /// unconstructible rather than merely wrong.
    public func announceSegment(_ record: PpcpCaptureRecord,
                                coverage updated: StreamCoverage) throws {
        try ensureOpen()
        try writer.announce(record)
        announced.append(record)
        coverage[updated.streamId] = updated
    }

    /// The coverage account for a Stream, to advance and hand back.
    public func coverage(of streamId: String) -> StreamCoverage? { coverage[streamId] }

    public func countShot() { shotCount += 1 }
    public func countCandidate() { candidateCount += 1 }

    /// `MSG` 7.1 — record a Candidate and count it for the manifest.
    ///
    /// ⛔ **Every nomination**, winners and losers alike (5.12c, 7.1d, I8). The
    /// count in `session_manifest` is therefore the candidate count and not the
    /// shot count, which is exactly the arithmetic the requirements review found
    /// wrong the other way round (REQ-PRIV-6).
    public func record(candidate: PpcpCandidate) throws {
        try ensureOpen()
        try writer.record(candidate: candidate)
        candidateCount += 1
    }

    /// `MSG` 7.2 — record a Shot and count it.
    ///
    /// ⚠ A bundle is written in the zero-host regime by construction, so every
    /// Shot in one carries `authority: device` and exactly one Candidate at
    /// issuance (8.3a, I23). 8.3h then permits it to *gain* Candidates later
    /// through 8.2e/8.2k, and that is not a violation.
    public func record(shot: PpcpShot) throws {
        try ensureOpen()
        try writer.record(shot: shot)
        shotCount += 1
    }

    /// `MSG` 9.3 — a `shot_link`, for a Shot minted during a link outage (8.3f).
    public func record(shotLink: PpcpShotLink) throws {
        try ensureOpen()
        try writer.record(shotLink: shotLink)
    }

    /// `MSG` 9.0 — an annotation, from either end (5.18d).
    public func record(annotation: PpcpAnnotation) throws {
        try ensureOpen()
        try writer.record(annotation: annotation)
    }

    /// `MSG` §9.2 then `ENC` §6 — the manifest, then every held payload, then the
    /// finish that emits no bytes (7e).
    ///
    /// - Parameters:
    ///   - completeness: **asserted** by the peer that owns the data (I10). A
    ///     session the app abandoned says `partial` and means it.
    ///   - closedAtNs: the instant the Streams stopped, for the I36 check below.
    public func close(completeness: PpcpCaptureRecord.Completeness,
                      closedAtNs: Int64?) throws {
        try ensureOpen()

        // ⛔ I36 / CT-I36 (c) and (d). A tail nobody accounted for is the
        // *declared incompleteness* in a `partial` Session and a **defect** in a
        // `complete` one. Refusing to write the second is the difference between
        // an honest bundle and one that reads as an implementation error.
        if completeness == .complete, let closedAtNs {
            for account in coverage.values {
                if let tail = account.unaccountedNs(asOf: closedAtNs) {
                    throw RecorderError.coverageIncomplete(streamId: account.streamId,
                                                           unaccountedNs: tail)
                }
            }
        }

        try writer.recordManifest(sessionId: sessionId,
                                  streamIds: streamIds,
                                  captures: announced,
                                  completeness: completeness,
                                  shotCount: shotCount,
                                  candidateCount: candidateCount)

        for payload in pendingPayloads {
            try writer.writePayload(captureId: payload.captureId,
                                    clip: try payload.clip(),
                                    achievedFrames: payload.frames)
        }
        try writer.finish()
        isClosed = true
    }

    private func ensureOpen() throws {
        guard isClosed == false else { throw RecorderError.closed }
    }
}
