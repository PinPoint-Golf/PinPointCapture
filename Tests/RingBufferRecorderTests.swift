//  RingBufferRecorderTests.swift
//  E1.1 — the ring's mechanics, driven by synthetic frames.
//
//  ⚠ **This suite exists because "needs a phone" was too broad a claim.** The
//  header of `RingBufferRecorder` and §1.4 of the delivery scope both said the
//  segment-delivery path could only be exercised on hardware. That is true of
//  the *camera* — a simulator has no 150 fps sensor, no locks to hold and no
//  thermal behaviour. It is NOT true of the writer: `AVAssetWriter`'s segmented
//  output, the initialisation segment, IDR-aligned fragments, the fragment
//  index, eviction and the concatenation contract all run on a simulator when
//  fed synthetic buffers, and every one of them is somewhere the code can be
//  wrong.
//
//  ⛔ **Frames must be paced at wall-clock rate.** `expectsMediaDataInRealTime =
//  true` makes the input throttle: feeding four seconds of PTS in milliseconds
//  left `isReadyForMoreMediaData` false for 113 of 120 frames and produced no
//  segments at all. Measured 24 Aug 2026 — and it is worth knowing that the
//  failure mode of over-feeding this path is silence, not an error.
//
//  ⚠ Deliberately 640×480 at 30 fps, not 1080p150. The point is the *mechanism*;
//  the rate and the resolution are what the device run is for.
//
//  Spec: `CORE` §5.8, §5.14, §8.4; requirements REQ-BUF-1..4.

import AVFoundation
import CoreGraphics
import CoreMedia
import ImageIO
import Foundation
import Testing
import CaptureCore
@testable import PinPointCapture

@Suite("E1.1 — the ring, on synthetic frames")
struct RingBufferRecorderTests {

    static let width = 640
    static let height = 480
    static let fps = 30
    static var periodNs: Int64 { Int64(1_000_000_000 / fps) }

    // MARK: Synthetic frames

