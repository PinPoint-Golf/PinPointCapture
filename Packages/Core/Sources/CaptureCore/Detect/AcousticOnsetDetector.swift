//  AcousticOnsetDetector.swift
//  The acoustic onset detector, and the taxonomy it labels what it hears with.
//
//  ⚠ **Accuracy is explicitly out of scope** (`CONF` §6: "which candidates a Mint
//  peer promotes is outside conformance"). What *is* in scope, and what this file
//  is shaped by, is that **every** onset it hears is emitted — the ones it
//  believes and the ones it does not (`CORE` 5.12c, 8.3b, I8). A detector that
//  suppressed its own rejects would destroy the only evidence explaining why
//  detection fired, which is the whole reason candidate-attached audio exists
//  (§5.12.1).
//
//  ⛔ **No threshold in this file is a protocol constant and none may become
//  one.** 5.12.1b and I14 put the emission threshold, the retention window and
//  the promotion policy in the peer, exactly as frame-rate floors are host
//  policy. The numbers below are this application's tuning and are labelled as
//  such; a port re-derives them and the protocol never sees them.
//
//  ⚠ **`CaptureCore` is platform-free** (REQ-PORT-3). This detector takes a
//  window of mono float samples with a start instant and a rate; it has never
//  heard of `AVAudioEngine`, and the platform layer converts.
//
//  Spec: `CORE` §5.12, §5.12.1, §8.1, §8.3b–c. Requirements: REQ-MIC-5,
//  REQ-PRIV-4, REQ-OBS-4. Plan D5.

import Foundation

// MARK: - What the microphone hands over

/// A window of mono audio, timestamped in the Source's own timebase.
///
/// ⚠ `startNs` is the instant of **sample zero**, and every onset instant is
/// derived from it by sample offset — never by counting windows. `CORE` 5.8e's
/// "frames drop; indices lie" is a statement about video, and it is exactly as
/// true of audio buffers arriving from a capture session.
public struct AudioWindow: Sendable, Hashable {
    public let timebaseId: String
    public let startNs: Int64
    public let sampleRate: Double
    public let samples: [Float]

    public init(timebaseId: String, startNs: Int64, sampleRate: Double, samples: [Float]) {
        self.timebaseId = timebaseId
        self.startNs = startNs
        self.sampleRate = sampleRate
        self.samples = samples
    }

    /// The instant of sample `index`, from the window's own start and rate.
    public func instantNs(ofSample index: Int) -> Int64 {
        startNs + Int64((Double(index) / sampleRate * 1_000_000_000).rounded())
    }

    public var durationNs: Int64 {
        Int64((Double(samples.count) / sampleRate * 1_000_000_000).rounded())
    }
}

// MARK: - The taxonomy

/// `CORE` 5.12 `classifier` — "for `acoustic`: the transient taxonomy", and
/// 5.12b makes it interpretable **only** in the context of `basis: acoustic`.
///
/// The labels are REQ-MIC-5's list of what a range bay actually contains. ⚠ They
/// are a *label plus the measurements the label was drawn from*, and both travel:
/// a consumer that disagrees with the label can still see the rise time and the
/// peak, and a later classifier can be re-run against retained audio (REQ-PRIV-7)
/// without the old label getting in its way.
public struct AcousticClassification: Sendable, Hashable {

    /// ⚠ An **open** vocabulary in the protocol's sense: a consumer meeting a
    /// label it does not know keeps it and does not guess.
    public enum Transient: String, Sendable, Hashable, CaseIterable {
        /// Club-face on ball: the fastest rise this detector distinguishes.
        case impact
        /// Ball into the screen, ~9 ms after impact at 3 m — the single most
        /// important non-shot to emit rather than suppress, because Draft 1's
        /// rule minted two Shots for it (`CORE` §8.3 commentary).
        case screen
        /// Club on mat, before or after the ball.
        case mat
        /// A dropped club, a bag, a door.
        case knock
        /// Speech or music: slow rise, long decay, no transient at all.
        case speech
        /// Heard, measured, not labelled. ⛔ Not "ignored" — it is still emitted.
        case unknown
    }

