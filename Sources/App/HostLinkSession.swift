//  HostLinkSession.swift
//  One live PPCP link, from a handshaken transport to observable state.
//
//  ⛔ **The seam that was missing.** `RendezvousCoordinator` has produced a fully
//  handshaken `PeerTransport` since D7, and nothing in `Sources/App` ever read it:
//  `RootView.scan` set `HostLink(state: .pairing)` and dropped the socket on the
//  floor. Eight tested subsystems — the peer engine, the pump, the driver, the
//  detection sink, the offer service, the transfer queue — had no caller outside
//  the `#if DEBUG` conformance harness. This is the first shipping path that
//  drives a `ppcp_peer` over a real link.
//
//  ⚠ **E3.1 + E3.2.** It completes a handshake, runs the clock sync burst and
//  reports both. It does not accept arm commands (E3.3), announce or transfer
//  (E3.4), or resume after an outage (E3.5). Each of those is a separate level
//  precisely so each is separately demonstrable, and this type should grow by
//  composition rather than by accumulating their responsibilities.
//
//  ⛔ **`.connected` needs a session with arbitration, and this type does not open
//  one.** `HostLinkDriver.derive` reports `.none` — not `.pairing` — until
//  `peer.sessionParameters?.hasArbitration` is true, which only happens once a
//  real host sends `session_open` (E3.3/E3.4 territory). Until then, `hostLink`
//  maps the driver's `.none` back to `.pairing`: a handshake really did succeed,
//  and "no host" would be a lie. Once a host opens a session, the driver's
//  `.pairing`/`.connected`/`.weak`/`.resyncing` take over unmapped.
//
//  ⚠ **`DevicePeer` is `@unchecked Sendable` over a C engine with no internal
//  locking, and `PeerLinkPump.perform` is the only door to it.** Every read of
//  peer state in this file goes through `perform` and returns a `Sendable` value
//  that is then assigned on the MainActor. `ConformanceHarness` reads
//  `peer.sessionParameters` outside `perform`; that is a latent race in the
//  harness and is deliberately not copied here.
//
//  Spec: `MSG` §3.1, §3.3, §6; `CORE` §5.15, §6.3, §7.4. Plan E3.1/E3.2, issues
//  #24, #25.

import Foundation
import Observation
import CaptureCore

/// What the live link needs to tell the application, as distinct from what it
/// lets the application *read*.
///
/// ⛔ **A delegate rather than an `AsyncStream`, and the reason is `arm`.**
/// `PeerLinkPump.takeEvents` already rejects a stream in its own documentation:
/// the consumer has to be able to call back into the peer between two events.
/// `arm`'s answer is a Readiness *measurement* (`MSG` 5.2a), so the reply has to
/// come back from the call — a stream would leave the ordering of that answer to
/// whoever happened to be draining.
///
/// ⚠ **This carries commands. `hostLink` still carries state**, polled at 250 ms
/// by `AppModel`. Collapsing the two would turn a rendered snapshot into a
/// command, and a missed poll into a missed arm.
/// The owner's answer to a requested Stream (`MSG` 5.1).
///
/// ⚠ `reason` is from the open vocabulary a Stream close shares (5.11a1) —
/// `not_needed`, `thermal_limit`, `storage_full`, `calibration_changed` — and
/// PinPointStudio renders it to an operator as written.
public enum StreamVerdict: Sendable, Hashable {
    case opened
    case refused(reason: String)
}

@MainActor
public protocol HostLinkSessionDelegate: AnyObject {

    /// The host opened a Session (`MSG` 4.1). ⚠ PinPointStudio does this at
    /// `declare`, before any arm, so this is the ordinary first event.
    func hostLink(_ link: HostLinkSession,
                  didOpenSession sessionId: String,
                  parameters: PpcpSessionParameters)

    /// `CORE` 5.2a / 5.15a — **returning is the answer.** The measurement is put
    /// on the wire before anything slow happens, and a device that will not arm
    /// says so here with a `blocked` reason rather than by staying silent.
    func hostLinkDidRequestArm(_ link: HostLinkSession) -> ReadinessMeasurement

    func hostLinkDidRequestDisarm(_ link: HostLinkSession)

    /// `MSG` 5.1 — a counterpart asks **this** peer, as the Source's owner, for a
    /// Stream on a `profile_id` it chose.
    ///
    /// ⛔ **Returning is the answer**, as it is for `arm`. A verdict is required
    /// (E18 1c) and 5.11l makes one of the refusals mandatory: a preview profile
    /// selected for a capture Stream MUST be refused, and a consumer MUST NOT
    /// select one.
    /// ⚠ **`async`, because honouring a preview request is real work** — the
    /// camera may need warming and the Stream has to be registered on the peer
    /// before anything can be announced on it. Answering `opened` and then
    /// producing nothing is the silence E18 1c exists to prevent, one step later.
    func hostLink(_ link: HostLinkSession, didRequestStream streamId: String,
                  sourceId: String, profileId: String,
                  kind: String) async -> StreamVerdict

