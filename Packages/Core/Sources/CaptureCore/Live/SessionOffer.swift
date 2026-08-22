//  SessionOffer.swift
//  `MSG` §9.1–9.2 — the device offers the Sessions it holds and the host chooses.
//
//  ⛔ **This is not an export format and not an importer, and it is emphatically
//  not a file picker.** The user's decision of 22 August 2026 (plan §9) is that a
//  *connected* capture device offers its recorded sessions and the host picks from
//  a list. PinPointStudio's menu item and native dialog were removed for it, and
//  this application has never had one.
//
//  ⚠ **A stored Session is a `PPCPBNDL` file and a live Session is a pair of
//  sockets, and `ENC` 7a makes them the same bytes.** So "offer the host my
//  stored sessions" is take the frames out of the file and put them through the
//  peer's TX path, with `msg_id` renumbered into the live sequence (`ENC` 5c).
//  That is `ppcp_bundle_replay`, and it is why there is no second encoder here.
//
//  ⚠ **`feed` stops when the peer's outbound queue is full**, reports what it
//  consumed and returns success. A caller that does not drain between feeds makes
//  no progress — deliberately, because the alternative is an engine that buffers
//  a whole session.
//
//  Spec: `MSG` §9.1, §9.2; `CORE` §9, §8.5c; `ENC` §7. Plan D6.

import Foundation
import CPPCP

/// `MSG` 9.1 — what the device says it holds.
///
/// ⚠ Session identity is `session_id` **plus** `minting_peer_id` (8.5c). A device
/// that offered only the id would collide with a session another device recorded.
public struct PpcpSessionOffer: Sendable, Hashable {
    public let sessionId: String
    public let mintingPeerId: String
    /// I10 — asserted by the peer that owns the data, never inferred from what a
    /// reader happens to find in the bytes.
    public let completeness: PpcpCaptureRecord.Completeness
    public let bytesEstimate: UInt64?
    /// `CORE` 6.5b — a wall-clock **label** beside an instant in a timebase that
    /// measures (I15). Both or neither, and never used to compute an interval.
    public let epochWallUtcNs: Int64?
    public let epochAtNs: Int64?
    public let epochTimebaseId: String?

    public init(sessionId: String, mintingPeerId: String,
                completeness: PpcpCaptureRecord.Completeness,
                bytesEstimate: UInt64? = nil,
                epochWallUtcNs: Int64? = nil,
                epochAtNs: Int64? = nil,
                epochTimebaseId: String? = nil) {
        self.sessionId = sessionId
        self.mintingPeerId = mintingPeerId
        self.completeness = completeness
        self.bytesEstimate = bytesEstimate
        self.epochWallUtcNs = epochWallUtcNs
        self.epochAtNs = epochAtNs
        self.epochTimebaseId = epochTimebaseId
    }

    var value: ppcp_body_session_offer {
        var body = ppcp_body_session_offer()
        _ = ppcp_id_set_z(&body.session_id, sessionId)
        _ = ppcp_id_set_z(&body.minting_peer_id, mintingPeerId)
        body.completeness = switch completeness {
        case .complete: PPCP_COMPLETE
        case .partial: PPCP_PARTIAL
        case .absent: PPCP_ABSENT
        }
        if let bytesEstimate {
            body.has_bytes_estimate = true
            body.bytes_estimate = bytesEstimate
        }
        if let epochWallUtcNs, let epochAtNs, let epochTimebaseId {
            body.epoch.present = true
            body.epoch.wall_utc_ns = epochWallUtcNs
            _ = ppcp_instant_make_z(&body.epoch.at, epochTimebaseId, epochAtNs)
        }
        return body
    }

    init(_ body: ppcp_body_session_offer) {
        sessionId = ppcpString(body.session_id)
        mintingPeerId = ppcpString(body.minting_peer_id)
        completeness = switch body.completeness {
        case PPCP_PARTIAL: .partial
        case PPCP_ABSENT: .absent
        default: .complete
        }
        bytesEstimate = body.has_bytes_estimate ? body.bytes_estimate : nil
        epochWallUtcNs = body.epoch.present ? body.epoch.wall_utc_ns : nil
        epochAtNs = body.epoch.present ? body.epoch.at.ns : nil
        epochTimebaseId = body.epoch.present ? ppcpString(body.epoch.at.tb) : nil
    }
}

/// `MSG` 9.1 — the host's answer.
///
/// ⚠ `haveDigests` is what the importer already holds, and it lets the exporter
/// **skip payloads**. ⛔ The `capture_announce` and the `session_manifest` entry
/// are still sent: the importer needs the Capture *record*, and it is the payload
/// that is redundant, not the fact.
public struct PpcpSessionAccept: Sendable, Hashable {

    public enum Verdict: Sendable, Hashable {
        case accept
        /// 8.5c — "re-import of a session already held is a no-op, never a
        /// duplicate". The device records it per host and stops offering.
        case alreadyHeld
        case refuse

        var c: ppcp_offer_verdict {
            switch self {
            case .accept: PPCP_OFFER_ACCEPT
            case .alreadyHeld: PPCP_OFFER_ALREADY_HELD
            case .refuse: PPCP_OFFER_REFUSE
            }
        }
    }

