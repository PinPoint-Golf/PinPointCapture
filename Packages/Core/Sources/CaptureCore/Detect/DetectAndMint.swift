//  DetectAndMint.swift
//  The composition: audio in, Candidates out, Shots minted, clips extracted.
//
//  ⚠ **The order of operations is the specification's and not a convenience.**
//
//   1. The detector emits **every** onset (5.12c, 8.3b, I8).
//   2. The evidence Capture is created and its id is chosen **before** the
//      Candidate, because `Candidate.evidence_capture_id` names it (5.12.1a) and
//      5.12.1c makes an evicted or never-retained window `absent` with a reason
//      rather than a dangling reference.
//   3. The Candidate is nominated — all of them, including the ones this peer
//      does not believe (7.1d).
//   4. The Mint engine holds them until 8.2i's deadline, or mints straight away
//      where there is no arbitrating host (8.3a).
//   5. A minted Shot drives the clip extraction, and the clip's Capture is
//      attached to the Shot.
//
//  ⛔ **Steps 3 and 4 are different decisions and one of them is not a filter.**
//  Emission is unconditional; promotion is policy. Draft 1 of the specification
//  collapsed them and forced a wrong answer on a correct device — ball-into-screen
//  ~9 ms after impact minted a second Shot, and the device's only escape was to
//  suppress the second candidate, destroying the evidence candidate-attached
//  retention exists to preserve.
//
//  Spec: `CORE` §5.12, §5.12.1, §5.14, §8.1, §8.2i–j, §8.3; `MSG` §7. Plan D5.

import Foundation

/// Where the records this pipeline produces go — a bundle in the hostless case,
/// a live link in the hosted one, and both at once while a host is connected.
///
/// ⚠ It is the same three calls either way, which is what makes "live bytes are
/// bundle bytes" true of the *detector* as well as of the transport.
/// ⚠ **`Sendable`, and every conformer already claimed it.**
/// `CaptureSessionRecorder`, `LiveDetectionSink` and `CompositeDetectionSink` are
/// each `@unchecked Sendable` over state they serialise themselves, and
/// `DetectAndMint` — which holds one and is itself `@unchecked Sendable` — has
/// been carried across isolation domains on that basis since it was written.
/// Saying so on the protocol makes the existing arrangement checkable instead of
/// implicit, and is what lets a `capture_request` be answered from inside
/// `PeerLinkPump.perform`.
public protocol DetectionSink: AnyObject, Sendable {
    func record(candidate: PpcpCandidate) throws
    func record(shot: PpcpShot) throws
    func announce(_ assembly: CaptureAssembly, clip: CaptureSessionRecorder.ClipProvider?) throws
}

extension CaptureSessionRecorder: DetectionSink {}

