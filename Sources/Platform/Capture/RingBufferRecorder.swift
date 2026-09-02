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
//  degrades last. ⚠ The flag itself is NOT set here — it lives on the output, and
//  `AVFoundationCaptureDevice.Routing.discardsLateFrames` derives it from which
//  consumer is active, so neither requirement can quietly overwrite the other.
//
//  ⚠ **Connected 24 Aug 2026 (E1.1), and still not exercised on hardware.**
//  `AVFoundationCaptureDevice` feeds this from the live session's sample
//  delegate; what no phone has yet done is produce twenty fragments, rolling, at
//  the claimed rate. The Core half is covered by `make test-core`, and the
//  simulator has no 150 fps camera and no encoder path worth trusting for the
//  rest. Where an API contract is load-bearing it is named in a comment so the
//  first device run has something to check against rather than a guess to
//  re-derive — and `stats` is there so that run reports numbers instead of an
//  impression.
//
//  Spec: `CORE` §5.8, §5.14, §8.4; requirements REQ-BUF-1..4, REQ-PORT-9.

import AVFoundation
import CoreMedia
import Foundation
import CaptureCore

/// What the ring did, counted rather than inferred.
///
/// ⚠ **The instrument exists because the exit criterion cannot be checked
/// without it.** E1.1 asks for "twenty fragments, rolling, at the claimed rate";
/// a directory listing shows the first two and says nothing about the third. An
/// average frame rate is the specific number that hides the failure — 150 fps
/// mean with one 40 ms stall is not 150 fps, and it is the stall that loses the
/// impact frame.
///
/// Adapted from PinPointStudio's `src/Buffer/source_stats.h`, which carries the
/// same intent on a different substrate: `events_written`,
/// `events_overwritten`, `max_inter_arrival_us`, `monotonicity_violations`. ⛔
/// The counters that matter most are the ones for frames that go NOWHERE —
/// PPS's `acquireWriteSlot` returns `valid=false` rather than swallowing a
/// write, and the equivalents here are `framesDroppedNotRetaining` and
/// `fragmentsDroppedWriteFailed`.
public struct RingStats: Sendable, Hashable {

    /// Frames handed to the encoder. The denominator for everything else.
    public var framesAppended: Int = 0
    /// The encoder was not ready. §9.2: counted, never ignored.
    public var framesDroppedEncoderBusy: Int = 0
    /// ⛔ A frame that arrived while nothing was retaining. Previously invisible:
    /// `append` returned early and the frame vanished without a trace.
    public var framesDroppedNotRetaining: Int = 0

    /// Fragments that reached the ring index.
    public var fragmentsWritten: Int = 0
    /// Fragments evicted by rollover. `written - evicted` should settle at the
    /// capacity once the ring is full.
    ///
    /// ⛔ **This is `CORE` 5.21a's counter and the frame-drop counters are
    /// not** (trap 7). 5.21a counts what never became part of *any* Capture; a
    /// frame the encoder was too busy to take is already accounted for in the
    /// Capture's `achieved_summary`, and adding it here would count it twice.
    ///
    /// ⚠ **Its epoch is the ARM, not the Stream open.** `RingStats` is created
    /// with the recorder and the recorder is created by `startRetaining`, so
    /// this resets every time a golfer arms. `buffer_status.discarded_since_open`
    /// is per *Stream open*, so its emitter subtracts a baseline rather than
    /// sending this number.
    public var fragmentsEvicted: Int = 0

    /// `CORE` 5.21 `last_discard` — the span of the most recently evicted
    /// fragment, on the capture timebase.
    ///
    /// ⛔ **Recorded where the eviction happens, because that is the only place
    /// the fragment's own instants exist.** A `FragmentRing` hands back what it
    /// dropped and then forgets it; reconstructing the span afterwards from
    /// `retainedNs` would be arithmetic over a ring that has already moved.
    ///
    /// ⚠ Both halves or neither — `last_discard` is one statement (a span), and
    /// the library's setter takes them together for that reason.
    public var lastDiscardStartNs: Int64?
    public var lastDiscardEndNs: Int64?

