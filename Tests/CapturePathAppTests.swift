//  CapturePathAppTests.swift
//  D4's platform half — the parts that need `AVFoundation`, `CoreMotion` or
//  `ProcessInfo` and therefore cannot live in the package suite.
//
//  ⚠ **What a simulator can and cannot show.** It has no 150 fps camera and no
//  hardware encoder path worth trusting, so `RingBufferRecorder`'s segment
//  delivery is not exercised here — it is exercised the first time this runs on a
//  phone. What *is* exercised is every place the platform layer makes a decision
//  the protocol constrains: the transpose, the interruption mapping, the thermal
//  timeline's covering rule, and the realised rate. Those are the ones a device
//  run would not catch either, because they look right in a video.
//
//  Spec: `CORE` §5.8, §7.3d; `ENC` §4.1; `CONF` CT-S7 (3).

import AVFoundation
import Foundation
import Testing
import simd
import CaptureCore
@testable import PinPointCapture

@Suite("D4 — the platform capture path")
struct CapturePathAppTests {

    /// ⛔ `ENC` §4.1 is **row-major**; `matrix_float3x3` is column-major.
    ///
    /// The fixture is asymmetric on purpose: a symmetric matrix passes a
    /// transpose bug, and the principal point is exactly the entry that moves.
    @Test("ENC 4.1 — the intrinsic matrix is transposed into row-major")
    func intrinsicsAreRowMajor() throws {
        // fx=1500, fy=1600, cx=960, cy=540, as AVFoundation lays it out:
        // columns are the initialiser's arguments.
        let matrix = matrix_float3x3(columns: (SIMD3<Float>(1500, 0, 0),
                                               SIMD3<Float>(0, 1600, 0),
                                               SIMD3<Float>(960, 540, 1)))
        let converted = try #require(FrameTimeline.rowMajor(matrix))
        #expect(converted.values == [1500, 0, 960,
                                     0, 1600, 540,
                                     0, 0, 1])
    }

    /// ⛔ `CORE` 5.8h / CT-S7 (3). `per_frame` is not reachable from the
    /// platform path, because `AVCaptureVideoDataOutput` attaches no exposure to
    /// a sample buffer. Under the lock the honest answer is `locked_constant`
    /// with the scalar form; without it, `sampled` with the array.
    @Test("CT-S7 (3) — the platform never claims per_frame exposure")
    func exposureProvenanceIsNeverOverclaimed() {
        let batch = FrameTimeline.Batch(timestampsNs: [1, 2, 3],
                                        exposureNs: [1_000_000, 1_000_100, 999_900])
        #expect(FrameTimeline.exposure(batch, lockedNs: 1_000_000).provenance
                == .lockedConstant)
        #expect(FrameTimeline.exposure(batch, lockedNs: 1_000_000).values
                == .constant(1_000_000))
        #expect(FrameTimeline.exposure(batch, lockedNs: nil).provenance == .sampled)
        #expect(FrameTimeline.exposure(batch, lockedNs: nil).values
                == .perFrame([1_000_000, 1_000_100, 999_900]))
    }

    /// Focus is locked for the session (REQ-OPT-2), so identical matrices go as
    /// the scalar form — which is smaller *and* the truer statement (5.8f).
    /// Matrices that differ are not collapsed, because a physical lens switch is
    /// exactly what REQ-OPT-5 exists to catch.
    @Test("5.8f — identical intrinsics collapse to a scalar, differing ones do not")
    func intrinsicsFormFollowsTheData() throws {
        let a = try #require(PpcpMatrix3([1500, 0, 960, 0, 1500, 540, 0, 0, 1]))
        let b = try #require(PpcpMatrix3([1100, 0, 960, 0, 1100, 540, 0, 0, 1]))
        #expect(FrameTimeline.intrinsics(
            FrameTimeline.Batch(intrinsics: [a, a, a])) == .constant(a))
        #expect(FrameTimeline.intrinsics(
            FrameTimeline.Batch(intrinsics: [a, b])) == .perFrame([a, b]))
        #expect(FrameTimeline.intrinsics(FrameTimeline.Batch()) == nil)
    }

    /// `CORE` 7.3d names three interruptions. ⛔ The platform's own reason code
    /// does not cross the wire — `kind` is protocol vocabulary, for the same
    /// reason 5.15a keeps a device state name off it.
    @Test("7.3d — the platform interruption reason maps onto the protocol's kinds")
    func interruptionKindsAreProtocolWords() {
        func note(_ reason: AVCaptureSession.InterruptionReason) -> Notification {
            Notification(name: AVCaptureSession.wasInterruptedNotification, object: nil,
                         userInfo: [AVCaptureSessionInterruptionReasonKey: reason.rawValue])
        }
        #expect(InterruptionMonitor.kind(of: note(.videoDeviceNotAvailableInBackground))
                == .background)
        #expect(InterruptionMonitor.kind(of: note(.audioDeviceInUseByAnotherClient))
                == .audioSession)
        #expect(InterruptionMonitor.kind(of: note(.videoDeviceInUseByAnotherClient))
                == .call)
        // A notification with no reason at all is still an interruption, and the
        // gap is still real. Reporting nothing would be the half of 7.3d that
        // gets dropped.
        #expect(InterruptionMonitor.kind(of: Notification(
            name: AVCaptureSession.wasInterruptedNotification)) == .call)
        #expect(InterruptionRecord.Kind.audioSession.rawValue == "audio_session")
    }

    /// `CORE` §5.8 — `thermal` is a timeline, and a Capture that saw no
    /// transition still carries the level it was steady at.
    @Test("5.8 — a Capture with no thermal transition still carries its level")
    func thermalTimelineCarriesThePrecedingLevel() {
        let timeline = ThermalTimeline(timebaseId: "tb:hosttime")
        timeline.start()
        defer { timeline.stop() }

        let now = MachClock.hostTimeNs
        // The interval starts after `start()` recorded the level as it is now, so
        // the covering set is the one synthesised point.
        let covering = timeline.points(covering: (now + 1_000)..<(now + 2_000_000_000))
        #expect(covering.count == 1)
        #expect(covering.first?.atNs == now + 1_000)
        #expect(covering.first?.level == DeviceHealthService.thermalState)
    }

    /// REQ-FPS-2 / I2 — realised rate from timestamp deltas, in millihertz.
    @Test("The metadata Stream's realised rate comes from deltas, in millihertz")
    func motionRealisedRateIsFromDeltas() {
        let samples = (0..<101).map { index in
            MotionMetadataSource.Sample(
                atNs: 1_000_000_000 + Int64(index) * 10_000_000,
                attitude: (0, 0, 0), gravity: (0, 0, -1))
        }
        #expect(MotionMetadataSource.realisedRateMillihertz(samples) == 100_000)
        // One sample spans no interval, so there is no rate — not a zero.
        #expect(MotionMetadataSource.realisedRateMillihertz([samples[0]]) == nil)
        // 8 bytes of instant plus six doubles, per sample.
        #expect(MotionMetadataSource.encode(samples).count == samples.count * 56)
    }

    /// I36 through the platform source: a segment with no samples is an `absent`
    /// segment carrying its interval, never silence.
    @Test("I36 — a metadata segment that sampled nothing is absent, with its interval")
    func emptyMetadataSegmentIsAbsent() throws {
        let stream = PpcpStreamRecord(
            id: "str:metadata", sessionId: "ses:1", sourceId: "src:imu",
            kind: PpcpStreamKind.metadata, profileId: "attitude-gravity-100",
            timebaseId: "tb:hosttime", continuity: .continuous,
            openedAtNs: 1_000_000_000)
        var coverage = try StreamCoverage(stream: stream)
        let source = MotionMetadataSource(timebaseId: "tb:hosttime")

        let (record, bytes) = try source.segment(id: "seg:1",
                                                 endingAtNs: 2_000_000_000,
                                                 coverage: &coverage)
        #expect(record.completeness == .absent)
        #expect(record.absentReason == "not_retained")
        #expect(record.anchor == .segment(startNs: 1_000_000_000, endNs: 2_000_000_000))
        #expect(bytes == nil)
        #expect(coverage.unaccountedNs(asOf: 2_000_000_000) == nil)
    }

    // MARK: The composition root

    /// §5.11's continuity table is normative, and the Streams are derived from
    /// what was **declared** rather than assembled by a caller: a Stream's
    /// `source_id`, `profile_id` and `timebase_id` must name things the peer
    /// actually declared (5.11a, I5).
    @Test("5.11 — the Streams come out of the declaration, with the table's continuity")
    func streamsAreDerivedFromTheDeclaration() throws {
        let declaration = try PpcpDeclaration(PpcpDeclarationInput(
            peerId: "peer:test",
            profiles: PpcpProfileSet.device,
            timebases: [PpcpTimebaseDeclaration(id: "tb:hosttime", kind: .monotonic,
                                                epochStable: true, resolutionNs: 42)],
            captureTimebaseId: "tb:hosttime",
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

        let streams = HostlessRecordingSession.streams(
            sessionId: "ses:1", declaration: declaration,
            videoProfileId: nil, openedAtNs: 1_000_000_000)

        let video = try #require(streams.first { $0.kind == PpcpStreamKind.video })
        #expect(video.continuity == .shotWindowed, "§5.11 — video is always shot_windowed")
        #expect(declaration.sources.contains { $0.id == video.sourceId })
        #expect(declaration.sources.first { $0.id == video.sourceId }?
            .profileIds.contains(video.profileId) == true)
        #expect(video.timebaseId == "tb:hosttime")

        let metadata = try #require(streams.first { $0.kind == PpcpStreamKind.metadata })
        #expect(metadata.continuity == .continuous,
                "§5.11 — metadata is always continuous, which is what obliges I36")
        // I4 — two Sources on one clock reference the same id.
        #expect(metadata.timebaseId == video.timebaseId)
    }

    /// ⛔ §9.2 — arming is not a claim. A device that could not warm up retains
    /// nothing, so it must not open a Session and must not say it is armed.
    @Test("Arming without a camera opens no Session and claims nothing")
    @MainActor
    func armingWithoutACameraOpensNoSession() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("d4-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel(store: SessionStore(root: root))
        model.refreshCapability()
        guard model.capabilityError != nil else { return }  // real hardware, skip

        model.arm()
        #expect(model.captureStatus.state != .armed)
        #expect(model.recording == nil)
        #expect(model.recordingError == nil, "nothing failed — nothing was attempted")
    }

    // MARK: E1.1 — the ring's instrument, and the flag that must follow the state

    /// ⛔ **The single line where REQ-CAP-3 and §9.2 pull in opposite
    /// directions.** The self-test wants late frames discarded so `didDrop`
    /// fires and degradation is visible; the ring wants them kept because
    /// capture is non-recoverable and degrades last. One property, two
    /// requirements — so it is derived from the routing state rather than
    /// written as a literal, and this is the test that it stays derived.
    @Test("REQ-CAP-3 vs §9.2 — late frames are discarded iff we are not retaining")
    func discardPolicyFollowsTheRoutingState() {
        #expect(AVFoundationCaptureDevice.Routing.retaining.discardsLateFrames == false)
        #expect(AVFoundationCaptureDevice.Routing.warm.discardsLateFrames == true)
        #expect(AVFoundationCaptureDevice.Routing.selfTesting(FrameRateProbe())
                    .discardsLateFrames == true)
    }

    /// ⛔ Frames arriving with nothing retaining used to vanish: `append`
    /// returned early and no counter moved. PPS's `acquireWriteSlot` returns
    /// `valid=false` precisely so the producer can see that its write went
    /// nowhere, and this is that signal.
    @Test("A frame delivered while nothing is retaining is counted, not swallowed")
    func framesBeforeRetainingAreCounted() throws {
        let directory = URL.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = RingBufferRecorder(
            directory: directory,
            queue: DispatchQueue(label: "test.samples"))
        #expect(recorder.isRetaining == false)

        let marker = try #require(Self.markerSampleBuffer())
        recorder.append(marker, device: nil)
        recorder.append(marker, device: nil)

        #expect(recorder.stats.framesDroppedNotRetaining == 2)
        #expect(recorder.stats.framesAppended == 0, "nothing reached an encoder")
    }

    /// ⚠ **Suspect the instrument first.** `maxInterArrivalNs` is the number the
    /// E1.1 exit criterion rests on — it is what separates a steady 150 fps from
    /// an average one — so the arithmetic is tested before any device run is
    /// asked to believe it.
    @Test("The rate instrument catches the stall an average hides")
    func maxInterArrivalCatchesWhatTheMeanHides() {
        let period: Int64 = 6_666_666  // 150 fps
        var steady = RingStats()
        for index in 0..<100 { steady.observeArrival(atNs: Int64(index) * period) }

        var stalled = RingStats()
        var clock: Int64 = 0
        for index in 0..<100 {
            // One 40 ms stall in the middle, the rest at rate.
            clock += index == 50 ? 40_000_000 : period
            stalled.observeArrival(atNs: clock)
        }

        #expect(steady.maxInterArrivalNs == period)
        #expect(stalled.maxInterArrivalNs == 40_000_000)
        // ⛔ Both report ~150 fps on the mean. Only one of them was.
        #expect(stalled.meanInterArrivalNs < period * 2,
                "the mean stays close to the frame period, which is exactly the problem")
        #expect(steady.framesAppended == stalled.framesAppended)
    }

    /// With `AllowFrameReordering = false` this should never fire. Counting it
    /// is how we learn that rather than assume it — `receive()` derives a
    /// fragment's period from first and last on the assumption that delivery is
    /// sorted.
    @Test("A timestamp that goes backwards is counted, not folded into the rate")
    func monotonicityViolationsAreCounted() {
        var stats = RingStats()
        stats.observeArrival(atNs: 1_000_000)
        stats.observeArrival(atNs: 2_000_000)
        stats.observeArrival(atNs: 1_500_000)   // backwards
        stats.observeArrival(atNs: 3_000_000)

        #expect(stats.monotonicityViolations == 1)
        #expect(stats.maxInterArrivalNs == 1_500_000,
                "the backwards step contributes no negative gap and no inflated one")
        #expect(stats.framesAppended == 4, "the frame still arrived")
    }

    /// A sample buffer with no data and no format — enough to drive the paths
    /// that reject a frame before reading it, which is all a simulator can
    /// honestly exercise.
    static func markerSampleBuffer() -> CMSampleBuffer? {
        var buffer: CMSampleBuffer?
        CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                             dataBuffer: nil, dataReady: false,
                             makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: nil, sampleCount: 0,
                             sampleTimingEntryCount: 0, sampleTimingArray: nil,
                             sampleSizeEntryCount: 0, sampleSizeArray: nil,
                             sampleBufferOut: &buffer)
        return buffer
    }
}

