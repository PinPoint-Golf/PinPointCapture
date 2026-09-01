//  PayloadSizeTests.swift
//  #98 — what a payload actually WEIGHS, asserted rather than assumed.
//
//  ⛔ **Every payload test in this suite was too small to fail.** `ENC` §6 has
//  been exercised since A9 with a 300-byte clip and `chunkBytes: 64`
//  (`SessionBundleTests.writeBundle`), which is one short chunk and a single
//  frame. A real clip is megabytes and a real `AchievedFrames` at 239 fps is
//  717 entries, and both of those overflow a `libppcp` buffer that 300 bytes
//  never came near. So the writer was green for three weeks while no session on
//  a phone had ever written a payload at all: Shots were minted, `close()`
//  threw "output buffer too small", and the bytes behind four swings went
//  nowhere.
//
//  ⚠ **These tests are sized against the hardware, not against convenience.**
//  1080p at 239 fps for three seconds — the rate E1.1 measured on a real sensor
//  (#17) — is the case that broke, and a test that used 150 fps would pass
//  while the product failed, which is exactly what happened.
//
//  ⛔ **Two of these assert someone else's limit, on purpose** (F-E1-1). The
//  ceilings below are `libppcp`'s, they contradict `ENC` §8's published table,
//  and they are pinned here so the day the engine's queue grows we are told by
//  a failing test rather than by nobody.
//
//  Spec: `ENC` §6 (6a1, 6b, 6f), §8; `CORE` 5.8d, I30. Issue #98.

import Foundation
import Testing
import CPPCP
@testable import CaptureCore

@Suite("Payloads at the sizes hardware actually produces — #98")
struct PayloadSizeTests {

    // MARK: Fixtures

    /// The Session up to the point a payload may be written: `ENC` 7c puts the
    /// manifest before every payload frame, so there is no shorter prelude.
    static func openWriter(_ sink: SessionBundleTests.Sink,
                           capture record: PpcpCaptureRecord) throws -> SessionBundleWriter {
        let writer = try SessionBundleWriter(peer: try SessionBundleTests.peer()) {
            sink.append($0)
        }
        try writer.record(declaration: try SessionBundleTests.declaration())
        try writer.open(session: PpcpSessionRecord(
            id: SessionBundleTests.sessionId, timebaseRef: SessionBundleTests.timebase,
            openedAtNs: 1_000_000_000,
            epochWallUtcNs: 1_787_000_000_000_000_000,
            epochAtNs: 1_000_000_000, epochTimebaseId: SessionBundleTests.timebase))
        try writer.open(stream: SessionBundleTests.videoStream)
        try writer.announce(record)
        try writer.recordManifest(sessionId: SessionBundleTests.sessionId,
                                  streamIds: [SessionBundleTests.videoStream.id],
                                  captures: [record], completeness: .complete,
                                  shotCount: 1, candidateCount: 1)
        return writer
    }

    /// Three seconds of HEVC at 1080p is megabytes. ⚠ The *number* matters only
    /// in that it is far larger than one chunk — a clip that fits in a single
    /// frame is the case that was already covered and already passing.
    static let clip = Data(repeating: 0x5A, count: 3 * 1024 * 1024)

    /// `ENC` 6a1's per-frame series, at the rate a real sensor delivered.
    ///
    /// - Parameter intrinsics: REQ-OPT-7's matrix per frame. ⚠ Nine doubles is
    ///   roughly four times everything else put together, which is why the
    ///   ceiling moves so far when it is present.
    static func achieved(frames count: Int, intrinsics: Bool) -> PpcpAchievedFrames {
        let matrix = PpcpMatrix3([1600, 0, 960, 0, 1600, 540, 0, 0, 1])!
        return PpcpAchievedFrames(
            timebaseId: SessionBundleTests.timebase,
            // 239 fps — 4.1841 ms.
            framesNs: (0..<count).map { Int64($0) * 4_184_100 },
            exposureNs: .perFrame(Array(repeating: 1_000_000, count: count)),
            exposureProvenance: .sampled,
            iso: .perFrame(Array(repeating: 640, count: count)),
            intrinsics: intrinsics
                ? .perFrame(Array(repeating: matrix, count: count)) : nil)
    }

    static func record(bytes: Int) -> PpcpCaptureRecord {
        SessionBundleTests.capture("cap:1", bytes: UInt64(bytes),
                                   digest: SessionBundleWriter.digest(of: clip))
    }

