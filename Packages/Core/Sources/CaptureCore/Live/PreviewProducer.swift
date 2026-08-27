//  PreviewProducer.swift
//  The live `preview` Stream: sent while it is fresh, shed the moment it is not.
//
//  ⛔ **Preview is live-only** (`CORE` 5.11j). What could not be delivered
//  promptly is *discarded* and announced `absent` with `not_retained` — it is
//  never retained for later transfer and never written to a bundle. A queue told
//  nothing else fills with the cheapest data in the session and starves the shot
//  payload behind it, and by the time it drains the frames are worthless.
//
//  ⛔ **A distinct bulk channel** (5.11h): preview payload does not share the
//  channel shot payload uses. Sharing it would put a low-value stream in front of
//  a high-value one on a link that is already the bottleneck, and 7.4d's ordering
//  — transfer, replay and reporting degrade before capture does — has no way to
//  express itself inside a single ordered channel.
//
//  ⚠ **Every interval is accounted for either way** (I36, 5.11c). A `continuous`
//  Stream's announced segments and gaps account for the whole interval from
//  `opened_at` onward; time accounted for by neither is a *defect*, not a dropout.
//  Shedding is therefore an announcement, not a silence.
//
//  Spec: `CORE` §5.11c, §5.11h, §5.11j, §5.14g; `MSG` §8.1i. Plan D6.

import Foundation

/// Produces `preview` segments on a live link, and sheds what it cannot deliver.
public final class PreviewProducer: @unchecked Sendable {

    /// What happened to one segment.
    public enum Outcome: Sendable, Hashable {
        case sent(captureId: String)
        /// 5.11j — discarded rather than queued, and **announced** as discarded.
        case shed(captureId: String)
    }

    private let peer: DevicePeer
    private let stream: PpcpStreamRecord
    private let channel: PpcpChannel
    private let mintId: @Sendable () -> String
    private var coverage: StreamCoverage

    /// - Parameter channel: ⛔ must not be the channel shot payload uses (5.11h).
    ///   `.preview` is the third channel this application allocates; `ENC` 2a
    ///   reserves 255 and leaves the rest to the embedding.
    public init(peer: DevicePeer, stream: PpcpStreamRecord,
                channel: PpcpChannel = .preview,
                mintId: @escaping @Sendable () -> String
                    = { UUID().uuidString.lowercased() }) throws {
        guard stream.kind == PpcpStreamKind.preview else {
            throw ProducerError.notAPreviewStream(stream.kind)
        }
        guard channel != .bulk else { throw ProducerError.sharesTheShotChannel }
        self.peer = peer
        self.stream = stream
        self.channel = channel
        self.mintId = mintId
        coverage = try StreamCoverage(stream: stream)
    }

    public enum ProducerError: Error, Sendable, Equatable {
        case notAPreviewStream(String)
        /// 5.11h — preview payload on the shot payload's channel.
        case sharesTheShotChannel
    }

    /// One segment, delivered now.
    ///
    /// ⛔ The Capture is announced `transfer: present`, never `pending`: `MSG` 8.1i
    /// makes a preview Capture announced `pending` a refusal in the **library**,
    /// because "pending" is the claim that it is queued, and preview is never
    /// queued.
    @discardableResult
    public func deliver(endingAtNs endNs: Int64, payload: Data) throws -> Outcome {
        let id = mintId()
        var record = try coverage.segment(id: id, endingAtNs: endNs,
                                          completeness: .complete)
        record.transfer = .present
        try peer.announce(record, isPreview: true)

        // ⚠ The bytes go out on the preview channel and nothing remembers them.
        // There is no `TransferJob` for a preview segment anywhere in this
        // application, which is 5.11j held by there being nowhere to queue it.
        try peer.payloadBegin(captureId: id, bytes: UInt64(payload.count),
                              digest: SessionBundleWriter.digest(of: payload),
                              chunkBytes: PayloadTransferQueue.chunkBytes,
                              channel: channel,
                              // `ENC` 6g (erratum E7) — a preview segment is a
                              // container-framed file like any other clip, and a
                              // receiver may not infer that (6h). ⛔ **JPEG, not
                              // MP4**: `PreviewFrameTap` encodes single frames,
                              // and this said `video/mp4` until 27 Aug.
                              container: PpcpMediaType.previewFrame)
        try peer.payloadChunk(captureId: id, index: 0,
                              chunkBytes: PayloadTransferQueue.chunkBytes,
                              data: payload, channel: channel)
        try peer.payloadEnd(captureId: id,
                            digest: SessionBundleWriter.digest(of: payload),
                            channel: channel)
        return .sent(captureId: id)
    }

    /// The interval this producer could not deliver in time.
    ///
    /// ⚠ **Announced, not dropped.** I36: an interval accounted for by neither a
    /// Capture nor a gap is a defect in the record, so shedding says so — and
    /// 5.14g exit 4 is what makes the payload's absence lawful rather than a
    /// breach of I38.
    @discardableResult
    public func shed(throughNs endNs: Int64) throws -> Outcome {
        let id = mintId()
        let record = try coverage.shed(id: id, endingAtNs: endNs)
        try peer.announce(record, isPreview: true)
        return .shed(captureId: id)
    }

    /// I36 — what neither a segment nor a shed has accounted for, as of `nowNs`.
    /// ⛔ Non-`nil` in a Session asserted `complete` is a defect, not a dropout.
    public func unaccountedNs(asOf nowNs: Int64) -> Range<Int64>? {
        coverage.unaccountedNs(asOf: nowNs)
    }

    public var accountedThroughNs: Int64 { coverage.accountedThroughNs }
}
