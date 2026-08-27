//  HostLink.swift
//  The state of the link to a PinPoint Studio host, and its telemetry.
//
//  ⛔ No transition here ever disarms capture. On `lost`, the first fact the UI
//  reports is that capture is still running — the priority rule made visible
//  (§9.2, REQ-RES-1).

import Foundation

/// REQ-SESS-3. Per-shot sync state. The device library is an independent store,
/// not a cache of PinPoint.
/// ⚠ **This is now the protocol's `Capture.transfer` axis (`CORE` 5.14), not a
/// vocabulary of its own** (REQ-PORT-11, D3). It used to have three cases; the
/// axis has five, and the two that were missing are the two that matter when
/// something goes wrong: `present` — the receiver has the bytes but has not
/// committed them — and `failed`.
///
/// ⛔ **`inStudio` is `confirmed`, and only a `capture_committed` from the
/// receiver produces it.** `CORE` 5.14f and 8.4b: "`confirmed` is asserted by the
/// receiver and by nobody else." The comment on the old case already said
/// "confirmed by the host, never merely uploaded", and the library now enforces
/// it — `ppcp_capture_set_transfer` cannot reach `confirmed` at all, and the only
/// route is `ppcp_transfer_on_committed`, which needs the message in hand. That
/// is what stops REQ-SESS-4 ("nothing unconfirmed is ever evicted") from resting
/// on a sender's optimism, and it is I38's whole subject.
public enum ShotSyncState: Sendable, Hashable {
    /// `pending` — held here and nowhere else.
    case onDevice
    /// `in_flight` — bulk transfer under way. `progress` is 0...1.
    case sending(progress: Double)
    /// `present` — the receiver has the bytes and has not committed them.
    /// ⚠ **Not `inStudio`.** A shot that arrived but was not committed is not
    /// safe to evict, and showing it as done is how it gets deleted.
    case delivered
    /// `confirmed` — ⛔ set **only** on `capture_committed` (5.14f, 8.4b).
    case inStudio
    /// `failed` — the transfer will not complete without another attempt.
    case failed

    /// Three words, not an icon — a golfer glancing from the mat needs a *state*.
    public var displayText: String {
        switch self {
        case .onDevice: "On device"
        case .sending(let p): "Sending \(Int((p * 100).rounded()))%"
        case .delivered: "Sent, not confirmed"
        case .inStudio: "In Studio"
        case .failed: "Send failed"
        }
    }

    /// ⛔ REQ-SESS-4 / `CORE` 5.14g1 — the eviction question, answered in one
    /// place. Only `confirmed` is safe, and `delivered` deliberately is not: the
    /// receiver has the bytes and has not said it kept them.
    /// The in-flight state, computed from what the **receiver** has acknowledged.
    ///
    /// ⛔ **Here rather than at the call site because it is easy to get wrong in
    /// two places.** `PpcpTransferRow` reports `in_flight` with a hardcoded zero
    /// fraction, so the number a screen shows has to be derived — and the only
    /// honest source is `acked_index`, which is the far end's word for how far it
    /// has got, not this end's count of what it handed to a socket.
    ///
    /// ⚠ **The index is inclusive.** 8.3d makes resumption restart from the chunk
    /// *after* the last acknowledged one, so an `ackedIndex` of 4 means five
    /// chunks are known received. `nil` means none — and `nil` is not zero, which
    /// is the distinction 8.3d exists to preserve.
    ///
    /// ⚠ Never exceeds 1. A receiver acking past the announced length is its bug,
    /// and must not become a progress bar reading 140%.
    public static func sending(bytes: UInt64?, ackedIndex: UInt32?,
                               chunkBytes: UInt32) -> ShotSyncState {
        guard let bytes, bytes > 0 else { return .sending(progress: 0) }
        let acked = Double(ackedIndex.map { Double($0) + 1 } ?? 0) * Double(chunkBytes)
        return .sending(progress: min(1, acked / Double(bytes)))
    }

    public var isConfirmedByReceiver: Bool {
        if case .inStudio = self { true } else { false }
    }
}

/// The four live states of B3, plus the states before a host exists.
public enum HostLinkState: String, Sendable, CaseIterable {
    case none, pairing, connected, weak, lost, resyncing

    /// The B3 status-card title.
    public var title: String {
        switch self {
        case .none: "No host"
        case .pairing: "Pairing"
        case .connected: "Connected"
        case .weak: "Connected, slowly"
        case .lost: "Host is gone"
        case .resyncing: "Catching up"
        }
    }

    /// The one-sentence explanation under the title. Reproduced verbatim from the
    /// design handoff — these strings carry the design and are decisions, not copy
    /// to be improved.
    public var explanation: String {
        switch self {
        case .none:
            "Everything is kept here until you send it."
        case .pairing:
            "Twenty round trips get the two clocks agreeing to a fraction of a frame."
        case .connected:
            "Every shot is reaching Studio as you hit it."
        case .weak:
            "Shots are still being correlated the moment you hit them. "
            + "The video is queueing behind the network."
        case .lost:
            "Capture never stops for this. Keep hitting — the shots are safe here "
            + "and will go across on their own when the host is back."
        case .resyncing:
            "Twenty fresh exchanges before anything is sent, so the shots captured "
            + "during the gap land on the right timeline."
        }
    }

