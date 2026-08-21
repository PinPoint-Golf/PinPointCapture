//  Session.swift
//  Session, shot and transfer queue.
//
//  REQ-SESS-1/2: session is a first-class object and exists without a host.
//  REQ-SESS-3: the device library is an independent store with per-shot sync
//  state, not a cache of PinPoint.

import Foundation

/// REQ-SHOT-3. The device mints its own identity when no host is present, for
/// later reconciliation — including against independently recorded launch
/// monitor records.
public struct Shot: Sendable, Identifiable, Hashable {
    public var id: UUID
    /// Ordinal within the session, as shown to the user: "41 · 7 iron".
    public var ordinal: Int
    /// Impact. ⚠ REQ-REPLAY-2: the replay timeline is addressed in *time*,
    /// zeroed on this instant, never in frame index.
    public var impact: Date
    public var duration: TimeInterval
    public var club: String?
    public var syncState: ShotSyncState
    /// REQ-MIC-6. Confidence from the acoustic detector.
    public var detectionConfidence: Double?
    /// A practice swing has no impact transient. It stays `onDevice` and is not
    /// worth the bandwidth (upload triage, v2).
    public var hasImpact: Bool

    public init(id: UUID = UUID(), ordinal: Int, impact: Date, duration: TimeInterval,
                club: String? = nil, syncState: ShotSyncState = .onDevice,
                detectionConfidence: Double? = nil, hasImpact: Bool = true) {
        self.id = id
        self.ordinal = ordinal
        self.impact = impact
        self.duration = duration
        self.club = club
        self.syncState = syncState
        self.detectionConfidence = detectionConfidence
        self.hasImpact = hasImpact
    }

    /// "41 · 7 iron", or "38 · practice swing".
    public var displayTitle: String {
        "\(ordinal) · \(club ?? (hasImpact ? "unknown club" : "practice swing"))"
    }

    /// "19:36:02 · 3.0 s", or "19:33:58 · no impact" — mono.
    public var displayDetail: String {
        let time = Self.timeFormatter.string(from: impact)
        return hasImpact
            ? "\(time) · \(String(format: "%.1f", duration)) s"
            : "\(time) · no impact"
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// REQ-SESS-1. Start, calibration state, device roster, context changes, end.
public struct Session: Sendable, Identifiable {
    public var id: UUID
    /// "Wednesday range"
    public var name: String
    public var start: Date
    public var end: Date?
    public var shots: [Shot]

    public init(id: UUID = UUID(), name: String, start: Date,
                end: Date? = nil, shots: [Shot] = []) {
        self.id = id
        self.name = name
        self.start = start
        self.end = end
        self.shots = shots
    }

    public var shotsStillToSend: Int {
        shots.filter { if case .inStudio = $0.syncState { false } else { true } }.count
    }

    /// "41 shots · 18:20 to 19:36 · 12 still to send"
    public var displaySubtitle: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let window = "\(f.string(from: start)) to \(f.string(from: end ?? Date()))"
        return "\(shots.count) shots · \(window) · \(shotsStillToSend) still to send"
    }
}

/// REQ-SESS-5/6. Decouple event from payload: a small event message goes
/// immediately on a low-latency channel; video follows on a bulk channel that is
/// permitted to lag, queue, resume across app launches, or never complete within
/// the session.
///
/// ⚠ A session where every shot is correlated and half the video syncs later is
/// a success, not a failure.
public struct TransferQueue: Sendable {
    /// Ordered. Shots leave in the order they were captured.
    public var pendingShotIDs: [UUID]
    /// User-level pause. Backpressure is separate and automatic.
    public var isPaused: Bool
    public var bytesRemaining: Int64
    /// Ordinal of the shot currently in flight, for the C3 banner.
    public var currentShotOrdinal: Int?
    public var totalShots: Int

    public init(pendingShotIDs: [UUID] = [], isPaused: Bool = false,
                bytesRemaining: Int64 = 0, currentShotOrdinal: Int? = nil,
                totalShots: Int = 0) {
        self.pendingShotIDs = pendingShotIDs
        self.isPaused = isPaused
        self.bytesRemaining = bytesRemaining
        self.currentShotOrdinal = currentShotOrdinal
        self.totalShots = totalShots
    }

    public var isActive: Bool { !pendingShotIDs.isEmpty && !isPaused }

    /// "shot 30 of 41 · 218 MB left" — mono.
    public var displayDetail: String {
        let mb = Int((Double(bytesRemaining) / 1_000_000).rounded())
        guard let current = currentShotOrdinal else { return "\(mb) MB left" }
        return "shot \(current) of \(totalShots) · \(mb) MB left"
    }
}
