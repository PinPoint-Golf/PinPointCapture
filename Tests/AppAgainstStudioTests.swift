//  AppAgainstStudioTests.swift
//  The shipping app, driven against a real PinPointStudio, from the simulator.
//
//  ⛔ **Why this exists, and why it is not `make conform`.** `ppcp-sim` is the
//  right instrument for conformance and the wrong one for interoperability: it
//  is `libppcp` at both ends, so it can only ever tell us we agree with
//  ourselves. The other half — does PinPointStudio's arbiter, its readiness
//  state machine and its import ledger agree with ours — cost a phone, a
//  network and someone standing in a bay for every attempt.
//
//  ⛔ **It does not cost a phone.** The iOS Simulator runs as a process on this
//  Mac and shares its network stack, so `127.0.0.1` here is PinPointStudio's own
//  loopback. Run it as often as you like:
//
//      make interop-app HOST=127.0.0.1:<port> PSK=<64 hex> IDENTITY=<identity>
//
//  ⚠ **What still needs a phone, so nobody expects otherwise.** A simulator
//  enumerates no camera and therefore declares no camera Source: no clip bytes,
//  no preview pixels, and CT-S3 is unreachable because there is no local camera
//  declaration for a foreign one to differ from. Everything else is here —
//  handshake, `session_open`, sync, arm and readiness, candidates and shots
//  (over injected audio), offers and `capture_committed`.
//
//  ⚠ **Rows REPORT where a person is involved and ASSERT where they are not.**
//  Whether an operator pressed arm during the window is their business, and a
//  row that failed because nobody pressed a button is a row nobody trusts. Read
//  the `APP-VS-STUDIO` lines; the assertions are reserved for things that are
//  true regardless of what the operator did.
//
//  Spec: `CORE` §5.10e, §5.13c, §7.3, §8.2, §8.3f; `MSG` §4.1, §5.2, §7.2, §9.1.

import Foundation
import Testing
import CaptureCore
@testable import PinPointCapture

@Suite("The composed app against PinPointStudio", .serialized)
@MainActor
struct AppAgainstStudioTests {

    // MARK: Reaching Studio

    /// Everything a row needs, or `nil` where the environment did not supply it.
    static func credentials() throws -> (PeerEndpoint, any PpcpCredentials)? {
        guard let endpoint = InteropTests.endpoint("HOST"),
              let pskText = InteropTests.value("PSK"),
              let tlsKey = InteropTests.hex(pskText) else { return nil }
        let identityText = InteropTests.value("IDENTITY") ?? ""
        let identity = InteropTests.hex(identityText) ?? Data(identityText.utf8)
        return (endpoint, try FixedPskCredentials(tlsKey: tlsKey, identity: identity))
    }

