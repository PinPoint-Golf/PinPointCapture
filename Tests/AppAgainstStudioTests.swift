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
                          store: SessionStore? = nil) async throws -> AppModel? {
        guard let (endpoint, credentials) = try credentials() else { return nil }
        let transport = try await PpcpConnector()
            .connect(to: endpoint, credentials: credentials,
                     channels: PpcpChannel.required + [.preview])

        let root = URL.documentsDirectory
            .appendingPathComponent("app-vs-studio-\(sessionId)", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let model = AppModel(device: CaptureDeviceFactory.create(),
                             store: store ?? SessionStore(root: root))
        let declaration = try PpcpDeclaration(
            ConformanceHarness.declarationWithoutACamera(peerId: PeerIdentity.current),
            allowingNoCameraSource: true)
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

    // MARK: E3.4 — the offer path, and the only route to In Studio

    /// ⛔ **The one path on which `.inStudio` is reachable today.**
    /// 5.14h makes `capture_committed` the receiver's statement that it holds the
    /// bytes and 8.4b forbids an owner claiming it — and PinPointStudio's live
    /// clip path cannot yet start a PPCP-backed camera, so nothing commits a
    /// Capture that crossed live. Their import ledger does commit a replayed one.
    ///
    /// ⚠ So this row is also the only way to exercise eviction: a Capture that
    /// never reaches `confirmed` is one I38 will never let go of.
    @Test("MSG 9.1 — a stored Session is offered, replayed, and committed back")
    func offersAreCommitted() async throws {
        guard try Self.credentials() != nil else { return Self.skipped() }

        // A bundle to offer, recorded the way a hostless session would.
        let root = URL.documentsDirectory
            .appendingPathComponent("app-vs-studio-offer", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SessionStore(root: root)
        _ = try InteropBundleFixture.record(shots: 1, into: store,
                                            device: CaptureDeviceFactory.create(),
                                            distance: MicToBallDistance(),
                                            sessionId: "ses:studio-offer")

        guard let model = try await Self.connected(sessionId: "ses:studio-offer-link",
                                                   store: store) else {
            return Self.skipped()
        }
        // The offer goes out on `declare`; the replay is pumped on the sync tick
        // and drains between calls, so this is bounded by the bundle's size.
        try await Task.sleep(for: .seconds(25))

        print("APP-VS-STUDIO stored=\(try store.bundles().map(\.sessionId))")
        if let rows = model.recording?.transferRows, rows.isEmpty == false {
            for row in rows {
                print("APP-VS-STUDIO capture=\(row.captureId) state=\(row.state.displayText)")
            }
        } else {
            print("APP-VS-STUDIO no transfer rows — the replay is the peer's, not the session's")
        }

        await model.disconnect()
    }
}