    /// The full-width action, tinted to the state.
    public var actionTitle: String {
        switch self {
        case .none: "Connect a host"
        case .pairing: "Cancel"
        case .connected: "Disconnect"
        case .weak: "Send over a cable instead"
        case .lost: "Find the host again"
        case .resyncing: "Pause sending"
        }
    }
}

/// A half-open window during which the host was absent, reported explicitly on
/// reconnect (REQ-STATE-5).
public struct GapWindow: Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var shotsInGap: Int

    public init(start: Date, end: Date, shotsInGap: Int) {
        self.start = start
        self.end = end
        self.shotsInGap = shotsInGap
    }
}

/// Clock agreement between this device and the host.
///
/// ⚠ REQ-SYNC-1: offset **and rate**, never offset alone. At 20 ppm a full frame
/// at 150 fps slips every ~5.5 minutes, so skew estimation is mandatory rather
/// than an optimisation.
/// ⚠ REQ-SYNC-3: the estimate is filtered, never stepped. A stepped offset
/// mid-session produces a discontinuity in fused output that is very hard to
/// diagnose later.
public struct ClockAgreement: Sendable, Hashable {
    public var offsetMilliseconds: Double
    public var offsetSigmaMilliseconds: Double
    public var driftPPM: Double
    /// REQ-SYNC-4. Per-shot residual against the acoustic fiducial.
    public var lastImpactResidualMilliseconds: Double?
    /// Progress of the sync burst: 10–20 exchanges on connect (REQ-SYNC-2).
    public var exchangesCompleted: Int
    public var exchangesExpected: Int

    public init(offsetMilliseconds: Double, offsetSigmaMilliseconds: Double,
                driftPPM: Double, lastImpactResidualMilliseconds: Double? = nil,
                exchangesCompleted: Int = 20, exchangesExpected: Int = 20) {
        self.offsetMilliseconds = offsetMilliseconds
        self.offsetSigmaMilliseconds = offsetSigmaMilliseconds
        self.driftPPM = driftPPM
        self.lastImpactResidualMilliseconds = lastImpactResidualMilliseconds
        self.exchangesCompleted = exchangesCompleted
        self.exchangesExpected = exchangesExpected
    }

    /// "−3.184 ms ± 0.21" — mono. Note the U+2212 minus, not a hyphen.
    ///
    /// ⚠ **Not what B3 shows.** `offsetMilliseconds` is measured against
    /// whatever local reference each peer's clock happens to be counting from
    /// (`tb:hosttime` is monotonic since boot — `CORE` 6.5, `PpcpTimebases.swift`),
    /// so its magnitude reflects nothing a golfer can act on: two devices with
    /// different uptimes since their own last boot disagree by however long that
    /// gap is, correctly and by design. `agreementText` is the number that
    /// answers a real question — how tightly the two clocks are related — and
    /// is what the screen shows instead.
    public var offsetText: String {
        let sign = offsetMilliseconds < 0 ? "\u{2212}" : ""
        return String(format: "%@%.3f ms ± %.2f", sign, abs(offsetMilliseconds),
                      offsetSigmaMilliseconds)
    }

    /// "± 0.21 ms" — what B3 actually shows for REQ-SYNC-1's offset row.
    /// ⚠ The uncertainty, not the offset: found live against real
    /// PinPointStudio (26 August 2026) that a two-way relation between two
    /// peers' own since-boot clocks can genuinely read minus several million
    /// milliseconds — correct, and meaningless to show a golfer. How tightly
    /// the relation holds is the number that answers "is this trustworthy".
    public var agreementText: String {
        String(format: "± %.2f ms", offsetSigmaMilliseconds)
    }

    /// "18 ppm, filtered" — the word matters (REQ-SYNC-3).
    public var driftText: String { "\(Int(driftPPM.rounded())) ppm, filtered" }
}

public struct HostLink: Sendable {
    public var state: HostLinkState
    public var hostName: String?
    public var hostVersion: String?
    public var clock: ClockAgreement?
    public var throughputMbitPerSecond: Double?
    public var lastSeen: Date?
    public var gap: GapWindow?

    public init(state: HostLinkState, hostName: String? = nil, hostVersion: String? = nil,
                clock: ClockAgreement? = nil, throughputMbitPerSecond: Double? = nil,
                lastSeen: Date? = nil, gap: GapWindow? = nil) {
        self.state = state
        self.hostName = hostName
        self.hostVersion = hostVersion
        self.clock = clock
        self.throughputMbitPerSecond = throughputMbitPerSecond
        self.lastSeen = lastSeen
        self.gap = gap
    }
}
