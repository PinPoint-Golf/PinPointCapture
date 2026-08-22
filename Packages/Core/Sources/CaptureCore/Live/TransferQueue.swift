//  TransferQueue.swift
//  The bulk channel: announce immediately, queue the payload, resume from the
//  last acknowledgement — and never evict anything the protocol has not released.
//
//  ⚠ **Announce and payload are two different obligations on two different
//  channels, and the split is `CORE` I30's.** `capture_announce` goes out on
//  control the moment the clip is assembled, so a host learns a swing exists
//  without waiting for a gigabyte; the payload queues behind it on bulk. A host
//  that has the announce and not the bytes knows exactly what it is missing.
//
//  ⛔ **Preview is never queued** (5.11j, `MSG` 8.1i). A preview Capture is
//  live-only: what could not be delivered promptly is *discarded* and announced
//  `absent` with `not_retained`. A queue told nothing else fills with the cheapest
//  data in the session and starves the shot payload behind it — which is why the
//  library refuses a preview Capture announced `transfer: pending` at the
//  announce, rather than letting a queue notice later.
//
//  ⛔ **Eviction goes through `ppcp_transfer_is_evictable` and nowhere else**
//  (I38, 5.14g). Four exits — `confirmed`, `absent`, `already_present`, or a
//  clause of the specification that permitted the owner to shed it — and 5.14g1
//  forbids a fifth: "a peer's own retention policy MUST NOT extend that list", and
//  **shot-anchored payload is never sheddable by policy**. A peer under storage
//  pressure refuses to arm rather than dropping swings a consumer has not
//  received (REQ-OFF-2, REQ-SESS-4).
//
//  ⚠ **Capture never stops for any of this** (7.4d): "loss of the link MUST NOT
//  cost a single captured frame. Capture is non-recoverable; transfer is
//  retryable." Nothing in this file can pause, disarm or drop a frame.
//
//  Spec: `CORE` §5.14f–g, §7.4d, §8.3f–h; `MSG` §8. `ENC` §6. Plan D6.

import Foundation
import CPPCP

/// One queued payload.
public struct TransferJob: Sendable {
    public let captureId: String
    public let bytes: UInt64
    public let digest: Data
    /// The bytes, fetched only when the chunk is sent. ⚠ At 1080p150 a session's
    /// clips are a gigabyte; holding them in memory to satisfy a queue would be
    /// the wrong trade in the wrong layer.
    public let payload: @Sendable () throws -> Data
    /// I30 / 5.8d — a camera Capture carries the per-frame series **here** and
    /// only here, on `payload_begin`.
    public let achievedFrames: PpcpAchievedFrames?

    public init(captureId: String, bytes: UInt64, digest: Data,
                achievedFrames: PpcpAchievedFrames? = nil,
                payload: @escaping @Sendable () throws -> Data) {
        self.captureId = captureId
        self.bytes = bytes
        self.digest = digest
        self.achievedFrames = achievedFrames
        self.payload = payload
    }
}

/// The device's bulk transfer queue.
public final class PayloadTransferQueue: @unchecked Sendable {

    /// `MSG` 8.3f — "`chunk_bytes` is 262144 (256 KiB). It MUST NOT exceed 4 MiB."
    /// ⚠ The SHOULD value, taken as written: it is the specification's number and
    /// not a tuning parameter this application gets to pick.
    public static let chunkBytes: UInt32 = 262_144

    public enum QueueError: Error, Sendable, Equatable {
        /// 5.11j — a preview Capture has no payload path. ⛔ Not "refused for now":
        /// there is no configuration in which a preview segment queues.
        case previewIsNeverQueued(String)
        /// I38 / 5.14g1 — asked to evict something the protocol has not released.
        case notEvictable(String)
    }

    private struct Entry {
        var job: TransferJob
        /// 8.3a — chunks for one Capture are sent in **ascending** index on one
        /// bulk channel.
        var nextIndex: UInt32 = 0
        var begun = false
        var finished = false
        /// 8.3c — the receiver answered `already_present`. Nothing more is sent
        /// and the Capture becomes evictable (5.14g exit 3).
        var alreadyPresent = false
    }

    private let peer: DevicePeer
    private let channel: PpcpChannel
    private var queue: [Entry] = []
    /// Retained candidate-evidence Capture ids, oldest first, for the retention
    /// cap of B7. ⛔ Their eviction is lawful (5.14g exit 4 names 5.12.1b); a shot
    /// clip's is not.
    private var candidateEvidence: [String] = []

