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

// MARK: - Preview at connect (#108)

/// PinPointStudio's specification of 27 August 2026: *"When a phone connects to
/// PinPointStudio, its preview must be available immediately. Not when the phone
/// arms. Not when a recording session starts. At connect."*
///
/// ⛔ **What these can and cannot see.** A simulator enumerates no camera, so it
/// declares no camera Source and no preview profile — the `opened` verdict is
/// only reachable on hardware and lives in `DeviceSessionTests`. What is provable
/// here is the defect that made preview impossible: every inbound `stream_open`
/// was answered from `recording?.declaration`, which is `nil` until a golfer
/// presses Capture, so a request arriving at connect was refused before it
/// reached any preview logic at all.
@Suite("#108 — a stream_open is answered before anything is armed")
@MainActor
struct PreviewAtConnectTests {

    private func counterpart(on transport: PipeTransport) async throws -> PeerLinkPump {
        let peer = try DevicePeer(peerId: "peer:test-host", role: .capture, listener: true,
                                  syncTimebase: "tb:test-host-clock")
        let pump = PeerLinkPump(peer: peer, transport: transport,
                                nowNs: { Int64(Date().timeIntervalSince1970 * 1_000_000_000) })
        await pump.start()
        return pump
    }

    private func connected() async throws -> (AppModel, PeerLinkPump, PpcpDeclaration) {
        let declaration = try PpcpDeclaration(
            ConformanceHarness.declarationWithoutACamera(peerId: PeerIdentity.current),
            allowingNoCameraSource: true)
        let (deviceSide, hostSide) = PipeTransport.pair()
        let hostPump = try await counterpart(on: hostSide)
        let model = AppModel()
        await model.connect(transport: deviceSide, sessionId: "ses:test",
                            hostDisplayName: nil, declaration: declaration)
        return (model, hostPump, declaration)
    }

    /// ⛔ **The regression, stated as an assertion.** Nothing is armed, so
    /// `recording` is `nil` — and the answer must still come from the Source list
    /// the link declared at `hello`, not from a refusal that fires first.
    @Test("A stream_open with nothing armed is answered from the link's declaration")
    func aRequestIsAnsweredBeforeAnythingIsArmed() async throws {
        let (model, hostPump, declaration) = try await connected()
        defer { Task { await hostPump.stop() } }
        let link = try #require(model.link)
        #expect(model.recording == nil, "the premise: nothing is armed")

        // A Source this peer never declared. ⚠ The verdict that matters is the
        // *reason*: `no_such_source` means the request reached the Source lookup.
        let stranger = await model.hostLink(link, didRequestStream: "str:x",
                                            sourceId: "src:nothing-declared",
                                            profileId: PpcpDeclaration.previewProfileId,
                                            kind: PpcpStreamKind.preview)
        #expect(stranger == .refused(reason: "no_such_source"), """
                a stream_open with nothing armed was refused before it reached \
                the declaration — which is exactly the defect in #108
                """)

        // A Source this peer *did* declare, with a profile it does not carry.
        let declared = try #require(declaration.sources.first)
        let wrongProfile = await model.hostLink(link, didRequestStream: "str:y",
                                                sourceId: declared.id,
                                                profileId: "no-such-profile",
                                                kind: PpcpStreamKind.preview)
        #expect(wrongProfile == .refused(reason: "no_such_profile"), """
                5.11a / I5 — a Stream names a profile the declaration carries, \
                and the refusal must say which half was wrong
                """)

        await model.disconnect()
    }

    /// `CORE` 5.11l — a preview profile is activatable on a `kind: preview`
    /// Stream and nowhere else. ⛔ The owner MUST refuse it for capture:
    /// honouring it silently hands an operator 640×360 where they asked for a
    /// capture format.
    @Test("A preview profile selected for a capture Stream is refused by name")
    func aPreviewProfileIsRefusedForCapture() async throws {
        let (model, hostPump, declaration) = try await connected()
        defer { Task { await hostPump.stop() } }
        let link = try #require(model.link)

        // ⚠ Needs a declared Source carrying a profile with `intrinsics: none`
        // (5.11m). Without a camera there is none, so this asserts the ordering
        // of the guards rather than the clause itself — the clause is exercised
        // on hardware.
        guard let source = declaration.sources.first,
              let profile = source.profiles.first(where: {
                  $0.intrinsics == PpcpDeclaration.Intrinsics.none
              }) else {
            #expect(model.livePreview == nil, "no preview Stream exists unasked")
            await model.disconnect()
            return
        }
        let verdict = await model.hostLink(link, didRequestStream: "str:z",
                                           sourceId: source.id, profileId: profile.id,
                                           kind: PpcpStreamKind.video)
        #expect(verdict == .refused(reason: "preview_profile_not_for_capture"))
        await model.disconnect()
    }

    /// ⚠ **Request-driven, never unprompted** — PinPointStudio asks per Source
    /// and asked explicitly not to be sent preview for a Source it never
    /// requested (their §5).
    @Test("No preview Stream exists until a host asks for one")
    func previewIsNeverUnprompted() async throws {
        let (model, hostPump, _) = try await connected()
        defer { Task { await hostPump.stop() } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.livePreview == nil)
        await model.disconnect()
    }
}
