//  SessionBundleTests.swift
//  Plan A9 exercised end to end: a Session written as a `PPCPBNDL` and read back
//  through `ppcp_bundle_reader`, which is `ppcp_peer_feed` with a header in
//  front of it.
//
//  ⚠ **A round trip, not two half-tests.** `ENC` §7's whole claim is that a file
//  is a transport — the writer emits the frames a peer would have sent and the
//  reader hands them to an engine a socket would have driven. Testing the writer
//  against a golden byte string would assert this implementation against itself,
//  which is the single-implementation trap `CONF` §2c names; testing it against
//  the library's own reader asserts it against the thing PinPointStudio will use.
//
//  ⛔ **What these cannot show.** They cannot show that PinPointStudio reads a
//  bundle this device wrote — that is the interop row "device, no host → bundle"
//  and it needs both applications. What they show is that the bytes are `ENC` §7,
//  that the ordering rules hold, and that the refusals refuse.
//
//  Spec: `CORE` §9, §7.3b, §5.14; `ENC` §7 (7c, 7d, 7e, 7g); `CONF` CT-I12,
//  CT-I34, CT-S4 assertion 1 (bundle half).

import Foundation
import Testing
import CPPCP
@testable import CaptureCore

@Suite("Session bundles — CORE §9 / ENC §7")
struct SessionBundleTests {

    // MARK: Fixtures

    static let peerId = "peer:test-device"
    static let sessionId = "ses:2026-08-22-a"
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
                claimed: [VideoMode(width: 1920, height: 1080, fps: 240, lens: .wide,
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

    static func peer() throws -> DevicePeer {
        try DevicePeer(peerId: peerId)
    }

    /// A collector standing in for the file. ⚠ The writer hands bytes back and
    /// never opens anything (ground rule 8), which is exactly why this test needs
    /// no filesystem and runs on the host in milliseconds.
    final class Sink: @unchecked Sendable {
        private(set) var bytes = Data()
        func append(_ data: Data) { bytes.append(data) }
    }

    static let videoStream = PpcpStreamRecord(
        id: "str:video:wide", sessionId: sessionId, sourceId: "src:camera:wide",
        kind: PPCP_STREAM_KIND_VIDEO, profileId: "1920x1080@240",
        timebaseId: timebase, continuity: .shotWindowed, openedAtNs: 1_000_000_000)

    static func capture(_ id: String, bytes: UInt64, digest: Data) -> PpcpCaptureRecord {
        PpcpCaptureRecord(
            id: id,
            // ⛔ **Shot-anchored, and it changed in S3 wave 2.** It used to be a
            // `segment` on this Stream, on the reasoning that a hostless device
            // has no host to issue a Shot — which was wrong twice over. `CORE`
            // 8.3a mints one *without* a host, `authority: device`, which D5 now
            // does; and 5.14d makes `{stream: true}` legal **only on a
            // `continuous` Stream**, which `video` never is (§5.11's table).
            //
            // The fixture passed anyway until `libppcp` L9 closed F-D4-1 and
            // `ppcp_peer_capture_announce` began applying
            // `ppcp_capture_validate_in_stream` at origination. It is exactly the
            // failure that finding predicted: a rule the engine held the data for
            // and did not enforce, so a wrong fixture read as a right one.
            anchor: .shot("sht:fixture"),
            streamId: videoStream.id, timebaseId: timebase,
            completeness: .complete,
            intervalNs: 2_000_000_000..<2_500_000_000,
            digest: digest, bytes: bytes)
    }

    /// The whole hostless recording, in the order `CORE` §9 and `ENC` 7c fix.
    static func writeBundle(streams: [PpcpStreamRecord],
                            captures: [(record: PpcpCaptureRecord, clip: Data)],
                            completeness: PpcpCaptureRecord.Completeness = .complete)
        throws -> Data {
        let sink = Sink()
        let writer = try SessionBundleWriter(peer: try peer()) { sink.append($0) }

        try writer.record(declaration: try declaration())
        try writer.open(session: PpcpSessionRecord(
            id: sessionId, timebaseRef: timebase,
            epochWallUtcNs: 1_787_000_000_000_000_000,
            epochAtNs: 1_000_000_000, epochTimebaseId: timebase))
        for stream in streams { try writer.open(stream: stream) }
        try writer.record(readiness: try PpcpReadiness.settled(),
                          streamIds: streams.map(\.id))
        for capture in captures { try writer.announce(capture.record) }
        try writer.recordManifest(sessionId: sessionId,
                                  streamIds: streams.map(\.id),
                                  captures: captures.map(\.record),
                                  completeness: completeness,
                                  shotCount: 0, candidateCount: 0)
        for capture in captures {
            try writer.writePayload(captureId: capture.record.id, clip: capture.clip,
                                    chunkBytes: 64)
        }
        #expect(writer.hasManifest)
        #expect(writer.isHostless, "CORE 4.1d — no arbitration parameters were recorded")
        try writer.finish()
        return sink.bytes
    }

    static let clip = Data((0..<300).map { UInt8($0 % 251) })

    // MARK: The container

    /// `ENC` §7 — "PPCPBNDL", major 1, minor 0. ⚠ Read through the library's own
    /// parser, and the reason that matters is a bug this test caught: the app
    /// used to hand `ppcp_bundle_header_parse` the bytes *after* the magic, so it
    /// refused every conformant bundle. `PPCP_BUNDLE_HEADER_BYTES` is 16 and
    /// includes the magic.
    @Test("A written bundle carries the ENC §7 magic and a 1.0 header")
    func headerIsEncSection7() throws {
        let digest = SessionBundleWriter.digest(of: Self.clip)
        let bytes = try Self.writeBundle(
            streams: [Self.videoStream],
            captures: [(Self.capture("cap:1", bytes: UInt64(Self.clip.count), digest: digest),
                        Self.clip)])

        #expect(SessionStore.hasBundleMagic(bytes))
        let header = try SessionStore.readHeader(bytes)
        #expect(header.major == 1)
        #expect(header.minor == 0)
        #expect(bytes.count > Int(PPCP_BUNDLE_HEADER_BYTES))
    }

    /// The round trip. ⛔ The reader is handed the bytes in **small arbitrary
    /// runs**, not whole: `ppcp_bundle_reader_feed` consumes whole frames and the
    /// embedding keeps the tail, and a test that fed it the file in one call
    /// would never exercise the half of that contract that actually bites.
    @Test("A bundle reads back through ppcp_bundle_reader, fed in fragments")
    func bundleRoundTrips() throws {
        let digest = SessionBundleWriter.digest(of: Self.clip)
        let bytes = try Self.writeBundle(
            streams: [Self.videoStream],
            captures: [(Self.capture("cap:1", bytes: UInt64(Self.clip.count), digest: digest),
                        Self.clip)])

        let reader = try SessionBundleReader()
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 37, bytes.count)
            try reader.feed(bytes[offset..<end])
            offset = end
        }
        #expect(reader.frameCount > 0)
        #expect(reader.manifestOrdered, "ENC 7c — session_manifest precedes every payload frame")
        #expect(reader.truncated == false)
        #expect(reader.minor == 0)

        // `ENC` 7d — the Session asserted `complete`, so that is what it is,
        // whatever the bytes happened to do.
        let frames = reader.frameCount
        let completeness = try reader.finish()
        #expect(completeness == .complete)
        // ⚠ The accounting survives `finish()`, because `finish()` is exactly
        // when an embedding asks how the read went.
        #expect(reader.frameCount == frames)
        #expect(reader.manifestOrdered)
    }

