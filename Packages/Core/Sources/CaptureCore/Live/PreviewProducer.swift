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
        // ⛔ **`transfer: .present` GOES IN, IT IS NOT SET AFTERWARDS.**  This
        // built the record with `segment()`'s default — `.pending` — and
        // assigned `.present` on the next line, but `StreamCoverage.segment()`
        // enforces 8.1i/5.11j itself and threw `previewMayNotBePending` before
        // returning, so the assignment was unreachable and NOT ONE PREVIEW
        // SEGMENT WAS EVER PRODUCED.  Every frame, every session, since this
        // file was written; `LivePreview` swallowed the throw with `try?`, so
        // the symptom was a black tile and complete silence at both ends.
        // Found on device 28 Aug 2026.
        //
        // ⚠ The unit tests asserted the REFUSAL (`CapturePathTests` — a preview
        // Capture announced `pending` is refused) and never the happy path, so
        // a suite that was green throughout was testing the guard that was
        // firing.
        let record = try coverage.segment(id: id, endingAtNs: endNs,
                                          completeness: .complete,
                                          transfer: .present)
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
        // ⛔ **CHUNKED, BECAUSE ONE FRAME IS BIGGER THAN ONE CHUNK.**  This sent
        // the whole JPEG as index 0, and `ppcp_peer_payload_chunk` refuses
        // `len > chunk_bytes` (`ppcp_peer.c:1529`).  A 640×360 preview frame at
        // q0.6 is ~35 kB against a 32 kB chunk, so nearly every frame was
        // refused — and the ones that squeezed under would have made it look
        // intermittent rather than broken.  `LivePreview` swallowed the throw,
        // so the result was a black tile and no error anywhere.  Found on
        // device 28 Aug 2026.
        let size = Int(PayloadTransferQueue.chunkBytes)
        var index: UInt32 = 0
        var offset = 0
        while offset < payload.count {
            let end = min(offset + size, payload.count)
            try peer.payloadChunk(captureId: id, index: index,
                                  chunkBytes: PayloadTransferQueue.chunkBytes,
                                  data: Data(payload[offset ..< end]), channel: channel)
            index += 1
            offset = end
        }
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
