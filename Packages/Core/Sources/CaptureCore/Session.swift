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
    /// ⛔ `nil` until a clip exists. Nothing records video yet (E1.1), and a
    /// shot rendered as "· 0.0 s" is a measurement claim of zero rather than an
    /// absence.
    public var duration: TimeInterval?
    public var club: String?
    public var syncState: ShotSyncState
    /// REQ-MIC-6. Confidence from the acoustic detector.
    public var detectionConfidence: Double?
    /// A practice swing has no impact transient. It stays `onDevice` and is not
    /// worth the bandwidth (upload triage, v2).
    public var hasImpact: Bool

    public init(id: UUID = UUID(), ordinal: Int, impact: Date, duration: TimeInterval? = nil,
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

    /// "19:36:02 · 3.0 s", "19:36:02 · timed, not filmed", or "19:33:58 · no
    /// impact" — mono.
    ///
    /// ⚠ The middle case is the honest one on this build: the impact instant is
    /// real and measured, and no video was recorded against it.
    public var displayDetail: String {
        let time = Self.timeFormatter.string(from: impact)
        guard hasImpact else { return "\(time) · no impact" }
        guard let duration else { return "\(time) · timed, not filmed" }
        return "\(time) · \(String(format: "%.1f", duration)) s"
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

    /// ⚠ Counts everything the receiver has not **confirmed** — `delivered`
    /// included. `CORE` 5.14f puts `confirmed` in the receiver's gift alone, so a
    /// shot whose bytes arrived and were never committed is still outstanding,
    /// and a count that treated it as done would tell a user it was safe to walk
    /// away (REQ-SESS-4).
    public var shotsStillToSend: Int {
        shots.filter { $0.syncState.isConfirmedByReceiver == false }.count
    }

    /// "41 shots · 18:20 to 19:36 · 12 still to send"
    /// ⚠ With no host there is nothing "still to send", and saying so implies a
    /// transfer that is queued rather than one that does not exist.
    public func displaySubtitle(hasHost: Bool) -> String {
        guard hasHost else {
            let span = Self.spanText(start: start, end: end)
            return "\(shots.count) shot\(shots.count == 1 ? "" : "s")\(span) · kept on this device"
        }
        return displaySubtitle
    }

    public var displaySubtitle: String {
        let window = Self.spanText(start: start, end: end)
        return "\(shots.count) shots\(window) · \(shotsStillToSend) still to send"
    }

    /// " · 18:20 to 19:36", or empty where no shot has been taken — a span
    /// between an open time and now, with nothing in it, is noise.
    static func spanText(start: Date, end: Date?) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return " · \(f.string(from: start)) to \(f.string(from: end ?? Date()))"
    }
}

/// One session bundle on disk, as C3 can honestly describe it.
///
/// ⛔ **Only what is knowable without opening the bundle.** `SessionStore.bundles()`
/// reads directory names; the shot count and the time span are *inside* the
/// container and reading them back means feeding frames to a peer, which is E4.1.
/// So this carries the file's facts and the screen says they are the file's.
///
/// ⚠ Deliberately no `shotCount`. The obvious shortcut — count the files in
/// `clips/` — returns zero on every device today, and a zero that looks measured
/// is worse than an absence.
public struct RecordedBundle: Sendable, Identifiable, Hashable {
    public let sessionId: String
    /// The bundle directory's modification date. ⚠ A *file* date, not the
    /// session's own — and the screen says so.
    public let fileDate: Date
    public let byteCount: Int64

    public var id: String { sessionId }

    public init(sessionId: String, fileDate: Date, byteCount: Int64) {
        self.sessionId = sessionId
        self.fileDate = fileDate
        self.byteCount = byteCount
    }

    /// "21 August, 18:20"
    public var displayTitle: String {
        let f = DateFormatter()
        f.dateFormat = "d MMMM, HH:mm"
        return f.string(from: fileDate)
    }

    /// "bundle · 4.2 MB"
    public var displayDetail: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "bundle · \(formatter.string(fromByteCount: byteCount))"
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