    /// `CORE` 5.21 `retained_from` — the oldest instant still in the ring.
    ///
    /// ⚠ **Filled by the reader, not by `append`.** It is derived from the
    /// ring's first fragment and would otherwise be a third thing to keep in
    /// step on the 150 fps frame path for a value nobody reads there. `nil`
    /// means the ring holds nothing, which is not the same as holding a
    /// zero-length window.
    public var retainedFromNs: Int64?
    /// ⛔ Bytes that did not land, so the ring must not claim them (8.4b).
    public var fragmentsDroppedWriteFailed: Int = 0
    /// A fragment that carried no frames at all, so it could not be indexed.
    public var fragmentsDroppedEmpty: Int = 0

    /// **The rate evidence.** The largest gap between consecutive delivered
    /// frames. PPS's `updateInterArrival`.
    public var maxInterArrivalNs: Int64 = 0
    /// Frame timestamps that went backwards. With `AllowFrameReordering = false`
    /// this should stay zero — counting it is how we find out rather than
    /// assume.
    public var monotonicityViolations: Int = 0

    /// ⛔ **What VideoToolbox actually chose**, read out of the encoded stream
    /// rather than asked for. E1.1's exit criterion names the encoded
    /// profile/level and **no run has ever printed it** — `AVVideoProfileLevelKey`
    /// is not set, so the encoder decides and nothing here contradicted it.
    ///
    /// ⚠ **The tier is the decisive half.** HEVC's bitrate ceiling is a property
    /// of profile *and tier*: at level 5.1 Main tier caps at 40 Mbit/s, and this
    /// application asks for a provisional **50** ([#20](https://github.com/PinPoint-Golf/PinPointCapture/issues/20)).
    /// So either VideoToolbox picked High tier and the request is honoured, or
    /// it picked Main and the ask exceeds the level it declared — and a decoder
    /// is entitled to believe the declaration. **`nil` means the run did not
    /// find out**, which is where this stood until 28 Aug 2026.
    public var encodedProfileLevel: String?

    // MARK: Where the gaps are, not just how big the worst one was (#101)

    /// ⛔ **A maximum answers "how bad" and refuses to answer "when", and "when"
    /// is the whole question.** #101's catastrophic gaps all landed in a narrow
    /// band — 8894, 8703, 8854 ms across three different capture modes — which
    /// is far too tight to be thermal or load and looks like one bounded
    /// operation. Whether that operation happens at the *start* of a run
    /// (a session reconfiguration) or throughout it is the difference between a
    /// startup defect and a sustained one, and `maxInterArrivalNs` cannot tell
    /// them apart.
    ///
    /// Counts of inter-arrival deltas by size, in these bounds:
    /// `< 2 ms, < 5, < 10, < 20, < 50, < 100, < 500, >= 500`.
    ///
    /// ⚠ **Absolute rather than in frame periods**, because `RingStats` does not
    /// know the rate — the caller does, and prints them against it.
    public var gapBuckets: [Int] = Array(repeating: 0, count: 8)

    /// The bucket upper bounds, in nanoseconds. `.max` is the open top bucket.
    public static let gapBucketBoundsNs: [Int64] = [
        2_000_000, 5_000_000, 10_000_000, 20_000_000,
        50_000_000, 100_000_000, 500_000_000, .max
    ]

    /// The largest gaps seen, each with **how far into the run it happened**.
    ///
    /// ⚠ Fixed at eight and inserted in place: this runs on the frame path, so
    /// there is no sort and no allocation — at most eight comparisons, and only
    /// for a delta already larger than the smallest one kept.
    public private(set) var largestGaps: [Gap] = []

    /// One inter-arrival gap, and how far into the run it happened.
    public struct Gap: Sendable, Hashable {
        /// From the first frame the ring saw to the frame *before* the gap.
        public var sinceFirstNs: Int64
        public var deltaNs: Int64
    }

