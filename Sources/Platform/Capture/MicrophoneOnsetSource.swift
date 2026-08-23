//  MicrophoneOnsetSource.swift
//  The microphone, turned into the platform-free `AudioWindow` the detector eats.
//
//  ⚠ **REQ-PORT-3.** `AVAudioEngine`, `AVAudioPCMBuffer` and `CMClock` appear
//  here and nowhere above: what crosses into `CaptureCore` is a start instant, a
//  sample rate and an array of floats. The detector has never heard of
//  AVFoundation, which is what makes swapping it for a better one a substitution.
//
//  ⛔ **The instant is the platform's, converted through the same clock the camera
//  is on** — `tb:hosttime`, `CMClockGetHostTimeClock` (`CORE` §5.3, CT-I4). An
//  audio buffer's `AVAudioTime` carries a host-time sample stamp, so the two
//  Sources share one Timebase and this device declares **no** relation between
//  them: I4 says identity is a shared `id`, not a relation.
//
//  ⚠ **`convention: mid` and no `format`** (`CORE` 6.1d). A microphone sample is
//  an instant, not a frame with an exposure, so the canonical instant is the raw
//  instant and there is no `d/2` to apply. That is why `CandidateFactory` passes a
//  `nil` profile for this Source.
//
//  Spec: `CORE` §5.3, §5.12, §6.1d; requirements REQ-MIC-1 to 5, REQ-PRIV-4/5.
//  Plan D5.

import Foundation
import AVFoundation
import CaptureCore

/// Delivers `AudioWindow`s from the built-in microphone.
public final class MicrophoneOnsetSource: @unchecked Sendable {

    /// The `Source` id this device declares for the microphone. ⚠ It must match
    /// `PpcpDeclaration`'s, because I26 refuses a Candidate naming anything else.
    public static let sourceId = "src:microphone"

    /// The Stream kind 5.12.1a requires the evidence to land on. ⛔ **Separate**
    /// from video: muxing the audio into the clip would retain the full video
    /// window of room audio per shot for no diagnostic benefit.
    public static let streamKind = PpcpStreamKind.audio

    private let engine = AVAudioEngine()
    private let timebaseId: String
    private let onWindow: @Sendable (AudioWindow) -> Void
    private var started = false

    /// - Parameter onWindow: called on the audio thread. ⚠ Do the least possible
    ///   there: `CORE` 7.4d makes capture the thing that must not degrade, and the
    ///   audio render thread is the one place a Swift allocation can cost a
    ///   dropout in something else.
    public init(timebaseId: String = PpcpTimebases.captureId,
                onWindow: @escaping @Sendable (AudioWindow) -> Void) {
        self.timebaseId = timebaseId
        self.onWindow = onWindow
    }

    public enum MicrophoneError: Error, Sendable, Equatable {
        /// ⛔ Not a failure to be worked around: `RV`-style silent degradation is
        /// exactly what 7.4b exists to stop. If the session cannot be configured
        /// the app says so rather than nominating on a clock it invented.
        case sessionUnavailable(String)
    }

    /// Starts delivering windows.
    ///
    /// ⚠ **A `.record` category with `.measurement` mode**: the default modes
    /// apply automatic gain and, on some devices, noise suppression tuned for
    /// speech — which is a filter applied to the exact transient this app is
    /// trying to time. REQ-MIC-2's raw path is the one the classifier was tuned
    /// against.
    public func start(bufferFrames: AVAudioFrameCount = 4_800) throws {
        guard started == false else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
        } catch {
            throw MicrophoneError.sessionUnavailable(error.localizedDescription)
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let timebaseId = self.timebaseId
        let onWindow = self.onWindow

        input.installTap(onBus: 0, bufferSize: bufferFrames, format: format) { buffer, when in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            let samples = [Float](UnsafeBufferPointer(start: channel, count: count))

            // ⛔ The instant of **sample zero**, from the platform's own host-time
            // stamp — never a wall clock and never `Date()`. `CORE` I15: a wall
            // clock is a label and no interval is ever computed from one.
            let hostTimeNs = Self.hostTimeNs(when)
            onWindow(AudioWindow(timebaseId: timebaseId, startNs: hostTimeNs,
                                 sampleRate: format.sampleRate, samples: samples))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MicrophoneError.sessionUnavailable(error.localizedDescription)
        }
        started = true
    }

    public func stop() {
        guard started else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        started = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// `AVAudioTime` → nanoseconds on `tb:hosttime`.
    ///
    /// ⚠ **`hostTime` is `mach_absolute_time` units, not nanoseconds**, and the
    /// two are equal only on some hardware. `PpcpTimebases` holds the conversion
    /// and its measured resolution; doing the arithmetic here with a hardcoded 1:1
    /// is the classic iOS timing bug, and it would show up as an offset that
    /// varies by device model.
    static func hostTimeNs(_ when: AVAudioTime) -> Int64 {
        guard when.isHostTimeValid else {
            return PpcpTimebases.now(timebaseId: PpcpTimebases.captureId) ?? 0
        }
        return MachClock.nanoseconds(fromMachUnits: when.hostTime)
    }
}
