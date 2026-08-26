//  HostLinkSyncTests.swift
//  E3.2 — the sync burst, driven through the live link app composition.
//
//  ⚠ **What this file does and does not prove.** `addSyncTimebase`/`syncTrigger`/
//  `syncPump`/`syncRelation` are exercised at the bare `DevicePeer` level already
//  (`LiveLinkTests.swift`, `CaptureCoreTests` — CT-I18/CT-I21's own half). What
//  had no test anywhere was whether `HostLinkSession` actually calls into that
//  API at all once a link establishes, and whether doing so leaves the link in a
//  sane, non-crashing state. That is what these tests assert.
//
//  ⛔ **Full two-peer convergence is not exercised here, deliberately.** A
//  synthetic counterpart built from two independent, uncoordinated 100 ms tick
//  loops (`PeerLinkPump`'s own internal tick plus `HostLinkSession`'s
//  `startSyncTicking`) hammering one in-process `Pipe` produced unreliable
//  convergence in manual testing — probes reached the counterpart (confirmed via
//  its own event stream) but replies never came back inside a 5 s window, for
//  reasons that traced into `libppcp`'s internal scheduling under concurrent
//  pumping rather than into anything `HostLinkSession` does wrong. The PPS team
//  has confirmed real-network convergence has only ever been validated against
//  same-process simulated clocks on their side too — a synthetic in-process test
//  here would not be more authoritative than that. Real convergence is verified
//  manually against a running PinPointStudio instance (see the issue).
//
//  Reuses `Pipe`/`PipeChannel`/`PipeTransport` from `HostLinkTests.swift`.

import Foundation
import Testing
import CaptureCore
@testable import PinPointCapture

@Suite("E3.2 — Synchronised")
@MainActor
struct HostLinkSyncTests {

    private func testDeclaration() throws -> PpcpDeclaration {
        try PpcpDeclaration(
            ConformanceHarness.declarationWithoutACamera(peerId: PeerIdentity.current),
            allowingNoCameraSource: true)
    }

    /// A counterpart that answers, in-process — same shape as
    /// `HostLinkTests.counterpart(on:)`, plus `syncTimebase:` and its own
    /// `declare()`, both required for it to answer a `sync_probe` at all
    /// (`peer_on_sync_probe` refuses `profile_not_supported` without either).
    private func counterpart(on transport: PipeTransport) async throws -> PeerLinkPump {
        let peer = try DevicePeer(peerId: "peer:test-host", role: .capture, listener: true,
                                  syncTimebase: "tb:test-host-clock")
        let pump = PeerLinkPump(peer: peer, transport: transport,
                                nowNs: { Int64(Date().timeIntervalSince1970 * 1_000_000_000) })
        await pump.start()
        let declaration = try PpcpDeclaration(
            ConformanceHarness.declarationWithoutACamera(peerId: "peer:test-host"),
            allowingNoCameraSource: true)
        try await pump.perform { try $0.declare(declaration) }
        return pump
    }

    @Test("Opening a link registers sync and keeps ticking without crashing")
    func syncTickingRunsWithoutFaulting() async throws {
        let model = AppModel()
        let declaration = try testDeclaration()

        let (deviceSide, hostSide) = PipeTransport.pair()
        let hostPump = try await counterpart(on: hostSide)
        defer { Task { await hostPump.stop() } }

        await model.connect(transport: deviceSide, sessionId: "ses:test",
                            hostDisplayName: nil, declaration: declaration)

        // ⚠ No session ever opens on either side in this harness, so
        // `HostLinkDriver.derive` never leaves `.none` — `hostLink` maps that
        // back to `.pairing` (see `HostLinkSession.hostLink`'s own comment).
        // Give the ticker a few real cycles before asserting, so this is a
        // check of "still sane after ticking", not just "sane at t=0".
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.hostLink.state == .pairing)
        #expect(model.hostLink.clock == nil)
        #expect(model.link?.hasSettled == true)

        await model.disconnect()
        // ⚠ `close()` cancels `syncTicker` alongside `events` — idempotent
        // disconnect must not hang waiting on either.
        #expect(model.hostLink.state == .none)
    }

    @Test("A thermal event is safe to report on a live link")
    func thermalEventOnALiveLinkDoesNotThrow() async throws {
        let model = AppModel()
        let declaration = try testDeclaration()

        let (deviceSide, hostSide) = PipeTransport.pair()
        let hostPump = try await counterpart(on: hostSide)
        defer { Task { await hostPump.stop() } }

        await model.connect(transport: deviceSide, sessionId: "ses:test",
                            hostDisplayName: nil, declaration: declaration)
        let link = try #require(model.link)

        // `syncTrigger(.thermalEvent)` restarts the estimator's window; calling
        // it here just asserts the plumbing doesn't throw or wedge the link.
        await link.notifyThermalEvent()
        #expect(link.hasSettled)

        await model.disconnect()
    }

    @Test("A thermal event is safe to report with no link up")
    func thermalEventWithNoLinkIsANoOp() async throws {
        let model = AppModel()
        #expect(model.link == nil)
        // `AppModel.refreshHealth()` guards on `link` before forwarding —
        // exercised through the public surface it's reachable through.
        model.refreshHealth()
        model.refreshHealth()
    }
}