    /// `MSG` 7.2 — the host arbitrated and issued. The timebase travels with the
    /// number so the receiver can convert it (I22).
    func hostLink(_ link: HostLinkSession, didIssueShot shotId: String,
                  t0Ns: Int64, t0TimebaseId: String, candidateIds: [String])

    /// `MSG` 7.3 — the host wants an interval from this device's ring.
    func hostLink(_ link: HostLinkSession, didRequestCapture shotId: String,
                  t0Ns: Int64, t0TimebaseId: String,
                  streamIds: [String], preNs: Int64, postNs: Int64,
                  replyTo: UInt64) async

    /// A `payload_ack` or a `capture_committed` moved something in the transfer
    /// table. ⚠ Deliberately carries nothing: `PeerLinkEvent.capture` has no
    /// capture id, so the truth is re-read from the table rather than inferred.
    func hostLinkTransfersChanged(_ link: HostLinkSession)

    /// `CORE` 7.4c — three consecutive missed intervals.
    /// ⛔ **Never disarms** (7.4d). REQ-STATE-3's lapse is warm → cold only.
    func hostLinkDidLoseLink(_ link: HostLinkSession)
    func hostLinkDidRestoreLink(_ link: HostLinkSession)
}

/// A single live host link.
@MainActor
@Observable
public final class HostLinkSession {

    /// How far the handshake has got. ⚠ Deliberately narrower than
    /// `HostLinkState`: this is about *this* link's establishment, and the
    /// app-wide link state is derived from it.
    public enum Phase: Sendable, Equatable {
        case connecting
        /// `hello` and `declare` are on the wire and the counterpart answered.
        case established
        /// The link ended. Carries why, in the terms the user is shown.
        case closed(reason: String?)
        case failed(String)
    }

    public private(set) var phase: Phase = .connecting
    /// The wire version the counterpart agreed. ⛔ Read through `perform` on the
    /// `.connected` event, never off the event payload — `PeerLinkEvent.connected`
    /// always carries `nil` (F-S5-4, found by the S5 wave-2 run).
    public private(set) var negotiatedVersion: String?
    /// The counterpart's `Peer.id`. ⚠ A `peer:` UUID, not a name.
    public private(set) var counterpartPeerId: String?
    /// The last time anything arrived. Drives "last seen".
    public private(set) var lastSeen: Date?
    /// A protocol error the counterpart reported, surfaced rather than counted.
    public private(set) var protocolError: String?
    /// E3.2 — `HostLinkDriver`'s own view of link state, from liveness and sync
    /// together. `.none` until a session with arbitration exists; `hostLink` maps
    /// that back to `.pairing` for as long as this link has merely handshaken.
    public private(set) var linkState: HostLinkState = .none
    /// REQ-SYNC-1/3 — `nil` until the burst has produced offset **and** rate.
    public private(set) var clockAgreement: ClockAgreement?

    /// What the transport actually negotiated, for B2's first row.
    public let security: NegotiatedSecurity
    /// What this Studio is called.
    ///
    /// ⚠ **Seeded from the scanned code, then REFRESHED FROM THE WIRE on
    /// `declare`** — see the `.declared` case. The code names the host once and
    /// is never read again, so a rename would otherwise never arrive. `var`
    /// rather than `let` for exactly that, and for nothing else.
    public private(set) var hostDisplayName: String?
    public let sessionId: String

    /// ⚠ Held so `ENC` 2.1d's third channel can be dialled later — a `preview`
    /// arrives after the session is established, which 2.1d calls the expected
    /// case, so the link cannot be a value the constructor consumed and dropped.
    private let transport: any PeerTransport
    /// ⛔ **The wired path inverts `RV` 2d, and this flag is the whole of it.**
    ///
    /// usbmux is host→device only (design §3), so on a cable this device listens
    /// and PinPointStudio dials. The dialler is the initiator, so **the host sends
    /// `hello` and this peer must not**: `libppcp` auto-replies `hello_accept`
    /// from `peer_on_hello`, which is what raises `.connected` here. A `hello`
    /// from this side as well would be two initiators on one link.
    ///
    /// ⚠ It follows that `declare`, the sync timebase and the connect burst all
    /// move from `open()` to the `.connected` event — see `completeOpening()`.
    /// On the WiFi path none of this changes: `ReconnectCoordinator` still dials,
    /// always, and this flag is `false` there.
    ///
    /// ⛔ **`setLinkId()` and `openChannel()` are also never called on this
    /// path.** `ENC` 2.1a puts the `link_id` in the dialler's hands and the host
    /// already wrote `link_bind` on every stream before this type existed.
    private let wired: Bool
    private let peer: DevicePeer
    private let pump: PeerLinkPump
    /// ⚠ `weak`, and `AppModel` owns both ends: the model holds the session and
    /// the session calls back into the model.
    public weak var delegate: (any HostLinkSessionDelegate)?

    /// `MSG` §9.1 — stored Sessions offered to this host, and replayed onto the
    /// link when it accepts.
    ///
    /// ⚠ Held here rather than in `AppModel` because it is built on the **link**
    /// peer and every use of it goes through `perform`. ⛔ `nil` until a store is
    /// attached: `CaptureCore` opens no file (ground rule 8), so the bytes come
    /// from a closure the app layer supplies.
    private var offers: SessionOfferService?