/// A `CaptureDevice` that reports a camera and can be told to refuse retention.
///
/// ⚠ **Why this exists.** The one thing `arm()` must never do is reach `armed`
/// on a device that is not retaining — §9.2, and the comment `arm()` already
/// carries about warm-up. That half is testable on a simulator because there is
/// no camera; the retention half is not, because `warmUp` fails first and the
/// new branch is never reached. A stub is the only way to see it before a phone
/// does.
///
/// ⛔ Everything except `startRetaining` is real: the declaration comes from
/// `DeviceProfiles` and `PpcpTimebases`, so a test that gets as far as arming
/// has genuinely built a hostless session. A stub that faked the declaration
/// would make `arm()` fail for the wrong reason and pass this test green.
final class StubCaptureDevice: CaptureDevice, @unchecked Sendable {

    var refusesToRetain = false
    private(set) var startRetainingCalls = 0
    private(set) var stopRetainingCalls = 0
    private(set) var isRetaining = false

    static let mode = VideoMode(width: 1920, height: 1080, fps: 150,
                                lens: .wide, deliversIntrinsics: true)

    func enumerateCapability() throws -> DeviceCapability {
        DeviceCapability(modelIdentifier: "stub", modelName: "Stub", claimed: [Self.mode])
    }

    func warmUp(mode: VideoMode) throws {}
    func goCold() { stopRetaining() }

