//  MicrophoneGeometry.swift
//  The microphone-to-ball distance, as a setting rather than as a constant.
//
//  ⛔ **`AcousticTimeOfFlight` existed since D5 and nothing supplied a distance**,
//  so every device Candidate went out with no `tof_correction` at all. At 343 m/s
//  the correction is ~2.9 ms per metre: a phone on a tripod 2 m from the ball
//  timestamps impact 5.8 ms late, which is most of a frame at 150 fps and all of
//  one at 120. It is not a small correction and it is not a random error — it is a
//  bias in one direction, and a bias is what a host's arbitration cannot see.
//
//  ⚠ **A user estimate, and the sigma says so.** `CORE` §5.9 distinguishes
//  surveyed geometry (tight) from an online estimate (converging — wide early,
//  tight late), and "the difference is the whole point of carrying a sigma at
//  all". Nobody has surveyed a driving-range bay with a tape measure; a golfer
//  chooses from a short list of distances they can judge by eye. So the sigma
//  attached here is the sigma of a **judgement**, and I29 makes it travel beside
//  the value or the correction is not emitted at all.
//
//  ⛔ **A12 applied to a number nobody measured.** Every constant below is
//  `assumed`, including the sigma, and the type says so rather than a comment
//  saying so. The day a rig measures the standing distance for a bay, `.surveyed`
//  is the case that replaces it — and it is a different case rather than a
//  smaller number, because a measurement and a guess with the same value are not
//  the same claim.
//
//  Decision: Mark, 23 August 2026 — "we definitely need a mic to ball distance
//  setting for PPC". Spec: `CORE` §5.9, §5.12d, §8.1d; I29. Plan D7.

import Foundation

/// How the distance was arrived at. ⛔ Two cases and no default: a value with no
/// provenance is the shape I31 and A12 exist to make unconstructible.
public enum DistanceProvenance: String, Sendable, Hashable, CaseIterable, Codable {
    /// The user picked it, or typed it. ⚠ The honest case for everything this
    /// application can produce today.
    case estimated
    /// Somebody measured this bay. Nothing in this application can produce it
    /// yet, and it is here so the setting does not have to change shape when
    /// something can.
    case surveyed
}

/// The microphone-to-ball distance, as the user set it.
public struct MicToBallDistance: Sendable, Hashable, Codable {

    /// ⚠ **1.5 m, and it is a choice with a reason rather than a round number.**
    /// A phone framing a full swing at 1080p on a wide lens sits roughly there:
    /// closer and the club head leaves frame at the top, further and the ball is
    /// too few pixels to see. It is `assumed` like everything else here.
    public static let defaultMetres = 1.5

    /// The range a user may choose within. ⛔ Bounded, because a `tof_correction`
    /// of half a second is not a plausible setting and a peer that emitted one
    /// would corrupt a Session's arbitration rather than merely be wrong.
    public static let permittedMetres: ClosedRange<Double> = 0.3...10.0

    /// ⚠ **The sigma of a judgement, not of an instrument.** A person asked to
    /// estimate a distance of a metre or two by eye is routinely 20 % out, and
    /// that is what this is: a fifth of the distance, floored so a very short
    /// distance does not claim implausible precision. ⛔ It is `assumed` and the
    /// provenance says so; a rig would replace both numbers at once.
    public static let assumedRelativeSigma = 0.20
    public static let assumedMinimumSigmaMetres = 0.10

    public var metres: Double
    public var provenance: DistanceProvenance

    public init(metres: Double = MicToBallDistance.defaultMetres,
                provenance: DistanceProvenance = .estimated) {
        self.metres = min(max(metres, Self.permittedMetres.lowerBound),
                          Self.permittedMetres.upperBound)
        self.provenance = provenance
    }

    /// The dispersion to attach. ⛔ A surveyed distance still carries one —
    /// I29 has no case for a point estimate, and a tape measure is not exact
    /// either.
    public var sigmaMetres: Double {
        switch provenance {
        case .estimated:
            max(metres * Self.assumedRelativeSigma, Self.assumedMinimumSigmaMetres)
        case .surveyed:
            // 20 mm: a tape measure to a ball position, read once, by one person.
            0.02
        }
    }

    /// What `CandidateFactory` takes. ⛔ Both halves in one value, which is what
    /// makes I29's "value **and** sigma, or absent" unbreakable one layer up:
    /// `ppcp_estimate_make` cannot be called with one of the two.
    public var timeOfFlight: AcousticTimeOfFlight {
        AcousticTimeOfFlight(distanceMetres: metres, distanceSigmaMetres: sigmaMetres)
    }

    /// The correction that will be subtracted from every raw onset, in
    /// milliseconds — the number the setting screen shows, because "1.5 m" means
    /// nothing to a golfer and "4.4 ms earlier" is the thing that changes.
    public var correctionMilliseconds: Double {
        Double(timeOfFlight.correctionNs) / 1_000_000
    }

    public var sigmaMilliseconds: Double { timeOfFlight.sigmaNs / 1_000_000 }

    /// The short list a screen offers. ⚠ Distances a person can judge against
    /// something — an arm's length, a driver's length, a bay's width — rather
    /// than a slider that invites false precision.
    public static let presets: [(label: String, metres: Double)] = [
        ("Very close", 0.8),
        ("Arm's length", 1.2),
        ("Typical tripod", 1.5),
        ("Across the mat", 2.5),
        ("Far side of the bay", 4.0)
    ]

    /// What the session bundle records about this setting.
    ///
    /// ⚠ It is **not** a protocol field: `CORE` has no place for "how the peer
    /// decided its own geometry", and `tof_correction` carries the consequence
    /// rather than the cause. So it goes in the bundle's own sidecar, where a
    /// later reader can tell a 1.5 m default nobody touched from a 4 m one
    /// somebody chose — which is the difference between a bias to correct and a
    /// bias to trust.
    public var recordedForm: [String: String] {
        ["mic_to_ball_m": String(format: "%.2f", metres),
         "mic_to_ball_sigma_m": String(format: "%.2f", sigmaMetres),
         "mic_to_ball_provenance": provenance.rawValue]
    }
}