/// Detect, nominate, promote, mint, extract.
public final class DetectAndMint: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var sessionId: String
        public var peerId: String
        /// 5.13c — `Shot.t0` is in `Session.timebase_ref`. ⚠ In a hostless session
        /// that is this device's own capture timebase, so the conversion is the
        /// identity (I4) and **no relation is asserted for it**.
        public var timebaseRefId: String
        /// 5.12.1a — a **separate** `audio` Stream. ⛔ Not muxed into the video
        /// capture: that would retain the full video window of room audio per
        /// shot for no diagnostic benefit, a privacy cost taken by accident.
        public var audioStream: PpcpStreamRecord
        public var videoStream: PpcpStreamRecord
        public var retention: CandidateAudioRetention
        /// The clip window around `t0`. ⛔ 5.11e puts the window length in the
        /// producing peer's hands and it appears nowhere in the specification
        /// (I14), so it is here and it is this application's.
        public var clipPreNs: Int64
        public var clipPostNs: Int64

        public init(sessionId: String, peerId: String, timebaseRefId: String,
                    audioStream: PpcpStreamRecord, videoStream: PpcpStreamRecord,
                    retention: CandidateAudioRetention = CandidateAudioRetention(),
                    clipPreNs: Int64 = 1_500_000_000,
                    clipPostNs: Int64 = 3_000_000_000) {
            self.sessionId = sessionId
            self.peerId = peerId
            self.timebaseRefId = timebaseRefId
            self.audioStream = audioStream
            self.videoStream = videoStream
            self.retention = retention
            self.clipPreNs = clipPreNs
            self.clipPostNs = clipPostNs
        }

        /// The window a shot carries with the default pre/post roll.
        ///
        /// ⚠ A7 printed a hardcoded `3.0` for this. The real figure is 4.5 —
        /// 1.5 s of pre-roll plus 3.0 s after — and a number a screen states
        /// about retention should come from the thing that does the retaining.
        public static let defaultClipWindowSeconds =
            Double(1_500_000_000 + 3_000_000_000) / 1_000_000_000

        /// How much video a shot would carry, in seconds.
        ///
        /// ⚠ A7 showed a hardcoded `3.0` for this. The real figure is the clip
        /// window this configuration actually uses, and it is not 3.0 — it is the
        /// pre-roll plus the post-roll. A number a screen states about retention
        /// should come from the thing that does the retaining.
        public var clipWindowSeconds: Double {
            Double(clipPreNs + clipPostNs) / 1_000_000_000
        }
    }

    /// What one audio window produced.
    public struct Detection: Sendable {
        public let candidate: PpcpCandidate
        /// The candidate-anchored evidence Capture, `absent` where the window was
        /// not retained.
        public let evidence: CaptureAssembly
        /// Whether this peer's own promotion policy believes it. ⚠ Reported, not
        /// acted on: the Mint engine takes the decision, and reporting it here is
        /// what lets a test assert I32 — that the *same* policy answers the
        /// hostless promotion and 8.2i's would-have-promoted test.
        public let wouldPromote: Bool
    }

    private let peer: DevicePeer
    private let sink: DetectionSink
    private let mint: DeviceMint
    private let factory: CandidateFactory
    private let configuration: Configuration
    private let promotion: PromotionPolicy
    private let mintCaptureId: @Sendable () -> String
    private var detector: AcousticOnsetDetector

    /// 5.12.1a — the audio window around one Candidate.
    private let extractAudio: @Sendable (Range<Int64>) -> ClipExtraction
    /// Everything the video Capture needs around one `t0`.
    ///
    /// ⚠ **One closure, because three had drifted apart from the builder they
    /// feed.** It was `extractVideo` + `videoExposure` + `videoPayload`, while
    /// `CaptureBuilder.shotCapture` wanted an extraction, an exposure,
    /// intrinsics AND a thermal timeline — so the last two had no way through
    /// and were silently absent from every Capture this application ever
    /// announced. `RetainedClip` mirrors the builder exactly.
    ///
    /// ⚠ Its `payload` is a provider, not bytes: the Capture id is minted inside
    /// `pump` so nothing could have been registered against it beforehand, and
    /// `ENC` 7c holds the bytes until after the manifest.
    private let videoClip: @Sendable (Range<Int64>) -> RetainedClip

    public init(peer: DevicePeer,
                sink: DetectionSink,
                mint: DeviceMint,
                factory: CandidateFactory,
                configuration: Configuration,
                detector: AcousticOnsetDetector = AcousticOnsetDetector(),
                promotion: @escaping PromotionPolicy,
                mintCaptureId: @escaping @Sendable () -> String
                    = { UUID().uuidString.lowercased() },
                extractAudio: @escaping @Sendable (Range<Int64>) -> ClipExtraction,
                videoClip: @escaping @Sendable (Range<Int64>) -> RetainedClip) {
        self.peer = peer
        self.sink = sink
        self.mint = mint
        self.factory = factory
        self.configuration = configuration
        self.detector = detector
        self.promotion = promotion
        self.mintCaptureId = mintCaptureId
        self.extractAudio = extractAudio
        self.videoClip = videoClip
    }

    /// One window of microphone audio, all the way to nomination.
    ///
    /// ⚠ Kept for the hostless path and the conformance harness, where nothing
    /// is serialised behind a link peer. **A hosted session must use `detect`
    /// and `nominate` separately** — see their notes.
    @discardableResult
    public func observe(_ window: AudioWindow) throws -> [Detection] {
        let detections = try detect(window)
        try nominate(detections)
        return detections
    }

    /// Everything about a window that does **not** touch the peer.
    ///
    /// ⛔ **Split out because it was costing a link its throughput.** With a host,
    /// the Mint engine lives on the link peer and every call into it must go
    /// through `PeerLinkPump.perform`, which is a single serialised door shared
    /// with sync, liveness, flushes and the transfer drain. Running the detector
    /// *inside* that door made every 100 ms audio window an actor round trip —
    /// and nine windows in ten produce nothing at all.
    ///
    /// ⛔ Worse, `extractAudio` reaches the ring through `sampleQueue.sync`, so a
    /// window with an onset blocked the socket on a camera queue saturated at
    /// 238 fps. Measured on hardware, 27 Aug: audio windows queued for ~24
    /// seconds, minting ran long after each `t0` had rolled out of a ten-second
    /// ring, and every Capture came out `absent` with no clip. The ring was
    /// fine; the door was the problem.
    public func detect(_ window: AudioWindow) throws -> [Detection] {
        var detections: [Detection] = []
        for onset in detector.observe(window) {
            // Step 2 — the evidence Capture id is minted first, because the
            // Candidate names it.
            let evidenceId = mintCaptureId()
            let extraction = extractAudio(configuration.retention.window(around: onset.rawNs))
            let evidence = CaptureBuilder.candidateCapture(
                id: evidenceId,
                candidateId: "",              // replaced below; see the note
                stream: configuration.audioStream,
                extraction: extraction,
                exposure: .noExposure)

            let candidate = try factory.candidate(from: onset,
                                                  evidenceCaptureId: evidenceId)
            // ⚠ The anchor has to name the Candidate and the Candidate has to name
            // the Capture, so one of the two ids is chosen before the object that
            // carries it. The Capture is rebuilt here rather than mutated, because
            // `PpcpCaptureAnchor` has one case per anchor and no setter — I27 made
            // structural one layer up.
            var record = evidence.record
            record.anchor = .candidate(candidate.id)
            let anchored = CaptureAssembly(record: record,
                                           achievedFrames: evidence.achievedFrames)

            // The instant on this device's own clock, kept for the ring.
            heardAt[candidate.id] = candidate.atNs
            detections.append(Detection(candidate: candidate, evidence: anchored,
                                        wouldPromote: promotion(candidate)))
        }
        return detections
    }

    /// Candidate id → when this device **heard** it, in its own capture clock.
    ///
    /// ⛔ **Kept so the ring is never indexed through the host's clock.** A
    /// Shot's `t0` is in `Session.timebase_ref` (5.13c) and converting it back
    /// is not free: the relation carries an offset *and* a rate, and applying
    /// that rate across the gap between two machines' boot origins turns a few
    /// ppm of skew error into tens of seconds. Measured on hardware, 27 Aug: a
    /// 6752 s baseline produced a `t0` **47 seconds in the future**, while the
    /// sync estimator reported 0.0 ms agreement.
    ///
    /// ⚠ The Candidate's own instant needs no conversion at all — it is what
    /// this device's microphone heard, on the same clock the ring indexes, and
    /// already corrected for time of flight. The round trip could only ever lose
    /// precision; this keeps the authoritative `t0` on the wire and the local
    /// instant for local use, which is what I1 is about.
    private var heardAt: [String: Int64] = [:]

    /// When this device heard the ball for a Shot it minted, in capture time.
    public func captureInstant(forShot shot: PpcpShot) -> Int64? {
        for candidateId in shot.candidateIds {
            if let atNs = heardAt[candidateId] { return atNs }
        }
        return nil
    }

    /// The three sends, and nothing else.
    ///
    /// ⛔ **Every line here touches the peer**, so with a host this is the only
    /// part that belongs inside `perform`. 7.1d — every nomination is emitted,
    /// including the ones this peer's own promotion policy would not have
    /// promoted; `wouldPromote` is reported, never used to filter.
    public func nominate(_ detections: [Detection]) throws {
        for detection in detections {
            try sink.announce(detection.evidence, clip: nil)
            try sink.record(candidate: detection.candidate)
            try mint.observe(own: detection.candidate)
        }
    }

    /// 8.2i–j / 8.3a — mint what is due and extract a clip for each Shot.
    ///
    /// - Parameter nowRefNs: a reading of `Session.timebase_ref`.
    /// - Returns: the Shots minted by this call, each already carrying its clip's
    ///   Capture id.
    @discardableResult
    public func pump(nowRefNs: Int64) throws -> [PpcpShot] {
        // ⚠ The hostless path only: `Session.timebase_ref` IS this device's
        // capture timebase there, so `t0` is already in capture terms (I4).
        let due = try mintDue(nowRefNs: nowRefNs)
        return try commit(extract(due, captureT0Ns: due.map(\.t0Ns)))
    }

    /// A Shot the mint deadline has made due, and nothing more.
    ///
    /// ⛔ Touches the peer: `ppcp_mint_pump` reads `timebase_ref`, the session id
    /// and the relation set off it, and sends the Shot under 8.2j.
    public func mintDue(nowRefNs: Int64) throws -> [PpcpShot] {
        try mint.pump(nowRefNs: nowRefNs)
    }

    /// A Shot, its clip, and the Capture that describes it.
    public struct PendingShot: Sendable {
        public var shot: PpcpShot
        public let assembly: CaptureAssembly
        public let clip: CaptureSessionRecorder.ClipProvider?
        /// The window asked of the ring, in **capture** time.
        ///
        /// ⚠ Carried so a Capture that came back `absent` can say what it asked
        /// for. "No clip" has meant four different things on hardware today and
        /// the record alone cannot tell them apart: an interval in the wrong
        /// clock, an interval that has rolled out, a ring that was not
        /// retaining, and a write that failed.
        public let requestedNs: Range<Int64>
    }

    /// The expensive half, and **none of it touches the peer**.
    ///
    /// ⛔ **`videoClip` reaches the ring through `sampleQueue.sync` and then
    /// writes the clip to disk.** Running that inside `PeerLinkPump.perform`
    /// held the link's only door for as long as tens of megabytes took to
    /// materialise, behind which sync, liveness and every candidate queued. It
    /// is the caller's job to run this outside.
    /// - Parameter captureT0Ns: `shot.t0Ns` expressed in **this device's capture
    ///   timebase**, one per shot and in the same order.
    ///
    ///   ⛔ **Not `shot.t0Ns`, and the difference is not cosmetic.** 5.13c puts a
    ///   Shot's `t0` in `Session.timebase_ref`. Hostless that is this device's
    ///   own capture clock and the conversion is the identity (I4); **with a
    ///   host it is the host's clock**, whose since-boot origin has nothing to do
    ///   with ours. Handing that number to the ring asks for an interval hours
    ///   from anything it holds, which answers `outside_buffer` — a Capture with
    ///   no bytes, and a session of shots marked "timed, not filmed". Measured on
    ///   hardware, 27 Aug: every clip absent, every displayed time ~2 hours wrong.
    public func extract(_ shots: [PpcpShot], captureT0Ns: [Int64]) -> [PendingShot] {
        zip(shots, captureT0Ns).map { shot, t0Ns in
            let lower = t0Ns - configuration.clipPreNs
            let upper = t0Ns + configuration.clipPostNs
            let clip = videoClip(lower..<upper)
            let assembly = CaptureBuilder.shotCapture(
                id: mintCaptureId(),
                shotId: shot.id,
                stream: configuration.videoStream,
                extraction: clip.extraction,
                exposure: clip.exposure,
                intrinsics: clip.intrinsics,
                thermal: clip.thermal)
            // ⛔ `absent` is a **result, not a failure** (I10, 8.4b). A ring that
            // no longer holds the interval answers `outside_buffer` and the Shot
            // still exists — a Shot with no Capture is a legitimate record.
            let isAbsent = assembly.record.completeness == PpcpCaptureRecord.Completeness.absent
            return PendingShot(shot: shot, assembly: assembly,
                               clip: isAbsent ? nil : clip.payload,
                               requestedNs: lower..<upper)
        }
    }

    /// The announce and the Shot's extension, both of which touch the peer.
    @discardableResult
    public func commit(_ pending: [PendingShot]) throws -> [PpcpShot] {
        // ⚠ A Shot that has been minted will not be extracted again.
        for entry in pending {
            for candidateId in entry.shot.candidateIds { heardAt[candidateId] = nil }
        }
        var minted: [PpcpShot] = []
        for var entry in pending {
            try sink.announce(entry.assembly, clip: entry.clip)
            try entry.shot.add(captureId: entry.assembly.record.id)
            try sink.record(shot: entry.shot)
            minted.append(entry.shot)
        }
        return minted
    }

}

