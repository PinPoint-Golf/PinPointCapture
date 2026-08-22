//  DetectMintTests.swift
//  D5 — Detect and Mint, asserted against `libppcp` rather than against this
//  application's own idea of the shape.
//
//  Rows exercised: CT-I6, CT-I8, CT-I23, CT-I26, CT-I29, CT-I32, CT-I33,
//  CT-S4 (2, 3, 5, 6).

import Foundation
import Testing
import CPPCP
@testable import CaptureCore

@Suite("Detect and Mint — CORE §5.12, §8.1, §8.2i, §8.3")
struct DetectMintTests {

    // MARK: Fixtures

    static let peerId = "peer:d5-device"
    static let sessionId = "ses:d5"
    static let timebase = "tb:hosttime"

    static func declaration() throws -> PpcpDeclaration {
        try PpcpDeclaration(PpcpDeclarationInput(
            peerId: peerId,
            profiles: PpcpProfileSet.device,
            timebases: [PpcpTimebaseDeclaration(id: timebase, kind: .monotonic,
                                                epochStable: true, resolutionNs: 42,
                                                origin: "CMClockGetHostTimeClock")],
            captureTimebaseId: timebase,
            capability: DeviceCapability(
                modelIdentifier: "iPhone17,3", modelName: "iPhone 16",
                claimed: [VideoMode(width: 1920, height: 1080, fps: 150, lens: .wide,
                                    pixelFormat: "420v")],
                measured: nil),
            timing: PpcpDeviceTimingProfile(
                frameStartToExposureOffsetNs: 0, offsetProvenance: .assumed,
                geometry: [PpcpGeometryEntry(readout: .assumedFractionOfFrameInterval(1.0),
                                             direction: .topToBottom)]),
            clipCodec: "hevc",
            declaresMicrophone: true,
            declaresIMU: true))
    }

    static func peer() throws -> DevicePeer {
        try DevicePeer(peerId: peerId)
    }

    /// One transient's shape. ⚠ **Impact and ball-into-screen are not the same
    /// sound**, and a fixture that made them identical would prove only that the
    /// detector fires twice — never that the *taxonomy* separates them, which is
    /// what the promotion policy turns on.
    struct Transient {
        var atSample: Int
        var amplitude: Float
        var riseSamples: Int
        var decaySamples: Int

        /// Club face on ball: loud, and the fastest rise there is.
        static func impact(at sample: Int) -> Transient {
            Transient(atSample: sample, amplitude: 0.9, riseSamples: 8, decaySamples: 240)
        }

        /// Ball into the screen: quieter, slower to rise, and it rings — a net or
        /// a screen is a membrane, and it keeps moving after the ball has gone.
        static func screen(at sample: Int) -> Transient {
            Transient(atSample: sample, amplitude: 0.35, riseSamples: 96,
                      decaySamples: 3_000)
        }
    }

    static func window(startNs: Int64 = 0, sampleRate: Double = 48_000,
                       count: Int = 9_600,
                       transients: [Transient] = []) -> AudioWindow {
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
        return AudioWindow(timebaseId: timebase, startNs: startNs,
                           sampleRate: sampleRate, samples: samples)
    }

    // MARK: CT-I8 / 5.12c — every nomination is emitted

