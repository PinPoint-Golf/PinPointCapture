//  InteropBundleFixture.swift
//  IOP-3 / IOP-10 — a stored Session this device wrote, for another
//  implementation to import.
//
//  ⛔ **DEBUG ONLY.** It exists so that "the device offers a stored Session"
//  (IOP-1, `MSG` §9.1) and "another implementation imports a bundle this one
//  wrote" (IOP-3, IOP-10, `CONF` §5) have something real to be about. A range
//  session on a phone produces one of these as a side effect; a simulator has no
//  camera and no microphone, so this drives the same pipeline from `CONF` §2a's
//  *injected* audio instead.
//
//  ⛔ **Nothing here is a second writer, a second encoder or a second schema.**
//  The bytes come out of `SessionBundleWriter` — which is `ppcp_bundle_writer`
//  with a file handle — over the same `CaptureSessionRecorder`, the same
//  `DetectAndMint`, the same `CandidateFactory` and the same `DeviceMint` that a
//  hostless range session uses. What differs from a phone's bundle is one thing
//  and it is stated in the bundle rather than hidden: **every Capture is
//  `absent` / `outside_buffer`**, because there is no camera and no ring, and
//  the manifest therefore asserts `partial`.
//
//  ⚠ **`partial`, and it is an assertion rather than an inference** (I10, 8.4b).
//  A reader must not conclude "complete" from finding what happens to be there,
//  and this writer must not claim it: the Shots and the Candidates in these
//  bundles are complete records of what happened, and the media is missing, so
//  the session is partial and says so.
//
//  Spec: `CORE` §8.3a–c, §8.4b, §9; `ENC` §7; `MSG` §9.1, §9.2; `CONF` §2a, §5.
//  Plan D6, S5 wave 1.

#if DEBUG

import Foundation
import CaptureCore

enum InteropBundleFixture {

    /// Record one hostless Session carrying `shots` minted Shots into `store`.
    ///
    /// - Returns: the bundle, and what it ended up containing.
    @discardableResult
    static func record(shots: Int,
                       into store: SessionStore,
                       device: any CaptureDevice,
                       distance: MicToBallDistance,
                       sessionId: String,
                       peerId: String = PeerIdentity.current) throws -> Written {

        let honest = try ConformanceHarness.honestDeclaration(of: device, peerId: peerId)
        let declaration = honest.declaration
        let bundle = try store.makeBundle(sessionId: sessionId, mintingPeerId: peerId)

        let file = bundle.bundleFile
        // ⚠ Truncated rather than appended: a bundle is a byte stream with a
        // header at offset zero (`ENC` §7), and a second run appending to the
        // first would produce a file whose second header is unreachable.
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        let peer = try DevicePeer(peerId: peerId)
        let writer = try SessionBundleWriter(peer: peer) { bytes in
            try handle.write(contentsOf: bytes)
        }

        let openedAt = MachClock.hostTimeNs
        let recorder = try CaptureSessionRecorder(
            writer: writer,
            declaration: declaration,
            // ⛔ Hostless by construction: `ppcp_session_make_hostless` cannot be
            // given the two arbitration parameters and there is no setter, so the
            // bundle's silence about arbitration is 4.1d's statement that none
            // occurred rather than an omission. `epoch` is a LABEL (I15) — a wall
            // instant paired with the capture instant it was read beside, and
            // never used to compute an interval.
            session: PpcpSessionRecord(
                id: sessionId,
                timebaseRef: PpcpTimebases.captureId,
                // ⛔ 5.10h — the instant this hostless Session opened, on the
                // capture timebase `timebaseRef` names. `openedAt` above is the
                // one reading, taken once.
                openedAtNs: openedAt,
                epochWallUtcNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000),
                epochAtNs: openedAt,
                epochTimebaseId: PpcpTimebases.captureId))

