//  PpcpTimebases.swift
//  The clocks this device declares (`CORE` §5.3), the readings behind them, and
//  the discontinuity observer of §6.4.
//
//  ⚠ REQ-PORT-3. `mach_absolute_time`, `mach_continuous_time` and
//  `mach_timebase_info` appear here and nowhere else. What leaves this file is
//  `PpcpTimebaseDeclaration`, `PpcpClockDiscontinuityEvent` and integers.
//
//  ────────────────────────────────────────────────────────────────────────────
//  ⛔ **A FINDING, AND THE REASON THIS FILE READS THE CLOCK IT DOES.**
//
//  The D2 brief specifies `tb:hosttime` as `mach_continuous_time`, `kind:
//  continuous`, `epoch_stable: true`. This file declares `tb:hosttime` as
//  `mach_absolute_time` / `CMClockGetHostTimeClock`, `kind: monotonic`, and
//  declares `mach_continuous_time` **separately** as `tb:continuous`.
//
//  The reason is a platform fact and not a preference. **AVFoundation stamps
//  `CMSampleBuffer` presentation timestamps with the host time clock, which is
//  `mach_absolute_time`** — and on iOS that clock *halts across device sleep*,
//  which is what `mach_continuous_time` was added (iOS 10) to avoid. `CORE` 5.6a
//  makes every Source declare "which clock its samples are in"; declaring the
//  continuous clock for samples stamped by the halting one would be a declaration
//  that is *wrong by exactly the accumulated sleep time*, silently, and only
//  after the first backgrounded session. That is I31's failure mode wearing I1's
//  clothes: everything agrees until it meets a peer that measured.
//
//  So the Source's `timebase_id` names the clock the samples are actually in.
//  `kind: monotonic` is then the honest kind — "halts across sleep" (5.3) — and
//  `epoch_stable: true` is still right, because the epoch (boot) does not move;
//  what the halt costs is the correspondence to elapsed real time, which is
//  precisely what `monotonic` declares.
//
//  `tb:continuous` is declared alongside it for one structural reason: `CORE`
//  5.5b requires a `ClockDiscontinuity`'s `observed_at` to be "in a reference
//  timebase that did **not** step", and the sleep gap in `tb:hosttime` is only
//  observable at all by differencing the two clocks. No Source references it.
//
//  **Reported to the orchestrator rather than resolved here** (plan ground rule
//  3). If the programme wants every peer on a continuous clock, the change is a
//  conversion in the capture path, not a relabelling of this declaration.
//  ────────────────────────────────────────────────────────────────────────────
//
//  Spec: `CORE` §5.3, §5.5, §6.4, §6.5.

import Foundation
import CaptureCore

// MARK: - Readings

/// The two mach clocks, in nanoseconds, and the tick they share.
enum MachClock {

    /// `mach_timebase_info` — the numerator/denominator that turn mach units into
    /// nanoseconds. ⚠ Read once: it is a constant of the running kernel, and the
    /// call is not free at 240 fps.
    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nanoseconds(fromMachUnits units: UInt64) -> Int64 {
        Int64(units * UInt64(timebase.numer) / UInt64(timebase.denom))
    }

    /// `CMClockGetHostTimeClock` — what AVFoundation stamps a sample buffer with.
    /// Halts across device sleep.
    static var hostTimeNs: Int64 { nanoseconds(fromMachUnits: mach_absolute_time()) }

    /// Does not halt across sleep.
    static var continuousNs: Int64 { nanoseconds(fromMachUnits: mach_continuous_time()) }

