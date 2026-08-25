//  ReconnectCoordinatorTests.swift
//  `PPCP-RV` §3 — reconnecting to a host already paired with, and the three
//  clauses that shape it.
//
//  ⛔ 3.6a — discovery failure is **not** an error. The tests below assert that a
//  silent network produces a `notFound` that says how long it has looked, and
//  never a thrown error or a failure case.
//  ⛔ 3.5e — the **host** advertises. An instance that resolves but claims some
//  other role is not dialled.
//  ⛔ 11.1a — a pairing from a code and a pairing from guided pairing are
//  indistinguishable from 11.6e onward, so the walk reads both from one list.
//
//  ⚠ **What these do NOT prove.** No real advertisement is on the network in a
//  simulator, so `PpcpBrowser` itself is stubbed here and the browse is measured
//  against PinPointStudio instead. What is measured here is everything between
//  the browse and the dial — the role filter, the index-to-key-material walk,
//  the refusal-outranks-unreachable diagnosis, and the silence.

import Foundation
import Network
import Testing
import CaptureCore
@testable import PinPointCapture

// MARK: - Doubles

/// A transport that exists and does nothing. ⚠ Enough for these tests: none of
/// them sends a byte, they assert which endpoint was dialled with which key.
private struct SilentChannel: ByteChannel {
    let channel: PpcpChannel
    func send(_ bytes: Data) async throws {}
    func receive() async throws -> Data? { nil }
    func close(_ reason: ChannelCloseReason) async {}
}

private struct SilentTransport: PeerTransport {
    let control: any ByteChannel = SilentChannel(channel: .control)
    let bulk: any ByteChannel = SilentChannel(channel: .bulk)
    let preview: (any ByteChannel)? = nil
    let security = NegotiatedSecurity.directPathPlaintext
    func close(_ reason: ChannelCloseReason) async {}
}

private struct StubBrowser: HostBrowsing {
    let results: [PpcpBrowser.Found]
    func browse(against identityKeys: [Data], seconds: Double) async -> [PpcpBrowser.Found] {
        results
    }
}

/// Records what it was asked to dial, so a test can assert the endpoint and the
/// key material rather than only the outcome.
private final class DialLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var endpoints: [NWEndpoint] = []
    private(set) var tlsKeys: [Data] = []
    func record(_ endpoint: NWEndpoint, _ tlsKey: Data) {
        lock.lock(); defer { lock.unlock() }
        endpoints.append(endpoint)
        tlsKeys.append(tlsKey)
    }
}

/// A clock a test can wind forward. ⚠ `Silence.searchedForNs` is monotonic, so
/// the only honest way to assert on it is to control the monotonic source.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    var now: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

private struct StubConnector: DiscoveredHostConnecting {
    let log: DialLog
    /// Thrown instead of connecting, per endpoint in dial order. `nil` connects.
    let failures: [(any Error)?]

    func connect(to endpoint: NWEndpoint,
                 credentials: any PpcpCredentials,
                 channels: [PpcpChannel]) async throws -> any PeerTransport {
        log.record(endpoint, credentials.tlsKey)
        let index = log.endpoints.count - 1
        if index < failures.count, let failure = failures[index] { throw failure }
        return SilentTransport()
    }
}

// MARK: - Fixtures

private enum Fixture {

    /// Real derived key material — `RendezvousKeys` runs the library's HKDF, so
    /// these are the same bytes a scanned code would produce. ⚠ No real pairing
    /// store is touched anywhere in this file — the walk runs through the
    /// `HeldPairings` seam. The store itself is covered by
    /// `PairingSecretStoreTests`, which erratum E56 made possible.
    static func keys(seed: UInt8) throws -> RendezvousKeys {
        try RendezvousKeys(psk: Data(repeating: seed, count: 16),
                           sid: Data(repeating: seed &+ 1, count: 16))
    }

    static func found(instance: String,
                      role: DiscoveryRole = .host,
                      pairingIndex: Int,
                      port: UInt16 = 51_000) -> PpcpBrowser.Found {
        PpcpBrowser.Found(
            instanceName: instance,
            rn: Data(repeating: 0xAA, count: 8),
            rid: Data(repeating: 0xBB, count: 8),
            role: role,
            protocolVersions: "1",
            pairingIndex: pairingIndex,
            // ⚠ A `.service` endpoint, which is what `NWBrowser` actually hands
            // over — a name, not an address. The point of carrying it.
            endpoint: .service(name: instance, type: DiscoveryAdvertisement.serviceType,
                               domain: "local.", interface: nil))
    }

