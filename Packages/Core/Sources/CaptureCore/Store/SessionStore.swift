//  SessionStore.swift
//  Plan A9: **the session store on the device *is* the bundle.** Each Session on
//  disk is a `PPCPBNDL` file (`ENC` §7) plus the clip files it references. There
//  is no second on-disk schema, no export step that converts anything, and every
//  range session is a regression fixture at no additional cost (REQ-TEST-3).
//
//  ⚠ **The bundle is written by `ppcp_bundle_writer`, and the frames in it are
//  the frames a live peer would have sent.** `SessionBundleWriter` below holds a
//  `DevicePeer` and appends what `ppcp_peer_drain` produces, which is exactly
//  what `ppcp_bundle_writer_append_frames` takes. There is no second encoder and
//  no second ordering rule: `ENC` 7c (`session_manifest` before any payload
//  frame), 7g (no `link_bind` in a bundle) and `CORE` 7.3b (no `arm`/`disarm` in
//  a hostless one) are the writer's refusals, not this file's checks.
//
//  Spec: `CORE` §9, §7.3b, §5.14; `ENC` §7; `CONF` CT-I12, CT-I34, CT-S4 (1).

import Foundation
import CPPCP

/// One Session on disk.
///
/// ⚠ **A directory, not a file, and the difference is `ENC` §7's.** The bundle is
/// one byte stream of control and payload frames; the *clips* those payload
/// frames describe are separate media files, because a 25 MB H.265 clip inside a
/// CBOR frame would have to be read whole to be played and would defeat every
/// streaming decoder on the device. `CORE` §9 puts the bundle and its media
/// side by side for exactly this reason (REQ-CLIP-2).
public struct SessionBundle: Sendable, Hashable, Identifiable {

    /// `ENC` §7 — the container's own extension.
    public static let fileExtension = "ppcpbndl"
    /// Where the clips a payload frame names actually live.
    public static let clipsDirectoryName = "clips"

    /// ⛔ `CORE` 5.1a — "an `Id` minted by a peer is stable for the lifetime of
    /// the entity it names and is **not derived from mutable local state** — a
    /// filesystem path, a directory name, an ordinal that renumbers on reindex."
    /// So this is the Session's own id, read from the bundle, and the directory
    /// is *named* after it rather than the other way round. I34's idempotent
    /// re-import keys on it plus the minting `Peer.id` (8.5c), and a store that
    /// keyed on the path would duplicate every session the user ever moved.
    public let sessionId: String
    public let mintingPeerId: String
    public let directory: URL

    public var id: String { "\(mintingPeerId)/\(sessionId)" }

    public var bundleFile: URL {
        directory.appendingPathComponent("session").appendingPathExtension(Self.fileExtension)
    }
    public var clipsDirectory: URL {
        directory.appendingPathComponent(Self.clipsDirectoryName, isDirectory: true)
    }

    public init(sessionId: String, mintingPeerId: String, directory: URL) {
        self.sessionId = sessionId
        self.mintingPeerId = mintingPeerId
        self.directory = directory
    }
}

/// The device's session library — what `SessionLibraryScreen` lists.
public struct SessionStore: Sendable {

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Is this file a PPCP bundle? ⚠ Asked of the **magic**, not the extension:
    /// `ENC` §7 puts `PPCPBNDL` in the first eight bytes, a file arriving by
    /// AirDrop or the Files app may have been renamed, and a store that trusted
    /// a suffix would hand the parser something else's bytes.
    public static func hasBundleMagic(_ bytes: Data) -> Bool {
        let magic = Data(PPCP_BUNDLE_MAGIC.utf8)
        guard bytes.count >= magic.count else { return false }
        return bytes.prefix(magic.count) == magic
    }

