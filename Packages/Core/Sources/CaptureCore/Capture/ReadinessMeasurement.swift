//  ReadinessMeasurement.swift
//  `CORE` §5.15 — readiness as a **measurement**, and §7.3d — interruptions with
//  the gap recorded explicitly.
//
//  5.15a, verbatim:
//
//    (5.15a) MUST NOT  A device state-machine name (`cold`, `warm`, `armed` or
//    any equivalent) cross the wire.
//
//  and the paragraph under it:
//
//    Readiness is a measurement, not a state name. The host's actual question is
//    "if I arm now, will the first shot have settled exposure?", which is a
//    measurement. Exporting the state names would export a platform-shaped
//    concept whose settling costs differ elsewhere; a measurement is portable and
//    answers the question asked.
//
//  ⛔ **This file is where `CaptureState` stops.** The application has a state
//  machine with names in it (`CaptureState.cold/.warm/.armed`, REQ-STATE-1..3),
//  and every one of those names is forbidden on the wire. The only function that
//  takes a `CaptureState` returns a measurement, and a measurement has nowhere to
//  put a name: `ppcp_readiness` is three fields, none of them a string a caller
//  chooses, and `libppcp` has no `ppcp_readiness_make(const char *state)` for the
//  same reason. `blocked_reason` is an open registry but is a *cause*, not a
//  state — and the four values §5.15 lists are the ones spelled here.
//
//  Spec: `CORE` §5.15 (5.15a), §7.3 (7.3c, 7.3d), §5.11a1; `CONF` §5b1.

import Foundation
import CPPCP

// MARK: - Readiness

/// What the device measured about its own readiness, in the only terms the
/// protocol has for it.
///
/// ⚠ **`estimatedReadyMs` is milliseconds**, not a `Duration` — §5.15 breaks with
/// the ns convention here and `Session.heartbeat_interval_ms` is the only other
/// field that does. Getting this wrong by 10⁶ produces a peer that is always
/// about to be ready.
public struct ReadinessMeasurement: Sendable, Hashable {

    /// `CORE` §5.15 `blocked_reason` — "set where the peer cannot become ready at
    /// all". An open registry (`Kind`) sharing its vocabulary with a Stream close
    /// `reason` (5.11a1). The first four are the ones §5.15 spells out.
    ///
    /// ⛔ **`sourceNotDelivering` is a registry addition, agreed with
    /// PinPointStudio on 27 August 2026 under 10.3a, and it is not ours alone to
    /// change.** A `blocked_reason` is rendered **verbatim** by a consumer — no
    /// mapping onto a reason it already knew — so the string is shared
    /// vocabulary from the moment it ships, whether or not anyone agreed to
    /// share it. That is why the fifth was raised rather than coined.
    ///
    /// ⚠ **What it exists to stop being said.** The settle timeout — camera
    /// present, permitted, configured, and delivering nothing inside 15 s — used
    /// to report `no_source`, which sends a golfer looking at a phone with a
    /// camera in it to fix a camera that is not missing. PinPointStudio's
    /// argument, and it is a better one than "the nearest of the four".
    ///
    /// ⚠ **A state, not an event.** The other four describe what the peer *is*;
    /// `warmup_timeout` would have named our own timer instead of the world, and
    /// a consumer cannot act on somebody else's stopwatch.
    public enum Blocker: String, Sendable, Hashable, CaseIterable {
        case storageFull = "storage_full"
        case thermalLimit = "thermal_limit"
        case permissionDenied = "permission_denied"
        case noSource = "no_source"
        case sourceNotDelivering = "source_not_delivering"
    }

    /// "If I arm now, will the first shot have settled exposure?"
    public var settled: Bool
    /// Mandatory when not settled. The peer's own estimate; the protocol carries
    /// it and never judges it (I14).
    public var estimatedReadyMs: UInt32
    public var blocked: Blocker?

    public init(settled: Bool, estimatedReadyMs: UInt32 = 0, blocked: Blocker? = nil) {
        self.settled = settled
        self.estimatedReadyMs = estimatedReadyMs
        self.blocked = blocked
    }

    /// The measurement a device in `state` is making.
    ///
    /// ⛔ **One-way, deliberately.** There is no inverse and there must not be: a
    /// receiver that could recover `armed` from a `Readiness` would have the
    /// state name back, which is exactly what 5.15a forbids crossing. Two of the
    /// three states also produce the *same* measurement — a settled `warm` device
    /// and a settled `armed` one both answer "yes, the next shot would be
    /// settled", because that is the question, and the difference between them is
    /// this peer's business.
    ///
    /// - Parameter settleEstimateMs: what the platform believes AE/AF settling
    ///   costs from cold. ⛔ A13/A12: an unmeasured figure here is the caller's to
    ///   supply and to label; nothing in this file invents one.
    public static func measuring(_ state: CaptureState,
                                 exposureHasSettled: Bool,
                                 settleEstimateMs: UInt32,
                                 blocked: Blocker? = nil) -> ReadinessMeasurement {
        switch state {
        case .cold:
            // A torn-down session has to be rebuilt before anything settles —
            // roughly a second plus settling (REQ-STATE-2). Not settled, and the
            // estimate is the caller's measured figure.
            ReadinessMeasurement(settled: false, estimatedReadyMs: settleEstimateMs,
                                 blocked: blocked)
        case .warm, .armed:
            exposureHasSettled
                ? ReadinessMeasurement(settled: true, blocked: blocked)
                : ReadinessMeasurement(settled: false, estimatedReadyMs: settleEstimateMs,
                                       blocked: blocked)
        }
    }

    /// Encode through the library. ⛔ Two constructors and no third: `settled`
    /// carries no estimate and `not_settled` requires one, so the malformed pair
    /// is unconstructible rather than validated.
    public func ppcpReadiness() throws -> ppcp_readiness {
        settled
            ? try PpcpReadiness.settled(blockedBy: blocked?.rawValue)
            : try PpcpReadiness.notSettled(readyInMilliseconds: estimatedReadyMs,
                                           blockedBy: blocked?.rawValue)
    }
}

// MARK: - Interruptions

/// `CORE` 7.3d — "a capture peer reports and recovers from platform
/// interruptions — an incoming call, an audio session interruption,
/// backgrounding — with automatic re-arm where it was armed, and with the
/// resulting gap recorded explicitly."
///
/// ⚠ **Two obligations, and the second is the one that is easy to drop.**
/// Recovering is the visible half; recording the gap is the half a consumer needs
/// in order not to interpolate across it (5.14b, I11). An interruption that
/// re-armed cleanly and said nothing leaves a hole that reads as a dropout.
public struct InterruptionRecord: Sendable, Hashable {

    /// An open registry. These are the three §7.3d names.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case call
        case background
        case audioSession = "audio_session"
    }

    public var kind: Kind
    public var timebaseId: String
    /// The gap itself — half-open, in the Stream's timebase.
    public var intervalNs: Range<Int64>
    /// Whether the peer got back to where it was.
    public var recovered: Bool
    /// Which Streams it affected. Empty means every open capture Stream.
    public var streamIds: [String]

    public init(kind: Kind, timebaseId: String, intervalNs: Range<Int64>,
                recovered: Bool, streamIds: [String] = []) {
        self.kind = kind
        self.timebaseId = timebaseId
        self.intervalNs = intervalNs
        self.recovered = recovered
        self.streamIds = streamIds
    }

    /// The span the interruption cost, in nanoseconds.
    public var durationNs: Int64 { intervalNs.upperBound - intervalNs.lowerBound }
}