    /// How many deltas exceeded `notableGapNs` in total, however few were kept.
    public var notableGapCount: Int = 0

    /// ⚠ Ten milliseconds: two frame periods at 240 fps and slightly over one at
    /// 120, so it is "a frame was missed" at every rate this device offers.
    public static let notableGapNs: Int64 = 10_000_000

    public init() {}

    /// The realised rate over what the ring actually saw, from timestamp deltas
    /// and never from a frame count over a wall clock (REQ-FPS-2, REQ-TIME-5).
    ///
    /// ⚠ Deliberately paired with `maxInterArrivalNs` at every call site. On its
    /// own it is the average that hides the stall.
    public var meanInterArrivalNs: Int64 {
        guard framesAppended > 1, spanNs > 0 else { return 0 }
        return spanNs / Int64(framesAppended - 1)
    }

    /// First to last delivered frame, in the capture timebase.
    public internal(set) var spanNs: Int64 = 0

    /// ⚠ Called on the frame path. No allocation, no locking — the caller owns
    /// the queue this runs on.
    mutating func observeArrival(atNs timestampNs: Int64) {
        defer { lastArrivalNs = timestampNs }
        framesAppended += 1
        guard let previous = lastArrivalNs else {
            firstArrivalNs = timestampNs
            return
        }
        let delta = timestampNs - previous
        if delta < 0 {
            monotonicityViolations += 1
            return
        }
        if delta > maxInterArrivalNs { maxInterArrivalNs = delta }
        if let first = firstArrivalNs { spanNs = timestampNs - first }

        // ── The distribution (#101) ───────────────────────────────────────
        var bucket = Self.gapBucketBoundsNs.count - 1
        for (index, bound) in Self.gapBucketBoundsNs.enumerated() where delta < bound {
            bucket = index
            break
        }
        gapBuckets[bucket] += 1

        guard delta >= Self.notableGapNs, let first = firstArrivalNs else { return }
        notableGapCount += 1
        let entry = Gap(sinceFirstNs: previous - first, deltaNs: delta)
        if largestGaps.count < 8 {
            largestGaps.append(entry)
        } else if let smallest = largestGaps.indices
            .min(by: { largestGaps[$0].deltaNs < largestGaps[$1].deltaNs }),
            largestGaps[smallest].deltaNs < delta {
            largestGaps[smallest] = entry
        }
    }