        // ⛔ Derived from the declaration, never assembled by hand: a Stream's
        // `source_id`, `profile_id` and `timebase_id` must name things the peer
        // actually declared (5.11a, I5).
        let streams = RecordingSession.streams(
            sessionId: sessionId, declaration: declaration,
            mode: nil, openedAtNs: openedAt)
        for stream in streams { try recorder.open(stream: stream) }

        guard let audio = streams.first(where: { $0.kind == PpcpStreamKind.audio }) else {
            throw HarnessBundleError.noAudioStream
        }
        // ⚠ With no camera the video Stream is the audio one: `DetectAndMint`
        // needs a Stream for the shot-anchored Capture to land on, and announcing
        // it `absent` on the Stream that does exist is honest where naming a
        // Stream that was never opened would not be (I5).
        let video = streams.first(where: { $0.kind == PpcpStreamKind.video }) ?? audio

        // 7.3c — `readiness` is conferred through **Capture** and belongs in a
        // hostless bundle; `arm` is conferred through **Live** and does not
        // (7.3b), which is why there is no arm here and could not be.
        try recorder.report(ReadinessMeasurement.measuring(
            .armed, exposureHasSettled: true,
            settleEstimateMs: AppModel.assumedSettleMs))

        let mint = try DeviceMint(peer: peer, promotion: DetectAndMint.defaultPromotion())
        let pipeline = DetectAndMint(
            peer: peer, sink: recorder, mint: mint,
            factory: CandidateFactory(declaration: declaration,
                                      sourceId: audio.sourceId,
                                      // 6.1d — a microphone has no `format`, so
                                      // no profile and no conversion.
                                      profileId: nil,
                                      timeOfFlight: distance.timeOfFlight),
            configuration: DetectAndMint.Configuration(
                sessionId: sessionId, peerId: peerId,
                // 5.13c / I4 — hostless, so `timebase_ref` is this device's own
                // capture clock and the conversion is the identity. No relation
                // is asserted for it.
                timebaseRefId: PpcpTimebases.captureId,
                audioStream: audio, videoStream: video),
            promotion: DetectAndMint.defaultPromotion(),
            // ⛔ 8.4b / I10 — "an absent capture is a result, not a failure".
            extractAudio: { ClipExtraction.nothingRetained($0) },
            videoClip: { RetainedClip.nothingRetained($0) })

        var nominated = 0
        var minted: [PpcpShot] = []
        for index in 0..<max(shots, 1) {
            // One swing per second of injected audio, so two Shots are two
            // events and not one event counted twice.
            let start = openedAt + Int64(index) * 1_000_000_000
            let detections = try pipeline.observe(
                SyntheticAudio.oneSwing(timebaseId: PpcpTimebases.captureId,
                                        startNs: start))
            nominated += detections.count
            for _ in detections { recorder.countCandidate() }
            // 8.2i — the deadline is local and it is read in `timebase_ref`,
            // which here is this device's own clock. Well past the swing, so the
            // Shot is due.
            let due = try pipeline.pump(nowRefNs: start + 2_000_000_000)
            for _ in due { recorder.countShot() }
            minted.append(contentsOf: due)
        }

        // ⛔ `partial`, asserted. See the note at the top of this file.
        try recorder.close(completeness: .partial,
                           closedAtNs: openedAt + Int64(max(shots, 1)) * 2_000_000_000)

        return Written(bundle: bundle,
                       streamIds: streams.map(\.id),
                       candidateCount: nominated,
                       shotIds: minted.map(\.id),
                       declaredCamera: honest.hasCamera)
    }

    struct Written: Sendable {
        var bundle: SessionBundle
        var streamIds: [String]
        var candidateCount: Int
        var shotIds: [String]
        /// ⛔ `false` on a simulator, and every Capture in the bundle is `absent`
        /// for that reason.
        var declaredCamera: Bool
    }

    enum HarnessBundleError: Error, Sendable {
        /// A device that declared no microphone cannot nominate, so it cannot
        /// produce a Session with a Shot in it. Not a failure of this fixture.
        case noAudioStream
    }
}

#endif