// MARK: - The promotion policy this application ships

public extension DetectAndMint {

    /// ⛔ **Detector tuning, and 8.3c keeps it out of the specification.** It is
    /// here so there is exactly one of it: I32 requires that the *same* policy
    /// answers the hostless promotion and 8.2i's would-have-promoted test, and two
    /// copies would eventually disagree — at which point a device with a host
    /// would mint Shots it would not have minted without one, which is precisely
    /// the defect 8.2i was written to close.
    static func defaultPromotion(_ tuning: AcousticOnsetDetector.Tuning
                                 = AcousticOnsetDetector.Tuning()) -> PromotionPolicy {
        { candidate in
            guard let classification = candidate.classification else {
                // No taxonomy: fall back to the bare confidence. ⚠ Not "reject" —
                // a Candidate this peer nominated with high confidence and no
                // classifier is still one it believes.
                return candidate.confidence >= 0.75
            }
            switch classification.transient {
            case .impact:
                return candidate.confidence >= 0.6
            case .screen, .mat, .knock, .speech:
                // ⛔ Emitted, retained, evidenced — and **not promoted**. This is
                // the branch Draft 1 could not express, and it is why the
                // ball-into-screen transient no longer mints a second Shot.
                return false
            case .unknown:
                return candidate.confidence >= 0.9
            }
        }
    }
}

public extension ExposureObservation {

    /// For a Capture on a Stream whose profile has **no `format`** — an `audio`
    /// window, an IMU segment, or an `absent` video Capture that has no frames
    /// to have been exposed.
    ///
    /// ⚠ `CORE` 6.1d fixes `convention: mid` there and the canonical instant is
    /// the raw one, so there is no `d` to carry and no conversion to feed. Zero is
    /// the honest value for a quantity that does not exist in that Stream, and
    /// `locked_constant` is the honest provenance: the value did not vary, because
    /// there was never one to vary.
    static var noExposure: ExposureObservation { .lockedConstant(0) }
}