    func startRetaining(mode: VideoMode) throws {
        startRetainingCalls += 1
        if refusesToRetain {
            throw CaptureDeviceError.configurationFailed("stub refuses to retain")
        }
        isRetaining = true
    }

    func stopRetaining() {
        stopRetainingCalls += 1
        isRetaining = false
    }

    var ringStats: RingStats { RingStats() }

    func measureSustainedRate(mode: VideoMode,
                              duration: TimeInterval) async throws -> MeasuredCapability {
        MeasuredCapability(mode: mode, achievedFPS: mode.fps, droppedFrames: 0,
                           thermalAtEnd: .nominal, measuredAt: Date(),
                           method: .coldSample, durationSeconds: duration,
                           observedHostTimeNs: 0, exposureSeconds: nil, iso: nil)
    }

    var thermalState: ThermalState { .nominal }

    func storageHeadroom(forMode mode: VideoMode) -> StorageHeadroom {
        StorageHeadroom(estimatedSessions: 40, freeBytes: 64 << 30)
    }

    func ppcpDeclarationInput(peerId: String,
                              viewpoint: PpcpViewpoint?) throws -> PpcpDeclarationInput {
        guard let timing = DeviceProfiles.ppcp(for: DeviceProfiles.currentIdentifier) else {
            throw CaptureDeviceError.configurationFailed("no timing profile")
        }
        return PpcpDeclarationInput(
            peerId: peerId,
            profiles: PpcpProfileSet.device,
            timebases: PpcpTimebases.all,
            captureTimebaseId: PpcpTimebases.captureId,
            capability: try enumerateCapability(),
            timing: timing,
            clipCodec: "hevc",
            declaresMicrophone: true,
            declaresIMU: true,
            viewpoint: viewpoint,
            product: ("Apple", "Stub", "1.0"))
    }