    private var firstArrivalNs: Int64?
    private var lastArrivalNs: Int64?
}

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

    /// `CORE` 5.21 `retention_target` — what the ring is *trying* to hold.
    ///
    /// ⚠ The two constants that actually decide it, multiplied here rather than
    /// written as a third constant that could disagree with them.
    public static let retentionTargetNs =
        Int64(Double(fragmentCapacity) * fragmentSeconds * 1_000_000_000)

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

    /// What the ring did during the current retention. ⛔ Reset by
    /// `startRetaining`, so the numbers always belong to one run — a counter
    /// accumulated across arms answers a question nobody asked.
    ///
    /// ⚠ Mutated on `queue` and read from anywhere. The read is a struct copy of
    /// plain integers, which is the reason this is a value type and not a class.
    public private(set) var stats = RingStats()

    /// ⚠ **Exposed for the synthetic-frame tests, which are the only thing that
    /// can prove the concatenation contract without a camera.** A clip is the
    /// initialisation segment followed by fragments; a fragment alone does not
    /// decode, and there is no platform guarantee the writer got that right — so
    /// a test has to be able to ask whether the header ever arrived.
    var hasInitialisationSegment: Bool { initialisationSegment != nil }

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
        try prepareDirectory()
        stats = RingStats()

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
        // ⛔ The guard comes BEFORE the timeline, and the order is the fix. It
        // used to observe first, so frames arriving after `stopRetaining` piled
        // into `pending` with no segment boundary left to drain them — and
        // frames arriving before `startRetaining` disappeared with no counter at
        // all. PPS makes the same moment explicit: `acquireWriteSlot` returns
        // `valid=false` when the buffer is not Capturing, and the producer can
        // see that it did.
        guard let writer, let input else {
            stats.framesDroppedNotRetaining += 1
            return
        }

        stats.observeArrival(
            atNs: FrameTimeline.nanoseconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
        timeline.observe(sampleBuffer, device: device)

        if sessionStarted == false {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }
        guard input.isReadyForMoreMediaData else {
            // ⛔ A frame the encoder could not take is a frame that is GONE, and
            // §9.2 says capture degrades last — so this is counted, not ignored,
            // and reaches the wire as `dropped_frames` on `AchievedSummary`.
            timeline.observeDrop()
            stats.framesDroppedEncoderBusy += 1
            return
        }
        input.append(sampleBuffer)
    }

    public func appendDrop() {
        timeline.observeDrop()
        stats.framesDroppedEncoderBusy += 1
    }

    // MARK: Extraction

    /// `CORE` 8.4a — the clip around a `t0` already converted into this device's
    /// timebase, and the bytes that make it up.
    ///
    /// - Returns: the extraction and, when it found frames, the concatenated
    ///   clip: the initialisation segment followed by every overlapping fragment
    ///   in time order.
    ///
    /// ⚠ **Assembled through `RetainedWindow` since E1.5.** The bytes are
    /// identical — the window walks the same entries in the same order behind
    /// the same header — but the walk is now the one implementation E4.1's
    /// bundle-backed source will reuse, instead of a private loop here that a
    /// second backing would have had to duplicate.
    public func clip(aroundNs t0: Int64, preNs: Int64, postNs: Int64)
        throws -> (extraction: ClipExtraction, bytes: Data?) {
        let extraction = ring.extract(aroundNs: t0, preNs: preNs, postNs: postNs)
        guard extraction.isAbsent == false else { return (extraction, nil) }

        let requested = (t0 - Swift.max(0, preNs))..<(t0 + Swift.max(0, postNs))
        let window = RetainedWindow(
            snapshot: TimelineIndex(ring.timelineEntries()).snapshot(requested),
            source: self)
        guard let assembled = try window
            .concatenatedPayload(ofSource: FragmentRing.defaultVideoSourceId) else {
            return (extraction, nil)
        }
        // ⛔ A fragment the ring indexed and the disk cannot serve is not a
        // shorter clip, it is a broken backing — the ring's own eviction removes
        // the entry and its file together, so a missing file means something
        // else deleted it. Throwing keeps that distinct from 8.4b's `absent`,
        // which is what an interval the ring never held answers with.
        if let firstMissing = assembled.missing.first {
            throw RecorderError.fragmentMissing(firstMissing.sequence)
        }
        return (extraction, assembled.bytes)
    }

    /// Everything a shot-anchored Capture needs around a `t0`, in one value.
    ///
    /// ⛔ **Does not throw**, because 8.4b makes "the interval is gone" an
    /// answer: a ring holding nothing returns an `absent` extraction and the
    /// Shot still exists. Only the payload provider throws, and only when a
    /// backing that ought to have bytes cannot produce them.
    ///
    /// ⚠ The payload is a closure over this recorder, so the bytes are read
    /// when the bundle writes them and not before (`ENC` 7c).
    public func retainedClip(aroundNs t0: Int64, preNs: Int64, postNs: Int64,
                             thermal: [PpcpThermalPoint] = []) -> RetainedClip {
        let extraction = ring.extract(aroundNs: t0, preNs: preNs, postNs: postNs)
        // Read beside the extraction, under the same queue, so the two describe
        // the same instant of the ring.
        let held = ring.retainedNs
        guard extraction.isAbsent == false else {
            return RetainedClip(extraction: extraction, exposure: .noExposure,
                                retainedNs: held)
        }
        let batch = FrameTimeline.Batch(timestampsNs: extraction.frameTimestampsNs,
                                        exposureNs: extraction.exposureNs,
                                        iso: extraction.iso,
                                        intrinsics: extraction.intrinsics,
                                        droppedFrames: extraction.droppedFrames)
        return RetainedClip(
            extraction: extraction,
            // ⛔ The measured value, not the `.lockedConstant(0)` that stood
            // here in `RecordingSession` — 5.8d makes exposure
            // mandatory precisely because I17's conversion needs it, and zero
            // would have converted every instant by the wrong amount.
            exposure: FrameTimeline.exposure(batch, lockedNs: lockedExposureNs),
            intrinsics: FrameTimeline.intrinsics(batch),
            thermal: thermal,
            payload: { [weak self] in
                guard let self else { throw RecorderError.notRecording }
                let (_, bytes) = try self.clip(aroundNs: t0, preNs: preNs, postNs: postNs)
                guard let bytes else { throw RecorderError.notRecording }
                return bytes
            },
            retainedNs: held)
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
                                        // ⛔ Was `[]`, and that was the whole of
                                        // E1.3's gap: the matrices were observed
                                        // per frame, drained per fragment, and
                                        // then thrown away one line before the
                                        // builder that wanted them.
                                        intrinsics: extraction.intrinsics,
                                        droppedFrames: extraction.droppedFrames)
        let assembly = CaptureBuilder.shotCapture(
            id: id, shotId: shotId, stream: stream, extraction: extraction,
            exposure: FrameTimeline.exposure(batch, lockedNs: lockedExposureNs),
            intrinsics: FrameTimeline.intrinsics(batch),
            thermal: thermal)
        return (assembly, bytes)
    }

    // MARK: Files

    /// Create the ring directory, mark it, and sweep whatever the last run left.
    ///
    /// ⛔ **The sweep is not tidiness.** Fragments that outlive their process —
    /// a crash, a jetsam kill mid-swing — are not in the in-memory ring, so
    /// nothing will ever evict them. They belong to no session, they cannot be
    /// extracted from, and they count against the storage headroom REQ-OFF-2's
    /// arm-time floor is computed from. The only moment it is safe to delete
    /// them is here, before anything starts writing.
    private func prepareDirectory() throws {
        var directory = directory
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)

        // ⚠ Excluded from backup, and NOT in Caches. The ring is regenerable, so
        // Caches is the conventional home — but iOS may purge it under storage
        // pressure while the session is armed, and a ring that empties itself
        // without saying so is precisely the silent failure §9.2 forbids.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)

        let orphans = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for orphan in orphans { try? FileManager.default.removeItem(at: orphan) }
    }

    func fileURL(ofSequence sequence: UInt64) -> URL {
        directory.appendingPathComponent("frag-\(sequence).mp4")
    }

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
            // ⛔ E1.1's last unreported number. The initialisation segment is the
            // `moov`, and the `hvcC` inside it is the encoder's own declaration
            // of what it produced — the only statement of profile/tier/level that
            // is not a guess about what we asked for.
            stats.encodedProfileLevel = Self.hevcProfileLevel(inMoov: data)
            return
        }

        let batch = timeline.drain()
        // ⛔ The fragment's coverage comes from the frames it actually carries,
        // never from the segment's nominal duration (I2, 5.8e). A segment report
        // whose track times disagree with the frames is a report about the
        // container; the frames are the measurement.
        guard let first = batch.timestampsNs.first, let last = batch.timestampsNs.last else {
            stats.fragmentsDroppedEmpty += 1
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
            // REQ-OPT-7 / `ENC` §4.1 — row-major, one per frame, and only where
            // the connection actually delivered them. ⛔ `FrameTimeline` appends
            // nothing when it did not, so an empty array here means the device
            // is not delivering intrinsics rather than that this fragment
            // missed them.
            intrinsics: batch.intrinsics,
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
            //
            // ⚠ PPS's `PublishOnInvalidSlotIsNoop` is the same rule on the other
            // substrate, and it is counted for the same reason: a ring that
            // silently shrinks looks identical to one that is simply young.
            stats.fragmentsDroppedWriteFailed += 1
            return
        }
        stats.fragmentsWritten += 1
        for evicted in ring.append(fragment) {
            stats.fragmentsEvicted += 1
            // `CORE` 5.21 `last_discard` — the span this eviction removed from
            // the retained window, taken here where `startNs`/`endNs` are still
            // to hand. The loop can evict more than one, and the *last* is the
            // one the field names.
            stats.lastDiscardStartNs = evicted.startNs
            stats.lastDiscardEndNs = evicted.endNs
            removeFile(of: evicted)
        }
    }
}

