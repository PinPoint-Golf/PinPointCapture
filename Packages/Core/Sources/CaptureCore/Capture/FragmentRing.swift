//  FragmentRing.swift
//  REQ-BUF-1 — the rolling buffer of hardware-encoded fragments, and the
//  extraction of a clip around a `t0` out of it.
//
//  ⚠ **This is the buffer's INDEX, not its bytes.** REQ-BUF-1 retains about
//  twenty half-second fragments; at 1080p150 the bytes are hundreds of megabytes
//  and belong to the platform's encoder, which owns the file or the memory they
//  sit in. What lives here is what the protocol needs to answer a
//  `capture_request`: which spans are retained, what times the frames in them
//  carry, and where the holes are. That split is what lets the whole of §8.4's
//  behaviour — including the `outside_buffer` answer — be tested on the host in
//  milliseconds with no camera and no encoder.
//
//  ⛔ **Absence is asserted, never inferred** (I10, 8.4b). A request for an
//  interval the ring no longer holds produces a `Capture` of
//  `completeness: absent` with `absent_reason: outside_buffer` — a *result*, not
//  a failure, and `PPCP-MSG` §7.3b is explicit that it is not an `error`. That is
//  why `extract` returns an outcome and never throws for a miss.
//
//  ⛔ **Holes are not always gaps** (I11). A gap is loss *inside* a segment that
//  otherwise exists, and it is meaningful only on a `continuous` Stream. Video is
//  `shot_windowed` (§5.11), so a hole inside a requested clip window makes the
//  Capture `partial` and is reported as nothing else; the library refuses gaps on
//  a `shot_windowed` Stream outright (`ppcp_capture_validate_in_stream`). This
//  type therefore reports the holes it found and leaves the decision about how to
//  express them to the record builder, which knows the Stream's continuity.
//
//  Spec: `CORE` §5.1 (intervals are half-open), §5.11, §5.14, §8.4;
//  `CONF` CT-I10, CT-I11, CT-I27.

import Foundation
import CPPCP

// MARK: - What the encoder hands over

/// One retained fragment: an independently decodable run of frames.
///
/// ⚠ REQ-BUF-2 fixes the fragment length by two independent requirements —
/// ring-buffer tractability and frame-accurate reverse stepping — and that
/// rationale must not later be "optimised" for bitrate.
///
/// ⛔ `frameTimestampsNs` are the *source* timestamps in the Stream's timebase,
/// one per frame delivered. Never derived from an index and never synthesised
/// from a nominal rate (I2, 5.8e): "frames drop; indices lie".
public struct CapturedFragment: Sendable, Hashable, Identifiable {

    /// Monotonic within one recording run. For loss detection only (I2).
    public var sequence: UInt64
    /// Inclusive start of the fragment's coverage.
    public var startNs: Int64
    /// **Exclusive** end — `CORE` §5.1 intervals are half-open `[start, end)`,
    /// so two abutting fragments share a boundary without overlapping (5.14e).
    public var endNs: Int64
    public var frameTimestampsNs: [Int64]
    /// Exposure duration per frame, parallel to `frameTimestampsNs` when the
    /// platform sampled it per frame, or empty under a lock.
    public var exposureNs: [Int64]
    /// ISO per frame, same rule.
    public var iso: [Int64]
    public var byteCount: Int
    /// Frames the platform reported dropped while this fragment was recorded.
    public var droppedFrames: Int

    public var id: UInt64 { sequence }

    public init(sequence: UInt64,
                startNs: Int64,
                endNs: Int64,
                frameTimestampsNs: [Int64],
                exposureNs: [Int64] = [],
                iso: [Int64] = [],
                byteCount: Int = 0,
                droppedFrames: Int = 0) {
        self.sequence = sequence
        self.startNs = startNs
        self.endNs = endNs
        self.frameTimestampsNs = frameTimestampsNs
        self.exposureNs = exposureNs
        self.iso = iso
        self.byteCount = byteCount
        self.droppedFrames = droppedFrames
    }

    public var intervalNs: Range<Int64> { startNs..<Swift.max(startNs, endNs) }
}

// MARK: - What an extraction found

/// The result of asking the ring for the clip around a `t0`.
///
/// ⚠ There is no `error` case and that is deliberate: §8.4b makes "the interval
/// is gone" an *answer*, and `PPCP-MSG` §7.3b makes answering it with an `error`
/// wrong. The only throwing path in this file is a malformed request.
public struct ClipExtraction: Sendable, Hashable {

