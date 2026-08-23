//  SyntheticAudio.swift
//  An injected `AudioWindow`, for the harness and for previews.
//
//  ⛔ **This is an injected input, not a fabricated Candidate**, and the
//  distinction is the whole reason it exists. `CONF` §2a's *injected* method is a
//  test that "drives an implementation with a synthetic input and asserts on what
//  it emits"; a harness that skipped the detector and posted a `candidate`
//  straight onto the wire would assert nothing about the detector, the time of
//  flight, the classifier bytes or the canonical instant, while looking exactly
//  the same from the far end.
//
//  ⚠ **So the pipeline under test is real and only the microphone is not.** The
//  samples below go into the same `AcousticOnsetDetector` a phone's microphone
//  feeds, through the same `CandidateFactory`, with the same
//  `tof_correction` — which is what makes a conformance run over these bytes
//  evidence about this application rather than about this fixture.
//
//  Spec: `CONF` §2a. Plan D9.

import Foundation

/// Windows of audio that were never heard.
public enum SyntheticAudio {

    /// One transient's shape.
    ///
    /// ⚠ **Impact and ball-into-screen are deliberately different sounds.** A
    /// fixture that made them identical would show only that the detector fires
    /// twice, never that the taxonomy separates them — and the taxonomy is what
    /// the promotion policy turns on (5.12c, 8.3b).
    public struct Transient: Sendable, Hashable {
        public var atSample: Int
        public var amplitude: Float
        public var riseSamples: Int
        public var decaySamples: Int

        public init(atSample: Int, amplitude: Float,
                    riseSamples: Int, decaySamples: Int) {
            self.atSample = atSample
            self.amplitude = amplitude
            self.riseSamples = riseSamples
            self.decaySamples = decaySamples
        }

        /// Club face on ball: loud, and the fastest rise there is.
        public static func impact(at sample: Int) -> Transient {
            Transient(atSample: sample, amplitude: 0.9, riseSamples: 8, decaySamples: 240)
        }

        /// Ball into the screen: quieter, slower to rise, and it rings — a net is
        /// a membrane and keeps moving after the ball has gone. `CORE` 5.12c's
        /// own example, "roughly 9 ms after impact at 3 m".
        public static func screen(at sample: Int) -> Transient {
            Transient(atSample: sample, amplitude: 0.35, riseSamples: 96,
                      decaySamples: 3_000)
        }
    }

    /// - Parameter startNs: the instant of **sample zero**, in `timebaseId`.
    public static func window(timebaseId: String, startNs: Int64,
                              sampleRate: Double = 48_000, count: Int = 9_600,
                              transients: [Transient]) -> AudioWindow {
        // ⚠ Not silence: a room floor, so the rising-edge test has something to
        // rise from. A window of exact zeros reads as −120 dBFS and every
        // transient in it looks like a 120 dB step, which no microphone produces.
        var samples = [Float](repeating: 0.0005, count: count)
        for transient in transients {
            let at = transient.atSample
            for offset in 0..<transient.riseSamples where at + offset < count {
                samples[at + offset] = transient.amplitude
                    * Float(offset + 1) / Float(transient.riseSamples)
            }
            for offset in 0..<transient.decaySamples
            where at + transient.riseSamples + offset < count {
                let decay = Float(transient.decaySamples - offset)
                    / Float(transient.decaySamples)
                samples[at + transient.riseSamples + offset] =
                    transient.amplitude * decay * decay
            }
        }
        return AudioWindow(timebaseId: timebaseId, startNs: startNs,
                           sampleRate: sampleRate, samples: samples)
    }

    /// One swing: impact, then the ball into the screen 9 ms later.
    public static func oneSwing(timebaseId: String, startNs: Int64) -> AudioWindow {
        // 9 ms at 48 kHz is 432 samples.
        window(timebaseId: timebaseId, startNs: startNs,
               transients: [.impact(at: 1_000), .screen(at: 1_432)])
    }
}