    public let transient: Transient
    /// Peak level in the window, dBFS.
    public let peakDbfs: Double
    /// 10 %→90 % rise, in nanoseconds. The feature that separates `impact` from
    /// `speech` far more reliably than level does.
    public let riseNs: Int64
    /// Time from peak to 10 % of peak.
    public let decayNs: Int64

    public init(transient: Transient, peakDbfs: Double, riseNs: Int64, decayNs: Int64) {
        self.transient = transient
        self.peakDbfs = peakDbfs
        self.riseNs = riseNs
        self.decayNs = decayNs
    }
}

/// One onset: an instant, a confidence, and what the detector made of it.
///
/// ⛔ **Not yet a Candidate.** The instant here is the *raw* one in the
/// microphone's timebase, before time-of-flight correction and before the
/// canonical-instant conversion. `CandidateFactory` does both, in that order, and
/// records each correction (`CORE` 5.12e–f, 8.1d).
public struct AcousticOnset: Sendable, Hashable {
    public let rawNs: Int64
    public let confidence: Double
    public let classification: AcousticClassification

    public init(rawNs: Int64, confidence: Double,
                classification: AcousticClassification) {
        self.rawNs = rawNs
        self.confidence = confidence
        self.classification = classification
    }
}

// MARK: - The detector

/// A short-time-energy onset detector with a refractory period.
///
/// ⚠ **Deliberately the simplest thing that emits losers.** The design question
/// this file answers is not "how good is the detector" — `CONF` §6 puts that
/// outside conformance — it is "does the pipeline carry a nomination the peer
/// itself does not believe, all the way to a wire". A more elaborate detector
/// with the same emission contract would drop in behind the same three types.
public struct AcousticOnsetDetector: Sendable {

    /// ⛔ Application tuning, not protocol (I14, 5.12.1b).
    public struct Tuning: Sendable, Hashable {
        /// The level a window must reach to be *emitted at all*. Everything above
        /// it is a Candidate, whatever the detector thinks of it.
        public var emissionFloorDbfs: Double
        /// The level at which this detector *believes* a transient is a shot.
        /// ⚠ Read by the promotion policy, never by the emitter: 8.3b promotes a
        /// subset, and 5.12c emits all of them.
        public var beliefDbfs: Double
        /// Two onsets closer together than this are one onset. ⚠ **Well under the
        /// ball-into-screen interval** (~9 ms at 3 m), because collapsing those
        /// two is exactly the suppression 5.12c forbids.
        public var refractoryNs: Int64
        /// The analysis hop. 1 ms at 48 kHz is 48 samples.
        public var hopNs: Int64
        /// REQ-OBS-4 — the device diagnostic mode. While it is on the floor drops
        /// and sub-threshold candidates are retained, so false *negatives* become
        /// diagnosable. ⛔ Default off, and the review's open point is answered
        /// here: it is a property of a detector built per session, so it expires
        /// with the session and cannot be left on since March.
        public var diagnosticMode: Bool

        public init(emissionFloorDbfs: Double = -38,
                    beliefDbfs: Double = -14,
                    refractoryNs: Int64 = 4_000_000,
                    hopNs: Int64 = 1_000_000,
                    diagnosticMode: Bool = false) {
            self.emissionFloorDbfs = emissionFloorDbfs
            self.beliefDbfs = beliefDbfs
            self.refractoryNs = refractoryNs
            self.hopNs = hopNs
            self.diagnosticMode = diagnosticMode
        }

        /// REQ-OBS-4's lowered floor: 12 dB below the ordinary one.
        public var effectiveFloorDbfs: Double {
            diagnosticMode ? emissionFloorDbfs - 12 : emissionFloorDbfs
        }
    }

