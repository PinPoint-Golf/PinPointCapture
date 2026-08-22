//  RingBufferRecorder.swift
//  REQ-BUF-1 on this platform — continuous capture into a rolling buffer of
//  hardware-encoded fragments, concatenated on trigger.
//
//  ⚠ **Encode to fragments, not raw frames** (REQ-BUF-1/4, REQ-PORT-9). Raw
//  1080p150 is ~466 MB/s and is not a RAM ring buffer. `AVAssetWriter`'s
//  segmented output does the encoding in hardware and hands back an independently
//  decodable segment every `preferredOutputSegmentInterval`; the index of what is
//  retained lives in `CaptureCore.FragmentRing`, which knows nothing about any of
//  this and can therefore be tested on the host.
//
//  ⛔ **REQ-BUF-2 — the fragment length is fixed by two INDEPENDENT
//  requirements**: ring-buffer tractability and frame-accurate reverse stepping
//  at capture rate (REQ-REPLAY-1). It must not later be "optimised" for bitrate.
//
//  ⛔ **`alwaysDiscardsLateVideoFrames` is `false` here and `true` in the
//  self-test, and the difference is deliberate.** The self-test wants drops to be
//  *visible* (REQ-CAP-3); the capture path wants them not to happen, because
//  §9.2 is "capture is non-recoverable; replay is repeatable" and capture
//  degrades last. The comment in `AVFoundationCaptureDevice.warmUp` asks for
//  exactly this and this is where it is answered.
//
//  ⚠ **Not exercised on hardware in this session.** The Core half is covered by
//  `make test-core`; what is below is the wiring, and the simulator has no
//  150 fps camera to run it against. Where an API contract is load-bearing it is
//  named in a comment so the first device run has something to check against
//  rather than a guess to re-derive.
//
//  Spec: `CORE` §5.8, §5.14, §8.4; requirements REQ-BUF-1..4, REQ-PORT-9.

import AVFoundation
import CoreMedia
import Foundation
import CaptureCore

/// The rolling buffer, its files, and the clip extraction that reads it.
///
/// ⚠ Every mutation happens on `queue`, which is the capture session's sample
/// queue. Nothing here takes a lock on the frame path.
public final class RingBufferRecorder: NSObject, @unchecked Sendable {

    public enum RecorderError: Error, Sendable {
        case notRecording
        case writerFailed(String)
        case fragmentMissing(UInt64)
    }

    /// REQ-BUF-2. ⛔ Not a tuning knob.
    public static let fragmentSeconds = 0.5
    /// REQ-BUF-1 — "retaining ~20 fragments".
    public static let fragmentCapacity = 20

    private let queue: DispatchQueue
    private let directory: URL
    private let timebaseId: String

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private var sequence: UInt64 = 0

    /// The `mpeg4AppleHLS` initialisation segment. ⛔ Prepended to every clip: a
    /// separable segment on its own does not decode, and a clip that needs a
    /// header the receiver has to reconstruct is a clip the receiver cannot open.
    private var initialisationSegment: Data?

    private let timeline = FrameTimeline()
    /// The frames of the fragment currently being written, drained at each
    /// segment boundary.
    private var pending = FrameTimeline.Batch()

    /// The protocol-facing index. ⛔ The only thing outside this file that
    /// answers "what does the buffer hold?".
    public private(set) var ring = FragmentRing(capacity: RingBufferRecorder.fragmentCapacity)

    /// Set while the exposure lock holds, which is the shipping configuration
    /// (REQ-OPT-3). `nil` means exposure was not locked and the numbers are
    /// `sampled` per frame (5.8h).
    public var lockedExposureNs: Int64?

    /// - Parameters:
    ///   - directory: where fragment files are written. One file per fragment;
    ///     evicted fragments are deleted with their ring entry.
    ///   - queue: the capture session's sample queue.
    public init(directory: URL, queue: DispatchQueue,
                timebaseId: String = PpcpTimebases.captureId) {
        self.directory = directory
        self.queue = queue
        self.timebaseId = timebaseId
        super.init()
    }

    // MARK: Lifecycle

    /// Start retaining. `CaptureState.armed` is the application's word for this;
    /// ⛔ that word does not cross the wire (5.15a).
    public func startRetaining(width: Int, height: Int, fps: Double,
                               bitrate: Int) throws {
        guard writer == nil else { return }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)