    /// The bulk queue of the hosted Session in force, if any.
    ///
    /// ⛔ **Held because `session_resume` needs it** — 4.3's message carries the
    /// Captures still owed (`pendingForResume`), and the queue is the only thing
    /// that knows what they are. ⚠ Set by `openHostedSession` and cleared when
    /// the recording ends, so a resume never names payloads from a Session that
    /// has closed.
    private weak var transferQueue: PayloadTransferQueue?

    /// REQ-STATE-5 — the outage this link is reporting, once it is back.
    public private(set) var gap: GapWindow?

    /// The host's `session_open`, held from the moment it arrives.
    ///
    /// ⚠ **Held, not acted on.** PinPointStudio opens the Session at `declare`,
    /// which is long before an arm; Streams open at arm, on both peers, from one
    /// set of records. I16 makes these immutable, so this is read once and never
    /// recomputed.
    public private(set) var hostSession: PpcpSessionParameters?

    /// E3.2 — turns liveness + sync into `HostLinkState` and the clock estimate.
    /// ⛔ **Touched only from inside a `pump.perform` closure.** It is a plain
    /// class, not an actor; `pump.perform` is what serialises every call into it,
    /// exactly as it does for `peer` itself.
    private let driver: HostLinkDriver
    /// Drains `takeEvents` and folds each batch into the state above.
    /// ⚠ `takeEvents(waitingUpTo:)` is a poll, not a stream, so this owns a task
    /// in the same shape as `AppModel`'s mint and health tickers.
    private var events: Task<Void, Never>?
    /// Pumps `HostLinkDriver` at `PeerLinkPump`'s own tick cadence. ⚠ Redundant
    /// with the liveness/sync calls `PeerLinkPump.tickOnce()` already makes on its
    /// own internal tick — both are cadence-checked internally against elapsed
    /// time, so the extra calls are no-ops between what's actually due. This is
    /// the read side: without it, nothing ever asks the driver what it derived.
    private var syncTicker: Task<Void, Never>?

    // MARK: Opening

    /// Builds a peer and a pump over an already-handshaken transport.
    ///
    /// ⚠ **The declaration comes from the device**, through
    /// `ppcpDeclarationInput` — the same non-DEBUG path `RecordingSession`
    /// uses. `ConformanceHarness.honestDeclaration` is `#if DEBUG` and its
    /// no-camera fallback exists for a simulator, not for a shipping link.
    /// - Parameter declaration: injected only by tests and by the conformance
    ///   harness. ⚠ A simulator enumerates no camera, so `ppcpDeclarationInput`
    ///   throws there and a handshake could otherwise only ever be exercised on
    ///   hardware — which would leave this seam's first run on a phone.
    /// - Parameter listener: ⛔ **`true` only on the WIRED path, where this
    ///   device is the responder** — see `wired` below and
    ///   `WiredPresenceListener`. Everywhere else this device dialled, and `RV`
    ///   2d makes the dialler the initiator.
    public init(transport: any PeerTransport,
                sessionId: String,
                hostDisplayName: String?,
                device: any CaptureDevice,
                declaration: PpcpDeclaration? = nil,
                listener: Bool = false) throws {
        self.sessionId = sessionId
        self.hostDisplayName = hostDisplayName
        self.security = transport.security
        self.transport = transport
        self.wired = listener

        let peerId = PeerIdentity.current
        // ⛔ The three arguments the live path needs and the bundle path does not:
        // a clock to stamp sync probes with, a health source for 7.4b, and the
        // timebase sync is expressed in. `RecordingSession` builds its peer
        // with none of them, which is why this is a second peer — see #24's note
        // on resolving that at E3.4.
        self.peer = try DevicePeer(
            peerId: peerId,
            role: .capture,
            // ⛔ `RV` 2d, inverted. On the cable the HOST dials, so this peer is
            // the listener and must not behave as an initiator.
            listener: listener,
            clock: PpcpDeviceClock { PpcpTimebases.now(timebaseId: $0) },
            health: { DeviceHealthService.current() },
            syncTimebase: PpcpTimebases.captureId)
        self.pump = PeerLinkPump(peer: peer, transport: transport,
                                 nowNs: { MachClock.hostTimeNs })
        self.driver = HostLinkDriver(peer: peer, timebaseId: PpcpTimebases.captureId)
        self.declaration = try declaration ?? PpcpDeclaration(
            device.ppcpDeclarationInput(peerId: peerId, viewpoint: nil))
    }

    /// ⚠ **Readable, because preview needs it before anything is armed.** The
    /// declaration is what says which Sources exist and which of their profiles
    /// is a preview profile (`intrinsics: none`, 5.11m), and a host's
    /// `stream_open` arrives at connect — long before `RecordingSession` exists
    /// to carry a copy. Reading it off `recording?.declaration` is what made
    /// every inbound `stream_open` unanswerable until arm (#108).
    public let declaration: PpcpDeclaration

