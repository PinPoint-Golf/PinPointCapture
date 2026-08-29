//  WiredPresenceListener.swift
//  The device half of the wired transport: one plaintext presence listener on a
//  fixed port, and one `PpcpListener` per held pairing behind it.
//
//  ⛔ **usbmux is host→device only, and everything here falls out of that.**
//  Apple ships no equivalent of `adb reverse`: a host process opens a connection
//  *to* a port the device is listening on, and a device process cannot open one
//  to the host. So on a cable **the device listens and the host dials**, which
//  inverts `RV` 2d — the host becomes the initiator and the TLS client, and this
//  device becomes the responder that answers `hello_accept`.
//
//  ⚠ **That does not contradict `ReconnectCoordinator`'s "PinPointStudio
//  advertises and this device dials. Always."** — and the two must be read
//  together rather than one of them deleted. That statement is about the
//  **WiFi/discovery** path of `RV` 3.5d/3.5e, where it is still exactly true and
//  still for the same measured reason: on a *browsed* connection the host draws a
//  fresh `rn2` per 5.3a and this platform's listener cannot resolve a rotating
//  identity. The cable is the explicit exception, and it is only survivable
//  because the identity resolution moves to the client (design §5.2): the device
//  publishes the identity it registered, and the host verifies it under 5.3b
//  before it dials. There is a listener in *this* file, on the direct path of
//  `RV` §2, and there is still none in `ReconnectCoordinator`.
//
//  ⛔ **THERE IS ONE PLAINTEXT LISTENER IN THIS FILE, AND `PpcpTransport.swift`'s
//  rule that there must never be one still stands.** `RV` 5.2f forbids an
//  unencrypted *PPCP connection* — no fallback, not on failure, not on user
//  instruction. This socket is not one: it carries no PPCP message (7.7a), no
//  Source, profile, calibration or stored session (7.7b), and nothing that is not
//  already public. A PSK identity crosses in the clear in every `ClientHello`, an
//  `rid` crosses in the clear in every multicast TXT record, and a port number is
//  not a secret. What it *does* disclose is how many pairings this device holds
//  (`RV` 3.4d1 keeps that unobservable on the radio) — which is the whole reason
//  for the bind below.
//
//  ⛔ **BOTH LISTENERS BIND `127.0.0.1` AND NOTHING ELSE.** This is the single
//  most important line in the file. Two load-bearing reasons (design §5.3):
//
//   1. The record is plaintext and it **names every pairing this device holds**.
//      An all-interfaces bind quietly converts it into a LAN broadcast of the
//      pairing set, and the trade §5.4 records is only defensible because the
//      reader is on the cable or on this device.
//   2. It keeps the wired path clear of the iOS local-network permission.
//      Loopback is exempt; a LAN-reachable listener is not. A wired connection
//      that works before the user has answered that prompt — or after they have
//      declined it — is worth having on its own merits.
//
//  ⚠ **A hostile process on this device could bind the presence port first and
//  serve a bogus record.** The consequence is a failed TLS handshake: it holds no
//  `K_tls`, and the identity it publishes resolves against no pairing the host
//  holds. That is denial of service and nothing more. **Noted, deliberately not
//  mitigated** (design §5.4) — a mitigation would be a second trust root for a
//  path whose whole security comes from the pairing.
//
//  ⚠ **A collision on the presence port is survivable and must be.** The host
//  reads a record it cannot parse and treats this device as not wired; `RV` 3.6a
//  makes that an ordinary outcome of discovery, not an error state, so it gets a
//  diagnosis and **never a banner**.
//
//  Contract: `PinPointStudio/docs/implementation/wired_transport_impl_plan.md`
//  **C3** (the record), **C4** (the port and the bind), **C5** (one listener per
//  held pairing). Design: `wired_transport_design.md` §5, §6, §6.5, §9.5.

import Foundation
import Network
import Synchronization
import CaptureCore