        // ⚠ `contentType:` plus `outputFileTypeProfile = .mpeg4AppleHLS` is what
        // makes the writer emit segments through the delegate instead of writing
        // one file. The initialiser that takes a URL cannot do this.
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: Self.fragmentSeconds,
                                                       preferredTimescale: 600)
        // ⛔ IDR at each boundary comes from the segment interval plus a GOP no
        // longer than it: `AVVideoMaxKeyFrameIntervalDurationKey` below.
        writer.initialSegmentStartTime = .zero
        writer.delegate = self

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                // REQ-BUF-1: an IDR at each fragment boundary, so a fragment is
                // independently decodable and a clip is a concatenation.
                AVVideoMaxKeyFrameIntervalDurationKey: Self.fragmentSeconds,
                // ⛔ REQ-REPLAY-1 — no B-frames. Frame-accurate reverse stepping
                // at capture rate is a requirement, and reordered output makes it
                // a decode-and-buffer problem instead of a seek.
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded())
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecorderError.writerFailed("cannot add the video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }

        self.writer = writer
        self.input = input
        self.sessionStarted = false
        self.timeline.reset()
    }

    /// Stop retaining and drop what is held. The ring's fragments go with it, and
    /// so do their files.
    public func stopRetaining() {
        input?.markAsFinished()
        writer?.cancelWriting()
        writer = nil
        input = nil
        sessionStarted = false
        for fragment in ring.fragments { removeFile(of: fragment) }
        ring.clear()
        initialisationSegment = nil
        timeline.reset()
    }

    public var isRetaining: Bool { writer != nil }

    // MARK: The frame path

    /// One delivered frame. ⚠ Called on `queue`, inside a 6.7 ms budget.
    public func append(_ sampleBuffer: CMSampleBuffer, device: AVCaptureDevice?) {
        timeline.observe(sampleBuffer, device: device)
        guard let writer, let input else { return }

        if sessionStarted == false {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }
        guard input.isReadyForMoreMediaData else {
            // ⛔ A frame the encoder could not take is a frame that is GONE, and
            // §9.2 says capture degrades last — so this is counted, not ignored,
            // and reaches the wire as `dropped_frames` on `AchievedSummary`.
            timeline.observeDrop()
            return
        }
        input.append(sampleBuffer)
    }

    public func appendDrop() { timeline.observeDrop() }

    // MARK: Extraction

    /// `CORE` 8.4a — the clip around a `t0` already converted into this device's
    /// timebase, and the bytes that make it up.
    ///
    /// - Returns: the extraction and, when it found frames, the concatenated
    ///   clip: the initialisation segment followed by every overlapping fragment
    ///   in time order.
    public func clip(aroundNs t0: Int64, preNs: Int64, postNs: Int64)
        throws -> (extraction: ClipExtraction, bytes: Data?) {
        let extraction = ring.extract(aroundNs: t0, preNs: preNs, postNs: postNs)
        guard extraction.isAbsent == false else { return (extraction, nil) }

        var bytes = initialisationSegment ?? Data()
        for fragment in extraction.fragments {
            let url = fileURL(of: fragment)
            guard let data = try? Data(contentsOf: url) else {
                throw RecorderError.fragmentMissing(fragment.sequence)
            }
            bytes.append(data)
        }
        return (extraction, bytes)
    }

    /// The Capture and its `AchievedFrames`, assembled honestly.
    public func capture(id: String, shotId: String, stream: PpcpStreamRecord,
                        aroundNs t0: Int64, preNs: Int64, postNs: Int64,
                        thermal: [PpcpThermalPoint] = [])
        throws -> (assembly: CaptureAssembly, bytes: Data?) {
        let (extraction, bytes) = try clip(aroundNs: t0, preNs: preNs, postNs: postNs)
        let batch = FrameTimeline.Batch(timestampsNs: extraction.frameTimestampsNs,
                                        exposureNs: extraction.exposureNs,
                                        iso: extraction.iso,
                                        intrinsics: [],
                                        droppedFrames: extraction.droppedFrames)
        let assembly = CaptureBuilder.shotCapture(
            id: id, shotId: shotId, stream: stream, extraction: extraction,
            exposure: FrameTimeline.exposure(batch, lockedNs: lockedExposureNs),
            intrinsics: nil,
            thermal: thermal)
        return (assembly, bytes)
    }

    // MARK: Files

    private func fileURL(of fragment: CapturedFragment) -> URL {
        directory.appendingPathComponent("frag-\(fragment.sequence).mp4")
    }

    private func removeFile(of fragment: CapturedFragment) {
        try? FileManager.default.removeItem(at: fileURL(of: fragment))
    }
}

// MARK: - Segment delivery

extension RingBufferRecorder: AVAssetWriterDelegate {

    /// ⚠ Called on the writer's own queue. `segmentType` is `.initialization`
    /// exactly once — that segment is the header every clip needs in front of it,
    /// and it is NOT a fragment.
    public func assetWriter(_ writer: AVAssetWriter,
                            didOutputSegmentData segmentData: Data,
                            segmentType: AVAssetSegmentType,
                            segmentReport: AVAssetSegmentReport?) {
        queue.async { [weak self] in
            self?.receive(segmentData, type: segmentType, report: segmentReport)
        }
    }

    private func receive(_ data: Data, type: AVAssetSegmentType,
                         report: AVAssetSegmentReport?) {
        guard type != .initialization else {
            initialisationSegment = data
            return
        }

        let batch = timeline.drain()
        // ⛔ The fragment's coverage comes from the frames it actually carries,
        // never from the segment's nominal duration (I2, 5.8e). A segment report
        // whose track times disagree with the frames is a report about the
        // container; the frames are the measurement.
        guard let first = batch.timestampsNs.first, let last = batch.timestampsNs.last else {
            return
        }
        let period = batch.timestampsNs.count > 1
            ? (last - first) / Int64(batch.timestampsNs.count - 1)
            : 0
        let fragment = CapturedFragment(
            sequence: sequence,
            startNs: first,
            // Half-open: the fragment covers up to the instant the next frame
            // would have been (`CORE` §5.1).
            endNs: last + max(period, 1),
            frameTimestampsNs: batch.timestampsNs,
            exposureNs: batch.exposureNs,
            iso: batch.iso,
            byteCount: data.count,
            droppedFrames: batch.droppedFrames)
        sequence += 1

        let url = directory.appendingPathComponent("frag-\(fragment.sequence).mp4")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // A fragment whose bytes did not land is not in the buffer, and the
            // ring must not claim it: the next `capture_request` for that span
            // gets `absent`/`outside_buffer`, which is the honest answer (8.4b).
            return
        }
        for evicted in ring.append(fragment) { removeFile(of: evicted) }
    }
}
