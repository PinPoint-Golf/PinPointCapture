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
        if stream.continuity == .continuous {
            coverage[stream.id] = try StreamCoverage(stream: stream)
        }
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
