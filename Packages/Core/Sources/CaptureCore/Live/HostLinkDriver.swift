//  HostLinkDriver.swift
//  `HostLinkState` driven by the library's liveness, and the reconnect sequence
//  §4.3b insists on.
//
//  ⚠ **B3's four live states were an app vocabulary and are now a *view* of the
//  protocol's facts.** `connected`/`weak`/`lost`/`resyncing` are what the screen
//  says; what decides them is `ppcp_peer_link_state` (7.4c, three consecutive
//  missed intervals), `ppcp_peer_zero_host` (8.3g), and whether the sync burst
//  has produced an estimate yet (6.3a). Nothing here counts heartbeats itself.
//
//  ⛔ **No transition in this file disarms capture, pauses the recorder or drops a
//  frame.** 7.4d: "loss of the link MUST NOT cost a single captured frame. Capture
//  is non-recoverable; transfer is retryable. Under any resource constraint,
//  transfer, replay and reporting degrade before capture does." On `lost` the
//  first thing the UI reports is that capture is still running (REQ-RES-1, §9.2).
//
//  ⛔ **8.3g — a Session with an unreachable host is not a Session with no host.**
//  `Session.peers`, `timebase_ref`, `coincidence_window_ns` and `issue_hold_ns`
//  are unchanged (I16, 5.10e); what changes is that no arbitration occurs and this
//  peer mints under 8.3a–c. This driver therefore never rewrites a session
//  parameter, and `PpcpSessionParameters` is how a test asserts that.
//
//  Spec: `CORE` §6.3, §7.4, §8.3f–h; `MSG` §4.3, §5.4, §6. Plan D6.

import Foundation

/// Turns the library's liveness and sync state into `HostLinkState`, and
/// sequences what happens when the link comes back.
public final class HostLinkDriver: @unchecked Sendable {

    private let peer: DevicePeer
    private let timebaseId: String
    /// 6.3c — "a burst of 10–20 exchanges". ⚠ The library's own `PPCP_SYNC_BURST`
    /// is 16, and this is what the progress row counts towards; it is the
    /// specification's number and not a target invented here.
    public let burstTarget: Int

    public private(set) var state: HostLinkState = .none
    /// REQ-STATE-5 — the window during which the host was absent, reported
    /// explicitly on reconnect.
    public private(set) var outageStartedAtNs: Int64?
    /// 4.3b — set on link loss, cleared only once the post-reconnect burst has
    /// produced an estimate. **Queued payload does not move while it is true.**
    public private(set) var isAwaitingResyncBurst = false
    /// 8.3f — Shots minted while the link was down, for `session_resume`.
    public private(set) var mintedDuringOutage: [String] = []

    public init(peer: DevicePeer, timebaseId: String, burstTarget: Int = 16) {
        self.peer = peer
        self.timebaseId = timebaseId
        self.burstTarget = burstTarget
    }

    /// One tick. Drives the library's two pumps — they are **separate** (6.3d:
    /// "the heartbeat rate does not set the sync rate") — and re-derives the state.
    ///
    /// - Parameter throughputMbitPerSecond: `nil` where nothing has been measured.
    ///   ⛔ It decides `weak` versus `connected`, which is a *presentation*
    ///   distinction: the protocol has no such state, and neither branch changes
    ///   what is captured.
    @discardableResult
    public func pump(nowNs: Int64, throughputMbitPerSecond: Double? = nil) throws
        -> HostLinkState {
        try peer.livenessPump(nowNs: nowNs)
        try peer.syncPump(nowNs: nowNs)

        let previous = state
        state = try derive(nowNs: nowNs, throughput: throughputMbitPerSecond)

        if previous != .lost, state == .lost {
            outageStartedAtNs = nowNs
            // 8.3f — the regime is entered for the duration: mint locally, queue
            // Captures as `transfer: pending`, reconcile on reconnect.
            isAwaitingResyncBurst = true
        }
        if previous == .lost, state != .lost {
            // 6.3c — a network change is one of the three triggers, and a link
            // that went away and came back is the clearest one there is. The
            // library restarts each estimator's window, because the FIT is stale
            // and not merely the offset.
            try peer.syncTrigger(.networkChange)
        }
        return state
    }