    /// The `ENC` §7 header, as the library reads it.
    ///
    /// ⛔ 7f: "a reader accepts a bundle whose `minor` exceeds its own and ignores
    /// the frames it does not understand (I13). A differing `major` is refused."
    /// Both halves are the library's decision and neither is re-decided here.
    public static func readHeader(_ bytes: Data) throws -> (major: Int, minor: Int) {
        // ⚠ **`PPCP_BUNDLE_HEADER_BYTES` is 16 and INCLUDES the eight magic
        // bytes.** This read used to advance past the magic before parsing and
        // then demand 24 bytes, which refused every conformant bundle — the
        // library's own `ppcp_bundle_header_parse` starts with a `memcmp`
        // against `PPCPBNDL` at offset zero. Found by writing one and reading it
        // back; a round trip is the only test that catches an off-by-a-field.
        let headerBytes = Int(PPCP_BUNDLE_HEADER_BYTES)
        guard hasBundleMagic(bytes), bytes.count >= headerBytes else {
            throw SessionStoreError.notABundle
        }
        var header = ppcp_bundle_header()
        try bytes.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            try check(ppcp_bundle_header_parse(base, &header))
        }
        return (Int(header.major), Int(header.minor))
    }

    /// Every bundle the library holds, newest first.
    ///
    /// ⚠ Reads the **directory names**, not the bundles, and that is a deliberate
    /// limit rather than an optimisation: opening every bundle to list them would
    /// make the library screen's cost grow with the range session, and `CORE`
    /// 5.1a already forbids deriving identity from the path. So the directory
    /// name is `<peer>/<session>` written at creation *from* the ids, and reading
    /// it back is recovering what was written, not inferring it.
    public func bundles() throws -> [SessionBundle] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return [] }

        return try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.hasDirectoryPath }
            .compactMap { directory in
                let parts = directory.lastPathComponent.split(separator: "~", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return SessionBundle(sessionId: String(parts[1]),
                                     mintingPeerId: String(parts[0]),
                                     directory: directory)
            }
            .sorted { a, b in
                let da = (try? a.directory.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let db = (try? b.directory.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return da > db
            }
    }

    /// Create the directory for a Session. ⛔ Idempotent by construction (I34):
    /// the name is a pure function of the two ids, so creating the same Session
    /// twice returns the same directory and never a second one.
    @discardableResult
    public func makeBundle(sessionId: String, mintingPeerId: String) throws -> SessionBundle {
        // ⚠ `~` as the separator, because `CORE` 5.1 makes an `Id` "opaque UTF-8,
        // 1–64 bytes" — a UUID today and not necessarily tomorrow — and `/` and
        // `:` are the two bytes a path cannot carry. `~` is rejected below rather
        // than escaped: an escape scheme is a parser, and 5.1a forbids parsing
        // structure out of an `Id` anyway.
        guard sessionId.contains("~") == false, mintingPeerId.contains("~") == false,
              sessionId.isEmpty == false, mintingPeerId.isEmpty == false else {
            throw SessionStoreError.unrepresentableIdentifier
        }
        let bundle = SessionBundle(
            sessionId: sessionId, mintingPeerId: mintingPeerId,
            directory: root.appendingPathComponent("\(mintingPeerId)~\(sessionId)",
                                                   isDirectory: true))
        try FileManager.default.createDirectory(at: bundle.clipsDirectory,
                                                withIntermediateDirectories: true)
        return bundle
    }
}

public enum SessionStoreError: Error, Sendable, Equatable {
    /// The first eight bytes are not `PPCPBNDL` (`ENC` §7).
    case notABundle
    /// An `Id` that cannot be a directory name. See `makeBundle`.
    case unrepresentableIdentifier
    /// `ENC` 7e — `finish()` was called and a further append is refused. The
    /// writer emits no bytes at finish, so this is the only thing that changes.
    case bundleFinished
    /// ⛔ `CORE` 5.11j — a preview Capture is live-only and "MUST NOT … be
    /// written to a bundle". CT-I36a's third assertion is that none reaches one,
    /// and this is where that is true rather than remembered.
    case previewIsNotRecordable
}

// MARK: - Writing the bundle

/// One Session, written as a `PPCPBNDL` while it happens.
///
/// ⚠ **The order below is `CORE` §9 and `ENC` §7, and the *library* holds it.**
///
///   `declare` → `session_open` → `stream_open` per Stream → `readiness`
///   → `candidate` / `shot` / `capture_announce` → `session_manifest`
///   → `payload_*` frames referencing the clip files.
///
/// Two things about a **hostless** bundle that are easy to get wrong, and are
/// unreachable rather than merely documented:
///
///  1. ⛔ **No `arm` and no `disarm`** (`CORE` 7.3b). Those are conferred by
///     **Live** and with nobody controlling there is no command to record; the
///     bundle carries the *effect* — Streams, `readiness`, Captures. The writer
///     refuses one after a hostless `session_open`, and this application could
///     not originate one anyway: `ppcp_peer_arm` refuses a peer that is not
///     `role: host`. `readiness` still appears, because 7.3c confers it through
///     **Capture**.
///  2. ⛔ **No arbitration parameters on `session_open`.** `PpcpSessionRecord`
///     goes to `ppcp_session_make_hostless`, which cannot be given them and has
///     no setter (5.10e).
///
/// ⚠ **Bytes are handed back, never written.** Neither the writer nor the reader
/// opens a file (ground rule 8): `emit` receives every byte in order and the
/// embedding appends it. That is what makes a bundle testable with no filesystem
/// at all, and it is how `CaptureCore` stays platform-free.
public final class SessionBundleWriter: @unchecked Sendable {

    /// Room for the largest control frame `ENC` §8 permits, so a whole frame
    /// always fits and `PPCP_ERR_NOSPACE` means a bug rather than a big frame.
    private static let scratchCapacity = 1 << 20

    private let peer: DevicePeer
    private let storage: UnsafeMutableRawPointer
    private var writer: OpaquePointer?
    private let emit: (Data) throws -> Void
    private var scratch: [UInt8]

    public private(set) var frameCount: Int = 0

    /// - Parameter emit: called with each run of bytes to append, in order.
    public init(peer: DevicePeer, emit: @escaping (Data) throws -> Void) throws {
        self.peer = peer
        self.emit = emit
        scratch = [UInt8](repeating: 0, count: Self.scratchCapacity)

        let size = ppcp_bundle_writer_sizeof()
        storage = .allocate(byteCount: size, alignment: MemoryLayout<UInt64>.alignment)
        var handle: OpaquePointer?
        do {
            try check(ppcp_bundle_writer_new(storage, size, &handle))
        } catch {
            storage.deallocate()
            throw error
        }
        writer = handle

        // `ENC` §7 — "PPCPBNDL", major 1, minor 0, reserved 0. Sixteen bytes,
        // and it MUST be the first call.
        var length = 0
        try check(ppcp_bundle_writer_begin(handle, &scratch, scratch.count, &length))
        try emit(Data(scratch[0..<length]))
    }

    deinit { storage.deallocate() }

    private func handle() throws -> OpaquePointer {
        guard let writer else { throw SessionStoreError.bundleFinished }
        return writer
    }

    /// Take whatever the peer has queued on `channel` and append it.
    ///
    /// ⛔ **This is the whole of "live bytes are bundle bytes".** The peer frames
    /// the message exactly as it would have sent it; `append_frames` takes what
    /// `ppcp_peer_drain` produced, byte for byte. A bundle written this way and a
    /// session captured over a socket differ in where the bytes went and in
    /// nothing else.
    public func appendPending(_ channel: PpcpChannel) throws { try flush(channel) }

    private func flush(_ channel: PpcpChannel) throws {
        let frames = try peer.drain(channel)
        guard frames.isEmpty == false else { return }
        let writer = try handle()
        var length = 0
        let result: ppcp_result = frames.withUnsafeBytes { raw in
            scratch.withUnsafeMutableBufferPointer { out in
                ppcp_bundle_writer_append_frames(
                    writer, raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                    out.baseAddress, out.count, &length)
            }
        }
        try check(result)
        try emit(Data(scratch[0..<length]))
        frameCount = ppcp_bundle_writer_frame_count(writer)
    }

    /// `MSG` 3.3a — the declaration, so the bundle says what produced it.
    public func record(declaration: PpcpDeclaration) throws {
        try peer.declare(declaration)
        try flush(.control)
    }

    /// `CORE` 4.1b — the hostless `session_open` this device records.
    public func open(session: PpcpSessionRecord) throws {
        try peer.openSession(session)
        try flush(.control)
    }

    public func open(stream: PpcpStreamRecord) throws {
        try peer.openStream(stream)
        try flush(.control)
    }

    public func record(readiness: ppcp_readiness, streamIds: [String] = []) throws {
        try peer.reportReadiness(readiness, streamIds: streamIds)
        try flush(.control)
    }

    /// `CORE` 7.3d — the interruption and the gap it left, recorded explicitly.
    ///
    /// ⚠ Conferred by **Capture** like `readiness`, so a hostless bundle carries
    /// it. What a bundle must not carry is `arm`/`disarm`, which are **Live**'s
    /// (7.3b) — the difference is that an interruption is something that happened
    /// to this peer, not a command somebody sent it.
    public func record(_ interruption: InterruptionRecord) throws {
        try peer.interruption(kind: interruption.kind.rawValue,
                              timebaseId: interruption.timebaseId,
                              intervalNs: interruption.intervalNs,
                              recovered: interruption.recovered,
                              streamIds: interruption.streamIds)
        try flush(.control)
    }

    /// - Parameter isPreview: ⛔ **refused.** 5.11j makes a preview Capture
    ///   live-only — "discard rather than queue; MUST NOT retain for later
    ///   transfer or write to a bundle". The parameter exists so a caller
    ///   forwarding announcements to both a live link and a bundle gets an error
    ///   here instead of silently persisting one (CT-I36a assertion 3).
    public func announce(_ capture: PpcpCaptureRecord, isPreview: Bool = false) throws {
        guard isPreview == false else { throw SessionStoreError.previewIsNotRecordable }
        try peer.announce(capture)
        try flush(.control)
    }

    /// `MSG` §9.2 — the manifest, and `ENC` 7c makes it precede every payload
    /// frame so an interrupted read still yields an analysable session.
    ///
    /// ⚠ `completeness` is **asserted** here, by the peer that owns the data, and
    /// is never inferred by a reader from what happens to be present (I10). A
    /// session the app abandoned says `partial` and means it.
    public func recordManifest(sessionId: String,
                               streamIds: [String],
                               captures: [PpcpCaptureRecord],
                               completeness: PpcpCaptureRecord.Completeness,
                               shotCount: UInt64,
                               candidateCount: UInt64) throws {
        // ⚠ **`ppcp_msg` is about 48 KB and every byte of that is on the heap
        // here, deliberately.** A C *union* imports into Swift as a struct whose
        // members are COMPUTED properties, so `message.pointee.body.session_manifest`
        // is a get-modify-set of the whole union — a 48 KB stack temporary per
        // field touched. Written the obvious way this suite died with SIGBUS,
        // which is what a stack overflow looks like on arm64. `body` itself is a
        // stored property, so taking one pointer to it and rebinding that is
        // in-place, and nothing large is ever copied.
        let bytes = MemoryLayout<ppcp_msg>.stride
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: bytes, alignment: MemoryLayout<ppcp_msg>.alignment)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        let message = raw.assumingMemoryBound(to: ppcp_msg.self)
        defer { raw.deallocate() }

        // ⚠ `1`, not `0`. `ENC` §5 numbers `msg_id` from 1 and
        // `ppcp_envelope_init` refuses a zero outright; the value here is a
        // placeholder either way, because `ppcp_peer_send` assigns the real one
        // from the peer's own sequence (5c) so two frames cannot share one.
        try check(ppcp_msg_init(message, PPCP_MT_SESSION_MANIFEST, 1))

        let streams = try DevicePeer.ids(streamIds)
        guard streams.count <= Int(PPCP_MAX_STREAM_IDS),
              captures.count <= Int(PPCP_MAX_MANIFEST) else {
            throw PpcpLibraryError(PPCP_ERR_LIMIT)
        }

        var entries: [ppcp_manifest_entry] = []
        for record in captures {
            var entry = ppcp_manifest_entry()
            try check(ppcp_id_set_z(&entry.capture_id, record.id))
            try check(ppcp_id_set_z(&entry.stream_id, record.streamId))
            entry.bytes = record.bytes ?? 0
            if let digestBytes = record.digest {
                guard digestBytes.count == Int(PPCP_SHA256_BYTES) else {
                    throw PpcpLibraryError(PPCP_ERR_INVALID)
                }
                var digestRaw = [UInt8](digestBytes)
                try check(ppcp_digest_set(&entry.digest, &digestRaw))
            }
            entries.append(entry)
        }

        let asserted: ppcp_completeness = switch completeness {
        case .complete: PPCP_COMPLETE
        case .partial: PPCP_PARTIAL
        case .absent: PPCP_ABSENT
        }

        try withUnsafeMutablePointer(to: &message.pointee.body) { body in
            try body.withMemoryRebound(to: ppcp_body_session_manifest.self,
                                       capacity: 1) { manifest in
                try check(ppcp_id_set_z(&manifest.pointee.session_id, sessionId))
                // A C fixed array imports as a tuple, which has no subscript;
                // rebinding it to a buffer is the supported way to index one.
                withUnsafeMutablePointer(to: &manifest.pointee.streams) { tuple in
                    tuple.withMemoryRebound(to: ppcp_id.self,
                                            capacity: Int(PPCP_MAX_STREAM_IDS)) {
                        for (index, id) in streams.enumerated() { $0[index] = id }
                    }
                }
                manifest.pointee.stream_count = streams.count
                withUnsafeMutablePointer(to: &manifest.pointee.captures) { tuple in
                    tuple.withMemoryRebound(to: ppcp_manifest_entry.self,
                                            capacity: Int(PPCP_MAX_MANIFEST)) {
                        for (index, entry) in entries.enumerated() { $0[index] = entry }
                    }
                }
                manifest.pointee.capture_count = captures.count
                manifest.pointee.completeness = asserted
                manifest.pointee.count_shots = shotCount
                manifest.pointee.count_candidates = candidateCount
                manifest.pointee.count_captures = UInt64(captures.count)
            }
        }

        try peer.send(message, on: .control)
        try flush(.control)
    }

    /// `ENC` §6 — the payload of one Capture, on the bulk channel.
    ///
    /// ⚠ `chunkBytes` is passed to every chunk call rather than remembered, so
    /// `offset` (6b) and each chunk's digest (6c) are computed by the library
    /// from the index and cannot disagree with what this side believes.
    ///
    /// ⛔ `ENC` 7c — refused by the writer before `session_manifest`, which is
    /// why `recordManifest` is not optional and not last.
    /// - Parameter achievedFrames: `CORE` 5.8d / I30 — the per-frame series
    ///   travels here, with the payload it describes, and nowhere else. A bundle
    ///   written without it is a bundle from which §6.1's conversion cannot be
    ///   performed at all (I17).
    public func writePayload(captureId: String, clip: Data,
                             chunkBytes: Int = 256 * 1024,
                             achievedFrames: PpcpAchievedFrames? = nil) throws {
        let digest = Self.digest(of: clip)
        try peer.payloadBegin(captureId: captureId, bytes: UInt64(clip.count),
                              digest: digest, chunkBytes: UInt32(chunkBytes),
                              achievedFrames: achievedFrames)
        try flush(.bulk)

        var index: UInt32 = 0
        var offset = 0
        while offset < clip.count {
            let end = min(offset + chunkBytes, clip.count)
            try peer.payloadChunk(captureId: captureId, index: index,
                                  chunkBytes: UInt32(chunkBytes),
                                  data: clip[offset..<end])
            try flush(.bulk)
            index += 1
            offset = end
        }
        try peer.payloadEnd(captureId: captureId, digest: digest)
        try flush(.bulk)
    }

    /// `ENC` 7e — **no bytes**. There is no footer and no trailing index:
    /// random access is deliberately not in `ppcp/1.0`, so this exists to answer
    /// "was this bundle finished on purpose" and to refuse a further append.
    public func finish() throws {
        let writer = try handle()
        // ⚠ Read the two facts out BEFORE dropping the handle. A finished bundle
        // is exactly the one a caller wants to ask about, and an accessor that
        // answered a default once the handle went would be worse than one that
        // refused: `hasManifest` would read `true` for a bundle that never had
        // one.
        finalHasManifest = ppcp_bundle_writer_has_manifest(writer)
        finalIsHostless = ppcp_bundle_writer_is_hostless(writer)
        try check(ppcp_bundle_writer_finish(writer))
        self.writer = nil
    }

    private var finalHasManifest = false
    private var finalIsHostless = false

    /// True once a `session_manifest` has been recorded (`ENC` 7c).
    public var hasManifest: Bool {
        writer.map(ppcp_bundle_writer_has_manifest) ?? finalHasManifest
    }

    /// True once a `session_open` **without** the two arbitration parameters has
    /// been recorded — the bundle stating that no arbitration occurred
    /// (`CORE` 4.1d, 5.10e).
    public var isHostless: Bool {
        writer.map(ppcp_bundle_writer_is_hostless) ?? finalIsHostless
    }

    /// SHA-256, from the library rather than from CryptoKit: `CaptureCore` links
    /// no platform framework, and `ENC` 6c names exactly one algorithm.
    public static func digest(of bytes: Data) -> Data {
        var out = [UInt8](repeating: 0, count: Int(PPCP_SHA256_BYTES))
        bytes.withUnsafeBytes { raw in
            ppcp_sha256_hash(raw.baseAddress, raw.count, &out)
        }
        return Data(out)
    }
}

