//  WiredPresenceListenerTests.swift
//  The one thing about the wired path that cannot be asserted from an API: where
//  the two listeners actually bound.
//
//  ⛔ **This suite exists for a single claim, and it is the one the whole design
//  rests on: `NWParameters.requiredLocalEndpoint` really does pin the bind to
//  `127.0.0.1` and really does keep the record off the LAN.** The presence record
//  is plaintext and it names every pairing this device holds; the trade recorded
//  in design §5.4 is defensible *only* because the reader has to be on the cable
//  or on this device. An all-interfaces bind would turn it into a broadcast of
//  the pairing set, and nothing in the type's shape would look different.
//
//  ⚠ **The reader here is a raw BSD socket, deliberately.** That is what the host
//  has at the far end of usbmux — a connected fd and no framing — so a reader
//  built out of `NWConnection` would be testing a more forgiving client than the
//  one that exists. Reading to EOF is the whole protocol (C3).
//
//  ⚠ **Every negative has a control.** "Could not connect to the LAN address" is
//  also what a firewall, a VPN or a locked-down network produces, and a test that
//  cannot tell those from a correct bind would pass on a machine where the bind
//  was wrong. So each negative is paired with an all-interfaces listener on an
//  ephemeral port that MUST be reachable at the same address; if the control
//  cannot be reached, the environment is the thing being measured and the case
//  says so rather than passing.
//
//  Contract: `PinPointStudio/docs/implementation/wired_transport_impl_plan.md`
//  C3, C4, C5. Design: `wired_transport_design.md` §5.3.

import Foundation
import Network
import Testing
import CaptureCore
@testable import PinPointCapture

@Suite("Wired presence listener", .serialized)
struct WiredPresenceListenerTests {

    /// `RV` §10's inputs. Two different `psk`s, so the two pairings derive two
    /// different `K_id`s and two different identities — which is what makes the
    /// per-pairing listener of C5 observable at all.
    private static func pairing(_ psk: String, session: String) throws
        -> WiredPresenceListener.HeldPairing {
        WiredPresenceListener.HeldPairing(
            sessionId: session,
            hostDisplayName: "Studio",
            keys: try RendezvousKeys(psk: Data(hex: psk),
                                     sid: Data(hex: "3f2504e04f8941d39a0c0305e82c3301")))
    }

    private static func twoPairings() throws -> [WiredPresenceListener.HeldPairing] {
        [try pairing("000102030405060708090a0b0c0d0e0f", session: "ses:aaaa"),
         try pairing("0f0e0d0c0b0a09080706050403020100", session: "ses:bbbb")]
    }

    /// ⛔ **Every case tears its listener down before the next one starts, and
    /// `defer` cannot do it.** The presence port is FIXED, so two cases overlap on
    /// one port; `defer { Task { await listener.stop() } }` is fire-and-forget and
    /// the next case binds while the last one is still cancelling — which is
    /// `EADDRINUSE`, and it is what this suite hit before `stop()` learned to wait
    /// for the port back. Swift has no `async defer`, so the teardown is here
    /// instead of in each case.
    private func withPresence<T>(
        label: String? = nil,
        channels: [PpcpChannel] = [.control],
        pairings: [WiredPresenceListener.HeldPairing]? = nil,
        onLink: @escaping @Sendable (WiredPresenceListener.WiredLink) async -> Void = { _ in },
        _ body: (WiredPresenceListener, WiredPresence) async throws -> T
    ) async throws -> T {
        let listener = WiredPresenceListener(displayLabel: label, channels: channels)
        let record: WiredPresence
        do {
            record = try await listener.start(pairings: try pairings ?? Self.twoPairings(),
                                              onLink: onLink)
        } catch {
            await listener.stop()
            throw error
        }
        do {
            let result = try await body(listener, record)
            await listener.stop()
            return result
        } catch {
            await listener.stop()
            throw error
        }
    }

    // MARK: The record on the wire

