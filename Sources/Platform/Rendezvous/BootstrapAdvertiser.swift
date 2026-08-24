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
//  Spec: `RV` 3.7a-3.7f, 3.3f, 3.3g, 11.3c, 11.3d, 11.9a, 11.9b. Plan D10. RT-22.

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

    /// ⛔ The seam for `libppcp`'s `bs_offer` decoder (plan L19). Until one
    /// exists this recognises nothing, so every connection is refused — which is
    /// 11.3c's correct behaviour for a peer with no acceptor.
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

    public init(timeoutNs: Int64 = BootstrapAdvertisement.maximumTimeoutNs,
                recognising recogniser: any BootstrapOfferRecognising
                    = BootstrapDecoderUnavailable()) throws {
        self.window = try BootstrapWindow(timeoutNs: timeoutNs)
        self.recogniser = recogniser
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
        let listener = try NWListener(using: .tcp)
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
        guard let payload = await firstFrame(on: connection) else {
            refuse(connection); return
        }
        // ⛔ The judgement is `libppcp`'s, not this repository's. With no decoder
        // this is always false and every dial is refused.
        guard recogniser.isWellFormedOffer(payload: payload) else {
            refuse(connection); return
        }

        // 11.3d — at most one attempt at a time; a concurrent one is refused.
        do {
            try window.beginAttempt(atNs: MachClock.hostTimeNs)
        } catch {
            refuse(connection); return
        }

        // ⛔ **D11 is the acceptor and it is not written.** Reaching here means a
        // decoder was supplied and a real `bs_offer` arrived; there is nothing yet
        // that can answer it, so the attempt ends as an abort and the window
        // closes with it (3.7b, 11.9a). ⚠ Do NOT make this branch complete a
        // pairing until §11.5's exchange exists — trap 2 lives in exactly this
        // code, and `bs_accept` MUST be sent before `pk_i` arrives.
        refuse(connection)
        try? await finishAttempt(.abortedOrRejected)
    }

    /// Accumulate until the envelope of `ENC` §3 is whole, or until it is refused.
    ///
    /// ⛔ Bounded twice over: by `BootstrapFirstFrame.maximumPayloadBytes`, and by
    /// the window's own deadline. An unauthenticated stranger controls this
    /// stream, so neither the byte count nor the wait may be open-ended.
    private func firstFrame(on connection: NWConnection) async -> Data? {
        let limit = BootstrapFirstFrame.headerBytes
            + Int(BootstrapFirstFrame.maximumPayloadBytes)
        var buffer = Data()
        while buffer.count < limit {
            guard window.isOpen else { return nil }
            switch BootstrapFirstFrame.classify(buffer) {
            case .envelope(let payload): return payload
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
