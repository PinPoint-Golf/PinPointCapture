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
//  ⚠ **E3.1 only.** It completes a handshake and reports what that establishes.
//  It does not sync clocks (E3.2), accept arm commands (E3.3), announce or
//  transfer (E3.4), or resume after an outage (E3.5). Each of those is a separate
//  level precisely so each is separately demonstrable, and this type should grow
//  by composition rather than by accumulating their responsibilities.
//
//  ⛔ **`.connected` is unreachable here, and that is correct.** `CORE` puts
//  `has_arbitration` and a settled clock estimate behind the connected state, and
//  neither exists until E3.2's burst has run. An honest E3.1 link reports
//  `.pairing`, which is what B2 was designed to show.
//
//  ⚠ **`DevicePeer` is `@unchecked Sendable` over a C engine with no internal
//  locking, and `PeerLinkPump.perform` is the only door to it.** Every read of
//  peer state in this file goes through `perform` and returns a `Sendable` value
//  that is then assigned on the MainActor. `ConformanceHarness` reads
//  `peer.sessionParameters` outside `perform`; that is a latent race in the
//  harness and is deliberately not copied here.
//
//  Spec: `MSG` §3.1, §3.3; `CORE` §5.15, §7.4. Plan E3.1, issue #24.

import Foundation
import Observation
import CaptureCore

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

    /// What the transport actually negotiated, for B2's first row.
    public let security: NegotiatedSecurity
    /// From the scanned code. ⚠ Not from the wire — see `EstablishedLink`.
    public let hostDisplayName: String?
    public let sessionId: String

    private let peer: DevicePeer
    private let pump: PeerLinkPump
    /// Drains `takeEvents` and folds each batch into the state above.
    /// ⚠ `takeEvents(waitingUpTo:)` is a poll, not a stream, so this owns a task
    /// in the same shape as `AppModel`'s mint and health tickers.
    private var events: Task<Void, Never>?

    // MARK: Opening

    /// Builds a peer and a pump over an already-handshaken transport.
    ///
    /// ⚠ **The declaration comes from the device**, through
    /// `ppcpDeclarationInput` — the same non-DEBUG path `HostlessRecordingSession`
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
        // timebase sync is expressed in. `HostlessRecordingSession` builds its peer
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
        } catch {
            phase = .failed(String(describing: error))
            await pump.stop(.failed("handshake did not complete"))
        }
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

        default:
            // ⚠ Every other event belongs to a level that is not built yet —
            // arm (E3.3), capture and payload (E3.4), sync and relations (E3.2),
            // resume (E3.5). They are dropped here rather than half-handled,
            // because a half-handled `session_open` is worse than an ignored one.
            break
        }
    }

    // MARK: Closing

    /// ⚠ Idempotent. Called from `disarm`, from backgrounding, from B2's Cancel
    /// and from `deinit`'s owner, and none of them coordinate.
    public func close(_ reason: ChannelCloseReason = .normal) async {
        events?.cancel()
        events = nil
        await pump.stop(reason)
        if case .closed = phase {} else {
            phase = .closed(reason: nil)
        }
    }

    // MARK: What the app renders

    /// This link, as the app-wide `HostLink`.
    ///
    /// ⛔ **Never `.connected`.** That state means an arbitrating host and a
    /// settled clock estimate, and E3.1 establishes neither. `clock` is `nil` for
    /// the same reason `HostLinkDriver` refuses to synthesise one: a displayed
    /// offset of `0.000 ms ± 0.00` reads as a very good measurement and is not one.
    public var hostLink: HostLink {
        switch phase {
        case .connecting:
            HostLink(state: .pairing, hostName: hostDisplayName)
        case .established:
            HostLink(state: .pairing, hostName: hostDisplayName,
                     hostVersion: negotiatedVersion, lastSeen: lastSeen)
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