    /// A model on a real link to Studio, or `nil` where there is nothing to dial.
    ///
    /// ⚠ **Three channels asked for up front.** `ENC` 2.1d permits opening
    /// `preview` later and calls that the expected case, but asking now proves
    /// PinPointStudio accepts the third `link_bind` at all — which is the half of
    /// preview that does not need pixels, and the half they asked us to test.
    static func connected(sessionId: String,
                          store: SessionStore? = nil,
                          device: (any CaptureDevice)? = nil) async throws -> AppModel? {
        guard let (endpoint, credentials) = try credentials() else { return nil }
        let transport = try await PpcpConnector()
            .connect(to: endpoint, credentials: credentials,
                     channels: PpcpChannel.required + [.preview])

        let root = URL.documentsDirectory
            .appendingPathComponent("app-vs-studio-\(sessionId)", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let model = AppModel(device: device ?? CaptureDeviceFactory.create(),
                             store: store ?? SessionStore(root: root))
        // ⚠ A supplied device declares itself — the stub has a camera, which is
        // what gives a Shot a clip for the host to decline (#105).
        let declaration: PpcpDeclaration? = device != nil ? nil : try PpcpDeclaration(
            ConformanceHarness.declarationWithoutACamera(peerId: PeerIdentity.current),
            allowingNoCameraSource: true)
        if device != nil {
            model.refreshCapability()
            model.permissions = Permissions(camera: .allowed, microphone: .allowed,
                                            localNetwork: .allowed, motion: .allowed)
        }
        await model.connect(transport: transport, sessionId: sessionId,
                            hostDisplayName: "PinPointStudio", declaration: declaration)
        return model
    }

    static func skipped() {
        withKnownIssue("no PPCP_INTEROP_HOST/PSK — run `make interop-app`",
                       isIntermittent: true) {
            Issue.record("skipped")
        }
    }

    // MARK: E3.1 — the link

    @Test("E3.1 — the shipping path reaches Studio over TLS and declares")
    func theLinkComesUp() async throws {
        guard let model = try await Self.connected(sessionId: "ses:studio-e31") else {
            return Self.skipped()
        }
        let link = try #require(model.link, "no link was composed")

        #expect(link.hasSettled, "hello and declare did not cross: \(link.phase)")
        #expect(model.hostLinkError == nil)
        try await Task.sleep(for: .seconds(2))
        #expect(link.negotiatedVersion != nil, "hello_accept set no version")
        #expect(link.counterpartPeerId != nil, "the counterpart never declared")

        // ⚠ Reported because it is a *measurement of what was negotiated*, and
        // Apple's TLS gives no external PSK above 1.2 (finding F-D1-1).
        print("APP-VS-STUDIO security=\(link.securitySummary)")
        print("APP-VS-STUDIO version=\(link.negotiatedVersion ?? "—") "
              + "counterpart=\(link.counterpartPeerId ?? "—")")

        await model.disconnect()
        #expect(model.link == nil)
    }

    // MARK: E3.2 / E3.3 — the Session, the clock, and the arm

    @Test("E3.2/E3.3 — a hosted Session arrives, the clocks agree, an arm is answered")
    func theSessionArrivesAndTheClocksAgree() async throws {
        guard let model = try await Self.connected(sessionId: "ses:studio-e33") else {
            return Self.skipped()
        }
        let link = try #require(model.link)

        // PinPointStudio opens the Session at `declare`, so this is the ordinary
        // first event rather than something an operator triggers.
        try await Task.sleep(for: .seconds(12))

        // ⛔ Asserted: 5.10e makes the two arbitration parameters the structural
        // statement that this Session has a host, so their presence is not an
        // operator's choice.
        let session = try #require(link.hostSession, "session_open never arrived")
        #expect(session.hasArbitration, "5.10e — a hosted Session carries both")
        #expect(session.timebaseRefId.isEmpty == false, "I16 — timebase_ref is fixed")
        print("APP-VS-STUDIO session=\(session.sessionId) ref=\(session.timebaseRefId) "
              + "hold=\(session.issueHoldNs)ns window=\(session.coincidenceWindowNs)ns "
              + "heartbeat=\(session.heartbeatIntervalMs)ms")

        // ⚠ Reported: the burst is 10–20 exchanges and how fast it settles is a
        // property of this network, not of either implementation.
        if let clock = model.hostLink.clock {
            print("APP-VS-STUDIO clock=\(clock.agreementText) drift=\(clock.driftText) "
                  + "exchanges=\(clock.exchangesCompleted)/\(clock.exchangesExpected)")
        } else {
            print("APP-VS-STUDIO clock=not-yet-settled")
        }
        print("APP-VS-STUDIO state=\(model.hostLink.state.rawValue)")

        // ⚠ Reported: whether Studio armed is an operator's choice. What is
        // asserted is the consequence *if* it did — `capabilityError` is the
        // proof `arm()` ran, since a simulator can never reach warm.
        let armed = model.capabilityError != nil
        print("APP-VS-STUDIO armed=\(armed) "
              + "blocker=\(model.currentBlocker()?.rawValue ?? "none")")
        if armed {
            #expect(model.currentBlocker() != nil, """
                    an arm that ran must terminate with a blocker — a host left \
                    holding `settled: false` with no blocker never leaves Arming
                    """)
        }

        await model.disconnect()
    }

    // MARK: E3.4 — candidates and shots

    /// ⛔ **Injected audio, which is what makes this reachable without a phone.**
    /// `CONF` §2a's *injected* method exists for exactly this: a simulator has no
    /// microphone worth timing, and the detector, the candidate factory and the
    /// Mint engine do not care where the samples came from.
    ///
    /// ⚠ **Whether a `shot` comes back is PinPointStudio's decision, not a pass
    /// condition.** Their corroboration rule refuses a Shot where a host detector
    /// was available and none fired within 50 ms, and refusing is the intended
    /// behaviour rather than a failure. What is asserted is that the Candidate
    /// left this device; what is reported is what came back.
    @Test("E3.4 — injected swings nominate, and whatever Studio decides is reported")
    func swingsCross() async throws {
        guard let model = try await Self.connected(sessionId: "ses:studio-e34") else {
            return Self.skipped()
        }
        let link = try #require(model.link)
        try await Task.sleep(for: .seconds(10))
        guard link.hostSession != nil else {
            Issue.record("no hosted Session — Studio did not open one")
            await model.disconnect()
            return
        }

        // ⚠ One ball at a time. PinPointStudio's shot pipeline is unavailable for
        // 15–40 s after each shot and drops what arrives inside that window; a
        // row that fired four swings in four seconds would be measuring their
        // backlog rather than our nomination.
        await model.arm()
        for index in 0..<2 {
            await model.observe(SyntheticAudio.oneSwing(
                timebaseId: PpcpTimebases.captureId, startNs: MachClock.hostTimeNs))
            print("APP-VS-STUDIO swing=\(index) candidates=\(model.candidateCount)")
            try await Task.sleep(for: .seconds(20))
        }

        print("APP-VS-STUDIO candidates=\(model.candidateCount) shots=\(model.shotCount)")

        // ⛔ **Asserted now, because the host has been made deterministic.** Under
        // `tools/probes/ppcp_assert.qml` PinPointStudio either has no detector
        // available — every Shot accepted unweighed — or injects one per foreign
        // Shot with `--corroborate`. Either way the outcome no longer depends on
        // whether a person swung a club, so this stops being a report.
        //
        // ⚠ **What it does NOT prove**, and the line must stay in: injection
        // exercises the corroboration *rule*, not either side's acoustic
        // detector. A green run means a Shot corroborated by something was
        // recorded, and nothing at all about whether we hear golf balls.
        #expect(model.candidateCount > 0, """
                no Candidate left this device — the injected swing never reached \
                the detector, which is ours and not the host's
                """)
        for shot in model.session.shots {
            print("APP-VS-STUDIO shot ordinal=\(shot.ordinal) state=\(shot.syncState.displayText)")
        }
        if let residual = model.hostLink.clock?.lastImpactResidualMilliseconds {
            print("APP-VS-STUDIO residual=\(residual) ms")
        } else {
            print("APP-VS-STUDIO residual=not-yet — no Shot was arbitrated over our Candidate")
        }

        model.disarm()
        await model.disconnect()
    }

    // MARK: #105 — the real host declines

    /// ⭐ **`make integration-decline`: PinPointStudio itself refuses the Shot.**
    /// Under `--decline-mode` its acoustic detector is available and hears
    /// nothing, so this phone's uncorroborated Candidate is excluded, the phone
    /// mints under 8.2i with a clip from the stub camera, and Studio declines the
    /// unadopted Shot. The same assertions as `ShotDispositionAppTests`, against
    /// the real host's own decision.
    @Test("#105 — a Shot Studio declines leaves the phone mid-link")
    func aShotStudioDeclinesLeavesThePhone() async throws {
        guard InteropTests.value("EXPECT_DECLINE") == "1" else {
            withKnownIssue("not a decline run — `make integration-decline`",
                           isIntermittent: true) { Issue.record("skipped") }
            return
        }
        let device = StubCaptureDevice()
        device.retainedClipBytes = Data((0..<200_000).map { UInt8($0 % 251) })
        guard let model = try await Self.connected(sessionId: "ses:studio-105",
                                                   device: device) else {
            return Self.skipped()
        }
        // The probe drives Studio: camera enabled, clocks agreed, session
        // started — and Studio's `arm` arms this phone.
        var armed = false
        for _ in 0..<120 where !armed {
            armed = model.captureStatus.state == .armed
            if !armed { try await Task.sleep(for: .seconds(1)) }
        }
        print("APP-VS-STUDIO decline armed-by-host=\(armed)")
        try #require(armed, "Studio never armed this phone")

        await model.observe(SyntheticAudio.oneSwing(timebaseId: PpcpTimebases.captureId,
                                                    startNs: MachClock.hostTimeNs))
        var declined = false
        for _ in 0..<600 where !declined {
            await model.pumpMint()
            declined = model.session.shots.last?.syncState == .declined
            if !declined { try await Task.sleep(for: .milliseconds(50)) }
        }
        let state = model.session.shots.last?.syncState.displayText ?? "no shot minted"
        print("APP-VS-STUDIO decline shot-state=\(state)")
        #expect(declined, "Studio did not decline the Shot: \(state)")

        await model.retentionTick()
        let clips = model.recording.map { rec in
            ((try? FileManager.default.contentsOfDirectory(
                atPath: rec.bundle.clipsDirectory.path)) ?? []).filter { $0.hasSuffix(".mp4") }
        } ?? []
        print("APP-VS-STUDIO decline clips-left=\(clips.count)")
        #expect(clips.isEmpty, "CORE 5.14g exit 5 — the declined clip was kept")

        model.disarm(stayWarm: true, keepDelivering: true)
        await model.retentionTick()
        print("APP-VS-STUDIO decline draining=\(model.draining.count)")
        #expect(model.draining.isEmpty, "the stopped session never drained")
        await model.disconnect()
    }
}
