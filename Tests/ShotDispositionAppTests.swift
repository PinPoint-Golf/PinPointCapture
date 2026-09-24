//  ShotDispositionAppTests.swift
//  #105 — a Shot the host will not keep leaves the phone mid-link, on every run.
//
//  ⛔ **Automated because it is too critical for a manual run** (Mark, 24 Sep
//  2026: "they will just be skipped in future"). The flow is the one that hung on
//  hardware on 27 August:
//    1. the phone hears a swing and nominates it,
//    2. the host issues nothing, so the phone mints under 8.2i and extracts a
//       clip,
//    3. the host declines the Shot (`MSG` 8.5, CR-03),
//    4. the clip is deleted within one retention tick, the stopped session
//       drains, and the next arm is not held back.
//  An accepted shot is the control, and a silent host is the guard: silence
//  releases nothing (I38), so nobody "fixes" #105 by evicting on a timeout.
//
//  ⚠ The host is an in-process `DevicePeer(role: .host)` scripted by the test,
//  not PinPointStudio: this proves the PHONE's half on every `make test`. The
//  real host's decision is `make integration-decline`.

import Foundation
import Testing
import CaptureCore
@testable import PinPointCapture

@Suite("#105 — a declined Shot leaves the phone mid-link", .serialized)
@MainActor
struct ShotDispositionAppTests {

    nonisolated private static let hostTimebase = "tb:test-host"

    /// A phone connected to a scripted host that has opened a hosted Session,
    /// with the clocks related and the phone armed.
    private struct Rig {
        let model: AppModel
        let host: PeerLinkPump
        let root: URL
        /// Shot ids the host has seen, in order.
        var shots: [String] = []
    }

    private func rig() async throws -> Rig {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                 isDirectory: true)
        let device = StubCaptureDevice()
        device.retainedClipBytes = Data((0..<200_000).map { UInt8($0 % 251) })
        let model = AppModel(device: device, store: SessionStore(root: root))
        model.refreshCapability()
        model.permissions = Permissions(camera: .allowed, microphone: .allowed,
                                        localNetwork: .allowed, motion: .allowed)

        let (deviceSide, hostSide) = PipeTransport.pair()
        // ⚠ **With a clock.** A responder stamps `t2`/`t3` on its own clock
        // (6.1b), and a peer built without one never answers a `sync_probe` —
        // so the phone never gets a relation and 8.2i1 forbids it to mint.
        let hostClock = PpcpDeviceClock { tb in
            tb == Self.hostTimebase ? MachClock.hostTimeNs : nil
        }
        let peer = try DevicePeer(peerId: "peer:test-host", role: .host, listener: true,
                                  clock: hostClock, syncTimebase: Self.hostTimebase)
        let host = PeerLinkPump(peer: peer, transport: hostSide,
                                nowNs: { MachClock.hostTimeNs })
        await host.start()
        var input = try ConformanceHarness.declarationWithoutACamera(peerId: "peer:test-host")
        input.isHost = true
        // The host's own clock, which is what it stamps `sync_reply` on (6.1b)
        // and what the Session's `timebase_ref` names — as PinPointStudio's is.
        input.timebases = [PpcpTimebaseDeclaration(id: Self.hostTimebase, kind: .monotonic,
                                                   epochStable: false, resolutionNs: 1)]
        input.captureTimebaseId = Self.hostTimebase
        let declaration = try PpcpDeclaration(input, allowingNoCameraSource: true)
        try await host.perform { try $0.declare(declaration) }

        await model.connect(transport: deviceSide, sessionId: "ses:105",
                            hostDisplayName: "test host")

