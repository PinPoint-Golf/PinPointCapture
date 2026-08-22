//  InterruptionMonitor.swift
//  `CORE` 7.3d — "a capture peer reports and recovers from platform
//  interruptions — an incoming call, an audio session interruption,
//  backgrounding — with automatic re-arm where it was armed, and with the
//  resulting gap recorded explicitly."
//
//  ⛔ **Two obligations, and the second is the one that gets dropped.**
//  Recovering is visible in the UI and everybody implements it. Recording the gap
//  is what stops a consumer interpolating across it (5.14b, I11) — an
//  interruption that re-armed cleanly and said nothing leaves a hole in the frame
//  timeline that reads as a dropout, and 5.11c calls unaccounted time between
//  announced Captures a defect rather than a dropout.
//
//  ⚠ The gap is measured on `tb:hosttime`, the clock the samples are in, and not
//  on the wall clock (I1, I15). Both edges are read from the same clock so the
//  duration is a difference and not a subtraction of two different things.
//
//  Spec: `CORE` §7.3d, §5.14b; requirements REQ-STATE-5, REQ-RES-1.

import AVFoundation
import Foundation
import UIKit
import CaptureCore

/// Watches the platform for the three things §7.3d names and reports each as a
/// closed gap once it ends.
public final class InterruptionMonitor: @unchecked Sendable {

    /// Called on the main queue with a completed interruption.
    public typealias Handler = @MainActor (InterruptionRecord) -> Void

    private let timebaseId: String
    private let handler: Handler
    private var observers: [any NSObjectProtocol] = []
    /// The open interruption: what kind, and when it started.
    private var openedAt: (kind: InterruptionRecord.Kind, ns: Int64)?
    /// Whether capture was retaining when it began, so "recovered" means
    /// something.
    private var wasRetaining = false

    public init(timebaseId: String = PpcpTimebases.captureId,
                onInterruption handler: @escaping Handler) {
        self.timebaseId = timebaseId
        self.handler = handler
    }

    deinit { stop() }

    /// - Parameter session: observed for `AVCaptureSession`'s own interruption
    ///   notifications, which is where a call and a resource conflict arrive.
    @MainActor
    public func start(observing session: AVCaptureSession, isRetaining: @escaping () -> Bool) {
        stop()
        let centre = NotificationCenter.default

        observers.append(centre.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session, queue: .main) { [weak self] note in
                guard let self else { return }
                self.begin(Self.kind(of: note), retaining: isRetaining())
            })

        observers.append(centre.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session, queue: .main) { [weak self] _ in
                // ⚠ `recovered: true` is the *session's* claim that it resumed,
                // not this file's guess. Where it was not retaining, there was
                // nothing to recover and the flag says so.
                self?.end(recovered: true)
            })

        // Backgrounding is named separately by 7.3d and does not always produce
        // an `AVCaptureSession` interruption — a session with no video input
        // running is simply suspended.
        observers.append(centre.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.begin(.background, retaining: isRetaining())
            })
        observers.append(centre.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.end(recovered: true)
            })
    }

    public func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    // MARK: The gap

    private func begin(_ kind: InterruptionRecord.Kind, retaining: Bool) {
        // A second notification inside one interruption keeps the first edge:
        // backgrounding often arrives alongside the session's own notice, and two
        // overlapping gaps for one event would breach 5.14e on any Stream that
        // recorded them.
        guard openedAt == nil else { return }
        openedAt = (kind, MachClock.hostTimeNs)
        wasRetaining = retaining
    }

    private func end(recovered: Bool) {
        guard let opened = openedAt else { return }
        openedAt = nil
        let endedAt = MachClock.hostTimeNs
        guard endedAt > opened.ns else { return }
        let record = InterruptionRecord(
            kind: opened.kind,
            timebaseId: timebaseId,
            intervalNs: opened.ns..<endedAt,
            recovered: recovered && wasRetaining)
        Task { @MainActor [handler] in handler(record) }
    }

    /// `AVCaptureSessionInterruptionReasonKey` mapped onto §7.3d's three names.
    ///
    /// ⛔ The platform's reason code does not cross the wire — `kind` is an open
    /// registry of protocol words, and exporting `videoDeviceInUseByAnotherClient`
    /// would export a platform-shaped concept for the same reason 5.15a forbids
    /// exporting a state name.
    static func kind(of note: Notification) -> InterruptionRecord.Kind {
        guard let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: raw)
        else { return .call }
        switch reason {
        case .videoDeviceNotAvailableInBackground: return .background
        case .audioDeviceInUseByAnotherClient: return .audioSession
        default: return .call
        }
    }
}