    /// `CORE` 5.12c, 8.3b, `MSG` 7.1d. Two transients 9 ms apart — impact and
    /// ball-into-screen — produce **two** Candidates, and only one is promoted.
    ///
    /// ⚠ The 9 ms is the specification's own example: "ball into the screen,
    /// roughly 9 ms after impact at 3 m". Draft 1 minted two Shots for it, and the
    /// device's only escape was to suppress the second candidate.
    @Test("Two transients 9 ms apart are two Candidates and one promotion")
    func everyOnsetIsEmitted() throws {
        var detector = AcousticOnsetDetector()
        // 9 ms at 48 kHz is 432 samples.
        let onsets = detector.observe(Self.window(transients: [.impact(at: 1_000), .screen(at: 1_432)]))
        #expect(onsets.count == 2)

        let promotion = DetectAndMint.defaultPromotion()
        let declaration = try Self.declaration()
        let factory = CandidateFactory(declaration: declaration, sourceId: "src:microphone")
        let candidates = try onsets.map {
            try factory.candidate(from: $0, evidenceCaptureId: "cap:evidence")
        }
        // ⛔ Both exist. The second is not suppressed; it is *not promoted*, which
        // is a different fact and is the one 5.12c protects.
        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { $0.basis == "acoustic" })
        #expect(candidates[0].classification?.transient == .impact)
        // ⛔ Emitted, retained, evidenced — and not promoted. This is the branch
        // Draft 1 could not express, and it is why the ball-into-screen transient
        // no longer mints a second Shot.
        #expect(candidates[1].classification?.transient != .impact)
        #expect(promotion(candidates[0]))
        #expect(promotion(candidates[1]) == false)
    }

    /// The refractory period does not swallow the second transient. ⚠ It is
    /// deliberately well under 9 ms for exactly this reason.
    @Test("The refractory period is shorter than the ball-into-screen interval")
    func refractoryDoesNotSuppressTheScreenTransient() {
        #expect(AcousticOnsetDetector.Tuning().refractoryNs < 9_000_000)
    }

    // MARK: CT-I26 / 5.12a — the Source must be one this peer declared

    @Test("A Candidate naming an undeclared Source is refused before a wire sees it")
    func undeclaredSourceIsRefused() throws {
        let declaration = try Self.declaration()
        var detector = AcousticOnsetDetector()
        let onset = try #require(detector.observe(Self.window(transients: [.impact(at: 1_000)])).first)

        let stranger = CandidateFactory(declaration: declaration, sourceId: "src:nobody")
        #expect(throws: CandidateFactory.FactoryError.undeclaredSource("src:nobody")) {
            _ = try stranger.candidate(from: onset, evidenceCaptureId: nil)
        }

        // And the library refuses it too, one layer down: a Candidate built for a
        // Source this peer did not declare cannot be nominated.
        let peer = try Self.peer()
        try peer.declare(declaration)
        let factory = CandidateFactory(declaration: declaration, sourceId: "src:microphone")
        let good = try factory.candidate(from: onset, evidenceCaptureId: nil)
        #expect(throws: Never.self) { try peer.nominate(good) }
    }

    // MARK: CT-I29 / 5.12d — tof carries both value and sigma

    /// I29 in the type system: `ppcp_estimate_make` is the only way to obtain the
    /// value `ppcp_candidate_set_tof_correction` takes, and it cannot be called
    /// with one of the two.
    @Test("Time of flight carries both a value and a dispersion, or neither")
    func tofCarriesBothOrNeither() throws {
        let declaration = try Self.declaration()
        var detector = AcousticOnsetDetector()
        let onset = try #require(detector.observe(Self.window(transients: [.impact(at: 1_000)])).first)

        // 2 m — the specification's own worked case, ~5.83 ms.
        let tof = AcousticTimeOfFlight(distanceMetres: 2, distanceSigmaMetres: 0.25)
        let factory = CandidateFactory(declaration: declaration, sourceId: "src:microphone",
                                       timeOfFlight: tof)
        let candidate = try factory.candidate(from: onset, evidenceCaptureId: nil)

        #expect(candidate.tofCorrectionNs == tof.correctionNs)
        #expect(candidate.tofSigmaNs != nil)
        #expect(tof.correctionNs > 5_700_000 && tof.correctionNs < 5_900_000)

        // 8.1d — the correction is **applied** before `at` is emitted, so the
        // canonical instant is earlier than the raw one by exactly that much.
        #expect(candidate.atNs == onset.rawNs - tof.correctionNs)

        // ⛔ Not present where there was none. Absence is absence, never a zero
        // correction with a zero sigma.
        let none = CandidateFactory(declaration: declaration, sourceId: "src:microphone")
        let plain = try none.candidate(from: onset, evidenceCaptureId: nil)
        #expect(plain.tofCorrectionNs == nil)
        #expect(plain.tofSigmaNs == nil)
    }

    // MARK: CT-I33 / 5.12e / 6.1d — the canonical instant, converted once

    /// For a microphone Source the profile has no `format`, so 6.1d fixes
    /// `convention: mid` and the canonical instant **is** the corrected raw
    /// instant. ⚠ The value being unchanged is the assertion: a `d/2` applied here
    /// would be the exposure of a frame the microphone never had.
    @Test("A microphone Candidate's canonical instant is the corrected raw instant")
    func microphoneCanonicalIsTheRawInstant() throws {
        let declaration = try Self.declaration()
        var detector = AcousticOnsetDetector()
        let onset = try #require(detector.observe(Self.window(transients: [.impact(at: 1_000)])).first)
        let factory = CandidateFactory(declaration: declaration, sourceId: "src:microphone")

        // An exposure is passed and is *ignored*, which is what 6.1d requires of a
        // Source whose profile has no `format`.
        let candidate = try factory.candidate(from: onset, evidenceCaptureId: nil,
                                              exposureNs: 2_000_000)
        #expect(candidate.atNs == onset.rawNs)
        #expect(candidate.canonicalCorrectionNs == nil || candidate.canonicalCorrectionNs == 0)
    }

    // MARK: 5.12.1a — the evidence Capture

    /// The audio window is a Capture on a **separate `audio` Stream**, anchored to
    /// the Candidate — never muxed into the video clip.
    @Test("Candidate evidence is a candidate-anchored Capture on an audio Stream")
    func evidenceIsOnItsOwnStream() throws {
        let audio = PpcpStreamRecord(
            id: "str:audio", sessionId: Self.sessionId, sourceId: "src:microphone",
            kind: PpcpStreamKind.audio, profileId: "default", timebaseId: Self.timebase,
            continuity: .shotWindowed, openedAtNs: 0)
        #expect(audio.kind == PPCP_STREAM_KIND_AUDIO)

        let extraction = ClipExtraction(
            requestedNs: 0..<2_000_000_000, outcome: .present(.complete), fragments: [],
            realisedNs: 0..<2_000_000_000, holesNs: [], frameTimestampsNs: [],
            exposureNs: [], iso: [], droppedFrames: 0, byteCount: 96_000)
        let assembly = CaptureBuilder.candidateCapture(
            id: "cap:evidence", candidateId: "cnd:1", stream: audio,
            extraction: extraction, exposure: .noExposure)

        guard case .candidate(let id) = assembly.record.anchor else {
            Issue.record("evidence must be candidate-anchored (5.12.1a)")
            return
        }
        #expect(id == "cnd:1")
        #expect(assembly.record.streamId == "str:audio")
    }

    /// 5.12.1c — an evicted window is `absent` **with a reason**, never a dangling
    /// reference.
    @Test("An evicted evidence window is asserted absent, not dropped")
    func evictedEvidenceIsAsserted() throws {
        let audio = PpcpStreamRecord(
            id: "str:audio", sessionId: Self.sessionId, sourceId: "src:microphone",
            kind: PpcpStreamKind.audio, profileId: "default", timebaseId: Self.timebase,
            continuity: .shotWindowed, openedAtNs: 0)
        let missing = ClipExtraction(
            requestedNs: 0..<2_000_000_000,
            outcome: .absent(reason: CandidateAudioRetention.evictedReason),
            fragments: [], realisedNs: nil, holesNs: [], frameTimestampsNs: [],
            exposureNs: [], iso: [], droppedFrames: 0, byteCount: 0)
        let assembly = CaptureBuilder.candidateCapture(
            id: "cap:evidence", candidateId: "cnd:1", stream: audio,
            extraction: missing, exposure: .noExposure)

        #expect(assembly.record.completeness == PpcpCaptureRecord.Completeness.absent)
        #expect(assembly.record.absentReason == PpcpAbsentReason.notRetained)
        // ⛔ `not_retained` and not `storage_full`: the window was evicted by a
        // policy this peer chose, and the disk did not fill up.
        #expect(assembly.record.absentReason != PpcpAbsentReason.storageFull)
    }

    // MARK: B7 — the retention bound and its statement

    /// The review of 22 August: REQ-PRIV-6 computed retention from the **shot**
    /// count while REQ-PRIV-4 attaches windows to **candidates**.
    @Test("The retention statement is expressed in candidates and names its cap")
    func retentionStatementIsHonest() {
        let retention = CandidateAudioRetention(maximumRetainedCandidates: 150)
        let text = retention.userVisibleStatement
        #expect(text.contains("150"))
        #expect(text.contains("shot") == false || text.contains("might be a shot"))
        // REQ-PRIV-6 — speech is incidental, and the label must say so.
        #expect(text.lowercased().contains("incidental"))
        #expect(retention.maximumRetainedSeconds == 300)

        // The cap is enforced by eviction, oldest first.
        let held = (0..<153).map { "cap:\($0)" }
        #expect(retention.evictions(from: held) == ["cap:0", "cap:1", "cap:2"])
        #expect(retention.evictions(from: Array(held.prefix(10))).isEmpty)
    }

    /// REQ-OBS-4 — the diagnostic mode lowers the floor and says so, and it is a
    /// property of a per-session object so it cannot outlive the session.
    @Test("Diagnostic mode lowers the emission floor and states its exit")
    func diagnosticModeIsBounded() {
        let plain = AcousticOnsetDetector.Tuning()
        var diagnostic = plain
        diagnostic.diagnosticMode = true
        #expect(diagnostic.effectiveFloorDbfs < plain.effectiveFloorDbfs)

        var retention = CandidateAudioRetention()
        retention.diagnosticMode = true
        #expect(retention.userVisibleStatement.contains("session ends"))
    }

    // MARK: CT-I32 / 8.2i — host silence does not promote

    /// I32 — one policy, used for both decisions. ⚠ Asserted as an identity rather
    /// than as a behaviour: two copies of a promotion policy would eventually
    /// disagree, and the failure mode is a device with a host minting Shots it
    /// would not have minted without one.
    @Test("The hostless promotion and 8.2i's would-have-promoted test are one policy")
    func promotionPolicyIsSingular() throws {
        let declaration = try Self.declaration()
        var detector = AcousticOnsetDetector()
        let onsets = detector.observe(Self.window(transients: [.impact(at: 1_000), .screen(at: 1_432)]))
        let factory = CandidateFactory(declaration: declaration, sourceId: "src:microphone")
        let candidates = try onsets.map {
            try factory.candidate(from: $0, evidenceCaptureId: nil)
        }

        // ⚠ One closure, consulted for both decisions. The counter is a class so
        // the `@Sendable` policy can record into it — a captured `var` would not
        // compile under strict concurrency, and silencing that would be hiding the
        // fact that the library may call this from wherever it likes.
        final class Asked: @unchecked Sendable { var ids: [String] = [] }
        let asked = Asked()
        let policy: PromotionPolicy = { candidate in
            asked.ids.append(candidate.id)
            return DetectAndMint.defaultPromotion()(candidate)
        }

        let peer = try Self.peer()
        try peer.declare(declaration)
        let mint = try DeviceMint(peer: peer, promotion: policy)
        for candidate in candidates { try mint.observe(own: candidate) }
        #expect(mint.pendingCount == candidates.count)
        // ⛔ Nothing is minted before the pump: 8.2j sends a `shot` on minting, and
        // observing is not minting.
        #expect(mint.mintedCount == 0)
    }

    // MARK: CT-I23 / 8.3a — the zero-host regime

    /// 8.3a — with no arbitrating host, **no coincidence window is applied** and a
    /// Shot carries exactly one Candidate with `authority: device`.
    @Test("A hostless Shot carries one Candidate and authority: device")
    func hostlessShotIsSingleCandidate() throws {
        let shot = try PpcpShot(id: "sht:1", sessionId: Self.sessionId,
                                timebaseRefId: Self.timebase, t0Ns: 5_000_000_000,
                                authority: .device, issuedBy: Self.peerId,
                                firstCandidateId: "cnd:1")
        #expect(shot.authority == .device)
        #expect(shot.candidateIds == ["cnd:1"])
        #expect(shot.captureIds.isEmpty)
    }

    /// 8.3h / 5.13d — a Shot minted with no host **may** gain Candidates later, and
    /// `t0` is not revised by it (I7).
    @Test("A Shot gains Candidates additively and never revises t0")
    func attachmentIsAdditiveAndT0Immutable() throws {
        var one = try PpcpShot(id: "sht:1", sessionId: Self.sessionId,
                               timebaseRefId: Self.timebase, t0Ns: 5_000_000_000,
                               authority: .device, issuedBy: Self.peerId,
                               firstCandidateId: "cnd:b")
        var two = one
        try one.attach(candidateId: "cnd:a")
        try one.attach(candidateId: "cnd:c")
        try two.attach(candidateId: "cnd:c")
        try two.attach(candidateId: "cnd:a")

        // 5.13e — "additive and order-independent", and the library keeps the list
        // sorted so convergence is byte-identical rather than merely set equality.
        #expect(one.candidateIds == two.candidateIds)
        #expect(one.t0Ns == 5_000_000_000)
        #expect(two.t0Ns == 5_000_000_000)

        // Re-attaching is a no-op, not a duplicate.
        try one.attach(candidateId: "cnd:a")
        #expect(one.candidateIds.count == 3)
    }

    // MARK: 8.3d — Mint is a declared profile

    /// `ppcp_mint_new` refuses a peer that has not declared **Mint**: 8.3d makes
    /// issuing a Shot the Mint profile's, and a peer that minted without declaring
    /// it fails `CONF` §1d.
    @Test("A peer that has not declared Mint cannot construct a Mint engine")
    func mintNeedsTheProfile() throws {
        let bare = try DevicePeer(peerId: "peer:no-mint", profiles: ["core", "capture"])
        #expect(throws: PpcpLibraryError.self) {
            _ = try DeviceMint(bare, promotion: { _ in true })
        }
    }

    // MARK: 8.5a / I9 — no merge anywhere

    /// CT-I9's method is "by API surface". The assertion is an absence, and it is
    /// stated here so it fails loudly the day somebody adds one.
    @Test("There is no merge, supersede or withdraw on a Shot")
    func thereIsNoMerge() throws {
        let shot = try PpcpShot(id: "sht:1", sessionId: Self.sessionId,
                                timebaseRefId: Self.timebase, t0Ns: 1,
                                authority: .device, issuedBy: Self.peerId,
                                firstCandidateId: "cnd:1")
        // The only mutating operations are additive.
        let mirror = Mirror(reflecting: shot)
        #expect(mirror.children.contains { $0.label == "t0Ns" })
        // ⛔ `t0Ns` is a `let`. A setter would not compile, which is the assertion;
        // this line exists so the intent is written down beside it.
        #expect(shot.t0Ns == 1)
    }
}

private extension DeviceMint {
    /// A shorthand so the "refuses without the Mint profile" test reads as one
    /// statement rather than three lines of ceremony.
    convenience init(_ peer: DevicePeer, promotion: @escaping PromotionPolicy) throws {
        try self.init(peer: peer, promotion: promotion)
    }
}