    public var tuning: Tuning
    /// The last onset's instant, so the refractory period spans windows.
    private var lastOnsetNs: Int64?

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// Every onset in this window, in order. ⛔ Every one — the caller does not
    /// get to filter here, and there is no `minimumConfidence` parameter.
    public mutating func observe(_ window: AudioWindow) -> [AcousticOnset] {
        guard window.samples.isEmpty == false, window.sampleRate > 0 else { return [] }

        let hop = max(1, Int(Double(tuning.hopNs) * window.sampleRate / 1_000_000_000))
        var onsets: [AcousticOnset] = []
        var index = 0
        var previousDb = Self.dbfs(peak: window.samples, from: 0, count: hop)

        while index + hop <= window.samples.count {
            let db = Self.dbfs(peak: window.samples, from: index, count: hop)
            defer { previousDb = db; index += hop }

            // A rising edge that clears the floor. The *rise* matters as much as
            // the level: a steady loud room is not an onset.
            guard db >= tuning.effectiveFloorDbfs, db - previousDb >= 6 else { continue }

            let atNs = window.instantNs(ofSample: index)
            if let last = lastOnsetNs, atNs - last < tuning.refractoryNs { continue }
            lastOnsetNs = atNs

            let shape = Self.shape(window, aroundSample: index, hop: hop)
            onsets.append(AcousticOnset(rawNs: atNs,
                                        confidence: confidence(peakDbfs: db),
                                        classification: shape))
        }
        return onsets
    }

    /// The detector's own belief, `0...1`. ⚠ It is a **confidence**, not a
    /// verdict: 5.12 makes it mandatory on every Candidate including the ones the
    /// nominator does not believe, and a confidence of 0.1 is a legitimate value
    /// that says exactly what it means.
    private func confidence(peakDbfs db: Double) -> Double {
        let span = tuning.beliefDbfs - tuning.effectiveFloorDbfs
        guard span > 0 else { return db >= tuning.beliefDbfs ? 1 : 0 }
        return max(0, min(1, (db - tuning.effectiveFloorDbfs) / span))
    }

    /// Rise, decay, peak — and a label drawn from them.
    private static func shape(_ window: AudioWindow, aroundSample index: Int,
                              hop: Int) -> AcousticClassification {
        let lookahead = min(window.samples.count, index + hop * 60)
        let region = index..<lookahead
        var peak: Float = 0
        var peakIndex = index
        for i in region where abs(window.samples[i]) > peak {
            peak = abs(window.samples[i])
            peakIndex = i
        }
        let peakDb = Self.dbfs(peak)

        var riseStart = peakIndex
        while riseStart > index, abs(window.samples[riseStart]) > peak * 0.1 { riseStart -= 1 }
        var decayEnd = peakIndex
        while decayEnd < lookahead - 1, abs(window.samples[decayEnd]) > peak * 0.1 {
            decayEnd += 1
        }

        let nsPerSample = 1_000_000_000 / window.sampleRate
        let riseNs = Int64(Double(peakIndex - riseStart) * nsPerSample)
        let decayNs = Int64(Double(decayEnd - peakIndex) * nsPerSample)

        // ⛔ Tuning, and honestly labelled as such. A rise under 1 ms with a short
        // decay is the club-face signature; a rise over 20 ms is not a transient
        // at all and is far more likely a voice.
        let transient: AcousticClassification.Transient
        switch (riseNs, decayNs, peakDb) {
        case let (rise, decay, db) where rise < 1_000_000 && decay < 30_000_000 && db > -18:
            transient = .impact
        case let (rise, decay, _) where rise < 3_000_000 && decay > 40_000_000:
            transient = .screen
        case let (rise, _, db) where rise < 2_000_000 && db <= -18:
            transient = .mat
        case let (rise, _, _) where rise < 6_000_000:
            transient = .knock
        case let (rise, _, _) where rise >= 20_000_000:
            transient = .speech
        default:
            transient = .unknown
        }
        return AcousticClassification(transient: transient, peakDbfs: peakDb,
                                      riseNs: riseNs, decayNs: decayNs)
    }

    private static func dbfs(peak samples: [Float], from: Int, count: Int) -> Double {
        var peak: Float = 0
        let upper = min(samples.count, from + count)
        for index in from..<upper where abs(samples[index]) > peak { peak = abs(samples[index]) }
        return dbfs(peak)
    }

    private static func dbfs(_ amplitude: Float) -> Double {
        // ⚠ −120 dBFS as the floor for silence rather than −∞: an infinity in a
        // measurement that reaches a wire is a value nothing downstream can sort.
        guard amplitude > 1e-6 else { return -120 }
        return 20 * log10(Double(amplitude))
    }
}