// MARK: - Reading a bundle back

/// `ENC` §7 read through `ppcp_bundle_reader` — the same frames, through the
/// same `ppcp_peer_feed` a socket drives.
///
/// ⚠ **There is no importer and no second schema.** A bundle is a recorded
/// message stream, so reading one is feeding an engine; what this type adds is
/// the embedding's buffer management and `ENC` 7d's three-way answer.
public final class SessionBundleReader: @unchecked Sendable {

    private let storage: UnsafeMutableRawPointer
    private var reader: OpaquePointer?
    private let sink: DevicePeer?
    private var tail = Data()
    /// I34's index, copied out of the reader at `finish()` so `hasSeen` still
    /// answers once the handle is gone. ⛔ Heap, never a Swift value: see the
    /// note in `finish()`.
    private let seenIndex: UnsafeMutablePointer<ppcp_capture_index>

    /// - Parameter sink: the peer the frames are delivered to. `nil` parses and
    ///   accounts for them without delivering, which is what a fixture validator
    ///   wants.
    public init(sink: DevicePeer? = nil) throws {
        self.sink = sink
        seenIndex = .allocate(capacity: 1)
        ppcp_capture_index_init(seenIndex)
        let size = ppcp_bundle_reader_sizeof()
        storage = .allocate(byteCount: size, alignment: MemoryLayout<UInt64>.alignment)
        var handle: OpaquePointer?
        do {
            try check(sink.withPeerHandle { ppcp_bundle_reader_new(storage, size, $0, &handle) })
        } catch {
            storage.deallocate()
            seenIndex.deallocate()
            throw error
        }
        reader = handle
    }

