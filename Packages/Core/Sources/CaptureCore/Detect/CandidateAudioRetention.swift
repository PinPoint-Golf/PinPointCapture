//  CandidateAudioRetention.swift
//  The bound on candidate-attached audio, and the sentence the app has to be able
//  to show a user.
//
//  ⚠ **This is an application obligation, not a protocol one, and the protocol
//  says so twice.** `CORE` 5.12.1b: the protocol MUST NOT constrain the retention
//  window, the emission threshold, or a retention cap — "these are peer policy,
//  exactly as frame-rate floors are host policy (I14)". `CORE` §13c and the
//  requirements review both then point out the consequence: **the candidate count
//  is not bounded by anything the user does.**
//
//  ⛔ **REQ-PRIV-6's arithmetic was computed on shots and retention attaches to
//  candidates.** The review of 22 August found it: "~50 windows × ~2 s ≈ 100 s per
//  session" uses the *shot* count, while REQ-PRIV-4 exists precisely because
//  candidates outnumber shots — ball-into-screen, club-on-mat, a dropped club, an
//  adjacent player, speech. REQ-PRIV-2 requires the privacy label to reflect
//  retention honestly, and a label built on the shot count is wrong in the one
//  direction a user would object to. So this type expresses the bound in
//  **candidates**, carries an explicit cap, and states which way the cap is
//  enforced.
//
//  ⛔ **The cap is enforced by eviction, and eviction of candidate evidence is
//  lawful** — 5.14g exit 4 names 5.12.1b explicitly, and 5.12.1c makes the
//  absence *assertable*: an evicted window is `completeness: absent` with a
//  reason, never a dangling reference. That is the one thing this file must get
//  right, because the alternative — a rule forbidding eviction — would retain
//  indefinitely the exact material the privacy section is about.
//
//  Spec: `CORE` §5.12.1, §5.14g, §13c. Requirements: REQ-PRIV-2, REQ-PRIV-4 to 7,
//  REQ-OBS-4. Plan D5 (B7).

import Foundation

/// What this device retains of the audio around each Candidate, and for how long.
public struct CandidateAudioRetention: Sendable, Hashable {

    /// REQ-PRIV-5 — "a separate stream from video with its own, shorter window,
    /// roughly 1.5–2 s centred on the transient". ⛔ Muxing it into the video clip
    /// would keep ~4.5 s of room audio per shot for no diagnostic benefit.
    public var windowNs: Int64
    /// How much of the window sits **before** the transient. Centred by default.
    public var preNs: Int64
    /// The cap, **in candidates**, not in shots. When it is reached the oldest
    /// window is evicted and its Capture re-announced `absent` (5.12.1c).
    public var maximumRetainedCandidates: Int
    /// REQ-OBS-4 — while the device diagnostic mode is on, retention is
    /// deliberately larger and less predictable, and the label obligation still
    /// applies. ⛔ It expires with the session, because this value is a property
    /// of a policy built per session and there is nowhere to persist it.
    public var diagnosticMode: Bool

    public init(windowNs: Int64 = 2_000_000_000,
                preNs: Int64 = 1_000_000_000,
                maximumRetainedCandidates: Int = 150,
                diagnosticMode: Bool = false) {
        self.windowNs = windowNs
        self.preNs = preNs
        self.maximumRetainedCandidates = maximumRetainedCandidates
        self.diagnosticMode = diagnosticMode
    }

    public var postNs: Int64 { max(0, windowNs - preNs) }

    /// The window around one raw onset instant, half-open (`CORE` §5.1).
    public func window(around rawNs: Int64) -> Range<Int64> {
        (rawNs - preNs)..<(rawNs + postNs)
    }

    /// The ceiling, in seconds of audio, this policy can hold at once.
    public var maximumRetainedSeconds: Double {
        Double(maximumRetainedCandidates) * Double(windowNs) / 1_000_000_000
    }

    /// REQ-PRIV-2 / REQ-PRIV-6 — the statement the app shows and the privacy label
    /// has to agree with.
    ///
    /// ⚠ **Written in candidates and with the cap in it**, because that is the
    /// review's finding: a sentence computed from the shot count understates
    /// retention by an unknown factor, and it understates exactly the case — an
    /// adjacent player's conversation triggering a rejected candidate — that a
    /// user would most object to.
    public var userVisibleStatement: String {
        let seconds = Int((Double(windowNs) / 1_000_000_000).rounded())
        let total = Int(maximumRetainedSeconds.rounded())
        let base = """
            This app keeps a \(seconds)-second clip of sound around every noise it \
            thinks might be a shot — including the ones it decides were not, such as \
            the ball hitting the screen, the club on the mat, or someone talking in \
            the next bay. That is how it can show you why it fired when it should not \
            have. It keeps at most \(maximumRetainedCandidates) of these clips at a \
            time — about \(total) seconds of sound in all — and deletes the oldest \
            when it reaches that. Speech is picked up incidentally, not on purpose, \
            and nothing is recorded continuously.
            """
        guard diagnosticMode else { return base }
        return base + """
             \n\nDiagnostic mode is on, so quieter noises are being kept too. \
            It switches off when this session ends.
            """
    }

    /// Which Captures to evict to come back inside the cap, oldest first.
    ///
    /// - Parameter retained: candidate-evidence Capture ids in the order they were
    ///   retained.
    /// - Returns: the ids to evict — ⛔ and every one of them must then be
    ///   **re-announced `absent`** with a reason (5.12.1c), never simply deleted.
    public func evictions(from retained: [String]) -> [String] {
        let excess = retained.count - maximumRetainedCandidates
        guard excess > 0 else { return [] }
        return Array(retained.prefix(excess))
    }

    /// 5.12.1c's reason for a window this policy dropped.
    ///
    /// ⛔ `not_retained`, not `storage_full`: the window was evicted by a *policy*
    /// this peer chose, and saying the disk filled up would be a different and
    /// untrue claim.
    public static let evictedReason = PpcpAbsentReason.notRetained
}