        // `session_open` is refused before the handshake completes; retried
        // rather than slept for.
        try await eventually("the host opened a hosted Session") {
            (try? await host.perform { peer in
                try peer.openHostedSession(id: "ses:105", timebaseRef: Self.hostTimebase,
                                           openedAtNs: MachClock.hostTimeNs)
            }) != nil
        }
        try await eventually("session_open reached the phone") {
            model.link?.hostSession != nil
        }
        // 8.2i1 — the phone may not mint a Shot whose `t0` it cannot express in
        // `timebase_ref`, so the sync burst has to have given it a relation.
        try await eventually("the clocks are related", seconds: 20) {
            _ = await host.takeEvents(waitingUpTo: 0.02)
            await host.tickOnce()
            return model.link?.clockAgreement != nil
        }
        await model.arm()
        #expect(model.recording != nil, "arm opened no recording")
        return Rig(model: model, host: host, root: root)
    }

    private func tearDown(_ rig: Rig) async {
        await rig.model.disconnect()
        await rig.host.stop()
        try? FileManager.default.removeItem(at: rig.root)
    }

    /// One swing heard, nominated, and — with the host silent — minted under
    /// 8.2i with its clip extracted and written. Returns the host's view of the
    /// Shot id.
    private func mintOneShot(_ rig: inout Rig) async throws -> String {
        let model = rig.model
        await model.observe(SyntheticAudio.oneSwing(timebaseId: PpcpTimebases.captureId,
                                                     startNs: MachClock.hostTimeNs))
        try await eventually("the phone minted after the host stayed silent", seconds: 15) {
            await model.pumpMint()
            return model.session.shots.isEmpty == false
        }
        try await eventually("the clip file was written") {
            clipFiles(model).count == 1
        }
        var seen: [String] = []
        let host = rig.host
        try await eventually("the host received the device's Shot") {
            for event in await host.takeEvents(waitingUpTo: 0.05) {
                if case .shotReceived(let id, _, _, _, _) = event { seen.append(id) }
            }
            await host.tickOnce()
            return seen.isEmpty == false
        }
        rig.shots.append(contentsOf: seen)
        return seen[0]
    }

    private func clipFiles(_ model: AppModel) -> [String] {
        guard let dir = model.recording?.bundle.clipsDirectory else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".mp4") }
    }

    // MARK: - The tests

    @Test("A declined Shot's clip is deleted mid-link, the session drains, and the next arm is not held back")
    func aDeclinedShotLeavesThePhone() async throws {
        var rig = try await rig()
        let model = rig.model
        let shotId = try await mintOneShot(&rig)

        try await rig.host.perform { try $0.shotDisposition(shotId: shotId,
                                                             reason: "not_corroborated") }
        try await eventually("the row reads Not kept") {
            model.session.shots.last?.syncState == .declined
        }
        await model.retentionTick()
        #expect(clipFiles(model).isEmpty, "CORE 5.14g exit 5 — the clip outlived its decline")
        #expect(model.transferQueue?.pendingShotIDs.isEmpty ?? true,
                "a declined shot is still counted as owed")

        // ⛔ #105's "the session cannot be cleared": the host's Stop, then one tick.
        model.disarm(stayWarm: true, keepDelivering: true)
        #expect(model.draining.count == 1)
        await model.retentionTick()
        #expect(model.draining.isEmpty, "the stopped session never drained")

        // … and the next arm is not held back behind it.
        await model.arm()
        let next = try #require(model.recording)
        #expect(next.isTransferring, "the next arm's upload was held back")

        await tearDown(rig)
    }

    @Test("An accepted Shot reaches In Studio and its clip is deleted (the control)")
    func anAcceptedShotIsConfirmed() async throws {
        var rig = try await rig()
        let model = rig.model
        _ = try await mintOneShot(&rig)

        // Commit once the payload has gone, naming the digest the phone announced.
        try await eventually("the payload was sent") {
            await model.recording?.hasPendingTransfers() == false
        }
        let captureIds = try #require(model.recording?.transferRows.map(\.captureId))
        try await rig.host.perform { peer in
            for id in captureIds { try? peer.captureCommitted(captureId: id) }
        }
        try await eventually("the row reads In Studio") {
            model.session.shots.last?.syncState == .inStudio
        }
        await model.retentionTick()
        #expect(clipFiles(model).isEmpty, "a confirmed clip was kept")

        model.disarm(stayWarm: true, keepDelivering: true)
        await model.retentionTick()
        #expect(model.draining.isEmpty)

        await tearDown(rig)
    }

    @Test("A silent host releases nothing: the clip is kept mid-link (I38)")
    func silenceReleasesNothing() async throws {
        var rig = try await rig()
        let model = rig.model
        _ = try await mintOneShot(&rig)

        try await eventually("the payload was sent") {
            await model.recording?.hasPendingTransfers() == false
        }
        // Several ticks, well past anything a timeout would pick.
        for _ in 0..<3 {
            await model.retentionTick()
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(clipFiles(model).count == 1,
                "⛔ I38 — a clip nobody confirmed or declined was evicted")
        #expect(model.session.shots.last?.syncState != .declined)

        // Only the link ending removes it — the #122 deviation, recorded.
        await tearDown(rig)
        #expect(model.bundlesOnDevice().isEmpty)
    }

    // MARK: - Waiting

    private func eventually(_ what: String, seconds: Double = 10,
                            _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("timed out after \(seconds) s waiting for: \(what)")
        throw CancellationError()
    }
}