    private func derive(nowNs: Int64, throughput: Double?) throws -> HostLinkState {
        // 8.3g — no host in the roster at all is not an outage; it is the
        // entry-level capture case, and the screen says "No host".
        guard peer.sessionParameters?.hasArbitration == true else {
            return peer.isLinkLost ? .lost : (state == .none ? .none : state)
        }
        if peer.isLinkLost { return .lost }
        if isAwaitingResyncBurst { return .resyncing }
        // 6.3a — offset **and** rate. Until the estimator has both, the pairing
        // burst is still running and the screen says so.
        guard peer.syncHasEstimate(timebaseId) else { return .pairing }
        if let throughput, throughput < 8 { return .weak }
        return .connected
    }

    /// Records a Shot minted while the link was down (8.3f).
    public func recordMintedDuringOutage(_ shotId: String) {
        guard state == .lost || isAwaitingResyncBurst else { return }
        mintedDuringOutage.append(shotId)
    }

    /// The reconnect sequence, in the order `MSG` §4.3 requires.
    ///
    /// ⛔ **`session_resume`, then the burst, then — and only then — the queued
    /// payload.** 4.3b is explicit that the synchronisation burst runs *before*
    /// any queued payload resumes: the relation drifted while the link was down,
    /// and shots captured during the gap have to land on the right timeline. A
    /// device that resumed the queue first would spend the reconnect's whole
    /// bandwidth putting bytes on a timeline it has not re-measured.
    ///
    /// - Returns: `false` while the burst is still converging — call again.
    @discardableResult
    public func resume(sessionId: String, peerId: String,
                       queue: PayloadTransferQueue, nowNs: Int64) throws -> Bool {
        if isAwaitingResyncBurst, hasSentResume == false {
            // 4.3a — `session_resume` and never `session_open`. Sent first so the
            // host learns what exists before anything large moves.
            try peer.sendSessionResume(sessionId: sessionId, peerId: peerId,
                                       mintedShots: mintedDuringOutage,
                                       pendingCaptures: queue.pendingForResume)
            hasSentResume = true
            try peer.syncTrigger(.connect)
        }
        guard isAwaitingResyncBurst else { return true }

        try peer.syncPump(nowNs: nowNs)
        guard peer.syncExchangeCount(timebaseId) >= burstTarget,
              peer.syncHasEstimate(timebaseId) else { return false }

        // 6.1f — publish the re-measured relation before the payload moves, so a
        // host reading a resumed Capture reads it against the current relation and
        // not the one that drifted.
        try peer.publishRelations()
        try queue.resumeAfterLinkLoss()
        isAwaitingResyncBurst = false
        hasSentResume = false
        mintedDuringOutage.removeAll()
        outageStartedAtNs = nil
        return true
    }

    private var hasSentResume = false

    /// REQ-STATE-5 — the gap to report, once the link is back.
    public func gap(endingAtNs: Int64, shotsInGap: Int,
                    epochWallUtcNs: Int64, epochAtNs: Int64) -> GapWindow? {
        guard let start = outageStartedAtNs else { return nil }
        // ⚠ `CORE` 6.5b / I15 — the wall clock is a **label** beside an instant in
        // a timebase that measures. The interval is computed in the measuring
        // timebase and only then labelled, never the other way round.
        let toDate: (Int64) -> Date = { atNs in
            Date(timeIntervalSince1970:
                    Double(epochWallUtcNs + (atNs - epochAtNs)) / 1_000_000_000)
        }
        return GapWindow(start: toDate(start), end: toDate(endingAtNs),
                         shotsInGap: shotsInGap)
    }

    /// The clock agreement, for B3's telemetry rows. `nil` before 6.3a is
    /// satisfied — ⛔ and `nil` rather than zeros, because a displayed offset of
    /// 0.000 ms ± 0.00 reads as a very good measurement and is not one.
    public var clockAgreement: ClockAgreement? {
        guard let relation = peer.syncRelation(timebaseId) else { return nil }
        return ClockAgreement(
            offsetMilliseconds: Double(relation.offset_ns) / 1_000_000,
            offsetSigmaMilliseconds: relation.offset_sigma_ns / 1_000_000,
            driftPPM: relation.skew_ppm,
            exchangesCompleted: peer.syncExchangeCount(timebaseId),
            exchangesExpected: burstTarget)
    }
}
