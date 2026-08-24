//  PpcpAdvertiser.swift
//  `PPCP-RV` §3 — advertising `_ppcp._tcp`, and the listener behind it.
//
//  ⛔ **The instance name is set explicitly and is `PPCP-<rid[0..3]>`** (3.2a).
//  Every platform advertising API defaults the service name to the device name,
//  which on a phone is frequently a person's name; 3.2b forbids that and says why.
//  `NWListener.service(name:)` with an empty name would take the default, so the
//  name is always passed.
//
//  ⛔ **The TXT record is `DiscoveryAdvertisement.txtRecord` and nothing else**
//  (3.3a/3.3b). No `Peer.id`, no model, no session count, no capability. The
//  closed list lives in `CaptureCore` where it can be tested without a simulator;
//  this file only publishes it.
//
//  ⚠ **`rn` rotates every registration and at least every 15 minutes** (3.4a).
//  The timer here re-registers with a fresh nonce rather than editing the record,
//  because the instance name is derived from `rid` and changes with it.
//
//  ⛔ **Discovery failure is never an error state** (3.6a). Multicast is
//  rate-limited or dropped by many consumer access points, blocked by client
//  isolation on guest networks, and does not cross VLANs — "it will not work at a
//  range". Nothing here reports a failure to the user; the pairing code is the
//  path (3.6b).
//
//  ⚠ **F-D1-1 stands and is why this advertises without accepting.** A
//  `Network.framework` listener cannot resolve a rotating PSK identity — the only
//  server-side entry point registers a (key, identity) pair in advance, and 5.3a
//  makes the identity fresh per connection. So this device can be *found* and a
//  host that finds it must still dial the pairing-code path. Advertising is
//  therefore reconnection convenience, exactly as §3's own preamble says.
//
//  Spec: `RV` §3, §7.6a. Plan D7.

import Foundation
import Network
import Security
import CaptureCore

/// Advertises this device as a PPCP capture peer.
public actor PpcpAdvertiser {

    /// What is currently published. `nil` when not advertising.
    public private(set) var advertisement: DiscoveryAdvertisement?

    private let identityKey: Data
    private let role: DiscoveryRole
    private var listener: NWListener?
    private var rotation: Task<Void, Never>?
    private let queue = DispatchQueue(label: "org.pinpointstudio.capture.ppcp.advertise")

    /// - Parameter identityKey: `K_id` of the pairing being offered for
    ///   reconnection (3.4d). ⛔ Never `K_tls`: 5.1a/5.1b give each key one use,
    ///   and publishing anything derived from the handshake key on a multicast
    ///   network is what the split exists to prevent.
    public init(identityKey: Data, role: DiscoveryRole = .capture) {
        self.identityKey = identityKey
        self.role = role
    }

    /// Registers the service and starts the rotation.
    ///
    /// - Parameter port: the TCP port a counterpart would dial. ⚠ Advertised
    ///   because DNS-SD requires one; see the F-D1-1 note above for what a dialler
    ///   actually finds there.
    public func start(port: UInt16) throws {
        guard listener == nil else { return }
        try register(port: port)
        rotation = Task { [weak self] in
            while Task.isCancelled == false {
                // 3.4a — "at least every 15 minutes". The library states the
                // interval; nothing here writes 900 down again.
                let interval = DiscoveryAdvertisement.maximumNonceAgeNs
                try? await Task.sleep(for: .nanoseconds(interval))
                guard Task.isCancelled == false else { return }
                try? await self?.rotate(port: port)
            }
        }
    }

    public func stop() {
        rotation?.cancel()
        rotation = nil
        listener?.cancel()
        listener = nil
        advertisement = nil
    }

    /// 3.4a — a fresh `rn`, therefore a fresh `rid` and a fresh instance name.
    private func rotate(port: UInt16) throws {
        listener?.cancel()
        listener = nil
        try register(port: port)
    }

    private func register(port: UInt16) throws {
        let built = try DiscoveryAdvertisement(
            identityKey: identityKey,
            // ⛔ From `SecRandomCopyBytes`, the platform's audited CSPRNG. `rv.h`
            // makes every random value a parameter for exactly this reason: a
            // library that called `rand()` would be the single point at which the
            // whole model fails silently.
            rn: try Self.nonce(),
            role: role,
            mintedAtNs: MachClock.hostTimeNs)

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TransportError.listenerFailed("port \(port)")
        }
        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: nwPort)
        // ⛔ The name is passed. An empty name takes the device name (3.2b).
        listener.service = NWListener.Service(
            name: built.instanceName,
            type: DiscoveryAdvertisement.serviceType,
            txtRecord: NWTXTRecord(built.txtRecord))
        // ⚠ Connections are refused rather than accepted: see F-D1-1. A listener
        // that accepted would be accepting a connection it cannot authenticate,
        // and `RV` 2c has no unauthenticated path.
        listener.newConnectionHandler = { connection in connection.cancel() }
        // 3.6a — a listener that will not start is not an error state to report.
        listener.stateUpdateHandler = { _ in }
        listener.start(queue: queue)

        self.listener = listener
        self.advertisement = built
    }

    /// 3.4a's eight bytes.
    static func nonce() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw TransportError.failedToMintLinkId(Int(status))
        }
        return Data(bytes)
    }
}

