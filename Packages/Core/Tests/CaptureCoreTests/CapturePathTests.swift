//  CapturePathTests.swift
//  D4 — the capture path from the REQ-BUF-1 ring to a Capture on the wire.
//
//  ⚠ **Every assertion here is against `libppcp`, not against this application's
//  own idea of the shape.** A Swift re-implementation of these rules would agree
//  with itself and meet nobody — `CONF` §2c's single-implementation trap — so the
//  refusals are the library's refusals and the bytes are the library's bytes.
//
//  Rows exercised: CT-I2, CT-I10, CT-I11, CT-I17, CT-I27, CT-I30, CT-I36,
//  CT-I36a, CT-S1 (6), CT-S7 (3), CT-S4 (1).

import Foundation
import Testing
import CPPCP
@testable import CaptureCore

@Suite("The capture path — CORE §5.8, §5.11, §5.14, §5.15, §7.3, §8.4")
struct CapturePathTests {

    // MARK: Fixtures

    static let peerId = "peer:d4-device"
    static let sessionId = "ses:d4"
    static let timebase = "tb:hosttime"

    /// 150 fps — 6,666,666 ns between frames. ⚠ Deliberately **not** a round
    /// number: a fixture on exact millisecond boundaries hides every arithmetic
    /// mistake that a real 1/150 s interval exposes.
    static let framePeriodNs: Int64 = 6_666_666
    /// REQ-BUF-1's fragment length.
    static let fragmentNs: Int64 = 500_000_000

    /// A `shot_windowed` video Stream (§5.11's table makes `video` always so).
    static let videoStream = PpcpStreamRecord(
        id: "str:video:wide", sessionId: sessionId, sourceId: "src:camera:wide",
        kind: PpcpStreamKind.video, profileId: "1920x1080@150",
        timebaseId: timebase, continuity: .shotWindowed, openedAtNs: 1_000_000_000)

    /// A `continuous` `metadata` Stream for attitude and gravity (§5.11's table
    /// makes `metadata` always continuous).
    static let metadataStream = PpcpStreamRecord(
        id: "str:metadata:attitude", sessionId: sessionId, sourceId: "src:imu",
        kind: PpcpStreamKind.metadata, profileId: "attitude-gravity-100",
        timebaseId: timebase, continuity: .continuous, openedAtNs: 1_000_000_000)

    static let previewStream = PpcpStreamRecord(
        id: "str:preview", sessionId: sessionId, sourceId: "src:camera:wide",
        kind: PpcpStreamKind.preview, profileId: "640x360@30",
        timebaseId: timebase, continuity: .continuous, openedAtNs: 1_000_000_000)

    /// One fragment's worth of frames, starting at `startNs`.
    ///
    /// ⚠ `gridOriginNs` puts every fragment's frames on **one** grid across the
    /// whole recording. The sensor does not restart at a fragment boundary, and a
    /// fixture that pretended it did would hide exactly the boundary arithmetic a
    /// realised-rate calculation gets wrong.
    static func fragment(_ sequence: UInt64, startNs: Int64,
                         lengthNs: Int64 = fragmentNs,
                         gridOriginNs: Int64? = nil,
                         exposureNs: Int64 = 1_000_000,
                         iso: Int64 = 640) -> CapturedFragment {
        let origin = gridOriginNs ?? startNs
        var frames: [Int64] = []
        var index = (startNs - origin + framePeriodNs - 1) / framePeriodNs
        while origin + index * framePeriodNs < startNs + lengthNs {
            frames.append(origin + index * framePeriodNs)
            index += 1
        }
        return CapturedFragment(
            sequence: sequence, startNs: startNs, endNs: startNs + lengthNs,
            frameTimestampsNs: frames,
            exposureNs: Array(repeating: exposureNs, count: frames.count),
            iso: Array(repeating: iso, count: frames.count),
            byteCount: frames.count * 40_000,
            droppedFrames: 0)
    }

    /// A ring holding `count` contiguous fragments from `startNs`.
    static func ring(from startNs: Int64, count: Int,
                     capacity: Int = FragmentRing.defaultCapacity) -> FragmentRing {
        var ring = FragmentRing(capacity: capacity)
        for index in 0..<count {
            ring.append(fragment(UInt64(index),
                                 startNs: startNs + Int64(index) * fragmentNs,
                                 gridOriginNs: startNs))
        }
        return ring
    }