    /// `MSG` 3.1 / 3.3 — `hello`, then a complete declaration snapshot.
    ///
    /// ⚠ `negotiatedVersion` is **not** read here. `hello_accept` has not arrived
    /// when `perform` returns; it is read on the `.connected` event instead.
    public func open() async {
        await pump.start()
        do {
            // ⛔ **On the wired path this device sends nothing here.** The host
            // is the initiator (`RV` 2d inverted — see `wired`), so everything
            // below waits for its `hello`, which arrives as `.connected` once
            // `libppcp` has auto-replied `hello_accept`. Sending `declare` or a
            // `sync_probe` first would be this peer talking before the version
            // it must speak has been agreed.
            guard wired == false else {
                lastSeen = Date()
                startDrainingEvents()
                return
            }
            let declaration = self.declaration
            try await pump.perform { peer in
                try peer.hello()
                try peer.declare(declaration)
            }
            phase = .established
            lastSeen = Date()
            startDrainingEvents()
            // REQ-SYNC-1a/I21 — one estimator for this device's own timebase, and
            // REQ-SYNC-2's first trigger: a burst on connect. ⚠ Best-effort: a
            // link that handshook but somehow failed to register sync is still a
            // usable link, and this level's job is not to fail it over that.
            try? await pump.perform { peer in
                try peer.addSyncTimebase(PpcpTimebases.captureId)
                try peer.syncTrigger(.connect)
            }
            startSyncTicking()
        } catch {
            phase = .failed(String(describing: error))
            await pump.stop(.failed("handshake did not complete"))
        }
    }

    /// The wired path's other half of `open()`, run when the host's `hello` has
    /// arrived and `libppcp` has answered it.
    ///
    /// ⚠ **Deliberately not merged with `open()`.** On the dialling path the same
    /// three calls are made *before* `hello_accept` comes back, because a dialler
    /// may pipeline them; on this path there is nothing to pipeline behind — the
    /// version is not agreed until the counterpart's `hello` lands, and a
    /// `declare` sent before it would be a snapshot in a version nobody chose.
    private func completeOpening() async {
        guard wired, phase == .connecting else { return }
        let declaration = self.declaration
        do {
            try await pump.perform { peer in try peer.declare(declaration) }
            phase = .established
        } catch {
            phase = .failed(String(describing: error))
            await pump.stop(.failed("declaration did not go out"))
            return
        }
        // As on the dialling path: best-effort, and a link without it is still a
        // link.
        try? await pump.perform { peer in
            try peer.addSyncTimebase(PpcpTimebases.captureId)
            try peer.syncTrigger(.connect)
        }
        startSyncTicking()
    }

    // MARK: Sync (E3.2)

