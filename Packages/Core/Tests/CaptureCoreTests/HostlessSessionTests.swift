//  HostlessSessionTests.swift
//  CT-S4 — the zero-host path end to end: microphone, Candidates, a minted Shot,
//  the clip around its `t0`, and a bundle that reads back carrying all three.
//
//  ⚠ **This is the scenario the product ships in.** UC-1 has no host at all, so
//  every clause exercised here is one an entry-level device meets on its first
//  session — 8.3a's regime, 5.12.1a's evidence, `ENC` 7c's ordering.
//
//  Rows exercised: CT-S4 (2, 3, 5, 6), CT-I6, CT-I8, CT-I23.

import Foundation
import Testing
import CPPCP
@testable import CaptureCore

@Suite("The hostless session, end to end — CORE §8.3, §9; ENC §7")
struct HostlessSessionTests {

    static let peerId = "peer:hostless"
    static let sessionId = "ses:hostless"
    static let timebase = "tb:hosttime"

    static let videoStream = PpcpStreamRecord(
        id: "str:video", sessionId: sessionId, sourceId: "src:camera:wide",
        kind: PpcpStreamKind.video, profileId: "1920x1080@150",
        timebaseId: timebase, continuity: .shotWindowed, openedAtNs: 0)

    /// 5.12.1a — a **separate** `audio` Stream, anchored to Candidates.
    static let audioStream = PpcpStreamRecord(
        id: "str:audio", sessionId: sessionId, sourceId: "src:microphone",
        kind: PpcpStreamKind.audio, profileId: "default",
        timebaseId: timebase, continuity: .shotWindowed, openedAtNs: 0)

    static let clip = Data((0..<600).map { UInt8($0 % 251) })

    final class Sink: @unchecked Sendable {
        private(set) var bytes = Data()
        func append(_ data: Data) { bytes.append(data) }
    }