    public let sessionId: String
    public let verdict: Verdict
    public let reason: String?
    public let haveDigests: [Data]

    public init(sessionId: String, verdict: Verdict,
                reason: String? = nil, haveDigests: [Data] = []) {
        self.sessionId = sessionId
        self.verdict = verdict
        self.reason = reason
        self.haveDigests = haveDigests
    }

    init(_ body: ppcp_body_session_accept) {
        sessionId = ppcpString(body.session_id)
        verdict = switch body.verdict {
        case PPCP_OFFER_ALREADY_HELD: .alreadyHeld
        case PPCP_OFFER_REFUSE: .refuse
        default: .accept
        }
        reason = body.has_reason ? ppcpString(body.reason) : nil
        var value = body
        haveDigests = withUnsafeBytes(of: &value.have_digests) { raw in
            let base = raw.bindMemory(to: ppcp_digest.self)
            return (0..<body.have_digest_count).compactMap { ppcpDigestData(base[$0]) }
        }
    }

    /// ⚠ Built on the heap: `ppcp_body_session_accept` carries 64 digests inline,
    /// and the Swift importer's computed union members would copy the lot for
    /// every field store.
    func withValue<T>(_ body: (UnsafeMutablePointer<ppcp_body_session_accept>) throws -> T)
        rethrows -> T {
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<ppcp_body_session_accept>.stride,
            alignment: MemoryLayout<ppcp_body_session_accept>.alignment)
        raw.initializeMemory(as: UInt8.self, repeating: 0,
                             count: MemoryLayout<ppcp_body_session_accept>.stride)
        defer { raw.deallocate() }
        let value = raw.assumingMemoryBound(to: ppcp_body_session_accept.self)
        _ = ppcp_id_set_z(&value.pointee.session_id, sessionId)
        value.pointee.verdict = verdict.c
        if let reason {
            value.pointee.has_reason = true
            _ = ppcp_id_set_z(&value.pointee.reason, reason)
        }
        let count = min(haveDigests.count, Int(PPCP_MAX_HAVE_DIGESTS))
        value.pointee.have_digest_count = count
        withUnsafeMutablePointer(to: &value.pointee.have_digests) { tuple in
            tuple.withMemoryRebound(to: ppcp_digest.self, capacity: count) { out in
                for index in 0..<count {
                    var bytes = [UInt8](haveDigests[index])
                    guard bytes.count == Int(PPCP_SHA256_BYTES) else { continue }
                    _ = ppcp_digest_set(out + index, &bytes)
                }
            }
        }
        return try body(value)
    }
}

// MARK: - Replaying a stored bundle onto the live link

/// `MSG` 9.1 device side: the accepted Session's frames, put onto the link.
///
/// ⛔ **`have_digests` is honoured by the library, not by this file** (9.1a). It
/// decides which payload frames to skip, and identity there is `Capture.digest` —
/// a *different* rule from I34's re-import identity, because a digest cannot be
/// the key for an `absent` Capture and an `absent` Capture has no payload to skip.
public final class BundleReplay: @unchecked Sendable {

    private let storage: UnsafeMutableRawPointer
    private var replay: OpaquePointer?

    public init(peer: DevicePeer, haveDigests: [Data]) throws {
        let size = ppcp_bundle_replay_sizeof()
        storage = .allocate(byteCount: size, alignment: MemoryLayout<UInt64>.alignment)
        var handle: OpaquePointer?
        var digests: [ppcp_digest] = []
        for data in haveDigests.prefix(Int(PPCP_REPLAY_SKIP_MAX)) {
            guard data.count == Int(PPCP_SHA256_BYTES) else { continue }
            var digest = ppcp_digest()
            var bytes = [UInt8](data)
            guard ppcp_digest_set(&digest, &bytes) == PPCP_OK else { continue }
            digests.append(digest)
        }
        do {
            let peerHandle = try peer.handleForLive()
            try digests.withUnsafeBufferPointer { buffer in
                try check(ppcp_bundle_replay_new(storage, size, peerHandle,
                                                 buffer.baseAddress, buffer.count, &handle))
            }
        } catch {
            storage.deallocate()
            throw error
        }
        replay = handle
    }

    deinit { storage.deallocate() }

    /// Consumes whole frames and reports how many bytes it took; the caller
    /// re-presents the tail. ⚠ **Drain between feeds** — see the note at the top
    /// of this file.
    @discardableResult
    public func feed(_ bytes: Data) throws -> Int {
        guard let replay, bytes.isEmpty == false else { return 0 }
        var consumed = 0
        let result: ppcp_result = bytes.withUnsafeBytes { raw in
            ppcp_bundle_replay_feed(replay, raw.bindMemory(to: UInt8.self).baseAddress,
                                    raw.count, &consumed)
        }
        try check(result)
        return consumed
    }

    public var sentFrames: Int { replay.map(ppcp_bundle_replay_sent) ?? 0 }
    /// Payload frames **not** re-sent because the importer said it holds them.
    public var skippedPayloads: Int { replay.map(ppcp_bundle_replay_skipped) ?? 0 }
    public var heldCaptures: Int { replay.map(ppcp_bundle_replay_held_count) ?? 0 }
}