    /// A held table with `count` pairings, session ids `ses-0`, `ses-1`, …
    static func held(count: Int) throws -> (HeldPairings, [RendezvousKeys]) {
        let all = try (0..<count).map { try keys(seed: UInt8($0 + 1)) }
        let store = HeldPairings(
            identityKeys: {
                (0..<count).map { ("ses-\($0)", all[$0].identityKey) }
            },
            keys: { sessionId in
                guard let index = Int(sessionId.dropFirst("ses-".count)),
                      index < all.count else { return nil }
                return all[index]
            },
            displayName: { "Studio \($0)" })
        return (store, all)
    }

    /// A cadence that does not make a test wait. ⚠ Only the gaps are shortened;
    /// the walk under test is unchanged.
    static let brisk = ReconnectCadence(sweepSeconds: 0,
                                        gapsNs: [1_000_000],
                                        steadyGapNs: 1_000_000)
}

// MARK: - The tests

@Suite("RV §3 — reconnecting to a host already paired with")
struct ReconnectCoordinatorTests {

    @Test("⛔ Nothing held means no browse at all — 3.4b has nothing to resolve against")
    func noPairingsHeldDoesNotBrowse() async throws {
        let empty = HeldPairings(identityKeys: { [] },
                                 keys: { _ in nil },
                                 displayName: { _ in nil })
        let log = DialLog()
        let coordinator = ReconnectCoordinator(
            browser: StubBrowser(results: [Fixture.found(instance: "PPCP-1", pairingIndex: 0)]),
            connector: StubConnector(log: log, failures: []),
            held: empty,
            cadence: Fixture.brisk)

        guard case .noPairingsHeld = await coordinator.attempt() else {
            Issue.record("expected noPairingsHeld")
            return
        }
        // ⛔ And crucially it did not dial the instance the stub browser offered.
        #expect(log.endpoints.isEmpty)
    }

    @Test("⛔ 3.6a — a silent network is NOT an error, and says how long it looked")
    func silenceIsNotAFailure() async throws {
        let (held, _) = try Fixture.held(count: 2)
        let clock = TestClock()
        let coordinator = ReconnectCoordinator(
            browser: StubBrowser(results: []),
            connector: StubConnector(log: DialLog(), failures: []),
            held: held,
            cadence: Fixture.brisk,
            nowNs: { clock.now })

        clock.now = 1_000
        guard case .notFound(let first) = await coordinator.attempt() else {
            Issue.record("expected notFound"); return
        }
        #expect(first.sweeps == 1)
        #expect(first.pairingsHeld == 2)

        // ⚠ **The distinction the clause must not cost.** A second sweep, later,
        // is a different `Silence` — "not yet" and "still not" are visibly
        // different to the caller without either being a failure.
        clock.now = 30_000_000_000
        guard case .notFound(let second) = await coordinator.attempt() else {
            Issue.record("expected notFound"); return
        }
        #expect(second.sweeps == 2)
        #expect(second.searchedForNs > first.searchedForNs)
        #expect(second.searchedForNs == 30_000_000_000 - 1_000)
    }

    @Test("⚠ reset() forgets an old wait so a fresh one does not inherit it")
    func resetClearsTheSilence() async throws {
        let (held, _) = try Fixture.held(count: 1)
        let coordinator = ReconnectCoordinator(
            browser: StubBrowser(results: []),
            connector: StubConnector(log: DialLog(), failures: []),
            held: held,
            cadence: Fixture.brisk)
        _ = await coordinator.attempt()
        _ = await coordinator.attempt()
        await coordinator.reset()
        guard case .notFound(let silence) = await coordinator.attempt() else {
            Issue.record("expected notFound"); return
        }
        #expect(silence.sweeps == 1)
    }

    @Test("⛔ 3.5e — an instance that resolves but is not a host is not dialled")
    func onlyHostsAreDialled() async throws {
        let (held, _) = try Fixture.held(count: 1)
        let log = DialLog()
        let coordinator = ReconnectCoordinator(
            browser: StubBrowser(results: [
                Fixture.found(instance: "PPCP-CAP", role: .capture, pairingIndex: 0),
                Fixture.found(instance: "PPCP-OBS", role: .observer, pairingIndex: 0)
            ]),
            connector: StubConnector(log: log, failures: []),
            held: held,
            cadence: Fixture.brisk)

        guard case .notFound = await coordinator.attempt() else {
            Issue.record("expected notFound — neither instance is a host"); return
        }
        #expect(log.endpoints.isEmpty)
    }