/// Serves the wired presence record, and owns the `PpcpListener`s it names.
actor WiredPresenceListener {

    /// ⛔ **The one constant in the wired design** — contract **C4**. Private
    /// range, no IANA assignment, and declared once per repository with the value
    /// written in both (`ppcp_usbmux.h` in PinPointStudio, here in
    /// PinPointCapture) because a shared header across three repositories would
    /// be a dependency none of them wants.
    ///
    /// ⚠ Fixed because it is the one thing the host cannot be told. Every other
    /// port in this design is ephemeral and reported in the record.
    static let presencePort: UInt16 = 50915

    /// A pairing this device holds, in the form the listener needs.
    ///
    /// ⛔ **The set is persisted pairings PLUS any code scanned and not yet
    /// connected** (design §6.5) — mirroring exactly what the host's
    /// `identityResolver()` already accepts, which is *"outstanding codes and
    /// persisted pairings alike"*. Symmetry is the rule: the two sets must match,
    /// or a code resolves at one end and is unpublished at the other, and a
    /// first pairing over the cable becomes impossible for no reason.
    struct HeldPairing: Sendable {
        /// `RV` 4.3e — the Session the pairing was established for, and the
        /// durable name of the counterpart on this side.
        let sessionId: String
        /// ⚠ From the pairing, never from the wire. Carried through so an
        /// adopted wired link reports the same host name a WiFi one would.
        let hostDisplayName: String?
        /// 5.1c — re-derived from the persisted `PRK`, not stored.
        let keys: RendezvousKeys
    }

    /// A link the host dialled over the cable, and the pairing it resolved to.
    ///
    /// ⛔ **The pairing comes from *which listener accepted it*, not from the
    /// wire.** That is the whole point of one listener per pairing: the identity
    /// the host offered is the identity that listener registered, so acceptance
    /// *is* the resolution. Nothing downstream has to ask the link who it is.
    struct WiredLink: Sendable {
        let sessionId: String
        let hostDisplayName: String?
        let transport: any PeerTransport
    }

    /// ⚠ Every case here is a **diagnosis**, not an error to raise at a user
    /// (`RV` 3.6a). "Wired is unavailable" is an ordinary state of a phone that
    /// is not plugged in.
    enum Unavailable: Error, Sendable, Equatable {
        /// Nothing to publish. A device that has paired with nothing has nothing
        /// a host could dial.
        case noPairingsHeld
        /// Every per-pairing listener failed to bind. ⚠ Distinct from the case
        /// above: this one is a fault, that one is a fact.
        case noListenerBound(String)
        /// The presence port is taken — by another copy of this app, or by
        /// something hostile (see the file header). Survivable by design.
        case presencePortUnavailable(String)
        /// The record could not be built from what did bind.
        case recordRefused(String)
    }

    /// `RV` 4.4d — untrusted display text. ⚠ It is *this* device's own label, and
    /// the host must still sanitise it before display; nothing on either side
    /// keys on it.
    private let displayLabel: String?
    private let channels: [PpcpChannel]

    private var presence: NWListener?
    /// One per held pairing (**C5**). `PpcpCredentials` carries one `tlsKey` and
    /// one `nextPskIdentity()`, and an `NWListener` registers exactly one (key,
    /// identity) pair — so a pairing is a listener, not a row in a table.
    private var listeners: [PpcpListener] = []
    private var accepting: [Task<Void, Never>] = []
    private var record: WiredPresence?

    private let queue = DispatchQueue(label: "org.pinpointstudio.capture.wired.presence")

    /// ⚠ `NWConnection` is not `Sendable` and has to cross from the listener's
    /// dispatch queue into this actor. Same box, same reason, as `PpcpListener`.
    private struct ConnectionBox: @unchecked Sendable {
        let connection: NWConnection
    }

    init(displayLabel: String?, channels: [PpcpChannel] = PpcpChannel.required) {
        self.displayLabel = displayLabel
        self.channels = channels
    }

    /// The record currently being served, for a diagnostic screen. `nil` before
    /// `start`. ⛔ Carries no key material — a PSK identity is public, a `PRK` is
    /// not and is nowhere near this type.
    func servedRecord() -> WiredPresence? { record }

    // MARK: Starting

    /// Binds one `PpcpListener` per pairing, then serves the record naming them.
    ///
    /// ⚠ **In that order, and it matters.** The record has to be complete before
    /// anything can read it; a host that read a half-built record would dial a
    /// port that is not listening yet and fail for a reason that looks like a
    /// cable fault.
    ///
    /// - Parameter onLink: called once per accepted wired link. ⚠ Called from
    ///   this actor's context; the caller hops wherever it needs to be.
    @discardableResult
    func start(pairings: [HeldPairing],
               onLink: @escaping @Sendable (WiredLink) async -> Void) async throws -> WiredPresence {
        guard pairings.isEmpty == false else { throw Unavailable.noPairingsHeld }
        await stop()

        var peers: [WiredPresence.Peer] = []
        var lastFailure = "none"
        for pairing in pairings {
            // ⛔ `port: 0` — the bound port goes into the record, so no port
            // derivation scheme is needed and none must be invented.
            let listener = PpcpListener(credentials: RendezvousCredentials(keys: pairing.keys),
                                        channels: channels,
                                        port: 0,
                                        loopbackOnly: true)
            do {
                let port = try await listener.start()
                guard let identity = await listener.registeredIdentity() else {
                    throw Unavailable.recordRefused("listener bound without an identity")
                }
                // ⛔ 5.3f — the identity goes into the record as the 17 octets
                // the platform was handed. No transcoding, no validation as
                // text, no truncation.
                peers.append(try WiredPresence.Peer(port: port, pskIdentity: identity))
                listeners.append(listener)
                accepting.append(acceptLoop(on: listener, for: pairing, onLink: onLink))
            } catch {
                // ⚠ One pairing's listener failing is not the others failing.
                // A phone holding four pairings and three ports is still wired.
                await listener.stop()
                lastFailure = String(describing: error)
            }
        }

        guard peers.isEmpty == false else {
            await stop()
            throw Unavailable.noListenerBound(lastFailure)
        }

        let record: WiredPresence
        do {
            record = try WiredPresence(displayLabel: displayLabel, peers: peers)
        } catch WiredPresence.Failure.labelTooLong {
            // ⚠ `dl` is display text and nothing keys on it, so an absurd device
            // name costs the label and not the record.
            record = try WiredPresence(displayLabel: nil, peers: peers)
        } catch {
            await stop()
            throw Unavailable.recordRefused(String(describing: error))
        }
        self.record = record

        do {
            try await servePresence(record.encoded())
        } catch {
            await stop()
            throw error
        }
        return record
    }

    /// The plaintext listener. Writes the record, then closes — **there is no
    /// framing** (C3), and the host reads to EOF with a 4096-byte cap and a 2 s
    /// deadline.
    private func servePresence(_ bytes: Data) async throws {
        let parameters = NWParameters.tcp
        // ⛔ The bind. See the file header — this line is the security argument.
        parameters.requiredLocalEndpoint =
            .hostPort(host: .ipv4(.loopback),
                      port: NWEndpoint.Port(rawValue: WiredPresenceListener.presencePort)!)
        // ⚠ We close first on every connection, so the listening port sits under
        // this device's own TIME_WAIT sockets. Without reuse, restarting the
        // listener — which design §6 does on every foreground entry — fails to
        // bind for two minutes and reads as a port collision.
        parameters.allowLocalEndpointReuse = true
        // `RV` §8 — nothing here wants a peer-to-peer radio, least of all a
        // socket that only ever talks to this device.
        parameters.includePeerToPeer = false

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Unavailable.presencePortUnavailable(String(describing: error))
        }
        presence = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let box = ConnectionBox(connection: connection)
            Task { await self.serve(box, bytes: bytes) }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // ⚠ A continuation may be resumed once and a state handler fires
            // many times — the same guard `PpcpListener` uses.
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let outcome: Result<Void, any Error>?
                switch state {
                case .ready:
                    outcome = .success(())
                case .failed(let error):
                    // ⛔ The collision case, and it is NOT an error state. `RV`
                    // 3.6a: the host reads a record it cannot parse and treats
                    // this device as not wired.
                    outcome = .failure(Unavailable.presencePortUnavailable(String(describing: error)))
                case .cancelled:
                    outcome = .failure(Unavailable.presencePortUnavailable("cancelled"))
                default:
                    outcome = nil
                }
                guard let outcome else { return }
                let claimed = resumed.withLock { taken -> Bool in
                    if taken { return false }
                    taken = true
                    return true
                }
                guard claimed else { return }
                continuation.resume(with: outcome)
            }
            listener.start(queue: queue)
        }
    }

    /// One presence read: write the record, send FIN, close.
    ///
    /// ⚠ Nothing is read from this connection, ever. The record is the whole
    /// exchange and a request would be a protocol to version.
    private func serve(_ box: ConnectionBox, bytes: Data) {
        box.connection.start(queue: queue)
        // `isComplete: true` on the final message is the FIN the host reads as
        // EOF.
        box.connection.send(content: bytes,
                            contentContext: .finalMessage,
                            isComplete: true,
                            completion: .contentProcessed { _ in box.connection.cancel() })
        // ⚠ A reader that connects and then stalls must not hold a connection
        // open indefinitely — it is an unbounded resource a stranger controls,
        // which is the same argument `PpcpListener`'s bind timeout makes.
        let queue = self.queue
        Task {
            try? await Task.sleep(for: .seconds(5))
            queue.async { box.connection.cancel() }
        }
    }

    // MARK: Accepting

    /// ⚠ **Which listener accepted is which pairing resolved**, so the sessionId
    /// travels with the link from here and is never read off it.
    private func acceptLoop(on listener: PpcpListener,
                            for pairing: HeldPairing,
                            onLink: @escaping @Sendable (WiredLink) async -> Void) -> Task<Void, Never> {
        let sessionId = pairing.sessionId
        let name = pairing.hostDisplayName
        return Task { [weak self] in
            while Task.isCancelled == false {
                guard let transport = try? await listener.accept() else { return }
                guard self != nil else {
                    await transport.close(.cancelled)
                    return
                }
                await onLink(WiredLink(sessionId: sessionId,
                                       hostDisplayName: name,
                                       transport: transport))
            }
        }
    }

    // MARK: Stopping

    /// ⛔ **`NWListener.cancel()` returns before the port is released, and on a
    /// FIXED port that is a defect rather than a nicety.** Design §6 restarts
    /// this listener on foreground entry and on any change to the pairing set, so
    /// a `stop()` that returned early would be followed immediately by a `start()`
    /// that failed with `EADDRINUSE` — and that failure is indistinguishable, from
    /// the outside, from the port collision §5.3 says to treat as "not wired".
    /// The device would simply stop being reachable on the cable, silently, after
    /// its first background trip. ⚠ Measured: this is exactly what
    /// `Tests/WiredPresenceListenerTests` hit between two cases.
    ///
    /// ⚠ The timer is the backstop, not the mechanism. A listener that already
    /// failed may never report `.cancelled` again, and a teardown that could hang
    /// is worse than one that is occasionally 2 s pessimistic.
    private static func awaitCancellation(of listener: NWListener,
                                          on queue: DispatchQueue) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = Mutex(false)
            let finish: @Sendable () -> Void = {
                let claimed = resumed.withLock { taken -> Bool in
                    if taken { return false }
                    taken = true
                    return true
                }
                if claimed { continuation.resume() }
            }
            listener.stateUpdateHandler = { state in
                if case .cancelled = state { finish() }
            }
            listener.cancel()
            queue.asyncAfter(deadline: .now() + 2) { finish() }
        }
    }

    /// ⛔ Idempotent, and it takes everything down together. A presence record
    /// naming ports that are no longer listening is worse than no record: the
    /// host dials, fails, and diagnoses a cable.
    func stop() async {
        record = nil
        if let presence {
            await Self.awaitCancellation(of: presence, on: queue)
        }
        presence = nil
        for task in accepting { task.cancel() }
        accepting.removeAll()
        for listener in listeners { await listener.stop() }
        listeners.removeAll()
    }
}