    func extractClip(_ requestedNs: Range<Int64>) -> ClipExtraction {
        ClipExtraction.nothingRetained(requestedNs)
    }

    func observeInterruptions(_ handler: @escaping @MainActor (InterruptionRecord) -> Void) {}
}

@MainActor
@Suite("E1.1 — arming is a claim about the ring")
struct ArmingRetainsTests {

    private func model(_ device: StubCaptureDevice) -> (AppModel, URL) {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                 isDirectory: true)
        let model = AppModel(device: device, store: SessionStore(root: root))
        model.refreshCapability()
        // ⚠ A simulator never grants these, and `warmUp` gates on them — so
        // without this the arm path stops before it reaches anything E1.1
        // changed, and all three tests below would pass having tested nothing.
        model.permissions = Permissions(camera: .allowed, microphone: .allowed,
                                        localNetwork: .allowed, motion: .allowed)
        return (model, root)
    }

    /// ⛔ **The rule §9.2 turns on.** An `armed` peer retaining nothing is the
    /// state the app reported on every device before E1.1, and it is the one
    /// thing capture must never be quietly wrong about.
    ///
    /// ⚠ **This test carries its own control.** `startRetainingCalls == 1` is
    /// only reachable past `arm()`'s `guard let recording` — so if the stub's
    /// declaration were malformed and the hostless session failed to open, the
    /// count would be zero and this would fail rather than pass green on a
    /// short-circuit. That matters more than usual here, because the *success*
    /// path cannot be tested beside it (see below).
    @Test("A device that cannot retain does not reach armed")
    func refusedRetentionBlocksArmed() throws {
        let device = StubCaptureDevice()
        device.refusesToRetain = true
        let (model, root) = self.model(device)
        defer { try? FileManager.default.removeItem(at: root) }

        model.arm()

        #expect(device.startRetainingCalls == 1,
                "the hostless session opened and retention was attempted")
        #expect(device.isRetaining == false)
        #expect(model.captureStatus.state != .armed)
        #expect(model.capabilityError != nil, "and the refusal is reported, not swallowed")
    }

    // ⛔ **The successful arm cannot be tested here, and the reason is the
    // simulator rather than the code.** `arm()` calls `startDetecting()` after
    // retention succeeds, and `AVAudioEngine.inputNode` **aborts the process**
    // in a simulator test host — `AURemoteIO::Initialize` → `_ReportRPCTimeout`
    // → `abort`, confirmed from the crash report on 24 Aug 2026, not inferred.
    // It is a trap in AudioToolbox, not a Swift error, so it cannot be caught
    // and no stub above it helps.
    //
    // ⚠ So "arm reaches `.armed` with a live ring" is a **device-run check**
    // (E1.1 step 3), listed as such rather than faked with a test that stops
    // short and reads as though it did not. The refusal path above is testable
    // because it returns before the microphone.

    /// ⛔ `goCold` removes the session's outputs; a writer left open across that
    /// teardown is one nothing will ever close. `disarm` must therefore stop
    /// retaining first.
    ///
    /// ⚠ Not armed first — see the note above. What this pins is that the call
    /// site exists and runs unconditionally, which is the half that silently
    /// disappears in a refactor. The ordering against `goCold` is additionally
    /// enforced inside `AVFoundationCaptureDevice.goCold`, so neither end
    /// depends on the other remembering.
    @Test("Disarm stops retaining, whatever state it was in")
    func disarmAlwaysStopsRetaining() throws {
        let device = StubCaptureDevice()
        let (model, root) = self.model(device)
        defer { try? FileManager.default.removeItem(at: root) }

        model.disarm()

        #expect(device.stopRetainingCalls >= 1)
        #expect(device.isRetaining == false)
        #expect(model.captureStatus.state == .cold)
    }
}