    // MARK: The regression

    /// ⛔ **#98's exit criterion, in the one place it can be asserted without a
    /// phone.** No `chunkBytes` argument: the default is what the application
    /// uses and the default is what was wrong. It was `256 * 1024`, and
    /// `libppcp` refuses the first chunk of any clip larger than ~64000 bytes —
    /// so this test, written against the old default, fails on the very first
    /// `payload_chunk`.
    @Test("A megabyte clip goes through the DEFAULT chunk size and reads back")
    func realClipThroughTheDefault() throws {
        let sink = SessionBundleTests.Sink()
        let record = Self.record(bytes: Self.clip.count)
        let writer = try Self.openWriter(sink, capture: record)

        try writer.writePayload(captureId: record.id, clip: Self.clip)
        try writer.finish()

        // ⚠ Read back through `libppcp`'s own reader, not through this writer's
        // idea of what it wrote — `CONF` §2c's single-implementation trap.
        let reader = try SessionBundleReader()
        var offset = 0
        while offset < sink.bytes.count {
            let end = min(offset + 8192, sink.bytes.count)
            try reader.feed(sink.bytes[offset..<end])
            offset = end
        }
        #expect(reader.manifestOrdered, "ENC 7c — the manifest precedes every payload")
        #expect(try reader.finish() == .complete)
        #expect(reader.captureCount == 1)
    }

    /// The same clip with `ENC` 6a1's series behind it, which is what a Capture
    /// off the ring actually carries.
    @Test("A megabyte clip and a three-second per-frame series at 239 fps")
    func realClipWithItsAchievedFrames() throws {
        let sink = SessionBundleTests.Sink()
        let record = Self.record(bytes: Self.clip.count)
        let writer = try Self.openWriter(sink, capture: record)

        try writer.writePayload(captureId: record.id, clip: Self.clip,
                                achievedFrames: Self.achieved(frames: 717,
                                                              intrinsics: false))
        try writer.finish()
        #expect(sink.bytes.count > Self.clip.count)
    }

    // MARK: The ceilings that are not ours (F-E1-1)