    public init(peer: DevicePeer, channel: PpcpChannel = .bulk) {
        self.peer = peer
        self.channel = channel
    }

    /// Queue a payload behind an announce that has already gone out.
    ///
    /// - Throws: `previewIsNeverQueued` where the Capture is on a `preview`
    ///   Stream. ⚠ The check reads the peer's own transfer table, which the
    ///   library filled from the announce — not a flag this file was told.
    public func enqueue(_ job: TransferJob) throws {
        if let row = peer.transfer(of: job.captureId), row.isPreview {
            throw QueueError.previewIsNeverQueued(job.captureId)
        }
        guard queue.contains(where: { $0.job.captureId == job.captureId }) == false else {
            return
        }
        queue.append(Entry(job: job))
    }

    /// Records a retained candidate-evidence Capture, for the B7 cap.
    public func retainedCandidateEvidence(_ captureId: String) {
        candidateEvidence.append(captureId)
    }

    /// Sends as much as `budgetBytes` allows, then stops. ⚠ **The budget is the
    /// caller's**, because the socket is: `CORE` T2 backpressure is what decides
    /// how fast this drains, and a queue that ran ahead of it would buffer a
    /// session in the engine.
    ///
    /// - Returns: how many bytes of payload it queued.
    @discardableResult
    public func pump(budgetBytes: Int = 4 << 20) throws -> Int {
        var spent = 0
        var index = 0
        while index < queue.count, spent < budgetBytes {
            if queue[index].finished || queue[index].alreadyPresent {
                index += 1
                continue
            }
            spent += try advance(&queue[index], budget: budgetBytes - spent)
            index += 1
        }
        queue.removeAll { $0.finished || $0.alreadyPresent }
        return spent
    }

    private func advance(_ entry: inout Entry, budget: Int) throws -> Int {
        let data = try entry.job.payload()
        if entry.begun == false {
            try peer.payloadBegin(captureId: entry.job.captureId,
                                  bytes: entry.job.bytes,
                                  digest: entry.job.digest,
                                  chunkBytes: Self.chunkBytes,
                                  channel: channel,
                                  achievedFrames: entry.job.achievedFrames)
            entry.begun = true
        }

        let chunk = Int(Self.chunkBytes)
        var spent = 0
        while spent < budget {
            let start = Int(entry.nextIndex) * chunk
            guard start < data.count else { break }
            let end = min(data.count, start + chunk)
            let slice = data.subdata(in: start..<end)
            // ⛔ `offset` (ENC 6b) and the chunk digest (6c) are computed by the
            // library from the index, so a sender cannot disagree with itself.
            try peer.payloadChunk(captureId: entry.job.captureId,
                                  index: entry.nextIndex,
                                  chunkBytes: Self.chunkBytes,
                                  data: slice, channel: channel)
            entry.nextIndex += 1
            spent += slice.count
        }

        if Int(entry.nextIndex) * chunk >= data.count {
            // 8.3b — `payload_end`'s digest MUST equal the one `payload_begin`
            // announced, and it is the same value here rather than a second hash.
            try peer.payloadEnd(captureId: entry.job.captureId,
                                digest: entry.job.digest, channel: channel)
            entry.finished = true
        }
        return spent
    }

    /// 8.3d — "resumption restarts from the chunk **after** the last acknowledged
    /// index, not from the beginning".
    ///
    /// ⚠ The acknowledged index comes from the **library's** transfer table, which
    /// `payload_ack` filled. A queue that tracked its own would disagree with the
    /// receiver exactly when the link had been unreliable.
    public func resumeAfterLinkLoss() throws {
        for index in queue.indices {
            let captureId = queue[index].job.captureId
            guard queue[index].begun else { continue }
            let from = (peer.transfer(of: captureId)?.ackedIndex).map { $0 + 1 } ?? 0
            queue[index].nextIndex = from
            queue[index].begun = false
            try peer.payloadResume(captureId: captureId, fromIndex: from, channel: channel)
        }
    }

    /// 8.3c / 5.14g exit 3 — the receiver already holds this payload. Nothing more
    /// is sent, and the Capture is now evictable.
    public func markAlreadyPresent(captureId: String) {
        guard let index = queue.firstIndex(where: { $0.job.captureId == captureId })
        else { return }
        queue[index].alreadyPresent = true
    }

