//  SessionResume.swift
//  `MSG` §4.3 — what a device says when it comes back.
//
//  ⚠ **F-D6-1: this is the one message in the whole application assembled as a
//  `ppcp_msg` by hand, because `libppcp` has no originator for it.** `peer.h`
//  gives `ppcp_peer_session_open`, `_state`, `_close`, `_context_change`,
//  `_offer`, `_accept` and `_manifest`, and no `ppcp_peer_session_resume`. 4.3a is
//  a MUST — "a peer reconnecting to a session it was previously joined to sends
//  `session_resume` rather than `session_open`" — so the message is not optional,
//  and `ppcp_peer_send` is the documented escape hatch for exactly this case: it
//  is still C2-checked and still channel-checked, so it is a route for messages
//  with no dedicated entry point rather than a way past the rules.
//
//  ⚠ **`ppcp_body_session_resume` is one of the large arms** — 64 Shot ids and 64
//  pending Captures inline — so it follows `message.h`'s heap-and-rebind pattern
//  exactly. Written the obvious way (`msg.body.session_resume.peer_id = …`) the
//  Swift importer reads the whole 48 KB union into a stack temporary per field
//  store, which is what killed D3's suite with SIGBUS on a device.
//
//  ⛔ **4.3b: a synchronisation burst runs BEFORE any queued payload resumes.**
//  The relation drifted while the link was down — at 20 ppm, about 1.2 ms per
//  minute — and shots captured during the gap must land on the right timeline.
//  `HostLinkDriver` sequences it; this file only carries the message.
//
//  ⛔ **4.3c: Shots minted during the outage are reconciled through `shot_link`.
//  They are not renumbered and their `authority` stays `device`** (I7, I9).
//
//  Spec: `MSG` §4.3; `CORE` §8.3f, §6.3c. Plan D6.

import Foundation
import CPPCP

/// One entry of `session_resume.pending_captures`.
public struct PendingCapture: Sendable, Hashable {
    public let captureId: String
    public let digest: Data
    public let bytes: UInt64
    /// 8.3d — the last index the receiver acknowledged. `nil` where none was, and
    /// resumption then starts at 0. ⛔ Absence is not zero: "no chunk was
    /// acknowledged" and "chunk 0 was acknowledged" are different facts.
    public let ackedIndex: UInt32?

    public init(captureId: String, digest: Data, bytes: UInt64, ackedIndex: UInt32?) {
        self.captureId = captureId
        self.digest = digest
        self.bytes = bytes
        self.ackedIndex = ackedIndex
    }
}

public extension DevicePeer {

    /// `MSG` 4.3 — `session_resume`.
    ///
    /// - Parameter mintedShots: 8.3f — the Shots minted while the link was down.
    ///   ⛔ Their ids as minted: 4.3c forbids renumbering them, and their
    ///   `authority` stays `device` whatever the host does next.
    func sendSessionResume(sessionId: String,
                           peerId: String,
                           mintedShots: [String],
                           pendingCaptures: [PendingCapture],
                           channel: PpcpChannel = .control) throws {
        guard mintedShots.count <= Int(PPCP_MAX_MINTED_SHOTS),
              pendingCaptures.count <= Int(PPCP_MAX_PENDING) else {
            throw PpcpLibraryError(PPCP_ERR_LIMIT)
        }

        let byteCount = MemoryLayout<ppcp_msg>.stride
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount, alignment: MemoryLayout<ppcp_msg>.alignment)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        defer { raw.deallocate() }
        let message = raw.assumingMemoryBound(to: ppcp_msg.self)

        // ⚠ `1` is a placeholder: `ppcp_peer_send` assigns the real `msg_id` from
        // the peer's own sequence (`ENC` 5c), and `ppcp_envelope_init` refuses a
        // zero outright.
        try check(ppcp_msg_init(message, PPCP_MT_SESSION_RESUME, 1))

        try withUnsafeMutablePointer(to: &message.pointee.body) { body in
            try body.withMemoryRebound(to: ppcp_body_session_resume.self,
                                       capacity: 1) { resume in
                try check(ppcp_id_set_z(&resume.pointee.session_id, sessionId))
                try check(ppcp_id_set_z(&resume.pointee.peer_id, peerId))

                resume.pointee.minted_shot_count = mintedShots.count
                withUnsafeMutablePointer(to: &resume.pointee.minted_shots) { tuple in
                    tuple.withMemoryRebound(to: ppcp_id.self,
                                            capacity: Int(PPCP_MAX_MINTED_SHOTS)) { out in
                        for (index, id) in mintedShots.enumerated() {
                            _ = ppcp_id_set_z(out + index, id)
                        }
                    }
                }

                resume.pointee.pending_count = pendingCaptures.count
                withUnsafeMutablePointer(to: &resume.pointee.pending) { tuple in
                    tuple.withMemoryRebound(to: ppcp_pending_capture.self,
                                            capacity: Int(PPCP_MAX_PENDING)) { out in
                        for (index, pending) in pendingCaptures.enumerated() {
                            let slot = out + index
                            _ = ppcp_id_set_z(&slot.pointee.capture_id, pending.captureId)
                            var bytes = [UInt8](pending.digest)
                            if bytes.count == Int(PPCP_SHA256_BYTES) {
                                _ = ppcp_digest_set(&slot.pointee.digest, &bytes)
                            }
                            slot.pointee.bytes = pending.bytes
                            if let acked = pending.ackedIndex {
                                slot.pointee.has_acked_index = true
                                slot.pointee.acked_index = acked
                            }
                        }
                    }
                }
            }
        }

        try send(message, on: channel)
    }
}