    /// ⛔ **`ENC` 6f SHOULDs 262144 and §8 permits 4 MiB; `libppcp` originates
    /// neither.** Every message a peer sends is CBOR-encoded into a 64 KiB
    /// per-channel queue (`PPCP_PEER_TXQ_BYTES`), so the published limits are
    /// unreachable by any sender. This pins both halves: what we send works, and
    /// the specification's own recommendation does not.
    ///
    /// ⚠ **When this test fails, the fix is to RAISE our constant**, not to
    /// change the assertion — it means the queue grew and
    /// `PayloadTransferQueue.chunkBytes` can go back to 262144.
    @Test("The chunk size libppcp will originate, and the one the spec asks for")
    func chunkCeilingIsThelibrarysAndNotTheSpecification() throws {
        func write(chunk: Int) throws {
            let sink = SessionBundleTests.Sink()
            let record = Self.record(bytes: Self.clip.count)
            let writer = try Self.openWriter(sink, capture: record)
            try writer.writePayload(captureId: record.id, clip: Self.clip,
                                    chunkBytes: chunk)
        }

        // What this application sends today.
        #expect(throws: Never.self) {
            try write(chunk: Int(PayloadTransferQueue.chunkBytes))
        }
        // The refusal threshold is itself originable — a guard that refused a
        // value the library accepts would be this file inventing a limit.
        #expect(throws: Never.self) {
            try write(chunk: SessionBundleWriter.maximumOriginableChunkBytes)
        }
        // `ENC` 6f's SHOULD, refused before it reaches the library so the error
        // names the number rather than saying "output buffer too small".
        #expect(throws: SessionStoreError.chunkTooLargeToOriginate(262_144)) {
            try write(chunk: 262_144)
        }
    }

    /// ⛔ **`ENC` 6a1 sizes the per-frame series at "roughly 44 KB" for 1080p150
    /// over three seconds, and the same three seconds at 239 fps with per-frame
    /// intrinsics does not fit in the engine's queue at all** (F-E1-1). There is
    /// no call-site fix: I30 puts the whole series in one `payload_begin`, so no
    /// chunk size helps.
    ///
    /// ⚠ This is why the failure appeared when it did. At 150 fps a three-second
    /// clip is 450 frames and fits; #17's hardware run at 239 fps makes it 717.
    @Test("The per-frame series ceiling, which chunking cannot move")
    func achievedFramesCeilingIsNotChunkable() throws {
        func write(frames: Int, intrinsics: Bool) throws {
            let sink = SessionBundleTests.Sink()
            let record = Self.record(bytes: Self.clip.count)
            let writer = try Self.openWriter(sink, capture: record)
            try writer.writePayload(
                captureId: record.id, clip: Self.clip,
                achievedFrames: Self.achieved(frames: frames, intrinsics: intrinsics))
        }

        // Timestamps, exposure and ISO alone are cheap: three seconds at 239 fps
        // is comfortably inside, and so is a great deal more.
        #expect(throws: Never.self) { try write(frames: 717, intrinsics: false) }
        #expect(throws: Never.self) { try write(frames: 2_400, intrinsics: false) }

        // Add REQ-OPT-7's matrix and the same capture will not go out. Measured
        // 25 August 2026: 680 passes, 700 does not.
        #expect(throws: Never.self) { try write(frames: 680, intrinsics: true) }
        #expect(throws: PpcpLibraryError(PPCP_ERR_NOSPACE)) {
            try write(frames: 717, intrinsics: true)
        }
    }

    // MARK: The other ceiling (F-E1-2)

    /// ⛔ **A Session may announce 128 Captures and no more** — `libppcp` tracks
    /// every `capture_announce` in a table of `PPCP_TRANSFER_MAX` entries, and
    /// the specification imposes no such cap. At one `metadata` segment a second
    /// that ceiling arrived after ~124 seconds and a running session stopped
    /// accounting for a `continuous` Stream, which is the I36 defect the
    /// accounting exists to prevent (#98, found while reproducing it).
    ///
    /// ⚠ `MotionMetadataSource.segmentSeconds` is ten seconds because of this
    /// test's number. It is asserted here rather than in the platform layer
    /// because the limit belongs to the library, not to CoreMotion.
    @Test("How many Captures one Session may announce, before anything else fails")
    func announcedCaptureCeiling() throws {
        let sink = SessionBundleTests.Sink()
        let writer = try SessionBundleWriter(peer: try SessionBundleTests.peer()) {
            sink.append($0)
        }
        try writer.record(declaration: try SessionBundleTests.declaration())
        try writer.open(session: PpcpSessionRecord(
            id: SessionBundleTests.sessionId, timebaseRef: SessionBundleTests.timebase,
            openedAtNs: 1_000_000_000,
            epochWallUtcNs: 1_787_000_000_000_000_000,
            epochAtNs: 1_000_000_000, epochTimebaseId: SessionBundleTests.timebase))
        try writer.open(stream: SessionBundleTests.videoStream)

        var announced = 0
        var refusal: Error?
        for index in 1...200 {
            do {
                try writer.announce(SessionBundleTests.capture(
                    "cap:\(index)", bytes: 1_024,
                    digest: SessionBundleWriter.digest(of: Data([0x01]))))
                announced += 1
            } catch {
                refusal = error
                break
            }
        }

        #expect(announced == 128, "PPCP_TRANSFER_MAX — and nothing in ENC or CORE says so")
        #expect(refusal as? PpcpLibraryError == PpcpLibraryError(PPCP_ERR_LIMIT))
    }

    // MARK: The sentence a golfer reads (#98)

    /// ⛔ **The error names the call.** "libppcp: output buffer too small" is
    /// true of about thirty call sites in this package, and it reached the
    /// capture screen as the whole explanation of why nothing was recording.
    @Test("A library failure says which call produced it")
    func libraryErrorsCarryTheirCallSite() throws {
        let sink = SessionBundleTests.Sink()
        let record = Self.record(bytes: Self.clip.count)
        let writer = try Self.openWriter(sink, capture: record)

        do {
            try writer.writePayload(
                captureId: record.id, clip: Self.clip,
                achievedFrames: Self.achieved(frames: 717, intrinsics: true))
            Issue.record("the per-frame series above does not fit and must throw")
        } catch let error as PpcpLibraryError {
            #expect(error.description.contains("output buffer too small"))
            #expect(error.description.contains("payloadBegin"),
                    "the failing call, not merely the failure: \(error)")
            #expect(error.description.contains("DevicePeer.swift"))
        }
    }
}