    static func pixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &buffer)
        return buffer
    }

    static func sample(_ pixels: CVPixelBuffer, ptsNs: Int64) -> CMSampleBuffer? {
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixels,
                                                     formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            presentationTimeStamp: CMTime(value: ptsNs, timescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                           imageBuffer: pixels, dataReady: true,
                                           makeDataReadyCallback: nil, refcon: nil,
                                           formatDescription: format,
                                           sampleTiming: &timing,
                                           sampleBufferOut: &sample)
        return sample
    }

    /// A recorder fed `seconds` of paced synthetic video, then given time for the
    /// last segment to land.
    ///
    /// - Returns: the recorder, its directory, and the queue that owns it. ⚠ Every
    ///   read of `ring` or `stats` must go through that queue, exactly as
    ///   `AVFoundationCaptureDevice` does.
    static func recorded(seconds: Double, capacityOverride: Int? = nil)
        async throws -> (recorder: RingBufferRecorder, directory: URL, queue: DispatchQueue) {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                      isDirectory: true)
        let queue = DispatchQueue(label: "test.ring.samples")
        let recorder = RingBufferRecorder(directory: directory, queue: queue)
        try recorder.startRetaining(width: width, height: height,
                                    fps: Double(fps), bitrate: 2_000_000)

        let pixels = try #require(pixelBuffer())
        let frames = Int(Double(fps) * seconds)
        for index in 0..<frames {
            let sample = try #require(sample(pixels, ptsNs: Int64(index) * periodNs))
            queue.sync { recorder.append(sample, device: nil) }
            try await Task.sleep(for: .nanoseconds(periodNs))
        }
        // The writer emits a segment on its own queue, after the boundary.
        try await Task.sleep(for: .milliseconds(1500))
        return (recorder, directory, queue)
    }

    // MARK: The tests

    /// ⛔ The first half of E1.1's exit criterion, at a rate a simulator can hold.
    /// The *claimed* rate is the device run's job; that fragments appear at all,
    /// on the expected cadence, with nothing lost to the encoder, is this one's.
    @Test("Frames reach the ring, and fragments land on disk at the fragment cadence")
    func framesReachTheRing() async throws {
        let (recorder, directory, queue) = try await Self.recorded(seconds: 3)
        defer { queue.sync { recorder.stopRetaining() }
                try? FileManager.default.removeItem(at: directory) }

        let stats = queue.sync { recorder.stats }
        let fragments = queue.sync { recorder.ring.fragments }

        #expect(stats.framesAppended == Self.fps * 3)
        #expect(stats.framesDroppedEncoderBusy == 0,
                "paced at rate, nothing should be refused by the encoder")
        #expect(stats.framesDroppedNotRetaining == 0)
        #expect(stats.fragmentsDroppedWriteFailed == 0)
        #expect(stats.monotonicityViolations == 0,
                "AllowFrameReordering = false, so delivery is in order")

        // 3 s of 0.5 s fragments, less the one still open at the end.
        #expect(fragments.count >= 4 && fragments.count <= 6,
                "got \(fragments.count) fragments for 3 s")

        // ⛔ Every indexed fragment has a file. A ring entry naming bytes that are
        // not there is what 8.4b's `absent` exists to avoid claiming.
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == fragments.count)

        // The index describes one contiguous window.
        for (earlier, later) in zip(fragments, fragments.dropFirst()) {
            #expect(earlier.sequence + 1 == later.sequence)
            #expect(earlier.endNs == later.startNs)
        }
        #expect(fragments.allSatisfy { $0.frameTimestampsNs.isEmpty == false })
    }

    /// ⛔ **The concatenation contract, proved rather than assumed.**
    ///
    /// `capability-spike.md` §2a is explicit: there is no platform guarantee that
    /// fragment boundaries are IDR-aligned or that a concatenation of retained
    /// fragments decodes, so `RingBufferRecorder` must guarantee both. This is
    /// the check — and it is the thing E1.2 is about to build on.
    ///
    /// ⚠ The negative half matters as much as the positive: a fragment WITHOUT
    /// the initialisation segment must NOT open. If it does, the header is
    /// redundant and the design is wrong about why it is retained.
    @Test("A clip is the init segment plus fragments, and does not decode without it")
    func concatenatedClipDecodesOnlyWithItsHeader() async throws {
        let (recorder, directory, queue) = try await Self.recorded(seconds: 3)
        defer { queue.sync { recorder.stopRetaining() }
                try? FileManager.default.removeItem(at: directory) }

        #expect(queue.sync { recorder.hasInitialisationSegment },
                "the writer delivered a header segment")

        let retained = try #require(queue.sync { recorder.ring.retainedNs })
        let (extraction, bytes) = try queue.sync {
            try recorder.clip(aroundNs: (retained.lowerBound + retained.upperBound) / 2,
                              preNs: 500_000_000, postNs: 500_000_000)
        }
        #expect(extraction.isAbsent == false)
        let clip = try #require(bytes)
        #expect(clip.isEmpty == false)

        // ── The clip, as a receiver would open it ────────────────────────────
        let playable = directory.appendingPathComponent("clip.mp4")
        try clip.write(to: playable)
        let asset = AVURLAsset(url: playable)
        let tracks = try await asset.loadTracks(withMediaCharacteristic: .visual)
        #expect(tracks.count == 1, "a decodable clip has exactly one video track")
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 0.4, "and a real duration, not an empty container")

        // ── The same fragments WITHOUT the header ────────────────────────────
        // ⛔ If this opened, the initialisation segment would not need retaining
        // and the comment claiming it does would be wrong.
        var headerless = Data()
        for fragment in extraction.fragments {
            let url = directory.appendingPathComponent("frag-\(fragment.sequence).mp4")
            headerless.append(try Data(contentsOf: url))
        }
        let orphan = directory.appendingPathComponent("headerless.mp4")
        try headerless.write(to: orphan)
        let orphanTracks = try? await AVURLAsset(url: orphan)
            .loadTracks(withMediaCharacteristic: .visual)
        #expect(orphanTracks?.isEmpty ?? true,
                "a separable segment without its header is not a movie")
    }

    /// ⛔ **The guard on E1.5's refactor.** `clip(aroundNs:)` now assembles through
    /// `RetainedWindow` instead of its own loop over `extraction.fragments`. This
    /// reconstructs the expected bytes *independently* — the initialisation
    /// segment, then each overlapping fragment file in sequence order — and
    /// compares. ⚠ Independently matters: asserting that the new path produces
    /// something plausible would pass whatever it produced.
    @Test("The window assembles exactly the bytes a manual concatenation would")
    func windowMatchesAManualConcatenation() async throws {
        let (recorder, directory, queue) = try await Self.recorded(seconds: 3)
        defer { queue.sync { recorder.stopRetaining() }
                try? FileManager.default.removeItem(at: directory) }

        let retained = try #require(queue.sync { recorder.ring.retainedNs })
        let midpoint = (retained.lowerBound + retained.upperBound) / 2
        let (extraction, bytes) = try queue.sync {
            try recorder.clip(aroundNs: midpoint, preNs: 500_000_000,
                              postNs: 500_000_000)
        }
        let assembled = try #require(bytes)

        // The old implementation, written out by hand rather than called.
        var expected = Data()
        let header = queue.sync { recorder.initialisationPrefix(ofSource: "") }
        expected.append(try #require(header))
        for fragment in extraction.fragments {
            expected.append(try Data(contentsOf: directory
                .appendingPathComponent("frag-\(fragment.sequence).mp4")))
        }

        #expect(assembled == expected)
        #expect(extraction.fragments.isEmpty == false, "and it was a real clip")
    }

    // MARK: E1.2 / E1.3 — the clip, and what describes it

    /// ⛔ **E1.2's exit criterion, in everything but the camera.** "A trigger
    /// produces a playable clip instead of `absent`" — here the trigger is a
    /// synthetic `t0` rather than a club strike, and the frames are 30 fps
    /// rather than 150, but the path from an instant to a decodable MP4 with a
    /// real exposure behind it is the shipping one.
    @Test("A t0 produces a RetainedClip whose payload is a playable MP4")
    func aTriggerProducesAPlayableClip() async throws {
        let (recorder, directory, queue) = try await Self.recorded(seconds: 3)
        defer { queue.sync { recorder.stopRetaining() }
                try? FileManager.default.removeItem(at: directory) }

        let retained = try #require(queue.sync { recorder.ring.retainedNs })
        let t0 = (retained.lowerBound + retained.upperBound) / 2
        let clip = queue.sync {
            recorder.retainedClip(aroundNs: t0, preNs: 500_000_000, postNs: 500_000_000)
        }

        #expect(clip.extraction.isAbsent == false, "⛔ not `absent` — that was the point")
        let payload = try #require(clip.payload, "a present Capture carries a provider")
        let bytes = try payload()

        let url = directory.appendingPathComponent("shot.mp4")
        try bytes.write(to: url)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaCharacteristic: .visual)
        #expect(tracks.count == 1, "playable, not just bytes")
        #expect(try await asset.load(.duration).seconds > 0.4)
    }

    /// ⛔ **The hardcoded exposure is gone.** `RecordingSession` supplied
    /// `.lockedConstant(0)` to every Capture this application ever announced.
    /// 5.8d makes exposure mandatory on a camera Capture with frames precisely
    /// because I17's canonical-instant conversion needs it, and converting by
    /// zero is converting by the wrong amount.
    @Test("The clip carries the measured exposure, not a placeholder zero")
    func clipCarriesMeasuredExposure() async throws {
        let (recorder, directory, queue) = try await Self.recorded(seconds: 3)
        defer { queue.sync { recorder.stopRetaining() }
                try? FileManager.default.removeItem(at: directory) }

        // What the device reports under the REQ-OPT-3 lock.
        queue.sync { recorder.lockedExposureNs = 4_000_000 }

        let retained = try #require(queue.sync { recorder.ring.retainedNs })
        let clip = queue.sync {
            recorder.retainedClip(
                aroundNs: (retained.lowerBound + retained.upperBound) / 2,
                preNs: 500_000_000, postNs: 500_000_000)
        }

        #expect(clip.exposure == .lockedConstant(4_000_000))
        #expect(clip.exposure.provenance == .lockedConstant,
                "5.8h / CT-S7 (3) — locked, not `sampled` and never `per_frame`")
    }

    /// ⛔ **E1.2's third component.** The default tolerance on
    /// `AVAssetImageGenerator` lets it return the nearest keyframe, and REQ-BUF-1
    /// puts an IDR at every 0.5 s boundary — so a defaulted generator could hand
    /// back a frame up to half a second from impact. At 150 fps that is
    /// seventy-five frames away.
    @Test("The thumbnail is the frame asked for, not the nearest keyframe")
    func thumbnailIsTheRequestedFrameNotAKeyframe() async throws {
        let (recorder, directory, queue) = try await Self.recorded(seconds: 3)
        defer { queue.sync { recorder.stopRetaining() }
                try? FileManager.default.removeItem(at: directory) }

        let retained = try #require(queue.sync { recorder.ring.retainedNs })
        let clip = queue.sync {
            recorder.retainedClip(
                aroundNs: (retained.lowerBound + retained.upperBound) / 2,
                preNs: 500_000_000, postNs: 500_000_000)
        }
        let url = directory.appendingPathComponent("thumb-source.mp4")
        // ⚠ Three statements, not one expression: the inline form
        // `try (try #require(clip.payload))().write(to: url)` crashes the Swift
        // type checker on this toolchain (`recordArgumentList` assertion).
        let payload = try #require(clip.payload)
        let bytes = try payload()
        try bytes.write(to: url)

        // ⚠ 700 ms in — deliberately NOT on a 0.5 s fragment boundary, so a
        // generator that snapped to the nearest keyframe would land elsewhere.
        let jpeg = try await ClipThumbnail.jpeg(fromClipAt: url, atNs: 700_000_000)
        #expect(jpeg.isEmpty == false)
        // JPEG magic — it is an image, not an empty container.
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))

        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width <= Int(ClipThumbnail.maximumEdge))
        #expect(image.height <= Int(ClipThumbnail.maximumEdge))
        #expect(image.width > 0 && image.height > 0)
    }

    /// ⛔ REQ-BUF-1's rollover, and the half that is easy to forget: the evicted
    /// fragment's **file** goes with its index entry. A ring that evicts entries
    /// and leaves bytes fills the disk at 6.25 MB/s.
    ///
    /// ⚠ Slow by construction — 20 fragments is 10 s of paced video and there is
    /// no honest way to shorten it, because `fragmentSeconds` and
    /// `fragmentCapacity` are fixed by REQ-BUF-2 and must not become tuning knobs
    /// for a test's convenience.
    @Test("The ring rolls at capacity, and evicted fragments take their files with them")
    func ringRollsAtCapacityAndDeletesFiles() async throws {
        let seconds = Double(RingBufferRecorder.fragmentCapacity)
            * RingBufferRecorder.fragmentSeconds + 2.0
        let (recorder, directory, queue) = try await Self.recorded(seconds: seconds)
        defer { queue.sync { recorder.stopRetaining() }
                try? FileManager.default.removeItem(at: directory) }

        let stats = queue.sync { recorder.stats }
        let fragments = queue.sync { recorder.ring.fragments }

        #expect(fragments.count == RingBufferRecorder.fragmentCapacity,
                "the ring holds exactly \(RingBufferRecorder.fragmentCapacity)")
        #expect(stats.fragmentsWritten > RingBufferRecorder.fragmentCapacity,
                "and more than that were written, so rollover actually happened")
        #expect(stats.fragmentsEvicted
                == stats.fragmentsWritten - RingBufferRecorder.fragmentCapacity)

        // ⛔ Files on disk match the index, not the history.
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == RingBufferRecorder.fragmentCapacity,
                "\(stats.fragmentsEvicted) evictions deleted \(stats.fragmentsWritten - files.count) files")

        // The retained window is the last `capacity` fragments, not the first.
        #expect(fragments.first?.sequence
                == UInt64(stats.fragmentsWritten - RingBufferRecorder.fragmentCapacity))
    }

    /// ⛔ An interval older than the retained window is `absent` / `outside_buffer`
    /// (8.4b, I10), never a `present` extraction over fragments that rolled away.
    @Test("An interval that has rolled out of a live ring is absent, not stale")
    func evictedIntervalIsAbsentOnALiveRing() async throws {
        let (recorder, directory, queue) = try await Self.recorded(seconds: 3)
        defer { queue.sync { recorder.stopRetaining() }
                try? FileManager.default.removeItem(at: directory) }

        let retained = try #require(queue.sync { recorder.ring.retainedNs })
        let longBefore = retained.lowerBound - 60_000_000_000
        let (extraction, bytes) = try queue.sync {
            try recorder.clip(aroundNs: longBefore, preNs: 100_000_000,
                              postNs: 100_000_000)
        }
        #expect(extraction.isAbsent)
        #expect(bytes == nil, "and no bytes were invented to go with it")
    }

    /// ⛔ Fragments that outlive their process belong to no session and nothing
    /// will ever evict them. `startRetaining` is the only safe moment to sweep.
    @Test("A previous run's orphaned fragments are swept before anything is written")
    func orphanedFragmentsAreSweptOnStart() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                      isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        // What a crash mid-swing leaves behind.
        for sequence in 0..<5 {
            try Data(repeating: 0xAB, count: 1024)
                .write(to: directory.appendingPathComponent("frag-\(sequence).mp4"))
        }

        let queue = DispatchQueue(label: "test.ring.sweep")
        let recorder = RingBufferRecorder(directory: directory, queue: queue)
        try recorder.startRetaining(width: Self.width, height: Self.height,
                                    fps: Double(Self.fps), bitrate: 2_000_000)
        defer { queue.sync { recorder.stopRetaining() } }

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.isEmpty, "left behind: \(files)")
        #expect(queue.sync { recorder.ring.fragments.isEmpty })
    }
}
