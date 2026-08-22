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
}