    deinit {
        storage.deallocate()
        seenIndex.deallocate()
    }

    private func handle() throws -> OpaquePointer {
        guard let reader else { throw SessionStoreError.bundleFinished }
        return reader
    }

    /// Feed bytes as they are read. ⚠ Whole frames are consumed and the tail is
    /// held here for the next call — the same contract as `ppcp_peer_feed`, and
    /// the reason a bundle can be streamed rather than read whole.
    public func feed(_ bytes: Data) throws {
        tail.append(bytes)
        let reader = try handle()
        var consumed = 0
        let result: ppcp_result = tail.withUnsafeBytes { raw in
            ppcp_bundle_reader_feed(reader, raw.bindMemory(to: UInt8.self).baseAddress,
                                    raw.count, &consumed)
        }
        try check(result)
        tail = Data(tail.dropFirst(consumed))
    }

    /// `ENC` 7d, and it is worth reading twice.
    ///
    ///   asserted in the bundle        → that value, whatever the bytes did
    ///   not asserted, bytes truncated → `partial`
    ///   not asserted, bytes whole     → `unknown`
    ///
    /// ⛔ `unknown` and not `complete` for the last row: completeness is
    /// **asserted** by the peer that owns the data and is never inferred by the
    /// receiver from what has arrived (I10).
    public enum Completeness: Sendable, Hashable { case complete, partial, absent, unknown }

