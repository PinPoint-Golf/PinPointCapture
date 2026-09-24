//  DevicePeerHost.swift
//  The host's half of a link, for a `DevicePeer` constructed with `role: .host`.
//
//  ⚠ **This application is never a host.** These exist so a test can stand a
//  counterpart up in-process that does what PinPointStudio does — open a hosted
//  Session, decline a Shot, commit a Capture — and drive `AppModel` through the
//  whole of `CORE` 5.14g against it on every `make test`, rather than on the
//  hardware runs that get skipped (#105, Mark 24 Sep 2026). Each is one libppcp
//  call; nothing here decides anything a host would decide.

import CPPCP

public extension DevicePeer {

    /// `CORE` 4.1b — a **hosted** `session_open`, with the two arbitration
    /// parameters 5.10e makes structural. ⛔ libppcp refuses it from a peer that
    /// is not `role: host` (`src/ppcp_peer.c`), which is the point.
    func openHostedSession(id: String, timebaseRef: String, openedAtNs: Int64,
                           coincidenceWindowNs: Int64 = Int64(PPCP_DEFAULT_COINCIDENCE_WINDOW_NS),
                           issueHoldNs: Int64 = Int64(PPCP_DEFAULT_ISSUE_HOLD_NS)) throws {
        let handle = try handleForLive()
        var session = ppcp_session()
        var openedAt = ppcp_instant()
        try check(ppcp_instant_make_z(&openedAt, timebaseRef, openedAtNs))
        try check(ppcp_session_make_hosted(&session, id, timebaseRef, &openedAt,
                                           coincidenceWindowNs, issueHoldNs))
        try check(ppcp_peer_session_open(handle, &session))
        noteSessionOpened(atNs: openedAtNs)
    }

    /// `MSG` 8.5 (CR-03) — this receiver will not keep `shotId`. The library
    /// remembers it, so a later `captureCommitted` for one of its Captures is
    /// refused (I40).
    func shotDisposition(shotId: String, declined: Bool = true, reason: String?) throws {
        let handle = try handleForLive()
        try check(ppcp_peer_shot_disposition(
            handle, shotId,
            declined ? PPCP_DISPOSITION_DECLINED : "com.pinpoint.test.kept",
            reason))
    }

    /// `MSG` 8.4a — this receiver holds `captureId` durably. The digest is the
    /// one the owner announced, read from this peer's record of that announce,
    /// so the commit names exactly the payload that was offered (I34).
    func captureCommitted(captureId: String) throws {
        let handle = try handleForLive()
        var id = ppcp_id()
        try check(ppcp_id_set_z(&id, captureId))
        guard let entry = ppcp_transfer_find(ppcp_peer_transfers(handle), &id),
              entry.pointee.digest.present
        else { throw PpcpLibraryError(PPCP_ERR_NOT_FOUND) }
        var digest = entry.pointee.digest
        try check(ppcp_peer_capture_committed(handle, captureId, &digest))
    }
}
