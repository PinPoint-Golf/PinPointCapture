//  WallClockAnchor.swift
//  The one place a monotonic instant becomes a date a person can read.
//
//  ⛔ **REQ-OFF-8 — "wall clock labels; monotonic measures."** Every instant this
//  application actually reasons about is on a monotonic base that does not halt
//  across sleep (REQ-TIME-4). The device wall clock jumps on NTP correction,
//  timezone change, manual adjustment and DST, so an interval computed from it
//  would be wrong in ways nobody notices until the fused output is already
//  corrupt.
//
//  But a golfer reading a shot list needs "19:36:02", not a 64-bit host-time
//  reading. This type is the seam between those two facts, and it is deliberately
//  one-way: it converts a monotonic instant *into* a label, and offers no inverse.
//
//  ⚠ **The pattern is not new here.** `MeasuredCapability` already pairs
//  `observedHostTimeNs` with `measuredAt` for exactly this reason, and the
//  comment there states it: "a `Date` beside a host-time reading is a label,
//  never a measurement." This type generalises that pairing rather than inventing
//  a second convention.
//
//  Spec: `CORE` §5.3b; requirements REQ-OFF-8, REQ-TIME-4, REQ-TIME-5.

import Foundation

/// A single correspondence between the capture timebase and the wall clock,
/// taken once, and used only to label.
public struct WallClockAnchor: Sendable, Hashable {

    /// The monotonic reading, in the peer's capture timebase.
    public let hostTimeNs: Int64
    /// What the wall clock said at that same moment. ⛔ A label. Never an operand.
    public let wallClock: Date

    public init(hostTimeNs: Int64, wallClock: Date) {
        self.hostTimeNs = hostTimeNs
        self.wallClock = wallClock
    }

    /// The date to *show* for a monotonic instant.
    ///
    /// ⚠ The elapsed term is computed entirely in the monotonic domain — the two
    /// host-time readings are subtracted, and only then is the result added to a
    /// date. Subtracting two `Date`s anywhere in this calculation would be the
    /// bug REQ-OFF-8 exists to prevent.
    public func label(_ instantNs: Int64) -> Date {
        let elapsedNs = instantNs - hostTimeNs
        return wallClock.addingTimeInterval(Double(elapsedNs) / 1_000_000_000)
    }

    /// How long a monotonic instant is after this anchor, in seconds. Monotonic
    /// throughout, so it is safe to compute an interval with.
    public func elapsedSeconds(to instantNs: Int64) -> TimeInterval {
        Double(instantNs - hostTimeNs) / 1_000_000_000
    }
}

public extension Shot {

    /// A minted `PpcpShot` as the session library renders it.
    ///
    /// ⛔ **The `id` is derived from the protocol id, not freshly generated.** A
    /// second identity for a shot that already has one is how a device library
    /// stops being reconcilable against what it sent (REQ-SHOT-3), and a `UUID()`
    /// here would produce a different answer on every redraw.
    ///
    /// - Parameters:
    ///   - minted: the Shot the Mint engine issued.
    ///   - ordinal: its place in the session, as shown: "41 · 7 iron".
    ///   - anchor: taken once at session open.
    ///   - duration: the clip window this shot would carry. ⚠ Not yet a measured
    ///     value — nothing records a clip (E1.1) — so callers pass the intended
    ///     window and the screen must not imply video exists.
    init(minted: PpcpShot, ordinal: Int, anchor: WallClockAnchor,
         duration: TimeInterval? = nil, club: String? = nil,
         detectionConfidence: Double? = nil) {
        self.init(id: Self.stableID(for: minted.id),
                  ordinal: ordinal,
                  impact: anchor.label(minted.t0Ns),
                  duration: duration,
                  club: club,
                  syncState: .onDevice,
                  detectionConfidence: detectionConfidence,
                  hasImpact: true)
    }

    /// A `UUID` that is the same every time for the same protocol id.
    ///
    /// The protocol's ids are strings shaped `shot:<uuid>` (`CORE` §5.2), so the
    /// tail usually parses. Where it does not, a deterministic hash keeps the
    /// promise that matters — same input, same id — without pretending the value
    /// is the protocol's.
    static func stableID(for protocolId: String) -> UUID {
        let tail = protocolId.split(separator: ":").last.map(String.init) ?? protocolId
        if let parsed = UUID(uuidString: tail) { return parsed }

        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in Array(protocolId.utf8).enumerated() {
            bytes[index % 16] ^= byte &+ UInt8(truncatingIfNeeded: index)
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
