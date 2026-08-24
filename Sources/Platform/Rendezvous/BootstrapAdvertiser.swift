//  BootstrapAdvertiser.swift
//  `PPCP-RV` §3.7 — publishing an open bootstrap window, and the listener behind
//  it.
//
//  ⛔ **THIS IS NOT A MODE OF `PpcpAdvertiser`, AND MUST NOT BECOME ONE** (3.7f).
//  A bootstrap instance is a service instance of its own on an endpoint of its
//  own: "that endpoint MUST NOT be the peer's PPCP listener — a bootstrap
//  connection and a PPCP link are different protocols with different first
//  frames, and separating them at the port is what keeps either from having to
//  guess which it received". A flag on the existing advertiser would have shared
//  the port, the TXT record and the rotation timer, and 3.3g makes a record
//  carrying both key sets malformed. So: a second actor, a second listener, a
//  second queue, and no reference between them.
//
//  ⚠ **3.7e allows both at once.** This advertises *alongside* whatever
//  `PpcpAdvertiser` is publishing for reconnection, and that does not breach
//  3.4d1's one-instance rule — that rule exists to keep the count of held
//  pairings unobservable, and a bootstrap instance carries no `rid` and so
//  contributes nothing to the count.
//
//  ⛔ **The window opens only on an explicit user action and does not reopen
//  without a further one** (3.7a, 11.9b). `BootstrapWindow` holds that; this file
//  must not add a retry, a restart-on-failure or a re-register-on-network-change,
//  all three of which are the ordinary reflex for a listener and all three of
//  which breach 11.9b.
//
//  ⚠ **Where a listener that will not start is, and is not, 3.6a.** 3.6a is about
//  *discovery* failure — not being found — and forbids reporting that as an error
//  state. A socket that will not bind is different: the user pressed a control and
//  nothing happened, so it throws. The window is opened only **after** the
//  listener is ready, so a failed start leaves the window closed and the user may
//  simply press again — rather than burning the one window 11.9b then refuses to
//  reopen.
//
//  ⛔ **D11 ADDED THE EXCHANGE, AND TRAP 2 LIVES IN EXACTLY THIS FILE.** The
//  acceptor's keypair is drawn **before the first frame is read**, and
//  `BootstrapAcceptor` returns `bs_accept` from the same call that consumes
//  `bs_offer` (11.5c). ⛔ Nothing in this file may defer that write — batching it
//  with a later frame, waiting for `bs_reveal` to "save a round trip", or
//  reordering `apply` so the outgoing bytes leave after the next read would each
//  destroy the security of the path and change **nothing on the wire**.
//  `ppcp-relay --probe order-acceptor` is the only thing that can see it.
//
//  Spec: `RV` 3.7a-3.7f, 3.3f, 3.3g, 11.3c, 11.3d, 11.3e, §11.5, 11.9a, 11.9b.
//  Plan D10, D11. RT-22, RT-20b.

import Foundation
import Network
import Security
import Synchronization
import CaptureCore

