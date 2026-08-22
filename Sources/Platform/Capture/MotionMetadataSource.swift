//  MotionMetadataSource.swift
//  The continuous `metadata` Stream — attitude and gravity — as stream-anchored
//  segments that account for the Stream's whole open interval (I36).
//
//  ⚠ §5.11's table makes `metadata` **always** `continuous`, which is what
//  obliges this Stream to account for its time. A `shot_windowed` Stream may be
//  silent between shots and that is correct; a `continuous` one may not, and
//  "time accounted for by neither a Capture nor a gap is a defect, not a
//  dropout" (I36).
//
//  ⛔ **Where the accounting lives is the point.** `StreamCoverage` in
//  `CaptureCore` holds the rule and makes a hole unconstructible; this file only
//  decides *when* to close a segment and hands the bytes over. An Android port
//  replaces this file and keeps the rule.
//
//  ⚠ `CMDeviceMotion.timestamp` is seconds since boot on the same base as
//  `mach_absolute_time`, which is the clock `tb:hosttime` names and the clock
//  AVFoundation stamps sample buffers with. That is what lets the IMU Source
//  share the camera's `timebase_id` — I4: "two Sources on the same clock
//  reference the same `Timebase.id`" — and it is a measured platform fact, not a
//  convenience.
//
//  Spec: `CORE` §5.11 (5.11b–5.11e), §5.14, §5.3; `CONF` CT-I36.

import CoreMotion
import Foundation
import CaptureCore

/// Attitude and gravity, sampled continuously and cut into segments.
public final class MotionMetadataSource: @unchecked Sendable {

    /// One sample, in neutral terms. ⛔ No `CMDeviceMotion` crosses this
    /// boundary (REQ-PORT-3).
    public struct Sample: Sendable, Hashable {
        public var atNs: Int64
        public var attitude: (roll: Double, pitch: Double, yaw: Double)
        public var gravity: (x: Double, y: Double, z: Double)

        public static func == (a: Self, b: Self) -> Bool { a.atNs == b.atNs }
        public func hash(into hasher: inout Hasher) { hasher.combine(atNs) }
    }

    /// REQ-BUF's neighbour: how long a segment covers. ⚠ 5.11e makes this "the
    /// producing peer's alone" — it "appears nowhere in the spec (I14) and cannot
    /// be negotiated in `ppcp/1.0`". One second, which §5.11e1's own sizing note
    /// uses as its example.
    public static let segmentSeconds: Double = 1

    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let timebaseId: String
    private var samples: [Sample] = []
    private let lock = NSLock()

    public init(timebaseId: String = PpcpTimebases.captureId) {
        self.timebaseId = timebaseId
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    public var isAvailable: Bool { manager.isDeviceMotionAvailable }

    /// - Parameter hertz: the declared profile's rate. The realised rate is what
    ///   `AchievedSummary` reports, not this.
    public func start(hertz: Double = 100) {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1 / hertz
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) {
            [weak self] motion, _ in
            guard let self, let motion else { return }
            // `CMLogItem.timestamp` — seconds since boot, on the host time base.
            let atNs = Int64((motion.timestamp * 1_000_000_000).rounded())
            let sample = Sample(
                atNs: atNs,
                attitude: (motion.attitude.roll, motion.attitude.pitch, motion.attitude.yaw),
                gravity: (motion.gravity.x, motion.gravity.y, motion.gravity.z))
            self.lock.lock()
            self.samples.append(sample)
            self.lock.unlock()
        }
    }

    public func stop() { manager.stopDeviceMotionUpdates() }

    /// Take everything collected so far.
    public func drain() -> [Sample] {
        lock.lock()
        defer { lock.unlock() }
        let taken = samples
        samples.removeAll(keepingCapacity: true)
        return taken
    }

    /// Close the next segment of the Stream at `endNs`, advancing `coverage`.
    ///
    /// ⚠ **The start is not a parameter and cannot be**: `StreamCoverage` puts it
    /// where the last segment ended, which is why a hole between two segments is
    /// not producible (CT-I36 (a)).
    ///
    /// - Returns: the Capture to announce, the payload bytes, and the advanced
    ///   coverage — or an `absent` segment when nothing was sampled, because
    ///   `absent` with an interval is how a peer states that a named span carries
    ///   nothing (5.11c2) and silence is not.
    public func segment(id: String, endingAtNs endNs: Int64,
                        coverage: inout StreamCoverage,
                        absentReason: String = PpcpAbsentReason.notRetained)
        throws -> (record: PpcpCaptureRecord, bytes: Data?) {
        let taken = drain()
        guard taken.isEmpty == false else {
            return (try coverage.absentSegment(id: id, endingAtNs: endNs,
                                               reason: absentReason), nil)
        }
        let summary = PpcpAchievedSummary(
            frameCount: Int64(taken.count),
            realisedRateMillihertz: Self.realisedRateMillihertz(taken))
        let record = try coverage.segment(id: id, endingAtNs: endNs,
                                          completeness: .complete,
                                          summary: summary)
        return (record, Self.encode(taken))
    }

    /// Realised rate from timestamp deltas, in millihertz — the same rule the
    /// video path follows (REQ-FPS-2, I2).
    static func realisedRateMillihertz(_ samples: [Sample]) -> Int64? {
        guard samples.count > 1 else { return nil }
        let span = samples[samples.count - 1].atNs - samples[0].atNs
        guard span > 0 else { return nil }
        return Int64((Double(samples.count - 1) * 1_000_000_000_000 / Double(span)).rounded())
    }

    /// The payload: seven doubles per sample after its instant, little-endian.
    ///
    /// ⚠ **Not a protocol format.** `ENC` fixes the *envelope*; a Capture's
    /// payload bytes are opaque to PPCP and described by the Stream's
    /// `profile_id`, which is why the profile id names the layout.
    static func encode(_ samples: [Sample]) -> Data {
        var bytes = Data(capacity: samples.count * (8 + 6 * 8))
        for sample in samples {
            withUnsafeBytes(of: sample.atNs.littleEndian) { bytes.append(contentsOf: $0) }
            for value in [sample.attitude.roll, sample.attitude.pitch, sample.attitude.yaw,
                          sample.gravity.x, sample.gravity.y, sample.gravity.z] {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
            }
        }
        return bytes
    }
}
