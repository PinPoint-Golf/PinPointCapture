//  LiveDetectionSink.swift
//  The other end of `DetectionSink`: a live link rather than a bundle.
//
//  ⚠ **`DetectAndMint` has had two ends since D5 and only one existed.**
//  `CaptureSessionRecorder` conformed to `DetectionSink` and wrote a bundle; the
//  hosted case — the same three calls onto a peer — was a comment. That is why
//  nothing composed a live session, and it is the smaller half of the same gap
//  `PeerLinkPump` fills.
//
//  ⛔ **The same three calls either way, which is what makes "live bytes are
//  bundle bytes" true of the detector as well as of the transport.** One
//  `DevicePeer` originates both (`CORE` A.3): what differs is where the drained
//  frames go, and nothing in `DetectAndMint` knows which.
//
//  ⚠ **The payload is queued, not sent.** `MSG` §8.2 puts capture payload on the
//  bulk channel behind its own flow control, and `PayloadTransferQueue` is what
//  holds I38's eviction predicate. Announcing on control and queueing on bulk is
//  `CORE` 3.1/T2 — a 25 MB clip in flight must not head-of-line block the next
//  shot's `candidate`.
//
//  Spec: `CORE` §5.12, §5.14, §8.1–8.2; `MSG` §7, §8. Plan D6/D-compose.

import Foundation

/// Sends what the detector produced onto a live link.
public final class LiveDetectionSink: DetectionSink, @unchecked Sendable {

    private let peer: DevicePeer
    private let queue: PayloadTransferQueue
    /// Every Capture announced through this sink, in order — what a screen shows
    /// as the per-shot sync column, read back from the library's transfer table.
    public private(set) var announced: [String] = []

    public init(peer: DevicePeer, queue: PayloadTransferQueue) {
        self.peer = peer
        self.queue = queue
    }

    /// `MSG` 7.1d / I8 — **every** nomination, winners and losers alike.
    public func record(candidate: PpcpCandidate) throws {
        try peer.nominate(candidate)
    }

    /// `MSG` 7.2 / 8.2j — sent immediately on minting, so a counterpart learns of
    /// the Shot without waiting for a payload that may take a minute.
    public func record(shot: PpcpShot) throws {
        try peer.send(shot: shot)
    }

    /// `MSG` 8.1 — the announce on **control**, the bytes on **bulk**.
    ///
    /// ⚠ The clip is read once here to fill `bytes` and `digest`, which 8.1
    /// wants on the announce so a receiver can decide whether it already holds
    /// it (9.1a). ⛔ That read is the reason the provider exists rather than a
    /// `Data`: at 1080p150 a session's clips are a gigabyte, and this is the one
    /// place they are touched before the transfer needs them.
    public func announce(_ assembly: CaptureAssembly,
                         clip: CaptureSessionRecorder.ClipProvider?) throws {
        var record = assembly.record
        var job: TransferJob?
        if let clip {
            let bytes = try clip()
            let digest = SessionBundleWriter.digest(of: bytes)
            record.bytes = UInt64(bytes.count)
            record.digest = digest
            job = TransferJob(captureId: record.id, bytes: UInt64(bytes.count),
                              digest: digest,
                              achievedFrames: assembly.achievedFrames,
                              payload: clip)
        }
        try peer.announce(record)
        announced.append(record.id)
        // ⛔ Enqueued **after** the announce. 8.2a makes `payload_begin` follow
        // the `capture_announce` for the Capture it carries, and a queue that
        // could run first would break that ordering under exactly the load it
        // matters under.
        if let job { try queue.enqueue(job) }
    }

    /// The owner's view of where each announced Capture's payload has got to.
    /// ⛔ Read from `ppcp_transfer_table`, never tracked here: `confirmed` is
    /// reachable only through a `capture_committed` that arrived (8.4b), and a
    /// second copy of the state would eventually claim it optimistically.
    public var transferRows: [PpcpTransferRow] {
        let known = Set(announced)
        return peer.transfers.filter { known.contains($0.captureId) }
    }
}

/// Writes to a bundle **and** a link at once.
///
/// ⚠ The case this exists for is the one a golfer actually meets: recording on
/// the mat with no host, then walking into a bay while the session is still
/// open. `CORE` §9 keeps the bundle authoritative whatever the link does, and
/// 7.4d makes transfer the thing that degrades — so a link that fails must not
/// take the bundle write with it.
public final class CompositeDetectionSink: DetectionSink, @unchecked Sendable {

    private let primary: any DetectionSink
    private let secondary: any DetectionSink
    /// ⛔ What the secondary threw, kept rather than propagated. The primary is
    /// the bundle and the secondary is the link: a dropped link is not a reason
    /// to stop recording (7.4d), and it is a reason to say so on a screen.
    public private(set) var secondaryError: (any Error)?

    public init(primary: any DetectionSink, secondary: any DetectionSink) {
        self.primary = primary
        self.secondary = secondary
    }

    public func record(candidate: PpcpCandidate) throws {
        try primary.record(candidate: candidate)
        do { try secondary.record(candidate: candidate) } catch { secondaryError = error }
    }

    public func record(shot: PpcpShot) throws {
        try primary.record(shot: shot)
        do { try secondary.record(shot: shot) } catch { secondaryError = error }
    }

    public func announce(_ assembly: CaptureAssembly,
                         clip: CaptureSessionRecorder.ClipProvider?) throws {
        try primary.announce(assembly, clip: clip)
        do { try secondary.announce(assembly, clip: clip) } catch { secondaryError = error }
    }
}