// MARK: - What the encoder actually produced (#17)

extension RingBufferRecorder {

    /// The HEVC profile, tier and level the encoder declared, read out of the
    /// `hvcC` box in an initialisation segment.
    ///
    /// ⚠ **A scan for the box type, not a walk of the box tree**, and that is a
    /// deliberate trade: this is a diagnostic readout on a path that already
    /// holds the whole `moov` in memory, `hvcC` appears exactly once in it, and a
    /// full ISO-BMFF walk would be a great deal of code to reach the same twelve
    /// bytes. ⛔ It returns `nil` rather than guessing if the box is absent or
    /// short — a wrong number here is worse than no number, because the whole
    /// point of the field is that nobody has measured it.
    ///
    /// Layout, ISO/IEC 14496-15 §8.3.3.1, from the first payload byte:
    /// `[0]` configurationVersion · `[1]` profile_space(2) | tier_flag(1) |
    /// profile_idc(5) · `[2…5]` compatibility flags · `[6…11]` constraint flags ·
    /// `[12]` level_idc, which is the level times thirty.
    static func hevcProfileLevel(inMoov data: Data) -> String? {
        let marker = Array("hvcC".utf8)
        let bytes = [UInt8](data)
        guard let box = bytes.firstRange(of: marker) else { return nil }
        let payload = box.upperBound
        guard bytes.count >= payload + 13 else { return nil }

        let profileIdc = bytes[payload + 1] & 0b0001_1111
        let tierFlag = (bytes[payload + 1] >> 5) & 0b1
        let levelIdc = bytes[payload + 12]

        let profile: String
        switch profileIdc {
        case 1: profile = "Main"
        case 2: profile = "Main 10"
        case 3: profile = "Main Still Picture"
        case 4: profile = "Range Extensions"
        default: profile = "profile_idc \(profileIdc)"
        }
        let tier = tierFlag == 0 ? "Main tier" : "High tier"
        // level_idc is thirty times the level, so 153 is 5.1.
        let level = String(format: "%.1f", Double(levelIdc) / 30.0)
        return "HEVC \(profile), \(tier), level \(level) "
             + "(profile_idc \(profileIdc), tier_flag \(tierFlag), level_idc \(levelIdc))"
    }
}

// MARK: - The ring as a payload backing (E1.5)

/// ⛔ **This is the seam E4.1 will implement a second time, against a bundle.**
/// The window above does not know it is talking to a live ring — it asks for an
/// entry's bytes and for whatever header they need in front, and both a
/// fragment directory and a `PPCPBNDL` can answer that honestly. PPS's
/// equivalent could not: `SwingPayloadSource::payloadOf` returns a RAM-ring
/// handle, so its disk source has to manufacture one.
extension RingBufferRecorder: RetainedPayloadSource {

    /// ⚠ `nil` means the ring listed this entry and the bytes are gone — an
    /// eviction that raced the snapshot. A **result**, not a failure (8.4b), so
    /// it does not throw; the caller decides what a short clip means.
    public func payload(for entry: TimelineEntry) throws -> Data? {
        let url = fileURL(ofSequence: entry.sequence)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// ⛔ The `mpeg4AppleHLS` initialisation segment, and it is load-bearing.
    /// Measured 24 August 2026: the header plus fragments opens as one video
    /// track, and the same fragments without it do not open at all. A backing
    /// that forgot this would serve clips that are bytes and not video.
    public func initialisationPrefix(ofSource sourceId: String) -> Data? {
        initialisationSegment
    }
}