    public var pendingCaptureIds: [String] {
        queue.filter { $0.finished == false && $0.alreadyPresent == false }
            .map(\.job.captureId)
    }

    /// `MSG` 4.3 — what `session_resume` carries: everything still owed, with the
    /// index the receiver last acknowledged so the far end knows where to pick up.
    public var pendingForResume: [PendingCapture] {
        queue.compactMap { entry in
            guard entry.finished == false, entry.alreadyPresent == false else { return nil }
            return PendingCapture(captureId: entry.job.captureId,
                                  digest: entry.job.digest,
                                  bytes: entry.job.bytes,
                                  ackedIndex: peer.transfer(of: entry.job.captureId)?
                                      .ackedIndex)
        }
    }

    // MARK: Eviction

    /// ⛔ **I38, through the library's predicate and through nothing else.**
    ///
    /// - Returns: the ids safe to delete, in the order offered.
    /// - Note: a caller that wants to free space and finds this empty has its
    ///   answer: 5.14g1 says refuse to arm, not shed.
    public func evictable(from captureIds: [String]) -> [String] {
        captureIds.filter { peer.isEvictable(captureId: $0) }
    }

    /// The candidate-evidence Captures the retention policy has pushed out.
    ///
    /// ⚠ Two conditions, both required. The policy says *which* windows are past
    /// the cap (B7, 5.12.1b — peer policy, and the protocol MUST NOT constrain
    /// it); the library says whether the protocol has released them (5.14g exit 4
    /// names 5.12.1b, so it has). ⛔ Neither alone is enough: a policy that evicted
    /// without asking would be the fifth exit 5.14g1 forbids.
    public func evictableCandidateEvidence(under retention: CandidateAudioRetention)
        -> [String] {
        evictable(from: retention.evictions(from: candidateEvidence))
    }

    /// Forget an evicted window. ⛔ The **caller** must then re-announce the
    /// Capture `absent` with `not_retained` (5.12.1c): absence is asserted, never
    /// left as a dangling reference.
    public func forgetCandidateEvidence(_ captureId: String) {
        candidateEvidence.removeAll { $0 == captureId }
    }
}

// MARK: - Storage pressure

/// `CORE` 5.14g1 / REQ-OFF-2 — "a peer under storage pressure **refuses to arm**
/// rather than dropping swings a consumer has not received".
///
/// ⛔ The floor is this application's and must not reach the protocol (I14, 5.7d).
/// What the protocol *does* define is the answer: a `readiness` that is not
/// settled, `blocked_by: storage_full` (5.15a) — a measurement, not a state name.
public struct StorageFloor: Sendable, Hashable {

    /// ⚠ `assumed`, in plan A12's sense: no rig has measured what a session
    /// actually costs on each device, and 1 GB is the requirements document's own
    /// per-session figure with one session of headroom.
    public var refuseToArmBelowBytes: UInt64
    /// The point at which the app warns but still arms (REQ-OFF-2's "warn on low
    /// free space").
    public var warnBelowBytes: UInt64

    public init(refuseToArmBelowBytes: UInt64 = 2 << 30,
                warnBelowBytes: UInt64 = 4 << 30) {
        self.refuseToArmBelowBytes = refuseToArmBelowBytes
        self.warnBelowBytes = warnBelowBytes
    }

    public enum Verdict: Sendable, Hashable {
        case armable
        case armableWithWarning
        /// ⛔ Refuse. **Not** "shed the oldest clip": that is the licence 5.14g1
        /// explicitly withholds.
        case refuseToArm
    }

    public func verdict(freeBytes: UInt64) -> Verdict {
        if freeBytes < refuseToArmBelowBytes { return .refuseToArm }
        if freeBytes < warnBelowBytes { return .armableWithWarning }
        return .armable
    }

    /// The `readiness` this device answers `arm` with when it will not arm.
    public func readiness(freeBytes: UInt64) throws -> ppcp_readiness {
        switch verdict(freeBytes: freeBytes) {
        case .refuseToArm:
            // ⚠ Not settled, and it says what is blocking it. 5.15a: no device
            // state name crosses the wire, so "cold"/"armed" never appear.
            return try PpcpReadiness.notSettled(readyInMilliseconds: 0,
                                                blockedBy: PpcpReadiness.blockedStorageFull)
        case .armableWithWarning, .armable:
            return try PpcpReadiness.settled()
        }
    }
}