    /// C3 end to end: what a host reading the presence port actually receives.
    @Test("The record served on the fixed port is the record that was built")
    func recordIsServedOnTheFixedPort() async throws {
        try await withPresence(label: "Test iPhone") { _, record in
            // ⚠ 50915 written out rather than read from the constant: this is the
            // number the host has compiled in, and a test that took it from the
            // same place the code does could not catch the day it changed (C4).
            let served = try #require(Sockets.readToEOF(host: "127.0.0.1", port: 50915,
                                                        timeout: 3))
            #expect(served == (try record.encoded()))
            #expect(served.count <= WiredPresence.maxRecordBytes)
            // Two held pairings, two listeners, two entries (C5).
            #expect(record.peers.count == 2)
            #expect(record.peers[0].port != record.peers[1].port)
            #expect(record.peers[0].pskIdentity != record.peers[1].pskIdentity)
            for peer in record.peers {
                #expect(peer.pskIdentity.count == PpcpKeyLengths.pskIdentity)
            }
        }
    }

    /// ⛔ **The bind.** The record is readable on loopback and unreachable at
    /// every other address this machine has.
    @Test("The presence port is loopback only")
    func presenceIsLoopbackOnly() async throws {
        try await withPresence { _, _ in
            #expect(Sockets.readToEOF(host: "127.0.0.1", port: 50915, timeout: 3) != nil)

            let lan = try #require(Sockets.firstNonLoopbackIPv4(),
                                   "no non-loopback IPv4 on this machine — the bind cannot be measured")
            let control = try #require(Sockets.allInterfacesListener(),
                                       "could not open a control listener")
            defer { close(control.fd) }
            try #require(Sockets.canConnect(host: lan, port: control.port, timeout: 2),
                         """
                         the control listener — bound to 0.0.0.0 — is unreachable at \(lan), \
                         so this environment blocks the connection regardless of where the \
                         presence listener bound. Nothing about the bind can be concluded.
                         """)

            #expect(Sockets.canConnect(host: lan, port: 50915, timeout: 2) == false,
                    "the presence record is readable from the LAN — design §5.3 is broken")
        }
    }

    /// ⛔ The same for the per-pairing `PpcpListener`s. They carry TLS, so this is
    /// less alarming than the presence port — but a LAN-reachable PPCP listener
    /// on this device is `RV` 3.5d's forbidden shape and pulls the local-network
    /// permission into a path that does not need it.
    @Test("Every per-pairing listener is loopback only")
    func perPairingListenersAreLoopbackOnly() async throws {
        try await withPresence { _, record in
            let lan = try #require(Sockets.firstNonLoopbackIPv4(),
                                   "no non-loopback IPv4 on this machine")
            let control = try #require(Sockets.allInterfacesListener())
            defer { close(control.fd) }
            try #require(Sockets.canConnect(host: lan, port: control.port, timeout: 2),
                         "the control listener is unreachable; nothing can be concluded")

            for peer in record.peers {
                #expect(Sockets.canConnect(host: "127.0.0.1", port: peer.port, timeout: 2),
                        "listener on \(peer.port) is not reachable on loopback")
                #expect(Sockets.canConnect(host: lan, port: peer.port, timeout: 2) == false,
                        "listener on \(peer.port) is reachable from the LAN")
            }
        }
    }

    // MARK: The identity in the record is the identity that was registered

    /// ⛔ **The design's load-bearing claim, measured rather than reasoned about.**
    /// A host that dials with the identity out of the record completes the
    /// handshake; the platform's listener accepts exactly the identity it
    /// registered, so a link at all is proof the two are the same 17 bytes.
    ///
    /// ⚠ This is precisely what PinPointStudio will do: resolve the published
    /// identity under `RV` 5.3b, then offer it back verbatim as the TLS client.
    /// `FixedPskCredentials` is that client's behaviour — one identity for the
    /// whole link, no rotation.
    @Test("A host dialling with the published identity gets a link")
    func publishedIdentityIsTheRegisteredOne() async throws {
        let pairings = try Self.twoPairings()
        let accepted = Mutexed<WiredPresenceListener.WiredLink?>(nil)
        // ⚠ Both channels here, unlike the cases above: `CORE` T2 makes two
        // independently flow-controlled channels the definition of a PPCP
        // transport, so a control-only dial produces `incompleteLink` however
        // well the identity resolved.
        try await withPresence(channels: PpcpChannel.required,
                               pairings: pairings,
                               onLink: { accepted.set($0) }) { _, record in
            // The SECOND pairing, so a listener that published the wrong entry —
            // or one entry for every pairing — fails here rather than passing by
            // luck.
            let peer = record.peers[1]
            let credentials = try FixedPskCredentials(tlsKey: pairings[1].keys.tlsKey,
                                                      identity: peer.pskIdentity)
            let transport = try await withTimeout(seconds: 20) {
                try await PpcpConnector().connect(to: PeerEndpoint(host: "127.0.0.1",
                                                                   port: peer.port),
                                                  credentials: credentials)
            }
            // ⚠ The accept side runs on the listener's own task; give it a moment
            // to deliver rather than asserting on a race.
            for _ in 0..<40 where accepted.get() == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let link = try #require(accepted.get(), "the listener did not deliver the link")
            // ⛔ The pairing is known from WHICH listener accepted, never off the
            // wire.
            #expect(link.sessionId == pairings[1].sessionId)
            #expect(link.hostDisplayName == "Studio")

            await transport.close(.normal)
            await link.transport.close(.normal)
        }
    }

    /// ⚠ A device that has paired with nothing publishes nothing — and that is a
    /// fact about the device, not a fault. ⛔ It must not bind the presence port
    /// either: a record with an empty `peers` is one the host refuses (C3), and
    /// holding the port while publishing nothing is worse than not being there.
    @Test("A device holding no pairing publishes nothing at all")
    func noPairingsPublishesNothing() async throws {
        let listener = WiredPresenceListener(displayLabel: nil, channels: [.control])
        await #expect(throws: WiredPresenceListener.Unavailable.noPairingsHeld) {
            _ = try await listener.start(pairings: []) { _ in }
        }
        #expect(Sockets.canConnect(host: "127.0.0.1", port: 50915, timeout: 1) == false)
        await listener.stop()
    }

    /// ⛔ **A collision on 50915 is survivable and must be** (`RV` 3.6a, C4). The
    /// second listener reports it and takes its own PPCP listeners down; nothing
    /// raises, and the host simply reads a record it cannot parse.
    @Test("A taken presence port is a diagnosis, not a failure")
    func takenPresencePortIsSurvivable() async throws {
        try await withPresence { _, _ in
            let second = WiredPresenceListener(displayLabel: nil, channels: [.control])
            var reported: WiredPresenceListener.Unavailable?
            do {
                _ = try await second.start(pairings: Self.twoPairings()) { _ in }
            } catch let error as WiredPresenceListener.Unavailable {
                reported = error
            }
            let failure = try #require(reported)
            guard case .presencePortUnavailable = failure else {
                Issue.record("expected a port collision, got \(failure)")
                return
            }
            // ⚠ And it left nothing listening behind it — the record the
            // incumbent serves must stay the only truth about which ports are
            // live.
            #expect(await second.servedRecord() == nil)
            #expect(Sockets.readToEOF(host: "127.0.0.1", port: 50915, timeout: 3) != nil,
                    "the incumbent's record is still served")
            await second.stop()
        }
    }
}