    /// `CORE` 5.3 `resolution_ns` — "nominal tick".
    ///
    /// ⚠ **Measured from `mach_timebase_info`, not written down.** On Apple
    /// silicon the tick is 41.67 ns (numer 125, denom 3) and on the Intel
    /// simulator it is 1 ns; a constant here would be right on one and wrong on
    /// the other, which is a declaration that varies with the build machine.
    /// ⛔ Rounded **up**, never down: `resolution_ns` is what a consumer treats as
    /// the floor of what this clock can distinguish, and rounding 41.67 down to
    /// 41 claims a finer clock than exists.
    static var resolutionNs: Int64 {
        let numer = Double(timebase.numer), denom = Double(timebase.denom)
        return max(1, Int64((numer / denom).rounded(.up)))
    }
}

// MARK: - The declared timebases

/// The three clocks this peer declares, and the ids they are declared under.
///
/// ⚠ Ids are stable strings and not UUIDs, deliberately: `CORE` 5.3 makes a
/// `Timebase.id` "local to the declaring peer, stable for that peer's lifetime",
/// and I4's whole mechanism is that two Sources on one clock reference **the
/// same id**. A per-launch UUID would satisfy the letter and make every bundle's
/// timebase unreadable next to the last one's.
public enum PpcpTimebases {

    /// What every Source on this device is on (I4).
    public static let captureId = "tb:hosttime"
    /// The reference for a discontinuity in the capture clock (5.5b).
    public static let continuousId = "tb:continuous"
    /// `CORE` 6.5a — labels, never measures (I15).
    public static let wallId = "tb:wall"

    public static var hostTime: PpcpTimebaseDeclaration {
        PpcpTimebaseDeclaration(
            id: captureId,
            // See the finding at the top of this file. `monotonic` because this
            // clock halts across sleep, which is the whole distinction 5.3 draws.
            kind: .monotonic,
            epochStable: true,
            resolutionNs: MachClock.resolutionNs,
            // 5.3 gives this exact string as its own example of an `origin`, and
            // "MUST NOT be interpreted" — it is here so a human reading a bundle
            // knows which clock, not so software branches on it.
            origin: "CMClockGetHostTimeClock")
    }

    public static var continuous: PpcpTimebaseDeclaration {
        PpcpTimebaseDeclaration(
            id: continuousId,
            kind: .continuous,
            epochStable: true,
            resolutionNs: MachClock.resolutionNs,
            origin: "mach_continuous_time")
    }

    /// ⛔ `epoch_stable: false`, and it is not a formality: a device wall clock
    /// "jumps on NTP correction, timezone change, manual adjustment and daylight
    /// saving" (6.5). It exists for `Session.epoch` (6.5b) and for nothing else —
    /// 5.3b forbids computing any interval from it and no Source references it.
    public static var wall: PpcpTimebaseDeclaration {
        PpcpTimebaseDeclaration(
            id: wallId,
            kind: .wall,
            epochStable: false,
            // `Date` is a double of seconds since 2001; a microsecond is a fair
            // nominal tick and nothing measures with it anyway.
            resolutionNs: 1_000,
            origin: "Foundation.Date")
    }

    public static var all: [PpcpTimebaseDeclaration] { [hostTime, continuous, wall] }

    /// The clock read for a declared id. ⚠ Returns an optional rather than
    /// trapping: this is the shape `ppcp_clock_now_fn` wants, and an id nobody
    /// declared is a caller's bug that should surface as a result code and not as
    /// a crash inside the library's call stack.
    public static func now(timebaseId: String) -> Int64? {
        switch timebaseId {
        case captureId: MachClock.hostTimeNs
        case continuousId: MachClock.continuousNs
        case wallId: Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        default: nil
        }
    }
}

// MARK: - Discontinuity (§6.4)