    public func finish() throws -> Completeness {
        let reader = try handle()
        var completeness = PPCP_COMPLETE
        try check(ppcp_bundle_reader_finish(reader, &completeness))
        // ⚠ Snapshot before dropping the handle. `finish()` is exactly when a
        // caller asks how the read went, and accessors that answered a default
        // afterwards would report a whole bundle as zero frames — a lie in the
        // one direction that matters, since "nothing arrived" is what an
        // embedding acts on.
        snapshot = Snapshot(frameCount: ppcp_bundle_reader_frame_count(reader),
                            manifestOrdered: ppcp_bundle_reader_manifest_ordered(reader),
                            minor: Int(ppcp_bundle_reader_minor(reader)),
                            truncated: ppcp_bundle_reader_truncated(reader),
                            captureCount: ppcp_bundle_reader_index(reader)
                                .map { ppcp_capture_index_count($0) } ?? 0)
        // ⚠ **The capture index is copied through raw memory, not assigned.**
        // D4 found `hasSeen` answering `false` for every Capture once `finish()`
        // had run — the exact "accessor that answered a default afterwards" the
        // note above warns about, and in the direction that matters, since a
        // caller acts on "not held" by importing the session again. The obvious
        // fix, snapshotting the index by value, died with SIGBUS: it holds 512
        // keys inline and is about 100 KB, so a Swift-level copy of it is a
        // 100 KB stack temporary. Same hazard as the `ppcp_msg` note in
        // `recordManifest`, same answer — keep it on the heap and `memcpy`.
        if let live = ppcp_bundle_reader_index(reader) {
            UnsafeMutableRawPointer(seenIndex).copyMemory(
                from: UnsafeRawPointer(live),
                byteCount: MemoryLayout<ppcp_capture_index>.size)
        }
        self.reader = nil
        return switch completeness {
        case PPCP_COMPLETE: .complete
        case PPCP_PARTIAL: .partial
        case PPCP_ABSENT: .absent
        default: .unknown
        }
    }