    public enum Outcome: Sendable, Hashable {
        /// Frames were found. `completeness` is `complete` when the whole
        /// requested window was covered, `partial` when only part of it was.
        case present(PpcpCaptureRecord.Completeness)
        /// Nothing was found. The reason is an open-registry `Kind`; for the ring
        /// it is `outside_buffer` (8.4b).
        case absent(reason: String)
    }

    /// What was asked for — `[t0 − pre, t0 + post)`.
    public var requestedNs: Range<Int64>
    public var outcome: Outcome
    /// The fragments the clip is assembled from, in time order.
    public var fragments: [CapturedFragment]
    /// The interval actually covered, clipped to what the ring holds. `nil` when
    /// the outcome is `absent`.
    public var realisedNs: Range<Int64>?
    /// Spans *inside* `realisedNs` that carry no data — a recording interruption
    /// (7.3d), never an eviction. ⛔ On a `shot_windowed` Stream these must not
    /// be sent as `gaps` (I11); they are why `completeness` is `partial`.
    public var holesNs: [Range<Int64>]
    /// Every frame timestamp inside `realisedNs`, in order.
    public var frameTimestampsNs: [Int64]
    public var exposureNs: [Int64]
    public var iso: [Int64]
    public var droppedFrames: Int
    public var byteCount: Int

    public var isAbsent: Bool {
        if case .absent = outcome { return true }
        return false
    }

    /// `CORE` §5.8 `realised_rate_mhz` — **millihertz, from timestamp deltas**.
    ///
    /// ⛔ Never a frame count over a wall-clock interval and never the rate the
    /// platform reports back (REQ-FPS-2, REQ-TIME-5). `n` frames span `n − 1`
    /// intervals, so a single frame has no realised rate and this is `nil`.
    public var realisedRateMillihertz: Int64? {
        guard frameTimestampsNs.count > 1 else { return nil }
        let span = frameTimestampsNs[frameTimestampsNs.count - 1] - frameTimestampsNs[0]
        guard span > 0 else { return nil }
        let intervals = Double(frameTimestampsNs.count - 1)
        return Int64((intervals * 1_000_000_000_000 / Double(span)).rounded())
    }
}

// MARK: - The ring

/// REQ-BUF-1 — "a rolling buffer of hardware-encoded fragments … retaining ~20
/// fragments; concatenate on trigger".
///
/// ⚠ A value type on purpose. The platform recorder owns one and mutates it on
/// its own queue; nothing here is shared, so nothing here needs a lock on the
/// 150 fps path (see the ⚠ on `CaptureDevice`).
public struct FragmentRing: Sendable, Hashable {

    /// REQ-BUF-1's figure. ~20 fragments of ~0.5 s is ~10 s of history, which is
    /// what a 3 s clip around a `t0` nobody predicted needs.
    public static let defaultCapacity = 20

    public let capacity: Int
    /// In time order, oldest first.
    public private(set) var fragments: [CapturedFragment]

    public init(capacity: Int = FragmentRing.defaultCapacity) {
        self.capacity = Swift.max(1, capacity)
        self.fragments = []
    }

    /// Append the newest fragment, evicting the oldest past `capacity`.
    ///
    /// - Returns: the fragments evicted by this append, oldest first. The caller
    ///   is what deletes their bytes — this type never owned them.
    @discardableResult
    public mutating func append(_ fragment: CapturedFragment) -> [CapturedFragment] {
        fragments.append(fragment)
        fragments.sort { $0.startNs < $1.startNs }
        guard fragments.count > capacity else { return [] }
        let evicted = Array(fragments.prefix(fragments.count - capacity))
        fragments.removeFirst(fragments.count - capacity)
        return evicted
    }

    /// Drop everything — a `goCold`, or a disarm that ends retention.
    public mutating func clear() { fragments.removeAll(keepingCapacity: true) }

    /// The span the ring currently holds, ignoring holes inside it.
    public var retainedNs: Range<Int64>? {
        guard let first = fragments.first, let last = fragments.last else { return nil }
        guard last.endNs > first.startNs else { return nil }
        return first.startNs..<last.endNs
    }

    /// Seconds currently retained, for `CaptureStatus.bufferSeconds`.
    public var retainedSeconds: Double {
        guard let retained = retainedNs else { return 0 }
        return Double(retained.upperBound - retained.lowerBound) / 1_000_000_000
    }