    static func declaration() throws -> PpcpDeclaration {
        try PpcpDeclaration(PpcpDeclarationInput(
            peerId: peerId,
            profiles: PpcpProfileSet.device,
            timebases: [PpcpTimebaseDeclaration(id: timebase, kind: .monotonic,
                                                epochStable: true, resolutionNs: 42,
                                                origin: "CMClockGetHostTimeClock")],
            captureTimebaseId: timebase,
            capability: DeviceCapability(
                modelIdentifier: "iPhone17,3", modelName: "iPhone 16",
                claimed: [VideoMode(width: 1920, height: 1080, fps: 150, lens: .wide,
                                    pixelFormat: "420v")],
                measured: nil),
            timing: PpcpDeviceTimingProfile(
                frameStartToExposureOffsetNs: 0, offsetProvenance: .assumed,
                geometry: [PpcpGeometryEntry(readout: .assumedFractionOfFrameInterval(1.0),
                                             direction: .topToBottom)]),
            clipCodec: "hevc",
            declaresMicrophone: true,
            declaresIMU: true))
    }

    final class Sink: @unchecked Sendable {
        private(set) var bytes = Data()
        func append(_ data: Data) { bytes.append(data) }
    }

    // MARK: - §8.4 — locating the interval, and the answer when it is gone

    /// `CORE` 8.4a — "converting `t0` into its own timebase and locating the
    /// interval in its buffer".
    @Test("8.4a — a clip around t0 comes out of the ring complete")
    func clipAroundT0IsComplete() throws {
        let ring = Self.ring(from: 10_000_000_000, count: 8)
        let t0: Int64 = 12_000_000_000
        let clip = ring.extract(aroundNs: t0, preNs: 1_000_000_000, postNs: 2_000_000_000)

        #expect(clip.outcome == .present(.complete))
        // The realised interval is the span of the fragments delivered, which
        // contains the request -- a fragment decodes whole and is sent whole.
        let realised = try #require(clip.realisedNs)
        #expect(realised.lowerBound <= 11_000_000_000 && realised.upperBound >= 14_000_000_000)
        #expect(clip.holesNs.isEmpty)
        // ⛔ CT-I2 — every timestamp is a real one from the fragments, none of
        // them reconstructed from a position.
        #expect(clip.frameTimestampsNs.allSatisfy { realised.contains($0) })
        #expect(clip.frameTimestampsNs.count > 400, "3 s at 150 fps")
        // Realised rate from timestamp deltas, in millihertz (REQ-FPS-2).
        let rate = try #require(clip.realisedRateMillihertz)
        #expect(abs(rate - 150_000) < 100, "150 fps is 150000 mHz; got \(rate)")
    }

    /// ⛔ `CORE` 8.4b / CT-I10 — "where the interval is no longer retained, the
    /// peer responds with a Capture of `completeness: absent` and
    /// `absent_reason: outside_buffer`". `PPCP-MSG` 7.3b: **not** an `error`.
    @Test("8.4b — an interval that has rolled out of the ring is absent, not an error")
    func evictedIntervalIsAbsentOutsideBuffer() throws {
        // Capacity 4 with 8 appended: the first four are gone.
        let ring = Self.ring(from: 10_000_000_000, count: 8, capacity: 4)
        let clip = ring.extract(aroundNs: 10_200_000_000, preNs: 100_000_000,
                                postNs: 100_000_000)

        #expect(clip.outcome == .absent(reason: "outside_buffer"))
        #expect(clip.realisedNs == nil)
        #expect(clip.frameTimestampsNs.isEmpty)

        let assembly = CaptureBuilder.shotCapture(
            id: "cap:gone", shotId: "shot:1", stream: Self.videoStream,
            extraction: clip, exposure: .lockedConstant(1_000_000))
        #expect(assembly.record.completeness == .absent)
        #expect(assembly.record.absentReason == "outside_buffer")
        // 5.8d — "a Capture of `completeness: absent` has no frames and carries
        // no `AchievedFrames`".
        #expect(assembly.achievedFrames == nil)
        // 5.14 — `interval` is absent on an absent shot-anchored Capture, and
        // the library refuses one that carries it.
        #expect(assembly.record.intervalNs == nil)
        try DevicePeer.withCapture(assembly.record) { _ in }
    }

    /// A window reaching further back than the ring holds is `partial`, not
    /// `absent`: part of it survived, and I10 makes the owner say which.
    @Test("A window half inside the ring is partial, with the realised interval")
    func partialWindowIsPartial() throws {
        let ring = Self.ring(from: 10_000_000_000, count: 4, capacity: 4)
        let clip = ring.extract(9_500_000_000..<10_800_000_000)
        #expect(clip.outcome == .present(.partial))
        // Partial because the ring's edge cut the request at 10.0 s; the upper
        // end reaches the end of the last fragment delivered.
        let realised = try #require(clip.realisedNs)
        #expect(realised.lowerBound == 10_000_000_000)
        #expect(realised.upperBound >= 10_800_000_000)
    }

    // MARK: - I11 — holes are not always gaps

