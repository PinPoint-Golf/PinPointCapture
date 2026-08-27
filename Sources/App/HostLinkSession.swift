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

    /// `MSG` 7.2 — the host arbitrated and issued. The timebase travels with the
    /// number so the receiver can convert it (I22).
    func hostLink(_ link: HostLinkSession, didIssueShot shotId: String,
                  t0Ns: Int64, t0TimebaseId: String)

    /// `MSG` 7.3 — the host wants an interval from this device's ring.
    func hostLink(_ link: HostLinkSession, didRequestCapture shotId: String,
                  streamIds: [String], preNs: Int64, postNs: Int64, replyTo: UInt64)

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
    /// From the scanned code. ⚠ Not from the wire — see `EstablishedLink`.
    public let hostDisplayName: String?
    public let sessionId: String

    private let peer: DevicePeer
    private let pump: PeerLinkPump
    /// ⚠ `weak`, and `AppModel` owns both ends: the model holds the session and
    /// the session calls back into the model.
    public weak var delegate: (any HostLinkSessionDelegate)?

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
    public init(transport: any PeerTransport,
                sessionId: String,
                hostDisplayName: String?,
                device: any CaptureDevice,
                declaration: PpcpDeclaration? = nil) throws {
        self.sessionId = sessionId
        self.hostDisplayName = hostDisplayName
        self.security = transport.security

        let peerId = PeerIdentity.current
        // ⛔ The three arguments the live path needs and the bundle path does not:
        // a clock to stamp sync probes with, a health source for 7.4b, and the
        // timebase sync is expressed in. `RecordingSession` builds its peer
        // with none of them, which is why this is a second peer — see #24's note
        // on resolving that at E3.4.
        self.peer = try DevicePeer(
            peerId: peerId,
            role: .capture,
            clock: PpcpDeviceClock { PpcpTimebases.now(timebaseId: $0) },
            health: { DeviceHealthService.current() },
            syncTimebase: PpcpTimebases.captureId)
        self.pump = PeerLinkPump(peer: peer, transport: transport,
                                 nowNs: { MachClock.hostTimeNs })
        self.driver = HostLinkDriver(peer: peer, timebaseId: PpcpTimebases.captureId)
        self.declaration = try declaration ?? PpcpDeclaration(
            device.ppcpDeclarationInput(peerId: peerId, viewpoint: nil))
    }

    private let declaration: PpcpDeclaration

    /// `MSG` 3.1 / 3.3 — `hello`, then a complete declaration snapshot.
    ///
    /// ⚠ `negotiatedVersion` is **not** read here. `hello_accept` has not arrived
    /// when `perform` returns; it is read on the `.connected` event instead.
    public func open() async {
        await pump.start()
        do {
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
                if let (state, clock) = try? await self.pump.perform({ peer
                    -> (HostLinkState, ClockAgreement?) in
                    let state = try self.driver.pump(nowNs: now)
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

        case .shotReceived(let id, let t0Ns, let t0TimebaseId, _):
            delegate?.hostLink(self, didIssueShot: id, t0Ns: t0Ns,
                               t0TimebaseId: t0TimebaseId)

        case .captureRequested(let shotId, let streamIds, let preNs, let postNs, let replyTo):
            delegate?.hostLink(self, didRequestCapture: shotId, streamIds: streamIds,
                               preNs: preNs, postNs: postNs, replyTo: replyTo)

        case .payload, .capture:
            // ⚠ Carries no id (`PeerLinkPump` maps both to a bare case), so the
            // model re-reads the library's transfer table rather than inferring.
            delegate?.hostLinkTransfersChanged(self)

        case .linkLost:
            delegate?.hostLinkDidLoseLink(self)

        case .linkRestored:
            delegate?.hostLinkDidRestoreLink(self)

        default:
            // ⚠ What is left is genuinely informational: `hello`, `heartbeat`,
            // `sync` and `relation_update` are E3.2's and are read by
            // `startSyncTicking`'s poll of the driver, not by an event case.
            break
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
        return try await HostedSessionContext.open(
            pump: pump, parameters: hostSession,
            hostPeerId: hostPeerId, promotion: promotion)
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
                     clock: clockAgreement, lastSeen: lastSeen)
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
