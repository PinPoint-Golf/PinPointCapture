//  BootstrapWindow.swift
//  `PPCP-RV` §3.7 — the bounded interval during which this peer will accept one
//  guided pairing from a peer it has never met.
//
//  ⛔ **THE WINDOW OPENS ONLY ON AN EXPLICIT USER ACTION** (3.7a). Not at launch,
//  not on a schedule, not on discovery of a counterpart, and not in response to
//  anything arriving on the network. `open` therefore takes a `UserAction` and
//  there is no other way in — a timer, a browser callback or an inbound
//  connection has no value of that type to pass and cannot manufacture one
//  without naming the control it is pretending to be.
//
//  ⛔ **AND IT DOES NOT REOPEN WITHOUT A FURTHER USER ACTION** (11.9b). There is
//  no `reopen`, no retry, and `tick` — the only method a timer calls — can close
//  the window and can never open it. 11.9b also forbids a *"try again"* control
//  that reopens without that action, which is a UI obligation this type cannot
//  enforce; `lastClose` carries the reason so the screen can obey 11.9c.
//
//  ⛔ **ONE ATTEMPT AT A TIME** (11.3d). Serialising is what makes 3.7b's
//  single-attempt bound mean what §11.8 says it means: an acceptor running ten
//  attempts in parallel would offer an attacker ten draws against one operator
//  confirmation. `beginAttempt` refuses a concurrent one.
//
//  ⚠ **Why a window and not a mode.** §11.8 bounds an active attacker to one
//  guess in a million *per operator confirmation*, and that bound is worth exactly
//  what the number of confirmations is. An always-open peer converts a one-shot
//  attack into a grinding one. 3.7a and 3.7b are the two clauses that keep the
//  count small, and this type is those two clauses.
//
//  ⚠ **Injectable clock, no timer.** Times arrive as `nowNs` in the caller's own
//  timebase, as everywhere else in Core (I15). Core owns no clock; the platform
//  layer ticks this.
//
//  Spec: `RV` 3.7a-3.7d, 11.3d, 11.3e, 11.9a, 11.9b. Plan D10. Unlocks RT-22.

import Foundation

/// The bootstrap window of `RV` §3.7.
public struct BootstrapWindow: Sendable, Equatable {

    // MARK: The one way in

    /// ⛔ 3.7a's "explicit user action", as a value that has to be constructed.
    ///
    /// Swift cannot prove that a caller really was a user's own control, and this
    /// type does not pretend to. What it buys is that **every path that opens a
    /// window is greppable and named**: `control` is mandatory and non-empty, so
    /// an automatic reopen has to write down which control it is impersonating
    /// before it compiles, and the review RT-20b(iv) asks for reads that list.
    public struct UserAction: Sendable, Hashable {
        /// The control the user operated, for the audit — e.g. `"pair-a-new-host"`.
        public let control: String