    @Test("A resolved host is dialled at the browse result's own endpoint, with that pairing's K_tls")
    func dialsTheResolvedHost() async throws {
        let (held, all) = try Fixture.held(count: 3)
        let log = DialLog()
        // 3.4b — the resolver said index 2, so it must be `ses-2`'s key material.
        let coordinator = ReconnectCoordinator(
            browser: StubBrowser(results: [Fixture.found(instance: "PPCP-9B1D2DF9",
                                                         pairingIndex: 2)]),
            connector: StubConnector(log: log, failures: []),
            held: held,
            cadence: Fixture.brisk)

        guard case .connected(let host) = await coordinator.attempt() else {
            Issue.record("expected connected"); return
        }
        #expect(host.sessionId == "ses-2")
        #expect(host.instanceName == "PPCP-9B1D2DF9")
        #expect(host.hostDisplayName == "Studio ses-2")
        #expect(log.tlsKeys.count == 1)
        // ⛔ The right pairing's `K_tls`, not the first one held.
        #expect(log.tlsKeys.first == all[2].tlsKey)
        // ⛔ And the endpoint carried through as a `.service`, not rebuilt.
        guard case .service(let name, _, _, _) = try #require(log.endpoints.first) else {
            Issue.record("expected a .service endpoint"); return
        }
        #expect(name == "PPCP-9B1D2DF9")
    }

    @Test("⛔ A host that answered and refused outranks a host that did not answer")
    func refusalOutranksUnreachability() async throws {
        let (held, _) = try Fixture.held(count: 2)
        let log = DialLog()
        let coordinator = ReconnectCoordinator(
            browser: StubBrowser(results: [
                Fixture.found(instance: "PPCP-DEAD", pairingIndex: 0),
                Fixture.found(instance: "PPCP-LIVE", pairingIndex: 1)
            ]),
            connector: StubConnector(log: log, failures: [
                TransportError.endpointUnreachable("no route"),
                TransportError.handshakeFailed("alert 20")
            ]),
            held: held,
            cadence: Fixture.brisk)

        // ⚠ The unreachable one was dialled FIRST, and is still not the answer:
        // something answered, so "nothing answered" would be false.
        guard case .hostRefusedThePairing(let sessionId, let reason)
                = await coordinator.attempt() else {
            Issue.record("expected hostRefusedThePairing"); return
        }
        #expect(sessionId == "ses-1")
        #expect(reason == "alert 20")
        #expect(log.endpoints.count == 2)
    }

    @Test("A host that never answers is couldNotReachHost, not a silent network")
    func unreachableIsNotSilence() async throws {
        let (held, _) = try Fixture.held(count: 1)
        let coordinator = ReconnectCoordinator(
            browser: StubBrowser(results: [Fixture.found(instance: "PPCP-1", pairingIndex: 0)]),
            connector: StubConnector(log: DialLog(),
                                     failures: [TransportError.endpointUnreachable("no route")]),
            held: held,
            cadence: Fixture.brisk)

        guard case .couldNotReachHost(let sessionId, _) = await coordinator.attempt() else {
            Issue.record("expected couldNotReachHost"); return
        }
        #expect(sessionId == "ses-0")
    }

    @Test("⚠ search() yields every silence and stops at the link")
    func searchYieldsSilencesThenConnects() async throws {
        let (held, _) = try Fixture.held(count: 1)
        // Silent for two sweeps, then the host appears.
        actor Sweeps {
            var count = 0
            func next() -> Int { count += 1; return count }
        }
        struct EventualBrowser: HostBrowsing {
            let sweeps: Sweeps
            func browse(against identityKeys: [Data], seconds: Double) async
            -> [PpcpBrowser.Found] {
                await sweeps.next() > 2
                    ? [Fixture.found(instance: "PPCP-1", pairingIndex: 0)] : []
            }
        }
        let coordinator = ReconnectCoordinator(
            browser: EventualBrowser(sweeps: Sweeps()),
            connector: StubConnector(log: DialLog(), failures: []),
            held: held,
            cadence: Fixture.brisk)

        var outcomes: [ReconnectOutcome] = []
        for await outcome in await coordinator.search() { outcomes.append(outcome) }

        #expect(outcomes.count == 3)
        guard case .notFound(let first) = outcomes[0],
              case .notFound(let second) = outcomes[1],
              case .connected = outcomes[2] else {
            Issue.record("expected two silences then a link"); return
        }
        // ⛔ The caller saw the wait grow rather than only hearing about success.
        #expect(first.sweeps == 1)
        #expect(second.sweeps == 2)
    }

    @Test("⛔ search() does not spin when nothing is held")
    func searchStopsWithNothingHeld() async throws {
        let empty = HeldPairings(identityKeys: { [] }, keys: { _ in nil },
                                 displayName: { _ in nil })
        let coordinator = ReconnectCoordinator(
            browser: StubBrowser(results: []),
            connector: StubConnector(log: DialLog(), failures: []),
            held: empty,
            cadence: Fixture.brisk)
        var count = 0
        for await _ in await coordinator.search() { count += 1 }
        #expect(count == 1)
    }

    @Test("⛔ The host is on DHCP — a failed dial re-browses, it does not retry the address")
    func aFailedDialReResolves() async throws {
        let (held, _) = try Fixture.held(count: 1)

        /// Sweep 1 offers the address the host used to be at; sweep 2 offers
        /// where it is now. ⚠ This is the DHCP case exactly: the instance name
        /// and the pairing are unchanged, only the record behind them moved.
        actor Sweeps {
            var count = 0
            func next() -> Int { count += 1; return count }
        }
        struct MovingHost: HostBrowsing {
            let sweeps: Sweeps
            func browse(against identityKeys: [Data], seconds: Double) async
            -> [PpcpBrowser.Found] {
                let sweep = await sweeps.next()
                return [Fixture.found(instance: sweep == 1 ? "PPCP-OLD" : "PPCP-NEW",
                                      pairingIndex: 0)]
            }
        }

        let log = DialLog()
        let coordinator = ReconnectCoordinator(
            browser: MovingHost(sweeps: Sweeps()),
            // The stale endpoint is not there any more; the fresh one answers.
            connector: StubConnector(log: log,
                                     failures: [TransportError.endpointUnreachable("no route")]),
            held: held,
            cadence: Fixture.brisk)

        var outcomes: [ReconnectOutcome] = []
        for await outcome in await coordinator.search() { outcomes.append(outcome) }

        // ⛔ The recovery is a **new browse**, so the second dial went somewhere
        // the second browse resolved — not to the address that just failed.
        #expect(log.endpoints.count == 2)
        guard case .service(let first, _, _, _) = try #require(log.endpoints.first),
              case .service(let second, _, _, _) = try #require(log.endpoints.last) else {
            Issue.record("expected .service endpoints"); return
        }
        #expect(first == "PPCP-OLD")
        #expect(second == "PPCP-NEW")
        guard case .couldNotReachHost = outcomes.first,
              case .connected = outcomes.last else {
            Issue.record("expected an unreachable host and then a link"); return
        }
    }

    @Test("⛔ Nothing about an endpoint survives a sweep — there is no address to go stale")
    func noEndpointIsCarriedBetweenSweeps() async throws {
        let (held, _) = try Fixture.held(count: 1)
        // A browser that finds the host once and then never again. If anything
        // cached the endpoint, the second sweep would dial it a second time.
        actor Sweeps {
            var count = 0
            func next() -> Int { count += 1; return count }
        }
        struct OnceOnly: HostBrowsing {
            let sweeps: Sweeps
            func browse(against identityKeys: [Data], seconds: Double) async
            -> [PpcpBrowser.Found] {
                await sweeps.next() == 1
                    ? [Fixture.found(instance: "PPCP-GONE", pairingIndex: 0)] : []
            }
        }
        let log = DialLog()
        let coordinator = ReconnectCoordinator(
            browser: OnceOnly(sweeps: Sweeps()),
            connector: StubConnector(log: log,
                                     failures: [TransportError.endpointUnreachable("no route")]),
            held: held,
            cadence: Fixture.brisk)

        _ = await coordinator.attempt()
        guard case .notFound = await coordinator.attempt() else {
            Issue.record("expected notFound — the host is no longer advertising"); return
        }
        // ⛔ One dial, from the one sweep that resolved something.
        #expect(log.endpoints.count == 1)
    }

    @Test("⚠ The cadence widens and then holds steady")
    func cadenceWidens() {
        let standard = ReconnectCadence.standard
        #expect(standard.gapNs(afterSweep: 1) == 2_000_000_000)
        #expect(standard.gapNs(afterSweep: 2) == 5_000_000_000)
        #expect(standard.gapNs(afterSweep: 3) == 10_000_000_000)
        #expect(standard.gapNs(afterSweep: 4) == 30_000_000_000)
        #expect(standard.gapNs(afterSweep: 99) == 30_000_000_000)
    }
}