// MARK: - A host's-eye view: raw sockets

/// ⚠ What the host has at the far end of usbmux is a connected fd, so that is
/// what reads here. Every call is bounded by a poll timeout: an unreachable
/// address must produce a verdict, not a hang.
private enum Sockets {

    /// Connect, read until the peer closes, return what arrived. `nil` if the
    /// connection could not be made.
    static func readToEOF(host: String, port: UInt16, timeout: Double) -> Data? {
        guard let fd = connected(host: host, port: port, timeout: timeout) else { return nil }
        defer { close(fd) }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return out }
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { return out }           // 0 is EOF, which is the framing
            out.append(contentsOf: buffer[0..<n])
            if out.count > 64 * 1024 { return out }
        }
    }

    static func canConnect(host: String, port: UInt16, timeout: Double) -> Bool {
        guard let fd = connected(host: host, port: port, timeout: timeout) else { return false }
        close(fd)
        return true
    }

    /// A non-blocking connect with a hard deadline. ⛔ Non-blocking because a
    /// blocking connect to an address a firewall drops does not return for
    /// minutes, and a test that hangs reads as a test that is still running.
    private static func connected(host: String, port: UInt16, timeout: Double) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { close(fd); return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return fd }
        guard errno == EINPROGRESS else { close(fd); return nil }

        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { close(fd); return nil }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// The control for every negative: a listener on `0.0.0.0`, which MUST be
    /// reachable at the LAN address if the environment permits the connection at
    /// all.
    static func allInterfacesListener() -> (fd: Int32, port: UInt16)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY.bigEndian
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); return nil }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { close(fd); return nil }
        return (fd, UInt16(bigEndian: actual.sin_port))
    }

    /// The first IPv4 address on this machine that is not `127.0.0.1`.
    ///
    /// ⚠ In a simulator these are the *Mac's* interfaces, which is exactly the
    /// right thing to test against: a listener bound to `0.0.0.0` in a simulator
    /// really is reachable from the network.
    static func firstNonLoopbackIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let raw = entry.pointee.ifa_addr,
                  raw.pointee.sa_family == sa_family_t(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let converted = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var address = pointer.pointee.sin_addr
                return inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN))
            }
            guard converted != nil else { continue }
            let host = String(cString: text)
            if host != "127.0.0.1" { return host }
        }
        return nil
    }
}

// MARK: - Small helpers

/// ⚠ A box, because the accept callback runs off this task and Swift 6 will not
/// let a `var` cross that boundary.
private final class Mutexed<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: Value) { lock.lock(); value = new; lock.unlock() }
}

/// Race `work` against a sleeper. ⚠ Local to this file; the copy in
/// `TransportLoopbackTests` is `private` there for the same reason.
private func withTimeout<T: Sendable>(seconds: Double,
                                      _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TransportError.handshakeFailed("timed out after \(seconds)s")
        }
        guard let first = try await group.next() else {
            throw TransportError.handshakeFailed("no result")
        }
        group.cancelAll()
        return first
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