// MARK: - Browsing

/// The discovery path's other half: finding a counterpart that advertises.
///
/// ⚠ Here even though 3.5b recommends the capture peer advertise, because 3.5c
/// makes the reverse conformant and it is the shape a "reconnect to a discovered
/// host" interaction needs — which is the interaction this application's B1
/// screen already draws.
public actor PpcpBrowser {

    public struct Found: Sendable, Hashable {
        public let instanceName: String
        public let rn: Data
        public let rid: Data
        public let role: DiscoveryRole
        public let protocolVersions: String
        /// The index into the pairing list whose `K_id` resolved it (3.4b).
        public let pairingIndex: Int
        /// ⛔ **The browse result's own endpoint, carried rather than rebuilt,
        /// and 3.4c is the reason it is not a host and a port.**
        ///
        /// A `NWBrowser` result carries no address at all — `.service(name:type:
        /// domain:interface:)` is a *name*, and resolution happens when something
        /// dials it. So "reconstruct host and port" is not a cheaper alternative
        /// to this; it is a second resolution this file would have to perform
        /// itself, and three things go wrong in it:
        ///
        ///  1. **The instance we resolved is not the instance a name re-resolves
        ///     to.** 3.4a rotates `rn` at least every fifteen minutes and 3.2a
        ///     derives the instance name from `rid`, so an instance name has a
        ///     bounded life and is reused by whoever registers it next. 3.4c says
        ///     a browsing peer must not connect to an instance it cannot resolve;
        ///     dialling *this* endpoint keeps the gap between resolving and
        ///     dialling as short as the platform allows, where a name looked up
        ///     again later could reach a different registration entirely.
        ///  2. A host publishes several addresses. `NWConnection` walks all of
        ///     them from a `.service` endpoint; a single reconstructed host
        ///     string picks one and fails if that one is the wrong family.
        ///  3. A link-local address needs its interface scope, which this
        ///     endpoint carries in its `interface` and a host string drops.
        ///
        /// ⚠ It is `NWEndpoint` and therefore Platform-only, which is why `Found`
        /// lives here and not in `CaptureCore` — `LayerPurityTests` forbids
        /// `import Network` in Core, correctly.
        public let endpoint: NWEndpoint

        public init(instanceName: String, rn: Data, rid: Data, role: DiscoveryRole,
                    protocolVersions: String, pairingIndex: Int, endpoint: NWEndpoint) {
            self.instanceName = instanceName
            self.rn = rn
            self.rid = rid
            self.role = role
            self.protocolVersions = protocolVersions
            self.pairingIndex = pairingIndex
            self.endpoint = endpoint
        }
    }

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "org.pinpointstudio.capture.ppcp.browse")

    public init() {}

    /// Browses until `seconds` elapse, resolving each advertisement against the
    /// held pairings.
    ///
    /// ⛔ 3.4c — an instance whose `rid` cannot be resolved is **not** returned,
    /// because a browsing peer must not connect to one. Filtering here rather than
    /// at a call site is what stops a screen offering it.
    public func browse(against identityKeys: [Data], seconds: Double = 3) async -> [Found] {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: DiscoveryAdvertisement.serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.browser = browser

        let collected = Mutexed<[Found]>([])
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint,
                      case let .bonjour(txt) = result.metadata else { continue }
                guard let rn = DiscoveryResolver.hexField(txt["rn"], bytes: 8),
                      let rid = DiscoveryResolver.hexField(txt["rid"], bytes: 8),
                      let role = DiscoveryRole(rawValue: txt["role"] ?? ""),
                      // 3.3a — a browser filters on MAJOR before connecting.
                      let versions = txt["pv"],
                      // ⛔ 3.3d / 3.3e (erratum E25) — `pv` is a version RANGE,
                      // and "a reader that cannot parse a range ignores that
                      // advertisement rather than guessing". So this is a `guard`
                      // and not a warning: a peer whose `pv` this build does not
                      // understand is not offered to the user at all, which is
                      // the same answer 3.4c gives for an unresolvable `rid`.
                      PpcpVersionRange.advertises(versions,
                                                  major: PpcpLibrary.wireMajor)
                else { continue }
                // ⛔ 3.4c. Unresolvable means not offered, not "offered with a
                // warning".
                guard let index = DiscoveryResolver.resolve(rid: rid, rn: rn,
                                                            against: identityKeys)
                else { continue }
                collected.mutate {
                    guard $0.contains(where: { $0.instanceName == name }) == false else { return }
                    // ⛔ `result.endpoint`, not a host and port assembled from
                    // `name`. See `Found.endpoint` for why that is a 3.4c
                    // question and not a convenience.
                    $0.append(Found(instanceName: name, rn: rn, rid: rid, role: role,
                                    protocolVersions: versions, pairingIndex: index,
                                    endpoint: result.endpoint))
                }
            }
        }
        browser.start(queue: queue)
        try? await Task.sleep(for: .seconds(seconds))
        browser.cancel()
        self.browser = nil
        return collected.value
    }
}

/// ⚠ A tiny box so the browser's callback — which fires on its own queue — can
/// accumulate without this file reaching for an actor it would then have to await
/// from a non-async handler.
private final class Mutexed<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&stored)
    }
}