    /// `ENC` 7d's middle row: **not asserted, bytes truncated → partial.** ⚠ Cut
    /// the bundle mid-frame and read what is left; the reader never upgrades what
    /// arrived into a claim the owner did not make (I10).
    @Test("ENC 7d — a truncated bundle with no assertion reads as partial")
    func truncationWithoutAssertionIsPartial() throws {
        let sink = Self.Sink()
        let writer = try SessionBundleWriter(peer: try Self.peer()) { sink.append($0) }
        try writer.record(declaration: try Self.declaration())
        try writer.open(session: PpcpSessionRecord(id: Self.sessionId,
                                                   timebaseRef: Self.timebase))
        try writer.open(stream: Self.videoStream)

        // Cut three bytes off the last frame.
        let truncated = sink.bytes.dropLast(3)
        let reader = try SessionBundleReader()
        try reader.feed(truncated)
        #expect(reader.truncated)
        #expect(try reader.finish() == .partial)
    }

    // MARK: CT-I12

    /// **CT-I12** — "a Session with any subset of Streams is valid, including
    /// none and including video-only." ⚠ Both ends of the subset, because the
    /// failure this guards against is a writer that quietly requires audio.
    @Test("CT-I12 — a video-only Session and a Session with no Streams both write")
    func anySubsetOfStreamsIsValid() throws {
        let videoOnly = try Self.writeBundle(streams: [Self.videoStream], captures: [])
        #expect(SessionStore.hasBundleMagic(videoOnly))
        let readerA = try SessionBundleReader()
        try readerA.feed(videoOnly)
        #expect(try readerA.finish() == .complete)

        let noStreams = try Self.writeBundle(streams: [], captures: [])
        #expect(SessionStore.hasBundleMagic(noStreams))
        let readerB = try SessionBundleReader()
        try readerB.feed(noStreams)
        #expect(try readerB.finish() == .complete)
    }