@Suite("E1.1 — the ring readout")
struct RingStatsOverlayTests {

    /// ⛔ A display that showed 23/20 would be reporting on itself rather than on
    /// the ring. `fragmentsWritten` and `fragmentsEvicted` are lifetime counters;
    /// what is *held* is their difference, clamped.
    @Test("Fragments held never exceeds capacity, whatever the counters say")
    func fragmentsHeldIsClamped() {
        var stats = RingStats()
        stats.fragmentsWritten = 137
        stats.fragmentsEvicted = 117
        #expect(stats.fragmentsInRing(capacity: 20) == 20)

        stats.fragmentsEvicted = 0          // impossible, and must not render as 137
        #expect(stats.fragmentsInRing(capacity: 20) == 20)

        stats.fragmentsWritten = 3
        stats.fragmentsEvicted = 0
        #expect(stats.fragmentsInRing(capacity: 20) == 3, "a young ring reads honestly")

        stats.fragmentsWritten = 0
        stats.fragmentsEvicted = 5          // also impossible; must not go negative
        #expect(stats.fragmentsInRing(capacity: 20) == 0)
    }

    /// ⚠ REQ-FPS-2 / REQ-TIME-5 — the rate comes from measured timestamp deltas,
    /// never from a frame count over a wall clock. The readout must not quietly
    /// reintroduce the count-based figure the requirement forbids.
    @Test("The displayed rate is derived from the measured period")
    func displayedRateComesFromThePeriod() {
        #expect(RingStatsOverlay.rate(fromPeriodNs: 6_666_666) == "150 fps")
        #expect(RingStatsOverlay.rate(fromPeriodNs: 33_333_333) == "30 fps")
        #expect(RingStatsOverlay.rate(fromPeriodNs: 0) == "—",
                "no measurement yet is a dash, not a zero and not a guess")
    }

    /// ⛔ The whole point of the panel: a run whose *mean* looks like 150 fps but
    /// which stalled for 40 ms is a failing run, and the readout must show the two
    /// numbers differently rather than averaging the stall away.
    @Test("A stalled run and a steady run report the same mean and different max")
    func theStallIsVisibleEvenThoughTheMeanIsNot() {
        let period: Int64 = 6_666_666

        var steady = RingStats()
        for index in 0..<150 { steady.observeArrival(atNs: Int64(index) * period) }

        var stalled = RingStats()
        var clock: Int64 = 0
        for index in 0..<150 {
            clock += index == 75 ? 40_000_000 : period
            stalled.observeArrival(atNs: clock)
        }

        #expect(RingStatsOverlay.rate(fromPeriodNs: steady.meanInterArrivalNs) == "150 fps")
        // ⛔ 145 against 150 — a 3% dent that reads as a healthy run, produced by
        // a stall SIX TIMES the frame period. That gap between the two numbers is
        // the entire argument for showing `max gap` beside the rate.
        #expect(RingStatsOverlay.rate(fromPeriodNs: stalled.meanInterArrivalNs) == "145 fps")
        #expect(RingStatsOverlay.ms(steady.maxInterArrivalNs) == "6.7 ms")
        #expect(RingStatsOverlay.ms(stalled.maxInterArrivalNs) == "40.0 ms")
    }
}
