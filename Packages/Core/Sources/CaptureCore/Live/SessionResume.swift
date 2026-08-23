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
    /// ✅ **F-D6-1 closed** (`libppcp` `e52647e`). This was the **one** message in
    /// this application assembled as a raw `ppcp_msg`, for a clause `MSG` 4.3a
    /// makes a MUST — and `ppcp_body_session_resume` is one of the large arms
    /// (64 Shot ids, 64 pending Captures), which is exactly the Swift hazard
    /// F-D3-1 is about. `ppcp_peer_session_resume` is the originator that was
    /// missing, so the union access, the 48 KB heap allocation and the two
    /// `withMemoryRebound` walks are all gone.
    ///
    /// ⚠ **The engine arms 4.3b's burst itself.** `peer.h`: a synchronisation
    /// burst runs *before* any queued payload resumes, because the relation
    /// drifted while the link was down — about 1.2 ms per minute at 20 ppm. The
    /// embedding still has to pump, which `HostLinkDriver.resume` does.
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
        let peer = try handleForLive()

        // ⛔ **The Session resumed is the one this peer holds, arbitration
        // parameters included.** I16 makes them immutable and 5.10e makes them
        // structural, so rebuilding a *hostless* Session for a resume would
        // silently drop the two parameters the host set — and 4.3a's whole point
        // is that the Session did not end.
        var session = ppcp_session()
        if let held = sessionParameters, held.hasArbitration {
            try check(ppcp_session_make_hosted(&session, sessionId, held.timebaseRefId,
                                               held.coincidenceWindowNs,
                                               held.issueHoldNs))
        } else {
            // ⚠ `CaptureCore` declares no timebase of its own — the ids are the
            // embedding's (`Sources/Platform/PpcpTimebases.swift`). A resume with
            // no Session to read one from can only happen for a Session nobody
            // opened, so it is refused rather than given an invented name: 5.1's
            // "absence never means zero" applied to an identifier.
            guard let reference = sessionParameters?.timebaseRefId else {
                throw PpcpLibraryError(PPCP_ERR_NOT_FOUND)
            }
            try check(ppcp_session_make_hostless(&session, sessionId, reference))
        }

        let shotIds = try DevicePeer.ids(mintedShots)
        var pending = pendingCaptures.map { entry -> ppcp_pending_capture in
            var slot = ppcp_pending_capture()
            _ = ppcp_id_set_z(&slot.capture_id, entry.captureId)
            var digest = [UInt8](entry.digest)
            if digest.count == Int(PPCP_SHA256_BYTES) {
                _ = ppcp_digest_set(&slot.digest, &digest)
            }
            slot.bytes = entry.bytes
            if let acked = entry.ackedIndex {
                slot.has_acked_index = true
                slot.acked_index = acked
            }
            return slot
        }

        try shotIds.withUnsafeBufferPointer { shots in
            try pending.withUnsafeMutableBufferPointer { captures in
                try check(ppcp_peer_session_resume(peer, &session,
                                                   shots.baseAddress, shots.count,
                                                   captures.baseAddress, captures.count))
            }
        }
    }
}