        /// `nil` for an empty name. A caller with nothing to name here is a
        /// caller that is not a user action.
        public init?(control: String) {
            let trimmed = control.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return nil }
            self.control = trimmed
        }
    }

    // MARK: State

    public enum State: Sendable, Equatable {
        case closed
        /// The window is open and advertised. ⚠ The advertisement lives **only**
        /// here (3.7d), so closing drops `bn` rather than keeping it around.
        case open(Open)
    }

    public struct Open: Sendable, Equatable {
        public let advertisement: BootstrapAdvertisement
        public let openedByNs: Int64
        public let deadlineNs: Int64
        /// 11.3d — at most one, and it is a `Bool` rather than a count because a
        /// count is a thing somebody increments.
        public var attemptInProgress: Bool
    }

    /// 3.7b — the earliest of these closes the window. All four are listed
    /// because a `CaseIterable` list of them is what a review reads against the
    /// clause.
    public enum CloseReason: Sendable, Equatable, CaseIterable {
        /// One guided pairing **completed**.
        case pairingCompleted
        /// One bootstrap attempt **aborted or rejected** (§11.9).
        case attemptAbortedOrRejected
        /// The peer's own timeout, which MUST NOT exceed 180 seconds.
        case timedOut
        /// A further user action closing it.
        case userClosed

        /// ⚠ 11.9c — whether a screen may offer the ordinary *try again* it
        /// offers for a network failure. **This is not the whole of 11.9c**: a
        /// mismatch and a MAC failure are both `attemptAbortedOrRejected`, and
        /// only the acceptor (D11) knows which. Where this is `true` the reason
        /// carries no implication either way; where it is `false` the answer is
        /// settled regardless of what the abort was.
        ///
        /// A mismatch is the one signal this path produces that an attack is
        /// under way, and a dialogue whose reflex is *try again* converts a
        /// one-shot bound into an unbounded one by way of muscle memory.
        public var mayBeReportedAsAnOrdinaryFailure: Bool {
            switch self {
            case .timedOut, .userClosed, .pairingCompleted: return true
            case .attemptAbortedOrRejected: return false
            }
        }
    }

    public struct Close: Sendable, Equatable {
        public let reason: CloseReason
        public let atNs: Int64
    }

    public enum Failure: Error, Sendable, Equatable {
        /// 3.7d — "at most one bootstrap instance at a time".
        case alreadyOpen
        /// 3.7b/11.3c — no window is open.
        case windowClosed
        /// 11.3d — one attempt is already running.
        case attemptAlreadyRunning
        /// 11.3d — there is no attempt to end.
        case noAttemptRunning
        /// ⛔ 3.7b — "MUST NOT exceed 180 seconds", refused at construction rather
        /// than clamped, because a policy that silently became 180 is a policy
        /// nobody reads back.
        case timeoutExceedsMaximum(Int64)
        case timeoutNotPositive(Int64)
    }

    // MARK: Stored

    public private(set) var state: State = .closed
    /// The last close, kept so a screen can obey 11.9c. ⚠ Carries no `bn` and no
    /// advertisement — 3.7c says `bn` is never persisted, and "persisted" starts
    /// at the field that outlives the window.
    public private(set) var lastClose: Close?

    /// This peer's own timeout policy (3.7b).
    public let timeoutNs: Int64

    /// - Parameter timeoutNs: 3.7b's bound is 180 seconds and it is a MUST NOT.
    ///   ⚠ 11.3e's 30 and 60 second bounds are the *attempt's*, not the window's,
    ///   and are D11's; "the window's own bound is 3.7b's 180 seconds and it binds
    ///   regardless".
    public init(timeoutNs: Int64 = BootstrapAdvertisement.maximumTimeoutNs) throws {
        guard timeoutNs > 0 else { throw Failure.timeoutNotPositive(timeoutNs) }
        guard timeoutNs <= BootstrapAdvertisement.maximumTimeoutNs else {
            throw Failure.timeoutExceedsMaximum(timeoutNs)
        }
        self.timeoutNs = timeoutNs
    }

    // MARK: Opening — 3.7a

    /// ⛔ 3.7a. The **only** transition from `.closed` to `.open`, and it needs a
    /// `UserAction`. 11.9b is the same clause read after a failure: this method is
    /// still the only way back, so nothing reopens on its own.
    ///
    /// - Parameter advertising: built with a `bn` drawn fresh for **this** window
    ///   (3.7c). Reusing one across two windows is what 3.2b forbids.
    public mutating func open(on action: UserAction,
                              advertising advertisement: BootstrapAdvertisement,
                              atNs nowNs: Int64) throws {
        guard case .closed = state else { throw Failure.alreadyOpen }
        _ = action
        state = .open(Open(advertisement: advertisement,
                           openedByNs: nowNs,
                           deadlineNs: nowNs + timeoutNs,
                           attemptInProgress: false))
    }

    // MARK: Closing — 3.7b

    /// 3.7b's fourth cause: a further user action.
    @discardableResult
    public mutating func close(on action: UserAction, atNs nowNs: Int64) -> Bool {
        _ = action
        return close(reason: .userClosed, atNs: nowNs)
    }

    /// 3.7b — closes on any of the four causes. `false` where it was already
    /// closed, so a second cause arriving after the first does not rewrite the
    /// record of why the window ended.
    @discardableResult
    public mutating func close(reason: CloseReason, atNs nowNs: Int64) -> Bool {
        guard case .open = state else { return false }
        // ⛔ 3.7c/3.7d — the advertisement and `bn` go with the window. The
        // platform layer withdraws the service instance on the same edge.
        state = .closed
        lastClose = Close(reason: reason, atNs: nowNs)
        return true
    }

    /// The peer's own timeout (3.7b), driven by whatever ticks this.
    ///
    /// ⛔ **This method can close a window and can never open one.** That is
    /// 11.9b expressed where a timer can reach it: the one thing running
    /// unattended has no opening path at all.
    @discardableResult
    public mutating func tick(nowNs: Int64) -> CloseReason? {
        guard case .open(let open) = state else { return nil }
        guard nowNs >= open.deadlineNs else { return nil }
        close(reason: .timedOut, atNs: nowNs)
        return .timedOut
    }

    // MARK: The attempt — 11.3d

    /// ⛔ 11.3d — "an acceptor runs **at most one** bootstrap attempt at a time".
    ///
    /// - Throws: `.windowClosed` where no window is open — which 11.3c answers
    ///   with `bs_abort` / `window_closed` **only** once the counterpart has shown
    ///   it speaks this protocol, and otherwise closes without reply.
    ///   `.attemptAlreadyRunning` for the concurrent case, which 11.3d answers the
    ///   same way.
    public mutating func beginAttempt(atNs nowNs: Int64) throws {
        guard case .open(var open) = state else { throw Failure.windowClosed }
        guard nowNs < open.deadlineNs else {
            close(reason: .timedOut, atNs: nowNs)
            throw Failure.windowClosed
        }
        guard open.attemptInProgress == false else {
            throw Failure.attemptAlreadyRunning
        }
        open.attemptInProgress = true
        state = .open(open)
    }

    /// How the one attempt ended. Both outcomes close the window (3.7b), and an
    /// abort leaves **no** pairing at either peer (11.9a).
    public enum AttemptOutcome: Sendable, Equatable {
        case completed
        case abortedOrRejected
    }

    /// ⛔ 3.7b + 11.9a. Ending the attempt ends the window — there is no state in
    /// which an attempt has finished and the window is still open, because that
    /// state is the one an attacker gets a second draw from.
    public mutating func endAttempt(_ outcome: AttemptOutcome, atNs nowNs: Int64) throws {
        guard case .open(let open) = state else { throw Failure.windowClosed }
        guard open.attemptInProgress else { throw Failure.noAttemptRunning }
        switch outcome {
        case .completed:         close(reason: .pairingCompleted, atNs: nowNs)
        case .abortedOrRejected: close(reason: .attemptAbortedOrRejected, atNs: nowNs)
        }
    }

    // MARK: Reading

    public var isOpen: Bool {
        if case .open = state { return true }
        return false
    }

    /// 3.7d — what is advertised, and `nil` the instant the window closes.
    public var advertisement: BootstrapAdvertisement? {
        if case .open(let open) = state { return open.advertisement }
        return nil
    }

    public var attemptInProgress: Bool {
        if case .open(let open) = state { return open.attemptInProgress }
        return false
    }

    public var deadlineNs: Int64? {
        if case .open(let open) = state { return open.deadlineNs }
        return nil
    }
}