    // MARK: CT-I34

    /// **CT-I34** — "identity is `Capture.id` scoped by session and owning peer,
    /// and `digest` where present is checked as CONTENT rather than used as the
    /// key. Replay a bundle twice and assert the second import is a no-op."
    ///
    /// ⚠ Replayed by feeding the same frames a second time into the same reader,
    /// which is what a user AirDropping the same session twice looks like from
    /// the index's point of view. ⛔ The digest is deliberately not in the key:
    /// a `complete` + `pending` Capture has no digest yet and an `absent` one
    /// never will, so keying on it would import both of those twice.
    @Test("CT-I34 — the same Capture read twice is held once")
    func reimportIsIdempotent() throws {
        let digest = SessionBundleWriter.digest(of: Self.clip)
        let bytes = try Self.writeBundle(
            streams: [Self.videoStream],
            captures: [(Self.capture("cap:1", bytes: UInt64(Self.clip.count), digest: digest),
                        Self.clip)])

        let reader = try SessionBundleReader()
        try reader.feed(bytes)
        #expect(reader.captureCount == 1)
        #expect(try reader.hasSeen(sessionId: Self.sessionId, peerId: Self.peerId,
                                   captureId: "cap:1"))

        // The same frames again, without a second header — the reader has already
        // consumed it, and the frames behind it are just more frames.
        try reader.feed(bytes.dropFirst(Int(PPCP_BUNDLE_HEADER_BYTES)))
        #expect(reader.captureCount == 1, "a second import of the same Capture is a no-op")

        // A Capture that was never in the bundle is not held, which is the
        // assertion that makes the one above mean something.
        #expect(try reader.hasSeen(sessionId: Self.sessionId, peerId: Self.peerId,
                                   captureId: "cap:never") == false)
    }

    // MARK: CT-S4 assertion 1 — the bundle half

    /// **`CORE` 7.3b** — "no `arm` or `disarm` once a HOSTLESS `session_open` has
    /// been recorded. Those are control messages conferred by **Live**, and with
    /// nobody controlling there is no command to record."
    ///
    /// ⚠ **`CONF` 4.4 assertion 1 no longer lists `arm`** (erratum E19, 23 August
    /// 2026). It used to — "declare, stream open, arm, readiness, candidates,
    /// shots, captures, bundle write, bundle read" — and 7.3b forbids the thing it
    /// asked for. The hostless peer arms *itself*; what the bundle carries is the
    /// **effect**, which is `readiness`. So this test is no longer exercising a
    /// row that asks for `arm`, and what it asserts is unchanged and still worth
    /// asserting: that the two refusals below exist. It is now a test of 7.3b
    /// rather than of the row.
    ///
    /// ⛔ **Two refusals, and the first is the stronger one.** `ppcp_peer_arm`
    /// refuses this peer outright because 7.3a makes arming host-controlled and
    /// this peer is `role: capture` — so the frame does not exist to be recorded.
    /// The writer's own refusal is the backstop for a host writing a bundle.
    @Test("CT-S4 (1) — a hostless bundle records readiness and cannot record arm")
    func hostlessBundleHasNoArm() throws {
        let peer = try Self.peer()
        let sink = Self.Sink()
        let writer = try SessionBundleWriter(peer: peer) { sink.append($0) }
        // ⛔ `ENC` 7h (erratum E9) — `declare` precedes every frame naming a
        // Stream, a Capture, a Shot or a Candidate.
        try writer.record(declaration: try Self.declaration())
        try writer.open(session: PpcpSessionRecord(id: Self.sessionId,
                                                   timebaseRef: Self.timebase))
        #expect(writer.isHostless)

        // 7.3a / C2 — a capture peer cannot originate `arm` at all.
        peer.withHandle { handle in
            #expect(ppcp_peer_arm(handle, nil, 0) != PPCP_OK)
            #expect(ppcp_peer_disarm(handle, nil, 0) != PPCP_OK)
        }

        // 7.3c — `readiness` is conferred by **Capture**, so it is recorded.
        try writer.open(stream: Self.videoStream)
        try writer.record(readiness: try PpcpReadiness.settled(),
                          streamIds: [Self.videoStream.id])
        #expect(writer.frameCount >= 3)
    }

    // MARK: The writer's other refusals

    /// `ENC` 7c — "no `payload_*` frame before `session_manifest`, so an
    /// interrupted read still yields an analysable session."
    @Test("ENC 7c — a payload frame before the manifest is refused")
    func payloadBeforeManifestIsRefused() throws {
        let sink = Self.Sink()
        let writer = try SessionBundleWriter(peer: try Self.peer()) { sink.append($0) }
        // ⛔ `ENC` 7h (erratum E9).
        try writer.record(declaration: try Self.declaration())
        try writer.open(session: PpcpSessionRecord(id: Self.sessionId,
                                                   timebaseRef: Self.timebase))
        try writer.open(stream: Self.videoStream)
        let digest = SessionBundleWriter.digest(of: Self.clip)
        try writer.announce(Self.capture("cap:1", bytes: UInt64(Self.clip.count),
                                         digest: digest))
        #expect(writer.hasManifest == false)
        #expect(throws: (any Error).self) {
            try writer.writePayload(captureId: "cap:1", clip: Self.clip, chunkBytes: 64)
        }
    }

    /// `ENC` 7g — "no `link_bind` in a bundle. A file has one stream and its
    /// channels are the header byte; there is nothing to bind."
    ///
    /// ⚠ Exercised through the peer rather than by hand: `ppcp_peer_open_channel`
    /// queues a real `link_bind`, and the writer refuses the frame it produced.
    @Test("ENC 7g — a link_bind frame cannot be appended to a bundle")
    func linkBindIsRefusedInABundle() throws {
        let peer = try Self.peer()
        try peer.setLinkId(try PpcpLinkId(bytes: Data((0..<16).map { UInt8($0) })))
        let sink = Self.Sink()
        let writer = try SessionBundleWriter(peer: peer) { sink.append($0) }

        try peer.openChannel(.bulk)
        #expect(peer.pending(.bulk) > 0, "the peer really did queue a link_bind")
        #expect(throws: (any Error).self) {
            // The writer is handed exactly what `ppcp_peer_drain` produced.
            try writer.record(readiness: try PpcpReadiness.settled())
            try writer.appendPending(.bulk)
        }
    }

    /// `ENC` 7e — "no trailing index, footer or table of contents … and
    /// `ppcp_bundle_writer_finish()` emits no bytes."
    @Test("ENC 7e — finish emits nothing and refuses a further append")
    func finishEmitsNoBytes() throws {
        let sink = Self.Sink()
        let writer = try SessionBundleWriter(peer: try Self.peer()) { sink.append($0) }
        try writer.open(session: PpcpSessionRecord(id: Self.sessionId,
                                                   timebaseRef: Self.timebase))
        let before = sink.bytes.count
        try writer.finish()
        #expect(sink.bytes.count == before, "ENC 7e — a footer would be bytes")
        #expect(throws: SessionStoreError.bundleFinished) {
            try writer.open(stream: Self.videoStream)
        }
    }

    // MARK: The store

    /// `CORE` 5.1a — identity is not derived from the path, so the directory is
    /// *named* after the ids and reading it back recovers what was written.
    @Test("The store's directory name is a pure function of the two ids")
    func storeIsIdempotentByIdentity() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ppcp-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)

        let first = try store.makeBundle(sessionId: Self.sessionId, mintingPeerId: Self.peerId)
        let second = try store.makeBundle(sessionId: Self.sessionId, mintingPeerId: Self.peerId)
        #expect(first.directory == second.directory)
        #expect(first.id == second.id)

        let listed = try store.bundles()
        #expect(listed.count == 1)
        #expect(listed.first?.sessionId == Self.sessionId)
        #expect(listed.first?.mintingPeerId == Self.peerId)

        // ⛔ An `Id` that cannot be a directory name is refused, never escaped:
        // an escape scheme is a parser, and 5.1a forbids parsing structure out of
        // an `Id` anyway.
        #expect(throws: SessionStoreError.unrepresentableIdentifier) {
            try store.makeBundle(sessionId: "a~b", mintingPeerId: Self.peerId)
        }
    }

    @Test("Deleting a bundle removes its directory and it stops being listed")
    func deleteRemovesTheDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ppcp-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)

        let bundle = try store.makeBundle(sessionId: Self.sessionId, mintingPeerId: Self.peerId)
        #expect(try store.bundles().count == 1)

        try store.delete(bundle)
        #expect(FileManager.default.fileExists(atPath: bundle.directory.path) == false)
        #expect(try store.bundles().isEmpty)
    }

    /// The magic is read from the **bytes**, not the extension: a file arriving
    /// by AirDrop or the Files app may have been renamed.
    @Test("Something that is not a bundle is refused by its bytes, not its name")
    func nonBundleIsRefused() throws {
        #expect(SessionStore.hasBundleMagic(Data("PPCPBND".utf8)) == false)
        #expect(SessionStore.hasBundleMagic(Data()) == false)
        #expect(throws: SessionStoreError.notABundle) {
            try SessionStore.readHeader(Data(repeating: 0, count: 64))
        }
    }
}