    private struct Snapshot {
        var frameCount = 0
        var manifestOrdered = true
        var minor = 0
        var truncated = false
        var captureCount = 0
    }
    private var snapshot = Snapshot()

    public var frameCount: Int {
        reader.map(ppcp_bundle_reader_frame_count) ?? snapshot.frameCount
    }
    /// `ENC` 7c is a MUST on the writer, so a `payload_*` before the manifest is
    /// a non-conformant bundle. The reader reads on — one misordered frame is not
    /// a reason to lose a session — and says so here.
    public var manifestOrdered: Bool {
        reader.map(ppcp_bundle_reader_manifest_ordered) ?? snapshot.manifestOrdered
    }
    /// `ENC` 7f — a `minor` above this reader's own is accepted and its unknown
    /// frames ignored (I13). This is what it was.
    public var minor: Int {
        reader.map { Int(ppcp_bundle_reader_minor($0)) } ?? snapshot.minor
    }
    public var truncated: Bool {
        reader.map(ppcp_bundle_reader_truncated) ?? snapshot.truncated
    }

    /// **I34** — "identity is `Capture.id` scoped by session and owning peer, and
    /// `digest` where present is checked as CONTENT rather than used as the key."
    ///
    /// ⛔ The index lives in `libppcp` because both applications need it and it is
    /// the same rule for both (ground rule 1). A second read of the same bundle
    /// through the same reader reports every Capture as already held.
    public func hasSeen(sessionId: String, peerId: String, captureId: String) throws -> Bool {
        var key = ppcp_capture_key()
        try check(ppcp_id_set_z(&key.session_id, sessionId))
        try check(ppcp_id_set_z(&key.peer_id, peerId))
        try check(ppcp_id_set_z(&key.capture_id, captureId))
        // Live handle first, then the copy taken at `finish()`.
        let index = reader.flatMap(ppcp_bundle_reader_index) ?? seenIndex
        return ppcp_capture_index_contains(index, &key)
    }

    public var captureCount: Int {
        guard let reader, let index = ppcp_bundle_reader_index(reader) else {
            return snapshot.captureCount
        }
        return ppcp_capture_index_count(index)
    }
}

private extension Optional where Wrapped == DevicePeer {
    /// ⚠ `ppcp_bundle_reader_new` takes a nullable sink, and a Swift optional of
    /// a class with an opaque handle inside it has no natural bridge. One place
    /// to unwrap it, rather than the same `if let` at both call sites.
    func withPeerHandle<T>(_ body: (OpaquePointer?) -> T) -> T {
        guard let self else { return body(nil) }
        return self.withHandle(body)
    }
}