    /// `CORE` §8.4a — "locating the interval in its buffer".
    ///
    /// - Parameters:
    ///   - t0: the Shot's instant, already converted into *this* Stream's
    ///     timebase by the caller. ⛔ This type does no conversion: a bare number
    ///     arriving here would be a timebase nobody named (I1), and the
    ///     conversion is the library's (`ppcp_relation_apply`).
    ///   - preNs: how far before `t0` to reach.
    ///   - postNs: how far after.
    public func extract(aroundNs t0: Int64, preNs: Int64, postNs: Int64) -> ClipExtraction {
        let requested = (t0 - Swift.max(0, preNs))..<(t0 + Swift.max(0, postNs))
        return extract(requested)
    }

    /// The interval form, for a `capture_request` that names one directly.
    public func extract(_ requested: Range<Int64>) -> ClipExtraction {
        let overlapping = fragments.filter { $0.intervalNs.overlaps(requested) }

        guard let firstCovered = overlapping.first, let lastCovered = overlapping.last else {
            // ⛔ 8.4b — the interval is no longer retained. `absent`, with a
            // reason, and never an error.
            return ClipExtraction(
                requestedNs: requested,
                outcome: .absent(reason: PpcpAbsentReason.outsideBuffer),
                fragments: [], realisedNs: nil, holesNs: [],
                frameTimestampsNs: [], exposureNs: [], iso: [],
                droppedFrames: 0, byteCount: 0)
        }

        let realised = Swift.max(requested.lowerBound, firstCovered.startNs)
            ..< Swift.min(requested.upperBound, lastCovered.endNs)

        // Holes: any discontinuity BETWEEN retained fragments inside the realised
        // span. A ring evicts only from the front, so a hole in the middle means
        // recording actually stopped — an interruption (7.3d), which is the one
        // thing a consumer must not interpolate across (5.14b).
        var holes: [Range<Int64>] = []
        for (previous, next) in zip(overlapping, overlapping.dropFirst())
        where next.startNs > previous.endNs {
            let hole = Swift.max(previous.endNs, realised.lowerBound)
                ..< Swift.min(next.startNs, realised.upperBound)
            if hole.isEmpty == false { holes.append(hole) }
        }

        var frames: [Int64] = []
        var exposure: [Int64] = []
        var isoValues: [Int64] = []
        var dropped = 0
        var bytes = 0
        for fragment in overlapping {
            for (index, timestamp) in fragment.frameTimestampsNs.enumerated()
            where realised.contains(timestamp) {
                frames.append(timestamp)
                if index < fragment.exposureNs.count { exposure.append(fragment.exposureNs[index]) }
                if index < fragment.iso.count { isoValues.append(fragment.iso[index]) }
            }
            dropped += fragment.droppedFrames
            bytes += fragment.byteCount
        }

        // ⚠ Frames, not span, decides presence. A window that overlaps a
        // fragment's declared interval but contains none of its frames has no
        // clip in it, and announcing `complete` over an empty frame list would
        // be an assertion nothing backs (I10).
        guard frames.isEmpty == false else {
            return ClipExtraction(
                requestedNs: requested,
                outcome: .absent(reason: PpcpAbsentReason.outsideBuffer),
                fragments: [], realisedNs: nil, holesNs: [],
                frameTimestampsNs: [], exposureNs: [], iso: [],
                droppedFrames: 0, byteCount: 0)
        }

        let covered = realised == requested && holes.isEmpty
        return ClipExtraction(
            requestedNs: requested,
            outcome: .present(covered ? .complete : .partial),
            fragments: overlapping,
            realisedNs: realised,
            holesNs: holes,
            frameTimestampsNs: frames,
            exposureNs: exposure,
            iso: isoValues,
            droppedFrames: dropped,
            byteCount: bytes)
    }
}

// MARK: - The reason vocabulary

/// `CORE` §5.14 `absent_reason` — an **open** registry, and these are the
/// spellings the specification writes out.
///
/// ⚠ Taken from `libppcp`'s macros rather than typed here, for the same reason
/// `PpcpProfileSet` takes the profile names from the library: a spelling this
/// application invented would be a spelling only this application understands.
public enum PpcpAbsentReason {
    /// 8.4b — the requested interval has rolled out of the ring.
    public static let outsideBuffer = PPCP_ABSENT_OUTSIDE_BUFFER
    /// 5.11c3 / 5.11j — deliberate non-retention. ⛔ Never a gap.
    public static let notRetained = PPCP_ABSENT_NOT_RETAINED
    public static let storageFull = PPCP_ABSENT_STORAGE_FULL
    public static let notArmed = PPCP_ABSENT_NOT_ARMED
    public static let thermalLimit = PPCP_ABSENT_THERMAL_LIMIT
    public static let linkLost = PPCP_ABSENT_LINK_LOST
}