    /// ⛔ **I11 / CT-I11.** A hole inside a clip on a `shot_windowed` Stream is
    /// **not** a gap — gaps are meaningful only on `continuous` streams, and the
    /// library refuses them anywhere else. It is why the Capture is `partial`.
    @Test("I11 — a hole in a shot_windowed clip makes it partial and emits no gaps")
    func holesOnShotWindowedAreNotGaps() throws {
        var ring = FragmentRing(capacity: 8)
        ring.append(Self.fragment(0, startNs: 10_000_000_000))
        // 250 ms of nothing — a recording interruption (7.3d), not an eviction.
        ring.append(Self.fragment(1, startNs: 10_750_000_000))

        let clip = ring.extract(10_100_000_000..<11_100_000_000)
        #expect(clip.outcome == .present(.partial))
        #expect(clip.holesNs == [10_500_000_000..<10_750_000_000])

        let assembly = CaptureBuilder.shotCapture(
            id: "cap:holed", shotId: "shot:1", stream: Self.videoStream,
            extraction: clip, exposure: .lockedConstant(1_000_000))
        #expect(assembly.record.gapsNs.isEmpty,
                "I11 — a shot_windowed Stream carries no gaps")
        #expect(assembly.record.completeness == .partial)

        // The same extraction on a `continuous` Stream *does* carry the gap.
        let onContinuous = CaptureBuilder.shotCapture(
            id: "cap:holed", shotId: "shot:1", stream: Self.metadataStream,
            extraction: clip, exposure: .lockedConstant(1_000_000))
        #expect(onContinuous.record.gapsNs == [10_500_000_000..<10_750_000_000])
    }

    /// CT-I11's negative half, asserted against the **library**: a Capture
    /// carrying gaps is refused on a `shot_windowed` Stream.
    @Test("CT-I11 — libppcp refuses gaps on a shot_windowed Stream")
    func libraryRefusesGapsOnShotWindowed() throws {
        var stream = ppcp_stream()
        var openedAt = ppcp_instant()
        try check(ppcp_instant_make_z(&openedAt, Self.timebase, 1_000_000_000))
        try check(ppcp_stream_make(&stream, Self.videoStream.id, Self.sessionId,
                                   "src:camera:wide", PPCP_STREAM_KIND_VIDEO,
                                   "1920x1080@150", Self.timebase,
                                   PPCP_SHOT_WINDOWED, &openedAt))

        let record = PpcpCaptureRecord(
            id: "cap:1", anchor: .shot("shot:1"), streamId: Self.videoStream.id,
            timebaseId: Self.timebase, completeness: .partial,
            intervalNs: 10_000_000_000..<11_000_000_000,
            gapsNs: [10_400_000_000..<10_500_000_000])

        try DevicePeer.withCapture(record) { capture in
            #expect(ppcp_capture_validate(capture) == PPCP_OK,
                    "valid in isolation — the rule needs the Stream")
            #expect(ppcp_capture_validate_in_stream(capture, &stream) != PPCP_OK,
                    "I11 — gaps are meaningful only on a continuous Stream")
        }
    }

    /// CT-I27's second assertion, against the library: `{stream: true}` is
    /// refused on a `shot_windowed` Stream.
    @Test("CT-I27 — a stream anchor is refused on a shot_windowed Stream")
    func streamAnchorRefusedOnShotWindowed() throws {
        var stream = ppcp_stream()
        var openedAt = ppcp_instant()
        try check(ppcp_instant_make_z(&openedAt, Self.timebase, 1_000_000_000))
        try check(ppcp_stream_make(&stream, Self.videoStream.id, Self.sessionId,
                                   "src:camera:wide", PPCP_STREAM_KIND_VIDEO,
                                   "1920x1080@150", Self.timebase,
                                   PPCP_SHOT_WINDOWED, &openedAt))

        let segment = PpcpCaptureRecord(
            id: "cap:seg", anchor: .segment(startNs: 1_000_000_000, endNs: 2_000_000_000),
            streamId: Self.videoStream.id, timebaseId: Self.timebase,
            completeness: .complete)
        try DevicePeer.withCapture(segment) { capture in
            #expect(ppcp_capture_validate_in_stream(capture, &stream) != PPCP_OK)
        }
    }

    // MARK: - I36 — coverage on a continuous Stream

    /// ⛔ **CT-I36 (a) is unconstructible, not merely detected.** A segment's
    /// start is never a parameter; it is where the last one ended.
    @Test("I36 — segments abut by construction, so a hole cannot be produced")
    func coverageCannotLeaveAHole() throws {
        var account = try StreamCoverage(stream: Self.metadataStream)
        let first = try account.segment(id: "seg:1", endingAtNs: 2_000_000_000)
        let second = try account.segment(id: "seg:2", endingAtNs: 3_000_000_000)

        #expect(first.anchor == .segment(startNs: 1_000_000_000, endNs: 2_000_000_000))
        // 5.14e — they abut, they do not overlap. The second starts where the
        // first ended because there is no other value it could start at.
        #expect(second.anchor == .segment(startNs: 2_000_000_000, endNs: 3_000_000_000))
        #expect(account.accountedThroughNs == 3_000_000_000)
        #expect(account.unaccountedNs(asOf: 3_000_000_000) == nil)
        // Running backwards is refused rather than silently overlapping.
        #expect(throws: (any Error).self) {
            _ = try account.segment(id: "seg:3", endingAtNs: 2_500_000_000)
        }
    }

    /// CT-I36 (b) — "an `absent` segment carrying an `interval` and an
    /// `absent_reason` **satisfies** coverage rather than breaching it".
    @Test("CT-I36 (b) — an absent segment with an interval satisfies coverage")
    func absentSegmentSatisfiesCoverage() throws {
        var account = try StreamCoverage(stream: Self.metadataStream)
        _ = try account.segment(id: "seg:1", endingAtNs: 2_000_000_000)
        let shed = try account.absentSegment(id: "seg:2", endingAtNs: 2_400_000_000,
                                             reason: PpcpAbsentReason.storageFull)
        _ = try account.segment(id: "seg:3", endingAtNs: 3_000_000_000)

        #expect(shed.completeness == .absent)
        #expect(shed.absentReason == "storage_full")
        // ⛔ 5.14d — mandatory on a segment even when absent: "for a segment the
        // interval IS the claim". The library refuses one without.
        #expect(shed.anchor == .segment(startNs: 2_000_000_000, endNs: 2_400_000_000))
        #expect(account.unaccountedNs(asOf: 3_000_000_000) == nil)
        try DevicePeer.withCapture(shed) { _ in }
    }

    /// CT-I36 (c) and (d) — the same unaccounted tail is the declared
    /// incompleteness in a `partial` Session and a defect in a `complete` one.
    @Test("CT-I36 (c)/(d) — a tail is incompleteness when partial, a defect when complete")
    func truncationDependsOnTheSessionsClaim() throws {
        func record(completeness: PpcpCaptureRecord.Completeness) throws {
            let sink = Sink()
            let writer = try SessionBundleWriter(peer: try DevicePeer(peerId: Self.peerId)) {
                sink.append($0)
            }
            let recorder = try CaptureSessionRecorder(
                writer: writer, declaration: try Self.declaration(),
                session: PpcpSessionRecord(id: Self.sessionId, timebaseRef: Self.timebase,
                                           openedAtNs: 1_000_000_000))
            try recorder.open(stream: Self.metadataStream)

            var account = try #require(recorder.coverage(of: Self.metadataStream.id))
            let segment = try account.segment(id: "seg:1", endingAtNs: 2_000_000_000)
            try recorder.announceSegment(segment, coverage: account)

            // The Stream ran to 5 s; three of them are unaccounted for.
            try recorder.close(completeness: completeness, closedAtNs: 5_000_000_000)
        }

        // (c) — truncation in a `partial` Session is the declared incompleteness.
        try record(completeness: .partial)
        // (d) — the same truncation in a `complete` Session is a defect.
        #expect(throws: CaptureSessionRecorder.RecorderError.self) {
            try record(completeness: .complete)
        }
    }

    /// ⛔ **CT-I36a.** Preview is live-only (5.11j): shed intervals are `absent`
    /// with `not_retained` and **never** gaps, no preview Capture is ever
    /// announced `transfer: pending`, and none reaches the bundle.
    @Test("CT-I36a — preview sheds as not_retained, is never pending, never bundled")
    func previewIsLiveOnly() throws {
        var account = try StreamCoverage(stream: Self.previewStream)
        let shed = try account.shed(id: "prev:1", endingAtNs: 1_500_000_000)
        #expect(shed.completeness == .absent)
        #expect(shed.absentReason == "not_retained")
        #expect(shed.gapsNs.isEmpty, "5.11c3 — non-retention is never a gap")

        // 8.1i — a present preview segment cannot be `pending`.
        #expect(throws: StreamCoverage.CoverageError.previewMayNotBePending) {
            _ = try account.segment(id: "prev:2", endingAtNs: 2_000_000_000,
                                    transfer: .pending)
        }
        let delivered = try account.segment(id: "prev:2", endingAtNs: 2_000_000_000,
                                            transfer: .present)
        #expect(delivered.transfer == .present)

        // None of it reaches a bundle.
        let sink = Sink()
        let writer = try SessionBundleWriter(peer: try DevicePeer(peerId: Self.peerId)) {
            sink.append($0)
        }
        // ⛔ `ENC` 7h (erratum E9) — the declaration comes first, because 8.5c
        // scopes Capture identity by the minting peer and a bundle states that
        // nowhere else. The writer refuses a `stream_open` before it.
        try writer.record(declaration: try Self.declaration())
        try writer.open(session: PpcpSessionRecord(id: Self.sessionId,
                                                   timebaseRef: Self.timebase,
                                                   openedAtNs: 1_000_000_000))
        try writer.open(stream: Self.previewStream)
        #expect(throws: SessionStoreError.previewIsNotRecordable) {
            try writer.announce(delivered, isPreview: true)
        }
    }

    // MARK: - I30 / I17 — the two halves of achieved capability

    /// ⛔ **CT-I30.** `capture_announce` carries summary capability only; the
    /// per-frame series travels with the payload. The library makes it
    /// structural: `ppcp_capture` has no `achieved_frames` member at all, so the
    /// announce is *small* by construction and not by discipline.
    @Test("CT-I30 — the announce carries no per-frame series and stays small")
    func announceCarriesSummaryOnly() throws {
        let ring = Self.ring(from: 10_000_000_000, count: 8)
        let clip = ring.extract(aroundNs: 12_000_000_000, preNs: 1_000_000_000,
                                postNs: 2_000_000_000)
        let assembly = CaptureBuilder.shotCapture(
            id: "cap:1", shotId: "shot:1", stream: Self.videoStream,
            extraction: clip, exposure: .lockedConstant(1_000_000),
            intrinsics: .constant(try #require(PpcpMatrix3(
                [1500, 0, 960, 0, 1500, 540, 0, 0, 1]))),
            thermal: [PpcpThermalPoint(timebaseId: Self.timebase, atNs: 11_000_000_000,
                                       level: .nominal),
                      PpcpThermalPoint(timebaseId: Self.timebase, atNs: 13_500_000_000,
                                       level: .fair)])

        let frames = try #require(assembly.achievedFrames)
        #expect(frames.framesNs.count == clip.frameTimestampsNs.count)
        #expect(frames.framesNs.count > 400)

        // Measure the encoded announce, as CT-I30 asks. 450 frames of int64
        // alone would be over 3 KB; the announce must be a small fraction of it.
        let sink = Sink()
        let writer = try SessionBundleWriter(peer: try DevicePeer(peerId: Self.peerId)) {
            sink.append($0)
        }
        let recorder = try CaptureSessionRecorder(
            writer: writer, declaration: try Self.declaration(),
            session: PpcpSessionRecord(id: Self.sessionId, timebaseRef: Self.timebase,
                                       openedAtNs: 1_000_000_000))
        try recorder.open(stream: Self.videoStream)
        let before = sink.bytes.count
        try recorder.announce(assembly, clip: { Data([0x00]) })
        let announceBytes = sink.bytes.count - before
        #expect(announceBytes > 0)
        #expect(announceBytes < 800,
                "CT-I30 — an announce carrying the series would be kilobytes; got \(announceBytes)")

        // The summary is there and says what was achieved.
        let summary = try #require(assembly.record.achievedSummary)
        #expect(summary.frameCount == Int64(clip.frameTimestampsNs.count))
        #expect(summary.droppedFrames == 0)
        #expect(summary.thermal.count == 2)
        #expect(summary.exposureNs?.median == 1_000_000)
        #expect(summary.iso?.median == 640)
    }

    /// CT-I30's second half — the constant series go as **scalars** under a lock,
    /// including `intrinsics`, the field where both forms are CBOR arrays.
    @Test("CT-I30 — locked exposure and focus send scalars, not constant arrays")
    func lockedSeriesAreScalars() throws {
        let matrix = try #require(PpcpMatrix3([1500, 0, 960, 0, 1500, 540, 0, 0, 1]))
        let scalarForm = PpcpAchievedFrames(
            timebaseId: Self.timebase,
            framesNs: [1_000, 2_000, 3_000],
            exposureNs: .constant(1_000_000),
            exposureProvenance: .lockedConstant,
            intrinsics: .constant(matrix))
        let arrayForm = PpcpAchievedFrames(
            timebaseId: Self.timebase,
            framesNs: [1_000, 2_000, 3_000],
            exposureNs: .perFrame([1_000_000, 1_000_000, 1_000_000]),
            exposureProvenance: .sampled,
            intrinsics: .perFrame([matrix, matrix, matrix]))

        let scalarBytes = try Self.encodedSize(scalarForm)
        let arrayBytes = try Self.encodedSize(arrayForm)
        #expect(scalarBytes < arrayBytes)

        // ⛔ CT-S1 assertion 6 — "the scalar form and an equivalent constant
        // array produce identical canonical instants". The shipping product
        // locks exposure, so the scalar path is the one that ships.
        var timing = ppcp_timing()
        try check(ppcp_timing_make_nominal_frame_start(&timing, 120_000, PPCP_PROV_ASSUMED))
        for index in 0..<3 {
            var fromScalar = ppcp_instant()
            var fromArray = ppcp_instant()
            try scalarForm.withCValue {
                try check(ppcp_achieved_frames_canonical_at($0, &timing, index, &fromScalar))
            }
            try arrayForm.withCValue {
                try check(ppcp_achieved_frames_canonical_at($0, &timing, index, &fromArray))
            }
            #expect(fromScalar.ns == fromArray.ns)
        }
    }

    /// ⛔ **CT-S7 (3) / 5.8h.** `exposure_provenance` is honest by construction:
    /// each `ExposureObservation` case carries exactly the wire form that goes
    /// with its provenance, so `per_frame` with a scalar — the way a peer
    /// over-claims — is not representable.
    @Test("CT-S7 (3) — provenance and form cannot be mismatched")
    func exposureProvenanceIsHonest() {
        #expect(ExposureObservation.lockedConstant(1_000_000).provenance == .lockedConstant)
        #expect(ExposureObservation.lockedConstant(1_000_000).values == .constant(1_000_000))
        #expect(ExposureObservation.sampledPerFrame([1, 2]).provenance == .sampled)
        #expect(ExposureObservation.sampledPerFrame([1, 2]).values == .perFrame([1, 2]))
        #expect(ExposureObservation.attachedPerFrame([1, 2]).provenance == .perFrame)
        // The wire spellings, so a rename in this enum cannot silently change them.
        #expect(PpcpExposureProvenance.perFrame.rawValue == "per_frame")
        #expect(PpcpExposureProvenance.lockedConstant.rawValue == "locked_constant")
        #expect(PpcpExposureProvenance.sampled.rawValue == "sampled")
    }

    /// 5.8d / I17 — the library refuses `AchievedFrames` that carries exposure
    /// with no provenance, and refuses a parallel array of the wrong length.
    @Test("5.8f — a parallel array must be exactly frames.ns long")
    func parallelArraysAreLengthChecked() {
        let wrongLength = PpcpAchievedFrames(
            timebaseId: Self.timebase, framesNs: [1, 2, 3],
            exposureNs: .perFrame([10, 20]), exposureProvenance: .sampled)
        #expect(throws: (any Error).self) {
            try wrongLength.withCValue { _ in }
        }
        let noProvenance = PpcpAchievedFrames(
            timebaseId: Self.timebase, framesNs: [1, 2, 3],
            exposureNs: .perFrame([10, 20, 30]), exposureProvenance: nil)
        #expect(throws: (any Error).self) {
            try noProvenance.withCValue { _ in }
        }
    }

    // MARK: - §5.15 — readiness is a measurement

    /// ⛔ **5.15a, verbatim: "A device state-machine name (`cold`, `warm`,
    /// `armed` or any equivalent) MUST NOT cross the wire."**
    ///
    /// ⚠ Asserted against the **bytes**, not against the API. An API-shaped
    /// assertion would only say that this application did not choose to send a
    /// name today; searching the encoded session says none is there.
    @Test("5.15a — no device state name appears anywhere in the encoded session")
    func noStateNameCrossesTheWire() throws {
        let sink = Sink()
        let writer = try SessionBundleWriter(peer: try DevicePeer(peerId: Self.peerId)) {
            sink.append($0)
        }
        let recorder = try CaptureSessionRecorder(
            writer: writer, declaration: try Self.declaration(),
            session: PpcpSessionRecord(id: Self.sessionId, timebaseRef: Self.timebase,
                                       openedAtNs: 1_000_000_000))
        try recorder.open(stream: Self.videoStream)

        for state in CaptureState.allCases {
            let measurement = ReadinessMeasurement.measuring(
                state, exposureHasSettled: state != .cold, settleEstimateMs: 1_200)
            try recorder.report(measurement, streamIds: [Self.videoStream.id])
        }
        try recorder.close(completeness: .partial, closedAtNs: nil)

        for name in CaptureState.allCases.map(\.rawValue) {
            #expect(sink.bytes.range(of: Data(name.utf8)) == nil,
                    "5.15a — the state name '\(name)' reached the wire")
        }

        // And the measurement itself says what 5.15 asks for.
        let cold = ReadinessMeasurement.measuring(.cold, exposureHasSettled: false,
                                                  settleEstimateMs: 1_200)
        #expect(cold.settled == false)
        #expect(cold.estimatedReadyMs == 1_200)
        // ⚠ Two different states, one measurement: the question is about the next
        // shot, not about this peer's internal bookkeeping.
        let warm = ReadinessMeasurement.measuring(.warm, exposureHasSettled: true,
                                                  settleEstimateMs: 1_200)
        let armed = ReadinessMeasurement.measuring(.armed, exposureHasSettled: true,
                                                   settleEstimateMs: 1_200)
        #expect(warm == armed)
    }

    /// 5.15 — `estimated_ready_ms` is mandatory when not settled, and the library
    /// has no constructor that omits it.
    @Test("5.15 — settled carries no estimate and not-settled requires one")
    func readinessConstructorsAreTheWholeApi() throws {
        let settled = try ReadinessMeasurement(settled: true).ppcpReadiness()
        #expect(settled.settled)
        #expect(settled.has_estimated_ready_ms == false)

        let waiting = try ReadinessMeasurement(settled: false, estimatedReadyMs: 900,
                                               blocked: .thermalLimit).ppcpReadiness()
        #expect(waiting.settled == false)
        #expect(waiting.has_estimated_ready_ms)
        #expect(waiting.estimated_ready_ms == 900)
        #expect(waiting.has_blocked_reason)
    }

    // MARK: - §7.3d — interruptions

    /// `CORE` 7.3d — "with the resulting gap recorded explicitly".
    @Test("7.3d — an interruption and its gap reach the bundle")
    func interruptionIsRecorded() throws {
        let sink = Sink()
        let writer = try SessionBundleWriter(peer: try DevicePeer(peerId: Self.peerId)) {
            sink.append($0)
        }
        let recorder = try CaptureSessionRecorder(
            writer: writer, declaration: try Self.declaration(),
            session: PpcpSessionRecord(id: Self.sessionId, timebaseRef: Self.timebase,
                                       openedAtNs: 1_000_000_000))
        try recorder.open(stream: Self.videoStream)

        let before = sink.bytes.count
        try recorder.record(InterruptionRecord(
            kind: .call, timebaseId: Self.timebase,
            intervalNs: 12_000_000_000..<14_500_000_000,
            recovered: true, streamIds: [Self.videoStream.id]))
        #expect(sink.bytes.count > before, "the interruption is a frame in the bundle")
        #expect(sink.bytes.range(of: Data("interruption".utf8)) != nil)
        try recorder.close(completeness: .partial, closedAtNs: nil)
    }

    // MARK: - CT-S4 (1) — the zero-host path, with real Captures

    /// The bundle half of CT-S4 assertion 1, now carrying a Capture that came out
    /// of the ring rather than a fixture: declare, `session_open`, `stream_open`,
    /// `readiness`, `capture_announce`, `session_manifest`, `payload_*`.
    ///
    /// ⛔ No `arm` and no `disarm` (7.3b) — conferred by **Live**, and there is
    /// nobody controlling.
    @Test("CT-S4 (1) — a hostless bundle carries a real Capture and reads back")
    func hostlessBundleCarriesARealCapture() throws {
        let ring = Self.ring(from: 10_000_000_000, count: 8)
        let clip = ring.extract(aroundNs: 12_000_000_000, preNs: 1_000_000_000,
                                postNs: 2_000_000_000)
        let assembly = CaptureBuilder.shotCapture(
            id: "cap:1", shotId: "shot:1", stream: Self.videoStream,
            extraction: clip, exposure: .lockedConstant(1_000_000),
            intrinsics: .constant(try #require(PpcpMatrix3(
                [1500, 0, 960, 0, 1500, 540, 0, 0, 1]))))
        let clipBytes = Data((0..<2048).map { UInt8($0 % 251) })

        let sink = Sink()
        let writer = try SessionBundleWriter(peer: try DevicePeer(peerId: Self.peerId)) {
            sink.append($0)
        }
        let recorder = try CaptureSessionRecorder(
            writer: writer, declaration: try Self.declaration(),
            session: PpcpSessionRecord(id: Self.sessionId, timebaseRef: Self.timebase,
                                       openedAtNs: 1_000_000_000,
                                       epochWallUtcNs: 1_787_000_000_000_000_000,
                                       epochAtNs: 10_000_000_000,
                                       epochTimebaseId: Self.timebase))
        try recorder.open(stream: Self.videoStream)
        try recorder.open(stream: Self.metadataStream)
        try recorder.report(ReadinessMeasurement(settled: true),
                            streamIds: [Self.videoStream.id])

        // One continuous metadata segment covering the whole open interval.
        var account = try #require(recorder.coverage(of: Self.metadataStream.id))
        let segment = try account.segment(id: "seg:1", endingAtNs: 15_000_000_000)
        try recorder.announceSegment(segment, coverage: account)

        recorder.countShot()
        try recorder.announce(assembly, clip: { clipBytes })
        try recorder.close(completeness: .complete, closedAtNs: 15_000_000_000)

        #expect(writer.hasManifest)
        #expect(writer.isHostless, "CORE 4.1d — no arbitration parameters were recorded")
        #expect(SessionStore.hasBundleMagic(sink.bytes))
        // ⛔ 7.3b — the bundle records the effect, never the command.
        #expect(sink.bytes.range(of: Data("\"arm\"".utf8)) == nil)

        // Read it back through the library's own reader, in small runs.
        let reader = try SessionBundleReader()
        var offset = 0
        while offset < sink.bytes.count {
            let end = min(offset + 61, sink.bytes.count)
            try reader.feed(sink.bytes[offset..<end])
            offset = end
        }
        #expect(try reader.finish() == .complete)
        #expect(reader.captureCount == 2, "the clip and the metadata segment")
        #expect(try reader.hasSeen(sessionId: Self.sessionId, peerId: Self.peerId,
                                  captureId: "cap:1"))
    }

    // MARK: The desktop buffer's hard-won tests, carried across (E1.1)

    // ⚠ **Ported as specifications, not as code.** PinPointStudio's
    // `src/Buffer/tests` pins behaviour learned the hard way on a RAM ring of raw
    // frames. The substrate does not transfer — `capability-spike.md` §4 shows
    // why — but three of the intents survive it unchanged, because a ring of
    // encoded fragments still overruns, still needs a monotonic sequence, and
    // still must refuse to publish something that did not land. Reimplementing
    // without carrying these across rediscovers the same bugs in the field.

    /// PPS `timeline_index_test.cpp` — `SequenceNumberWrapAround`.
    @Test("Fragment sequence is monotonic across a rollover, and never reused")
    func sequenceIsMonotonicAcrossRollover() {
        var ring = FragmentRing(capacity: 4)
        for index in 0..<12 {
            ring.append(Self.fragment(UInt64(index),
                                      startNs: 10_000_000_000 + Int64(index) * Self.fragmentNs,
                                      gridOriginNs: 10_000_000_000))
        }
        let sequences = ring.fragments.map(\.sequence)
        #expect(sequences == [8, 9, 10, 11],
                "the ring holds the last `capacity`, and their sequences are the originals")
        #expect(sequences == sequences.sorted(), "strictly increasing, never renumbered")
        #expect(Set(sequences).count == sequences.count, "and never reused")
    }

    /// PPS `source_ring_test.cpp` — `OverrunNoCorruption`.
    ///
    /// ⛔ The point is not that eviction happens. It is that after an overrun the
    /// *index* still describes exactly what is there: no torn entry, no fragment
    /// naming an interval it no longer covers, and a retained window that matches
    /// the fragments rather than the history.
    @Test("Overrunning the ring evicts the oldest and leaves the index consistent")
    func overrunLeavesTheIndexConsistent() {
        let capacity = 20
        var ring = FragmentRing(capacity: capacity)
        let origin: Int64 = 10_000_000_000
        for index in 0..<(capacity * 3) {
            ring.append(Self.fragment(UInt64(index),
                                      startNs: origin + Int64(index) * Self.fragmentNs,
                                      gridOriginNs: origin))
        }

        #expect(ring.fragments.count == capacity, "never more than capacity")

        let retained = ring.retainedNs
        #expect(retained?.lowerBound == ring.fragments.first?.startNs)
        #expect(retained?.upperBound == ring.fragments.last?.endNs)

        // Contiguous and ordered: an overrun must not leave a hole behind.
        for (earlier, later) in zip(ring.fragments, ring.fragments.dropFirst()) {
            #expect(earlier.sequence + 1 == later.sequence)
            #expect(earlier.endNs == later.startNs)
        }

        // ⛔ An interval that rolled away is `absent`, not a stale hit.
        let evicted = ring.extract(origin..<(origin + Self.fragmentNs))
        #expect(evicted.isAbsent)
    }

    /// PPS `source_ring_test.cpp` — `PublishOnInvalidSlotIsNoop`.
    ///
    /// ⛔ `RingBufferRecorder.receive` returns without appending when the
    /// fragment's bytes fail to write, so the ring never claims an interval it
    /// cannot produce (8.4b). Nothing tested that the *index* behaves correctly
    /// when a fragment is skipped, and a skipped fragment is what a full disk
    /// looks like.
    @Test("A fragment that never landed leaves a hole the ring reports honestly")
    func skippedFragmentIsAHoleAndNotAClaim() {
        var ring = FragmentRing(capacity: 8)
        let origin: Int64 = 10_000_000_000
        // Sequences 0 and 2 land; 1's bytes failed, so it was never appended.
        ring.append(Self.fragment(0, startNs: origin, gridOriginNs: origin))
        ring.append(Self.fragment(2, startNs: origin + 2 * Self.fragmentNs,
                                  gridOriginNs: origin))

        #expect(ring.fragments.map(\.sequence) == [0, 2],
                "the gap in sequence is the record that something did not land")

        let clip = ring.extract(origin..<(origin + 3 * Self.fragmentNs))
        #expect(clip.isAbsent == false, "what did land is still extractable")
        #expect(clip.holesNs.isEmpty == false,
                "and the interval that did not is reported as a hole, not silently spanned")
        let hole = clip.holesNs.first
        #expect(hole?.lowerBound == origin + Self.fragmentNs)
        #expect(hole?.upperBound == origin + 2 * Self.fragmentNs)
    }

    // MARK: Helpers

    /// Encoded size of an `AchievedFrames`, through the library's own encoder.
    static func encodedSize(_ frames: PpcpAchievedFrames) throws -> Int {
        var scratch = [UInt8](repeating: 0, count: 1 << 16)
        return try frames.withCValue { built in
            try scratch.withUnsafeMutableBufferPointer { out -> Int in
                var writer = ppcp_cbor_writer()
                ppcp_cbor_writer_init(&writer, out.baseAddress, out.count)
                try check(ppcp_achieved_frames_encode(&writer, built))
                return writer.len
            }
        }
    }
}