/// `CORE` §5.5 — "the only record a peer writes about its own clock,
/// mid-session", in neutral terms.
///
/// ⚠ 6.4b: "a discontinuity is reported as an **observation**, not merely as a
/// property of the clock. `epoch_stable` declares what a clock *should* do; a
/// discontinuity records what it *did*." So this type carries a magnitude that
/// was measured, not one that was predicted from the declaration.
public struct PpcpClockDiscontinuityEvent: Sendable, Hashable {
    /// The clock that stepped.
    public let timebaseId: String
    /// ⛔ 5.5b — in a timebase that did **not** step. On this device that is
    /// `tb:continuous`, which is the reason it is declared at all.
    public let observedAtTimebaseId: String
    public let observedAtNs: Int64
    /// Signed.
    public let magnitudeNs: Int64
    /// Open registry (`CORE` 10.3): `sleep`, `ntp_correction`, `manual`,
    /// `timezone`, `unknown`.
    public let cause: String
}

/// Watches for the capture clock halting across sleep and publishes what it saw.
///
/// ⚠ **Publishes a neutral event and does nothing else.** It does not encode a
/// `ClockDiscontinuity`, does not hold a peer, and does not decide what a
/// consumer should do about a step — that is `DevicePeer`'s, once L6's engine
/// exists. Keeping the observer this thin is what lets it be tested without a
/// session and reused by the bundle path, which has no peer at all.
///
/// ⛔ **The step is measured, never assumed from `epoch_stable`** (6.4b). The two
/// clocks are read as close together as a pair of function calls allows and their
/// *difference* is tracked; a change in that difference is exactly the time the
/// device spent asleep, and it is reported with `cause: sleep` because that is
/// the only thing on iOS that moves `mach_continuous_time` without moving
/// `mach_absolute_time`.
public final class PpcpClockObserver: @unchecked Sendable {

    /// ⚠ Below this, a step is not a step. Reading two clocks takes two calls and
    /// the pair is not atomic, so the difference jitters by whatever the thread
    /// was interrupted for. A millisecond is far above that jitter and far below
    /// any sleep worth recording; without a floor this would report a
    /// discontinuity every time the scheduler blinked.
    public static let noiseFloorNs: Int64 = 1_000_000

    private let onDiscontinuity: @Sendable (PpcpClockDiscontinuityEvent) -> Void
    private let lock = NSLock()
    private var lastDelta: Int64?

    public init(onDiscontinuity: @escaping @Sendable (PpcpClockDiscontinuityEvent) -> Void) {
        self.onDiscontinuity = onDiscontinuity
    }

    /// Take a reading. Called at session start, on foregrounding, and on the
    /// heartbeat — ⚠ by the caller, because a timer of its own would be I/O and a
    /// wake-up this file has no business owning.
    public func sample() {
        // Read continuous first and host second: the gap between them is then
        // charged against `host`, which biases a spurious delta in the direction
        // the noise floor already rejects.
        let continuousNs = MachClock.continuousNs
        let hostNs = MachClock.hostTimeNs
        let delta = continuousNs - hostNs

        let step: Int64? = lock.withLock {
            defer { lastDelta = delta }
            guard let previous = lastDelta else { return nil }
            let step = delta - previous
            return abs(step) >= Self.noiseFloorNs ? step : nil
        }
        guard let step else { return }

        onDiscontinuity(PpcpClockDiscontinuityEvent(
            // The capture clock is the one that stepped: `tb:continuous` kept
            // counting and `tb:hosttime` did not.
            timebaseId: PpcpTimebases.captureId,
            observedAtTimebaseId: PpcpTimebases.continuousId,
            observedAtNs: continuousNs,
            // Signed, and the sign says which way: a positive step is time
            // `tb:hosttime` did not count, i.e. the device slept.
            magnitudeNs: step,
            // ⛔ `unknown` for a *negative* step rather than a guess. Nothing on
            // this platform should make the host clock outrun the continuous one,
            // and reporting `sleep` for something that is not sleep would be the
            // same class of untruth as a synthesised provenance.
            cause: step > 0 ? "sleep" : "unknown"))
    }

    /// Forget the baseline — after a session ends, so the next one's first sample
    /// establishes a fresh one rather than reporting the gap between sessions as
    /// a mid-session step.
    public func reset() {
        lock.withLock { lastDelta = nil }
    }
}