/// Advertises one open bootstrap window and listens on its own endpoint.
public actor BootstrapAdvertiser {

    /// ⚠ `NWConnection` is not `Sendable` and has to cross from the listener's
    /// dispatch queue into this actor. Same box, same reason, as `PpcpListener`.
    private struct ConnectionBox: @unchecked Sendable {
        let connection: NWConnection
    }

    public struct Opened: Sendable, Hashable {
        /// 3.2c — `PPCP-` + eight uppercase hex of `bn`.
        public let instanceName: String
        /// 3.7f — the endpoint the SRV record names, and **not** the PPCP one.
        public let port: UInt16
        public let deadlineNs: Int64
    }

    public enum Failure: Error, Sendable, Equatable {
        /// ⛔ 3.7f — the bootstrap endpoint came back equal to the PPCP listener's.
        case endpointNotDistinctFromPpcpListener(UInt16)
    }

    /// The window itself. ⚠ Read-only from outside: every transition goes through
    /// a method here so the service instance and the window cannot disagree about
    /// whether one is open.
    public private(set) var window: BootstrapWindow

    /// ⛔ `libppcp`'s `bs_offer` decoder (plan L19), which is where 11.4c1's
    /// closed vocabulary is judged. ⚠ D10 defaulted this to
    /// `BootstrapDecoderUnavailable`, which recognised nothing and refused every
    /// dial — 11.3c's correct behaviour for a peer with **no acceptor**. There is
    /// one now, so the default is the real decoder; the stand-in stays reachable
    /// for a test that wants a peer with no acceptor.
    private let recogniser: any BootstrapOfferRecognising

    private var listener: NWListener?
    private var deadline: Task<Void, Never>?
    /// Connections that have not yet produced a well-formed `bs_offer`. ⚠ Bounded
    /// because an unauthenticated stranger opens them: see `maximumPendingDials`.
    private var pendingDials = 0
    private let queue = DispatchQueue(label: "org.pinpointstudio.capture.ppcp.bootstrap")

    /// ⚠ **Not an attempt limit — 11.3d's limit is one and `BootstrapWindow` holds
    /// it.** This bounds the connections that have not yet *become* an attempt, so
    /// that a stranger cannot exhaust the peer by dialling the advertised port and
    /// saying nothing. Refusing beyond it costs an honest initiator nothing: it
    /// dials once.
    static let maximumPendingDials = 4

    /// How much is read at a time once the exchange is running. §11's vocabulary
    /// is CLOSED (11.10a) and its largest frame is 45 payload octets, so this is
    /// generous rather than a guess.
    private static let readChunk = 512

    // MARK: - The exchange (D11)

    /// What a screen needs to know about the one attempt.
    ///
    /// ⛔ **There is no `.digitsMatched` and there never will be** (11.1d, trap
    /// 8). The comparison has value only because it crosses a channel the
    /// attacker is not on, and the only such channel is a person looking at two
    /// screens. This actor never compares anything: `.compare` hands the digits
    /// out and `affirm(on:)` takes a decision a person made.
    public enum GuidedPairingEvent: Sendable {
        /// ⛔ 11.7b/11.7c/11.7d — show these to **this device's** user and ask
        /// whether they **match**. Not *trust*, not *continue*, and the
        /// affirmative control is neither pre-selected nor where a stray tap
        /// lands.
        case compare(BootstrapDigits)
        /// 11.5g — this side affirmed **and** the counterpart's MAC verified.
        case paired(BootstrapPairing)
        /// 11.9a — the attempt is over and nothing survives it. ⛔ `advice`
        /// is 11.9c: a mismatch or a MAC failure is **not** reported in terms
        /// that invite a retry.
        case aborted(reason: BootstrapAbortReason, advice: BootstrapAbortAdvice)
    }

    /// The one attempt's acceptor, or `nil` between attempts (11.3d).
    private var acceptor: BootstrapAcceptor?
    private var liveConnection: NWConnection?
    /// 11.3e's two bounds, ticked while the attempt runs.
    private var attemptTimer: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<GuidedPairingEvent>.Continuation] = [:]

    public init(timeoutNs: Int64 = BootstrapAdvertisement.maximumTimeoutNs,
                recognising recogniser: any BootstrapOfferRecognising
                    = LibppcpOfferRecogniser()) throws {
        self.window = try BootstrapWindow(timeoutNs: timeoutNs)
        self.recogniser = recogniser
    }

    /// The attempt's events, for a screen. Several subscribers are permitted;
    /// they all see the same one attempt, because 11.3d allows only one.
    public func events() -> AsyncStream<GuidedPairingEvent> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id, continuation) }
            continuation.onTermination = { _ in Task { await self.unsubscribe(id) } }
        }
    }

    private func subscribe(_ id: UUID, _ c: AsyncStream<GuidedPairingEvent>.Continuation) {
        subscribers[id] = c
    }
    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }
    private func emit(_ event: GuidedPairingEvent) {
        for c in subscribers.values { c.yield(event) }
    }

    /// ⛔ **THIS DEVICE'S OWN USER affirmed that the numbers match** (11.7c).
    ///
    /// A single affirmation at one end does not establish a pairing at the other,
    /// and the counterpart's `bs_confirm` never stands in for this one — there is
    /// no path in this actor that calls this on a received frame. ⚠ Call it only
    /// from a control a person operated; `UserAction` has to name which.
    public func affirm(on action: BootstrapWindow.UserAction) async {
        guard let acceptor, let connection = liveConnection else { return }
        await apply(acceptor.affirm(on: action, atNs: MachClock.hostTimeNs), on: connection)
    }

    /// The user said the numbers do **not** match, or declined. 11.4f — reported
    /// as `rejected`, indistinguishable to the counterpart from a failed MAC.
    public func decline(on action: BootstrapWindow.UserAction) async {
        guard let acceptor, let connection = liveConnection else { return }
        await apply(acceptor.decline(on: action, atNs: MachClock.hostTimeNs), on: connection)
    }

    // MARK: - Opening — 3.7a

    /// Opens a window: binds the listener, publishes the instance, starts the
    /// timeout.
    ///
    /// - Parameters:
    ///   - action: ⛔ 3.7a. There is no overload without one.
    ///   - label: ⛔ 3.3f/3.3g — `dl`, **no default value**, and never defaulted
    ///     from a device, user or host name. Pass `nil` where the operator set
    ///     none.
    ///   - distinctFrom: the PPCP listener's port, where this peer has one, so
    ///     3.7f is checked rather than assumed.
    @discardableResult
    public func open(on action: BootstrapWindow.UserAction,
                     label: BootstrapLabel?,
                     role: DiscoveryRole = .capture,
                     distinctFrom ppcpListenerPort: UInt16?,
                     // ⚠ Test affordance — see the note at the listener below.
                     on fixed: UInt16? = nil,
                     // ⚠ `nil` rather than `MachClock.hostTimeNs`: the clock is
                     // internal to this target and a public default argument may
                     // not name it. Tests pass a value; the app passes nothing.
                     nowNs providedNowNs: Int64? = nil) async throws -> Opened {
        let nowNs = providedNowNs ?? MachClock.hostTimeNs
        guard window.isOpen == false else { throw BootstrapWindow.Failure.alreadyOpen }

        // 3.7c — four bytes from the platform CSPRNG, fresh for THIS window, used
        // for the instance name and for nothing else, and never persisted.
        let advertisement = try BootstrapAdvertisement(bn: try Self.windowId(),
                                                       role: role,
                                                       label: label)

        // ⛔ 3.7f — port 0. The OS assigns an ephemeral port, which is therefore
        // not the PPCP listener's by construction; the check below is what turns
        // "by construction" into something that fails loudly if it ever stops
        // being true.
        //
        // ⚠ `on:` overrides that, and it exists for one reason: `ppcp-relay`
        // DIALS this window, so RT-20b needs a port the harness can be told about
        // before the app is running. The application passes nothing and gets 0.
        // The 3.7f check below runs either way, which is why a fixed port is an
        // affordance rather than a hole.
        let listener: NWListener
        if let fixed, fixed != 0 {
            listener = try NWListener(using: .tcp,
                                      on: NWEndpoint.Port(rawValue: fixed)!)
        } else {
            listener = try NWListener(using: .tcp)
        }
        listener.service = NWListener.Service(
            name: advertisement.instanceName,
            type: BootstrapAdvertisement.serviceType,
            txtRecord: NWTXTRecord(advertisement.txtRecord))
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let box = ConnectionBox(connection: connection)
            Task { await self.take(box) }
        }

        let port: UInt16
        do {
            port = try await Self.start(listener, on: queue)
        } catch {
            listener.cancel()
            throw error
        }
        if let ppcpListenerPort, port == ppcpListenerPort {
            listener.cancel()
            throw Failure.endpointNotDistinctFromPpcpListener(port)
        }

        self.listener = listener
        try window.open(on: action, advertising: advertisement, atNs: nowNs)

        // 3.7b — the peer's own timeout, which `BootstrapWindow` has already
        // refused to let exceed 180 seconds.
        let timeout = window.timeoutNs
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .nanoseconds(timeout))
            guard Task.isCancelled == false else { return }
            await self?.timedOut()
        }

        return Opened(instanceName: advertisement.instanceName,
                      port: port,
                      deadlineNs: window.deadlineNs ?? nowNs)
    }

    /// ⚠ Resolves on `.ready` with the bound port, once. `claim()` is the same
    /// guard `PpcpListener` uses: the state handler fires many times and a
    /// continuation may be resumed once.
    private static func start(_ listener: NWListener,
                              on queue: DispatchQueue) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let outcome: Result<UInt16, any Error>?
                switch state {
                case .ready:
                    outcome = listener.port.map { .success($0.rawValue) }
                        ?? .failure(TransportError.listenerFailed("no bound port"))
                case .failed(let error):
                    outcome = .failure(TransportError.listenerFailed("\(error)"))
                case .cancelled:
                    outcome = .failure(TransportError.listenerFailed("cancelled"))
                default:
                    outcome = nil
                }
                guard let outcome, resumed.claim() else { return }
                continuation.resume(with: outcome)
            }
            listener.start(queue: queue)
        }
    }

    // MARK: - Closing — 3.7b

    /// 3.7b's fourth cause: a further user action.
    public func close(on action: BootstrapWindow.UserAction,
                      nowNs providedNowNs: Int64? = nil) async {
        guard window.close(on: action,
                           atNs: providedNowNs ?? MachClock.hostTimeNs) else { return }
        await withdraw()
    }

    /// 3.7b — one completed pairing, or one attempt aborted or rejected.
    public func finishAttempt(_ outcome: BootstrapWindow.AttemptOutcome,
                              nowNs providedNowNs: Int64? = nil) async throws {
        try window.endAttempt(outcome, atNs: providedNowNs ?? MachClock.hostTimeNs)
        await withdraw()
    }

    private func timedOut() async {
        // ⚠ Forced rather than routed through `tick`: `Task.sleep` runs on the
        // continuous clock and `MachClock` is what the deadline was computed in,
        // so a wake a nanosecond early would leave `tick` returning nil and the
        // window open past its bound. 3.7b is a MUST and this is the one place
        // that enforces it, so it does not depend on two clocks agreeing.
        guard window.close(reason: .timedOut, atNs: MachClock.hostTimeNs) else { return }
        await withdraw()
    }

    /// ⛔ 3.7b — "on close the peer withdraws the service instance", and 3.7d —
    /// "the instance exists only while the window is open". Cancelling the
    /// listener deregisters it. That is RT-22's third assertion.
    ///
    /// ⚠ **Nothing here reopens anything** (11.9b). There is no restart, no
    /// re-register and no retry, and adding one would breach the clause silently.
    ///
    /// ⛔ **This AWAITS the cancellation, and that is the repair for a measured
    /// defect.** `NWListener.cancel()` is asynchronous: it returns immediately
    /// and the listener reaches `.cancelled` later, on its own queue. Until it
    /// does, the listening socket is still bound, so a dial arriving in that gap
    /// completes its TCP handshake into the accept backlog and is only then
    /// reset. `close(on:)` used to return inside that gap — observed as
    /// `SO_ERROR [54: Connection reset by peer]` in the test log of
    /// 2026-08-24 17:25:12, with a connection succeeding after the window had
    /// closed. Withdrawal is a MUST on the close edge (3.7b), so the method that
    /// performs it does not return until the platform says it is done.
    private func withdraw() async {
        deadline?.cancel()
        deadline = nil
        pendingDials = 0
        // ⛔ 11.6f / 11.9a — the window closing ends the attempt with it, and
        // nothing ephemeral outlives it. `wipe()` is idempotent and safe on every
        // path the embedding abandons, which includes this one: the deadline
        // firing, a further user action, and a completed pairing all arrive here.
        attemptTimer?.cancel()
        attemptTimer = nil
        acceptor?.wipe()
        acceptor = nil
        liveConnection?.cancel()
        liveConnection = nil
        // ⚠ The window is the attempt's whole lifetime (3.7b/11.9b), so the event
        // stream ends with it rather than leaving a screen waiting on something
        // that will never arrive.
        for c in subscribers.values { c.finish() }
        subscribers.removeAll()
        guard let listener else { return }
        self.listener = nil
        listener.newConnectionHandler = { $0.cancel() }
        await Self.cancel(listener)
    }

    /// Resolves when the listener reports `.cancelled`.
    ///
    /// ⚠ Bounded. A listener that never reports would otherwise hang the caller,
    /// and a hang is worse than a failure because it reads as "still running" —
    /// which is exactly how a deadlock in this file's own tests reached the
    /// orchestrator as a 25-minute silence.
    private static func cancel(_ listener: NWListener) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                guard case .cancelled = state, resumed.claim() else { return }
                continuation.resume()
            }
            listener.cancel()
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard resumed.claim() else { return }
                continuation.resume()
            }
        }
    }

    // MARK: - 11.3c — the first frame

    /// ⛔ **11.3c: close without reply unless the first frame is a well-formed
    /// `bs_offer`.**
    ///
    /// ⚠ **When an attempt BEGINS, and why it matters.** 11.9a lists "a malformed
    /// frame, a closed connection" among the aborts that close the window, and
    /// 3.7b closes the window on "one bootstrap attempt aborted or rejected". Read
    /// so that a connection becomes an *attempt* the moment it arrives, **any
    /// device on the link closes the user's window by dialling once with
    /// garbage** — and 11.9b then forbids reopening it without a further user
    /// action. That cannot be the intent, and 11.3c draws the line this
    /// implementation follows: the distinction is "whether the counterpart has
    /// already demonstrated it speaks this protocol". So an attempt begins at a
    /// **well-formed `bs_offer`** and not before; everything refused here leaves
    /// the window untouched. Reported to the protocol owner.
    private func take(_ box: ConnectionBox) async {
        let connection = box.connection

        // 3.7b/11.3c — no window open. ⚠ 11.3c would have this reply
        // `bs_abort` / `window_closed` where the first frame IS a well-formed
        // offer, and close without reply otherwise. Writing that reply needs the
        // bootstrap frame encoder (CA6's separate write path, plan L19), so for
        // now both cases close silently — which is the conservative half: it
        // withholds a diagnostic, it does not grant anything.
        guard window.isOpen else { refuse(connection); return }
        guard pendingDials < Self.maximumPendingDials else { refuse(connection); return }

        pendingDials += 1
        defer { pendingDials -= 1 }

        connection.start(queue: queue)
        guard let first = await firstFrame(on: connection) else {
            refuse(connection); return
        }
        // ⛔ The judgement is `libppcp`'s, not this repository's — 11.4c1's closed
        // vocabulary is decided in one place. A first frame that is not a
        // well-formed `bs_offer` closes WITHOUT REPLY (11.3c): something that has
        // not demonstrated it speaks this protocol gets nothing to learn from.
        guard recogniser.isWellFormedOffer(payload: first.payload) else {
            refuse(connection); return
        }

        // 11.3d — at most one attempt at a time. ⛔ Serialising is what makes
        // 3.7b's single-attempt bound mean what §11.8 says it means; an acceptor
        // running ten attempts in parallel would offer an attacker ten draws
        // against one operator confirmation.
        do {
            try window.beginAttempt(atNs: MachClock.hostTimeNs)
        } catch {
            // ⛔ **The other half of 11.3c, and D10 could not write it.** The
            // counterpart HAS demonstrated it speaks this protocol, so it is owed
            // a diagnostic its user can act on rather than a silent close — far
            // more likely a peer racing a window than an attacker. `bs_abort` /
            // `window_closed`, carrying `rc` and nothing else (11.4g).
            await Self.send(BootstrapAbortFrame.bytes(.windowClosed), on: connection)
            refuse(connection); return
        }

        await runExchange(on: connection, buffered: first.buffered)
    }

    // MARK: - §11.5 — the exchange

    /// Drives `BootstrapAcceptor` over this connection until the attempt ends.
    ///
    /// ⛔ **The keypair is drawn HERE, before a single byte of the offer reaches
    /// the engine** (11.5a, 11.5c). By the time `feed` runs, `pk_a` is fixed —
    /// which is what makes trap 2 unreachable rather than merely avoided.
    private func runExchange(on connection: NWConnection, buffered: Data) async {
        let acceptor: BootstrapAcceptor
        do {
            // 11.5a — a FRESH keypair, for this attempt only. There is
            // deliberately no seam here through which a stored one could arrive.
            acceptor = try BootstrapAcceptor(agreement: CryptoKitKeyAgreement(),
                                             startedAtNs: MachClock.hostTimeNs)
        } catch {
            await Self.send(BootstrapAbortFrame.bytes(.malformed), on: connection)
            refuse(connection)
            try? await finishAttempt(.abortedOrRejected(.malformed))
            return
        }
        self.acceptor = acceptor
        self.liveConnection = connection
        startAttemptTimer()

        // ⛔ `bs_offer` in, `bs_accept` out, in one call and with no `pk_i` in
        // sight. `buffered` is everything read so far, frame and any pipelined
        // remainder — the engine consumes one frame at a time and holds the rest.
        await apply(acceptor.feed(buffered, atNs: MachClock.hostTimeNs), on: connection)

        while self.acceptor === acceptor, acceptor.isFinished == false {
            guard let more = await Self.receive(on: connection, maximum: Self.readChunk),
                  more.isEmpty == false
            else {
                // 11.9a — a closed connection ends the attempt. ⚠ Reported as a
                // `timeout`, which 11.9c permits to read as the ordinary failure
                // it is; a mismatch and a MAC failure are the two that may not.
                guard self.acceptor === acceptor, acceptor.isFinished == false else { break }
                acceptor.wipe()
                refuse(connection)
                // ⚠ **Emit BEFORE the window closes, not after.** `finishAttempt`
                // withdraws, and withdrawing ends the event stream — an event
                // yielded afterwards reaches nobody. Measured: the acceptor's own
                // account of the first relay run was empty for exactly this
                // reason while the relay reported a pass.
                emit(.aborted(reason: .timeout, advice: BootstrapAbortReason.timeout.advice))
                try? await finishAttempt(.abortedOrRejected(.timeout))
                break
            }
            guard self.acceptor === acceptor else { break }
            await apply(acceptor.feed(more, atNs: MachClock.hostTimeNs), on: connection)
        }
    }

    /// One engine transition reaching the socket and the screen.
    ///
    /// ⛔ **The write happens before the close and before the next read**, which
    /// is 11.5c's ordering at the socket. Reordering these two lines is trap 2.
    private func apply(_ steps: [BootstrapAcceptor.Step],
                       on connection: NWConnection) async {
        for step in steps {
            if let out = step.outgoing {
                await Self.send(out, on: connection)
            }
            switch step.event {
            case .compare(let digits):
                // ⛔ 11.7b/11.7c — handed to a screen, and to nothing else. This
                // actor does not compare them and offers no call that would.
                emit(.compare(digits))
            case .paired(let pairing):
                // 11.5g — and only now. 3.7b closes the window on a completed
                // pairing, and 11.5h closes the connection.
                emit(.paired(pairing))
                try? await finishAttempt(.completed)
            case .aborted(let reason):
                emit(.aborted(reason: reason, advice: reason.advice))
                try? await finishAttempt(.abortedOrRejected(reason))
            case nil:
                break
            }
            if step.closeConnection { refuse(connection) }
        }
    }

    /// 11.3e's two bounds — 30 seconds to the comparison, 60 more for this
    /// device's own user. `BootstrapAcceptor` holds the arithmetic; this supplies
    /// the clock, because Core owns none.
    ///
    /// ⚠ Ticking once a second rather than scheduling two one-shots: the second
    /// bound is measured from the comparison, whose time is not known when the
    /// attempt starts. The task ends with the attempt.
    private func startAttemptTimer() {
        attemptTimer?.cancel()
        attemptTimer = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(1))
                guard Task.isCancelled == false else { return }
                guard let self, await self.tickAttempt() else { return }
            }
        }
    }

    /// - Returns: `false` once there is nothing left to tick.
    private func tickAttempt() async -> Bool {
        guard let acceptor, let connection = liveConnection else { return false }
        let steps = acceptor.tick(nowNs: MachClock.hostTimeNs)
        guard steps.isEmpty == false else { return acceptor.isFinished == false }
        await apply(steps, on: connection)
        return false
    }

    /// ⛔ Awaits the platform's confirmation that the bytes have gone. `cancel()`
    /// is abrupt, so a `bs_accept` or a `bs_abort` written and then immediately
    /// cancelled can be lost — and a lost `bs_accept` is indistinguishable, from
    /// the far end, from an acceptor that never sent one.
    private static func send(_ bytes: Data, on connection: NWConnection) async {
        guard bytes.isEmpty == false else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = Mutex(false)
            connection.send(content: bytes, completion: .contentProcessed { _ in
                guard resumed.claim() else { return }
                continuation.resume()
            })
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard resumed.claim() else { return }
                continuation.resume()
            }
        }
    }

    /// Accumulate until the envelope of `ENC` §3 is whole, or until it is refused.
    ///
    /// ⛔ Bounded twice over: by `BootstrapFirstFrame.maximumPayloadBytes`, and by
    /// the window's own deadline. An unauthenticated stranger controls this
    /// stream, so neither the byte count nor the wait may be open-ended.
    /// - Returns: the first frame's payload for the recogniser, **and** every
    ///   byte read so far. ⚠ The second is what the engine is fed: an initiator
    ///   may pipeline, and a frame this method has already taken off the socket
    ///   would otherwise be lost between the envelope check and the exchange.
    private func firstFrame(on connection: NWConnection) async -> (payload: Data,
                                                                  buffered: Data)? {
        let limit = BootstrapFirstFrame.headerBytes
            + Int(BootstrapFirstFrame.maximumPayloadBytes)
        var buffer = Data()
        while buffer.count < limit {
            guard window.isOpen else { return nil }
            switch BootstrapFirstFrame.classify(buffer) {
            case .envelope(let payload): return (payload, buffer)
            case .refuse:                return nil
            case .incomplete:            break
            }
            guard let more = await Self.receive(on: connection,
                                                maximum: limit - buffer.count),
                  more.isEmpty == false
            else { return nil }
            buffer.append(more)
        }
        return nil
    }

    private static func receive(on connection: NWConnection,
                                maximum: Int) async -> Data? {
        await withCheckedContinuation { continuation in
            let resumed = Mutex(false)
            connection.receive(minimumIncompleteLength: 1,
                               maximumLength: maximum) { data, _, isComplete, error in
                guard resumed.claim() else { return }
                if error != nil || (isComplete && (data?.isEmpty ?? true)) {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    /// 11.3c — "closes the connection **without reply**".
    private func refuse(_ connection: NWConnection) {
        connection.cancel()
    }

    // MARK: - 3.7c

    /// 3.7c's four bytes, from `SecRandomCopyBytes` — the platform's audited
    /// CSPRNG, on the same discipline `PpcpAdvertiser.nonce()` applies to `rn`.
    static func windowId() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: BootstrapAdvertisement.windowIdBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw TransportError.failedToMintLinkId(Int(status))
        }
        return Data(bytes)
    }
}

/// ⚠ Same one-shot resume guard `PpcpTransport` defines for its own use; this
/// file cannot see that one because it is `private` there, and duplicating four
/// lines is better than widening its visibility for a second caller.
private extension Mutex<Bool> {
    func claim() -> Bool {
        withLock { taken in
            if taken { return false }
            taken = true
            return true
        }
    }
}