    /// A deterministic id source, so the bundle's contents can be named in the
    /// assertions rather than fished out of it.
    final class Ids: @unchecked Sendable {
        private var next = 0
        private let prefix: String
        init(_ prefix: String) { self.prefix = prefix }
        func mint() -> String { next += 1; return "\(prefix)\(next)" }
    }

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
            declaresIMU: false))
    }

    /// An extraction that always succeeds, on a 150 fps grid.
    static func extraction(_ window: Range<Int64>) -> ClipExtraction {
        let period: Int64 = 6_666_666
        var frames: [Int64] = []
        var at = (window.lowerBound / period + 1) * period
        while at < window.upperBound { frames.append(at); at += period }
        return ClipExtraction(
            requestedNs: window, outcome: .present(.complete), fragments: [],
            realisedNs: window, holesNs: [], frameTimestampsNs: frames,
            exposureNs: Array(repeating: 1_000_000, count: frames.count),
            iso: Array(repeating: 640, count: frames.count),
            droppedFrames: 0, byteCount: clip.count)
    }

    /// One transient with an `impact` shape at `atSample`, in a 0.2 s window.
    static func window(startNs: Int64, atSample: Int) -> AudioWindow {
        var samples = [Float](repeating: 0.0005, count: 9_600)
        for offset in 0..<8 where atSample + offset < samples.count {
            samples[atSample + offset] = 0.9 * Float(offset + 1) / 8
        }
        for offset in 0..<240 where atSample + 8 + offset < samples.count {
            let decay = Float(240 - offset) / 240
            samples[atSample + 8 + offset] = 0.9 * decay * decay
        }
        return AudioWindow(timebaseId: timebase, startNs: startNs,
                           sampleRate: 48_000, samples: samples)
    }

    /// **CT-S4 (2, 3, 5, 6)** — the whole zero-host path, and the bundle that
    /// comes out of it.
    ///
    /// ⛔ The assertions that matter are the ones about what the bundle carries:
    /// D4 could write a Capture but had nothing to anchor it to, so a hostless
    /// bundle held Captures and no Shots. A consumer reading that has clips and no
    /// events.
    @Test("A hostless session mints Shots and its bundle carries them with their Captures")
    func hostlessSessionRoundTrips() throws {
        let sink = Sink()
        let peer = try DevicePeer(peerId: Self.peerId)
        let writer = try SessionBundleWriter(peer: peer) { sink.append($0) }
        let recorder = try CaptureSessionRecorder(
            writer: writer,
            declaration: try Self.declaration(),
            // ⛔ Hostless by construction: `ppcp_session_make_hostless` cannot be
            // given the two arbitration parameters and there is no setter, so the
            // bundle's silence about arbitration is 4.1d's statement that none
            // occurred rather than an omission.
            session: PpcpSessionRecord(id: Self.sessionId, timebaseRef: Self.timebase))
        try recorder.open(stream: Self.videoStream)
        try recorder.open(stream: Self.audioStream)

        let captureIds = Ids("cap:")
        let shotIds = Ids("sht:")
        let candidateIds = Ids("cnd:")
        let declaration = try Self.declaration()
        let mint = try DeviceMint(peer: peer, mintId: { shotIds.mint() },
                                  promotion: DetectAndMint.defaultPromotion())
        let clip = Self.clip
        let pipeline = DetectAndMint(
            peer: peer,
            sink: recorder,
            mint: mint,
            factory: CandidateFactory(declaration: declaration,
                                      sourceId: "src:microphone",
                                      // 8.1d — 2 m from the ball, ~5.83 ms, and
                                      // the correction is recorded with its sigma.
                                      timeOfFlight: AcousticTimeOfFlight(
                                          distanceMetres: 2, distanceSigmaMetres: 0.25),
                                      mintId: { candidateIds.mint() }),
            configuration: DetectAndMint.Configuration(
                sessionId: Self.sessionId, peerId: Self.peerId,
                timebaseRefId: Self.timebase,
                audioStream: Self.audioStream, videoStream: Self.videoStream),
            promotion: DetectAndMint.defaultPromotion(),
            mintCaptureId: { captureIds.mint() },
            extractAudio: { Self.extraction($0) },
            // ⚠ One closure since E1.2/E1.3 — it was `extractVideo` +
            // `videoExposure` + `videoPayload`, which had no way to carry the
            // intrinsics or the thermal timeline `CaptureBuilder` asks for.
            videoClip: { requested in
                RetainedClip(extraction: Self.extraction(requested),
                             exposure: .lockedConstant(1_000_000),
                             payload: { clip })
            })

        // Two swings, a second apart.
        let first = try pipeline.observe(Self.window(startNs: 10_000_000_000,
                                                     atSample: 1_000))
        let second = try pipeline.observe(Self.window(startNs: 11_000_000_000,
                                                      atSample: 1_000))
        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first[0].wouldPromote)

        // 5.12.1a — each Candidate names the audio Capture that explains it.
        #expect(first[0].candidate.evidenceCaptureId == first[0].evidence.record.id)
        guard case .candidate(let anchored) = first[0].evidence.record.anchor else {
            Issue.record("evidence must be candidate-anchored")
            return
        }
        #expect(anchored == first[0].candidate.id)
        #expect(first[0].evidence.record.streamId == Self.audioStream.id)

        // 8.3a — one Candidate per Shot, `authority: device`, no coincidence
        // window applied.
        let minted = try pipeline.pump(nowRefNs: 20_000_000_000)
        #expect(minted.count == 2)
        for shot in minted {
            #expect(shot.authority == .device)
            #expect(shot.candidateIds.count == 1)
            #expect(shot.captureIds.count == 1)
            #expect(shot.sessionId == Self.sessionId)
            #expect(shot.timebaseRefId == Self.timebase)
        }
        // 8.1d — `t0` is the canonical instant, which for a `mid`-convention
        // microphone is the raw instant with the time of flight taken off.
        #expect(minted[0].t0Ns == first[0].candidate.atNs)

        #expect(recorder.shotCount == 2)
        // ⛔ Candidates outnumber Shots and the manifest counts them separately —
        // the arithmetic REQ-PRIV-6 got the wrong way round.
        #expect(recorder.candidateCount == 2)

        try recorder.close(completeness: .complete, closedAtNs: 30_000_000_000)

        // The bundle reads back through the library's own reader.
        let reader = try SessionBundleReader()
        var offset = 0
        while offset < sink.bytes.count {
            let end = min(offset + 211, sink.bytes.count)
            try reader.feed(sink.bytes[offset..<end])
            offset = end
        }
        #expect(reader.manifestOrdered, "ENC 7c — the manifest precedes every payload")
        #expect(try reader.finish() == .complete)
        // Two shot clips and two audio windows.
        #expect(reader.captureCount == 4)
    }
}