    /// Reads `HostLinkDriver`'s derived state at `PeerLinkPump`'s own cadence.
    /// ⚠ REQ-SYNC-2's network-change trigger is automatic inside `driver.pump` on
    /// leaving `.lost` — nothing here decides that.
    private func startSyncTicking() {
        syncTicker?.cancel()
        syncTicker = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                guard let self else { return }
                let now = MachClock.hostTimeNs
                if let (state, clock) = try? await self.pump.perform({ [offers = self.offers,
                                                                        host = self.counterpartPeerId,
                                                                        queue = self.transferQueue,
                                                                        session = self.hostSession?.sessionId
                                                                            ?? self.sessionId] peer
                    -> (HostLinkState, ClockAgreement?) in
                    let state = try self.driver.pump(nowNs: now)
                    // ⛔ **`MSG` 4.3's sequence, and the order is the whole of
                    // it**: `session_resume` first so the host learns what exists,
                    // then a fresh sync burst, then `publishRelations` — and only
                    // then does bulk resume. A payload sent against the relation
                    // that drifted through the outage would be read at the wrong
                    // instant. `resume` returns false while it is still
                    // converging, so the tick simply calls it again.
                    if let queue, self.driver.isAwaitingResyncBurst {
                        _ = try? self.driver.resume(sessionId: session,
                                                    peerId: PeerIdentity.current,
                                                    queue: queue, nowNs: now)
                    }
                    // ⚠ **Drained between calls, which is what makes progress.**
                    // `pumpReplay` stops when the peer's outbound queue is full
                    // and `perform` flushes on the way out, so the next tick
                    // resumes from where this one stopped.
                    if let offers, let host { try? offers.pumpReplay(hostPeerId: host) }
                    return (state, self.driver.clockAgreement)
                }) {
                    self.linkState = state
                    self.clockAgreement = clock
                }
                try? await Task.sleep(for: .nanoseconds(PeerLinkPump.defaultTickIntervalNs))
            }
        }
    }

    /// REQ-SYNC-2's third trigger. `AppModel` calls this when
    /// `DeviceHealthService`'s thermal reading changes — oscillator frequency
    /// shifts with temperature, so the estimator's fit is stale and not merely
    /// the offset.
    public func notifyThermalEvent() async {
        try? await pump.perform { try $0.syncTrigger(.thermalEvent) }
    }

    // MARK: Events

    private func startDrainingEvents() {
        events?.cancel()
        events = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                guard let pump = self?.pump else { return }
                // 250 ms matches the harness's batch cadence. The pump's own tick
                // task drives liveness and sync independently of this loop.
                let batch = await pump.takeEvents(waitingUpTo: 0.25)
                guard let self, Task.isCancelled == false else { return }
                for event in batch { await handle(event) }
            }
        }
    }

    private func handle(_ event: PeerLinkEvent) async {
        lastSeen = Date()
        switch event {
        case .connected:
            // ⛔ Through `perform`, and off the peer rather than the payload.
            negotiatedVersion = try? await pump.perform { $0.negotiatedVersion }
            // ⚠ On the wired path this is the first moment there is an agreed
            // version to declare under. A no-op on the dialling path.
            await completeOpening()

        case .declared(let peerId):
            counterpartPeerId = peerId
            // ⛔ **7.4c — a persisted pairing is scoped to the counterpart peer
            // identity learned INSIDE the authenticated channel, and this is that
            // moment.** `hello` is the first disclosure of `Peer.id` (7.6b), so
            // nothing earlier could have recorded it honestly.
            //
            // ⚠ `bind` was written under D7 and had no caller until #96. It
            // mattered less while a pairing was kept only on request; now that
            // every successful pairing is kept, "a pairing scoped to nobody is a
            // pairing scoped to anybody" is the ordinary case rather than the
            // rare one.
            //
            // ⚠ A no-op where nothing is stored — a `mu > 1` pairing (7.4f) has
            // no row to bind, and `bind` returns without writing one.
            try? PairingSecretStore.bind(sessionId: sessionId, toCounterpart: peerId)

            // ⛔ **AND THE HOST'S NAME, WHICH IS THE ONLY MOMENT IT CAN BE
            // REFRESHED.** The pairing code carried a name once, at pairing time,
            // and a persisted pairing never expires (7.4a) — so a Studio renamed
            // afterwards would be shown under its old name on this phone for
            // ever, and Remembered Studios would list several machines under one
            // indistinguishable label. Raised by Mark testing one phone against
            // macOS, Linux and Windows, all three called "PinPointStudio".
            //
            // ⚠ `rename` is a no-op when the name has not changed, which matters:
            // this runs on every connect, and a write would bump the pairing
            // generation and restart the wired presence listener each time.
            if let name = (try? await pump.perform { $0.counterpartName }) ?? nil {
                try? PairingSecretStore.rename(sessionId: sessionId, to: name)
                hostDisplayName = name
            }
            // ⚠ **Offered on `declare`, which is the first moment the counterpart
            // has an identity to owe them to** (7.6b). 9.1's dispositions are
            // held per (host, session), so a second connection to the same host
            // does not re-offer what it already took.
            await offerStoredSessions(toHost: peerId)

        case .protocolError(let code):
            // Surfaced. A counterpart refusing this device is the thing a user
            // most needs told, and `CORE` 11 gives it a reason to show.
            protocolError = code

        case .transportClosed(let reason):
            phase = .closed(reason: String(describing: reason))
            events?.cancel()
            events = nil

        case .sessionOpened(let id), .sessionJoined(let id):
            // ⛔ Read the parameters through `perform` — they live in the engine.
            hostSession = try? await pump.perform { $0.sessionParameters }
            if let hostSession {
                delegate?.hostLink(self, didOpenSession: id, parameters: hostSession)
            }

        case .armRequested:
            // ⛔ **The answer is a measurement and it goes first** (5.2a, 5.15a).
            // The delegate returns synchronously and nothing slow happens in
            // between, so a host learns what this device is before it learns
            // whether the camera eventually settled.
            guard let measurement = delegate?.hostLinkDidRequestArm(self) else { break }
            try? await pump.perform { peer in
                try peer.reportReadiness(measurement.ppcpReadiness())
            }

        case .disarmRequested:
            delegate?.hostLinkDidRequestDisarm(self)

        case .streamRequested(let streamId, let sourceId, let profileId,
                              let kind, _, let replyTo):
            // ⛔ **Answering is a MUST** (erratum E18, 1c) — `stream_open_ack` or
            // `error`, never silence. `stream_open` is `any → owner`, so this is
            // a host asking us for a Stream on a `profile_id` it chose, which is
            // the only carrier the protocol has for a capture-format choice.
            let verdict = await delegate?.hostLink(self, didRequestStream: streamId,
                                             sourceId: sourceId,
                                             profileId: profileId, kind: kind)
                ?? .refused(reason: "not_needed")
            try? await pump.perform { [openedAt = MachClock.hostTimeNs] peer in
                switch verdict {
                case .opened:
                    try peer.streamOpenAck(streamId: streamId, opened: true,
                                           openedAtNs: openedAt,
                                           timebaseId: PpcpTimebases.captureId,
                                           inReplyTo: replyTo)
                case .refused(let reason):
                    try peer.streamOpenAck(streamId: streamId, opened: false,
                                           reason: reason, inReplyTo: replyTo)
                }
            }

        case .shotReceived(let id, let t0Ns, let t0TimebaseId, let candidateIds, _):
            delegate?.hostLink(self, didIssueShot: id, t0Ns: t0Ns,
                               t0TimebaseId: t0TimebaseId, candidateIds: candidateIds)

        case .captureRequested(let shotId, let t0Ns, let t0TimebaseId,
                               let streamIds, let preNs, let postNs, let replyTo):
            await delegate?.hostLink(self, didRequestCapture: shotId,
                                     t0Ns: t0Ns, t0TimebaseId: t0TimebaseId,
                                     streamIds: streamIds,
                                     preNs: preNs, postNs: postNs, replyTo: replyTo)

        case .payload, .capture:
            // ⚠ Carries no id (`PeerLinkPump` maps both to a bare case), so the
            // model re-reads the library's transfer table rather than inferring.
            delegate?.hostLinkTransfersChanged(self)

        case .sessionAccepted(let accept):
            // ⛔ Only `accept` starts a replay; the other two verdicts are
            // recorded and nothing moves.
            // ⛔ Keyed on the HOST's peer id, not the Session's. 9.1's
            // dispositions are per (host, session) — I34 scopes Capture identity
            // by the minting peer, and who holds it is a fact about the host.
            guard let hostPeerId = counterpartPeerId else { break }
            try? await pump.perform { [offers] _ in
                try offers?.received(accept, fromHost: hostPeerId)
            }

        case .linkLost:
            // ⛔ A replay does not survive the link it was accepted on:
            // `BundleReplay` holds the `have_digests` from a `session_accept`
            // that belonged to it. Dropped here, re-offered on the next link.
            offers?.linkLost()
            delegate?.hostLinkDidLoseLink(self)

        case .linkRestored:
            // REQ-STATE-5 — the window during which this host was absent, stated
            // explicitly rather than left for a consumer to notice from a hole.
            //
            // ⚠ **`GapWindow` does not cross the wire, and that is not an
            // oversight.** What crosses on reconnect is `session_resume`'s
            // minted shots and pending Captures; the gap is what a *person* is
            // told, on B3. libppcp's own `gap` is a different thing entirely —
            // lost data inside a segment on a `continuous` Stream (I11) — and
            // conflating the two would report a dropout this device did not have.
            gap = await gapOnRestore()
            delegate?.hostLinkDidRestoreLink(self)

        default:
            // ⚠ What is left is genuinely informational: `hello`, `heartbeat`,
            // `sync` and `relation_update` are E3.2's and are read by
            // `startSyncTicking`'s poll of the driver, not by an event case.
            break
        }
    }

    /// The outage that just ended, in wall-clock terms a person can read.
    ///
    /// ⚠ `CORE` 6.5b / I15 — the interval is computed in the timebase that
    /// *measures* and only then labelled with the wall clock. The driver does
    /// that; this supplies the epoch pair, read adjacently so the two readings
    /// name the same moment.
    private func gapOnRestore() async -> GapWindow? {
        let epochWall = Date()
        let epochAtNs = MachClock.hostTimeNs
        return try? await pump.perform { [driver] _ in
            driver.gap(endingAtNs: epochAtNs,
                       shotsInGap: driver.mintedDuringOutage.count,
                       epochWallUtcNs: Int64(epochWall.timeIntervalSince1970 * 1_000_000_000),
                       epochAtNs: epochAtNs)
        } ?? nil
    }

    /// `MSG` 6.2 / `CORE` 6.3h — how far this device's own acoustic fiducial sat
    /// from the instant the host decided the shot happened.
    ///
    /// ⛔ **REQ-SYNC-4, and it is the only genuinely new arithmetic in E3.** Both
    /// numbers exist and nothing had ever subtracted them: the Candidate's
    /// `atNs` is when this device *heard* the ball, already corrected for
    /// time of flight; the Shot's `t0` is when the host says it *happened*. The
    /// difference is what the clock estimate is wrong by, per shot, and
    /// accumulating it is also how REQ-MIC-4 eventually solves the
    /// microphone-to-ball distance without anyone holding a tape measure.
    ///
    /// ⚠ **Skipped, silently, where the conversion has no relation to work
    /// with.** 8.2i1 — a residual computed against no relation is not a small
    /// residual, it is a meaningless one, and publishing it would poison exactly
    /// the series E2.3 wants to estimate from.
    public func reportResidual(shotId: String, heardAtNs: Int64,
                               issuedT0Ns: Int64, t0TimebaseId: String) async -> Double? {
        try? await pump.perform { [driver] peer -> Double? in
            guard let heardInHostTerms = try peer.instant(heardAtNs,
                                                          on: PpcpTimebases.captureId,
                                                          expressedIn: t0TimebaseId)
            else { return nil }
            let residualNs = heardInHostTerms - issuedT0Ns
            try peer.syncResidual(shotId: shotId, timebaseId: PpcpTimebases.captureId,
                                  residualNs: residualNs)
            driver.recordResidual(nanoseconds: residualNs)
            return Double(residualNs) / 1_000_000
        } ?? nil
    }

    // MARK: Offering stored Sessions (MSG §9.1)

    /// The store this link offers from, and how its bytes are read.
    ///
    /// ⛔ The read closure comes from the app layer because `CaptureCore` opens
    /// no file, and it is a **provider** rather than `Data` because a session is
    /// about a gigabyte.
    public func attachOfferStore(_ store: SessionStore,
                                 read: @escaping @Sendable (SessionBundle) throws -> Data) async {
        offers = try? await pump.perform { peer in
            SessionOfferService(peer: peer, store: store, read: read)
        }
    }

    private func offerStoredSessions(toHost hostPeerId: String) async {
        guard let offers else { return }
        try? await pump.perform { _ in
            try offers.offerAll(toHost: hostPeerId)
        }
    }

    // MARK: The hosted Session (E3.3/E3.4)

    /// Opens this device's Streams on the link and builds the live half a hosted
    /// `RecordingSession` needs.
    ///
    /// ⛔ **Called at arm, not when `session_open` arrived.** The Streams
    /// themselves are opened afterwards, through `HostedSessionContext
    /// .openStreams`, from the recording session's own records — so the wire and
    /// the bundle name one `profile_id` and one `opened_at`.
    ///
    /// ⚠ Returns `nil` where no host has opened a Session, which is the ordinary
    /// hostless path and not a failure.
    public func openHostedSession(promotion: @escaping PromotionPolicy)
        async throws -> HostedSessionContext? {
        guard let hostSession, let hostPeerId = counterpartPeerId else { return nil }
        let context = try await HostedSessionContext.open(
            pump: pump, parameters: hostSession,
            hostPeerId: hostPeerId, promotion: promotion)
        transferQueue = context.queue
        return context
    }

    /// A Shot minted while the host was unreachable (`CORE` 8.3f).
    ///
    /// ⛔ **This is what `session_resume` carries**, and it is the whole reason a
    /// device may mint during an outage without the host losing track: 4.3c says
    /// the ids are not renumbered, so the host learns what happened rather than
    /// being handed a renumbered history.
    public func recordMintedDuringOutage(_ shotId: String) async {
        try? await pump.perform { [driver] _ in
            driver.recordMintedDuringOutage(shotId)
        }
    }

    /// True while the link is down and this device is minting on its own
    /// authority — which is what makes a Shot one to record for the resume.
    public var isOutage: Bool { linkState == .lost }

    /// `ENC` 2.1d — the third channel, opened after the session is established.
    ///
    /// ⛔ **The dialler's job, and only the dialler can do it.** 2.1d carries a
    /// further stream with the **same** `link_id`; a new one would be a new link
    /// and the listener would treat it as a stranger's first connection. So this
    /// is `DiallingPeerLink.openChannel`, and a link that cannot dial (the
    /// listener side, and the plaintext harness path) answers `nil` rather than
    /// pretending.
    ///
    /// ⚠ **Preview refuses the bulk channel** (`PreviewProducer`, 5.11h), so
    /// there is no fallback to be had: without a third channel there is no
    /// preview, which is the honest outcome and not a degraded one. 5.11i's
    /// ordering — preview degrades before transfer, transfer before capture — is
    /// the reason that is acceptable.
    ///
    /// - Returns: `true` where the channel is open and the engine knows about it.
    @discardableResult
    public func openPreviewChannel() async -> Bool {
        // ⛔ **Once per link, and the guard is not defensive tidiness.** Two
        // concurrent calls dial two channels, one gets attached and the other is
        // held by the listener until its bind timeout and swept — which is
        // PinPointStudio's `no link_bind inside the bind timeout` on 27 Aug, and
        // reads at both ends as preview simply not working.
        if hasPreviewChannel { return true }
        // ⛔ **AND `hasPreviewChannel` DOES NOT GUARD THAT, BECAUSE IT IS ONLY
        // TRUE ONCE THE DIAL HAS FINISHED.** The comment above described the
        // defect exactly and the code did not prevent it: a caller arriving
        // while the first dial was still in flight saw `false` and dialled
        // again.  Which is not hypothetical — it is the ordinary case.  This
        // application starts the dial in a detached `Task` at session open, and
        // PinPointStudio sends `stream_open` for preview immediately after
        // `session_open` (5.11.2 — setup and framing is preview's main use), so
        // the request lands DURING the dial essentially every time.  One of the
        // two racing callers then got `false`, `src:camera:wide` was refused
        // `no_preview_channel`, and nothing ever asked again: no picture, no
        // error, on a link whose third channel was up a second later.
        // Diagnosed on device 28 Aug 2026 after two evenings of a black tile.
        //
        // ⚠ A second caller now AWAITS the first dial and takes its answer.
        if let inFlight = previewChannelDial { return await inFlight.value }
        let dial = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.dialPreviewChannel()
        }
        previewChannelDial = dial
        let opened = await dial.value
        previewChannelDial = nil
        return opened
    }

    /// The dial itself. ⚠ Only ever entered through `openPreviewChannel()`,
    /// which is what makes it happen once.
    private func dialPreviewChannel() async -> Bool {
        guard let dialling = transport as? any DiallingPeerLink else {
            print("[preview] channel: transport cannot dial (\(type(of: transport)))")
            return false
        }
        let channel: any ByteChannel
        do {
            channel = try await dialling.openChannel(.preview)
        } catch {
            print("[preview] channel: dial failed — \(String(describing: error))")
            return false
        }
        await pump.attachPreview(channel)
        // ⛔ **THE ENGINE IS NOT TOLD, BECAUSE IN THIS APPLICATION THE TRANSPORT
        // OWNS `link_bind`.**  `PpcpTransport.openChannel(_:)` mints the link id
        // (`PpcpLinkIdSource.mint()`) and writes the 2.1d bind frame itself, and
        // `DevicePeer.setLinkId` is called nowhere — so the engine has no link
        // id, and `ppcp_peer_open_channel()` refuses on exactly that
        // (`ppcp_peer.c:899`).  The call was therefore redundant AND could only
        // ever fail: it asked the engine to emit a second `link_bind` it could
        // not build for a channel the transport had already bound.
        //
        // ⚠ That refusal was read as "there is no preview channel", so
        // `src:camera:wide` was refused `no_preview_channel` on every connect
        // while its third channel sat up and working — no picture, no error,
        // for two days.  Diagnosed on device 28 Aug 2026.
        //
        // ⚠ Nothing else in the engine wants the bit: `opened_channels` gates
        // only `link_bind` emission and `hello`'s auto-bind, never `peer_queue`,
        // so sending preview payload on channel 2 needs no registration at all.
        hasPreviewChannel = true
        print("[preview] channel: open")
        return true
    }

    /// The dial in flight, if there is one — see `openPreviewChannel()`.
    private var previewChannelDial: Task<Bool, Never>?

    /// Whether `ENC` 2.1d's third channel is open on this link.
    public private(set) var hasPreviewChannel = false

    /// Builds the live `preview` Stream a host asked for.
    ///
    /// ⛔ **Here rather than in `AppModel`, because `pump` is private and stays
    /// private** — this file's header calls `perform` the only door to the peer,
    /// and a `pump` accessor would be a door beside it.
    public func openPreview(_ stream: PpcpStreamRecord,
                            device: any CaptureDevice) async throws -> LivePreview {
        try await LivePreview(pump: pump, device: device, stream: stream)
    }

    /// `CORE` 7.3c — readiness again, whenever `settled` changes.
    ///
    /// ⚠ Best-effort: a link that cannot carry the measurement is still a link,
    /// and the bundle records it either way.
    public func report(_ measurement: ReadinessMeasurement,
                       streamIds: [String] = []) async {
        try? await pump.perform { peer in
            try peer.reportReadiness(measurement.ppcpReadiness(), streamIds: streamIds)
        }
    }

    // MARK: Closing

    /// ⚠ Idempotent. Called from `disarm`, from backgrounding, from B2's Cancel
    /// and from `deinit`'s owner, and none of them coordinate.
    public func close(_ reason: ChannelCloseReason = .normal) async {
        events?.cancel()
        events = nil
        syncTicker?.cancel()
        syncTicker = nil
        await pump.stop(reason)
        if case .closed = phase {} else {
            phase = .closed(reason: nil)
        }
    }

    // MARK: What the app renders

    /// This link, as the app-wide `HostLink`.
    ///
    /// ⚠ **`.connected` is reachable, but only once a host actually arbitrates.**
    /// `HostLinkDriver.derive` reports `.none` until `session_open` carries
    /// arbitration, and `.none` here would read as "no host" for a link that has
    /// genuinely handshaken — so it is mapped back to `.pairing`. Once a host
    /// opens a session, the driver's own states take over unmapped. `clock` comes
    /// from the same driver and is `nil` for the reason it always was: a
    /// displayed offset of `0.000 ms ± 0.00` reads as a very good measurement and
    /// is not one.
    public var hostLink: HostLink {
        switch phase {
        case .connecting:
            HostLink(state: .pairing, hostName: hostDisplayName)
        case .established:
            HostLink(state: linkState == .none ? .pairing : linkState,
                     hostName: hostDisplayName, hostVersion: negotiatedVersion,
                     clock: clockAgreement, lastSeen: lastSeen,
                     // REQ-STATE-5 — B3's *Gap reported to host* and *Shots in
                     // the gap* have rendered "none" since they were written.
                     gap: gap,
                     // ⚠ `wired` is the LISTENER flag, and that is the honest
                     // source: this device cannot see a cable, but it can see
                     // that the host dialled IT — which only happens over
                     // usbmux (`RV` 2d inverted). Not a guess about hardware.
                     transport: wired ? .cable : .wifi)
        case .closed, .failed:
            HostLink(state: .lost, hostName: hostDisplayName,
                     hostVersion: negotiatedVersion, lastSeen: lastSeen)
        }
    }

    /// Whether the handshake has settled far enough to leave B2.
    public var hasSettled: Bool { phase == .established }

    /// B2's first row, from what the transport actually negotiated rather than a
    /// literal. ⚠ On this platform it reads "TLS 1.2 · PSK" — there is no TLS 1.3
    /// external PSK on iOS, which `RV` 5.4b1 predicted and D1 measured.
    public var securitySummary: String { security.summary }
}
