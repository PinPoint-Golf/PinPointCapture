//  ThermalTimeline.swift
//  `CORE` §5.8 `AchievedSummary.thermal` — "a timeline, not a single value".
//
//  ⛔ **One reading at the end cannot answer the question the field exists for.**
//  A Capture that finished at `serious` may have been `nominal` for the swing and
//  degraded afterwards, or may have been hot throughout; those are different
//  facts about the same clip and only a timeline distinguishes them. The
//  specification writes the field as `[{ at: Instant, level: ThermalLevel }]` for
//  that reason.
//
//  ⚠ Change-driven, not polled. `ProcessInfo` posts on every transition, and
//  sampling on a timer would either miss a transition or fill a session with
//  identical points.
//
//  Spec: `CORE` §5.8; requirements REQ-RES-3, REQ-ENC-4.

import Foundation
import CaptureCore

/// Thermal transitions, stamped on the capture clock.
public final class ThermalTimeline: @unchecked Sendable {

    private let timebaseId: String
    private let lock = NSLock()
    private var points: [PpcpThermalPoint] = []
    private var observer: (any NSObjectProtocol)?

    public init(timebaseId: String = PpcpTimebases.captureId) {
        self.timebaseId = timebaseId
    }

    deinit { stop() }

    /// Begin recording. ⚠ The first point is the state **now**: a timeline that
    /// started at the first transition would say nothing about a device that was
    /// already hot when the session opened, which is the case REQ-ENC-4 is about.
    public func start() {
        stop()
        record(DeviceHealthService.thermalState)
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil) { [weak self] _ in
                self?.record(DeviceHealthService.thermalState)
            }
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func record(_ level: ThermalState) {
        let point = PpcpThermalPoint(timebaseId: timebaseId,
                                     atNs: MachClock.hostTimeNs, level: level)
        lock.lock()
        points.append(point)
        lock.unlock()
    }

    /// The points relevant to one Capture: everything inside its interval, plus
    /// the last transition **before** it.
    ///
    /// ⚠ The point before the interval is not padding. Without it a clip that saw
    /// no transition would carry an empty timeline, which reads as "not measured"
    /// rather than as "steady at this level throughout".
    public func points(covering intervalNs: Range<Int64>) -> [PpcpThermalPoint] {
        lock.lock()
        let all = points
        lock.unlock()

        var result = all.filter { intervalNs.contains($0.atNs) }
        if let preceding = all.last(where: { $0.atNs < intervalNs.lowerBound }) {
            result.insert(PpcpThermalPoint(timebaseId: timebaseId,
                                           atNs: intervalNs.lowerBound,
                                           level: preceding.level), at: 0)
        }
        return result
    }
}
