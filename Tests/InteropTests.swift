//  InteropTests.swift
//  `CONF` §5 wave 2 — this device against the REAL PinPointStudio listener, over
//  the shipping transport.
//
//  ⛔ **No harness transport and no plaintext.** Wave 1's rows dial
//  `PpcpDirectTransport`, which is `RV` §2's `direct` path and is what `ppcp-sim`
//  speaks. This one dials `PpcpConnector` — `Network.framework`, `RV` §5's TLS
//  profile, the same code a scanned pairing code drives — with a PSK handed in on
//  the command line. That is the whole point of the row: the two applications
//  meeting over the transport they ship, not over the one built for testing.
//
//  ⚠ **The PSK is given rather than derived, and the row says so.** A real
//  pairing runs `RV` §3's rendezvous and derives `K_tls` from the code; supplying
//  a fixed 32-byte key and a fixed identity is the *shape* that produces, not the
//  derivation, and the derivation is `RendezvousCredentials`' own tested path
//  (D7). What this row measures is the link and the session above it.
//
//  ⛔ **It SKIPS without a host in the environment**, so `make test-app` stays
//  green on a machine with no listener. A test that failed for a missing
//  counterpart would be a red suite that says nothing about interoperability.
//
//      make interop HOST=127.0.0.1:9443 PSK=<64 hex> IDENTITY=<hex or text>
//
//  Spec: `RV` §2, §5.2, §5.3; `MSG` §3–§9; `CONF` §5. Plan S5 wave 2.

import Foundation
import Testing
import CaptureCore
@testable import PinPointCapture

@Suite("CONF §5 wave 2 — the real pair over TLS", .serialized)
struct InteropTests {

    /// `host:port` of one PinPointStudio TLS listener. ⚠ **Two of them, one
    /// simulator launch**: booting, installing and launching costs tens of
    /// seconds and a row costs thirty, so `make interop HOST=… HOST2=…` starts a
    /// plain host and an acoustic one and the suite dials each in turn.
    static func endpoint(_ name: String) -> PeerEndpoint? {
        let raw = value(name)
        guard let raw else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]), port > 0 else { return nil }
        return PeerEndpoint(host: String(parts[0]), port: port)
    }

    static func value(_ name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        return environment["PPCP_INTEROP_\(name)"]
            ?? environment["TEST_RUNNER_PPCP_INTEROP_\(name)"]
    }

    /// Where a summary is written inside the app container; `make interop`
    /// copies it out.
    static func summaryFile(_ name: String) -> URL {
        URL.documentsDirectory.appendingPathComponent(name)
    }

    /// ⚠ Hex, because a key on a command line has to survive a shell. An
    /// identity that is not hex is taken as its UTF-8 bytes, which is what a
    /// human-typed one would be.
    static func hex(_ text: String) -> Data? {
        let characters = Array(text.utf8)
        guard characters.count % 2 == 0, characters.isEmpty == false else { return nil }
        var bytes = Data()
        var index = 0
        while index < characters.count {
            let pair = String(decoding: characters[index..<index + 2], as: UTF8.self)
            guard let byte = UInt8(pair, radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        return bytes
    }

    /// **IOP-1 (wave 2)** — the reference pairing `CONF` 5a names, over the
    /// transport both products ship. The device dials, joins, opens its Streams,
    /// answers `arm`, nominates from injected audio, and offers a stored Session
    /// which the host imports (**IOP-10**, over the wire rather than through a
    /// file).
    @Test("IOP-1 / IOP-10 — the real pair over TLS, and a stored Session offered",
          .timeLimit(.minutes(4)))
    func aRealPairOverTls() async throws {
        try await runRow(hostVariable: "HOST", summary: "interop-summary.json",
                         session: "ses:interop:wave2") { report, transcript in
            // `MSG` 4.1 — the host opened a Session and this peer joined it.
            #expect(report.sessionId != nil, "\(transcript)")
            // §5.11 — a Stream per declared Source. ⛔ No camera on a simulator.
            #expect(report.streamsOpened.isEmpty == false, "\(transcript)")
            // 5.2a / 7.3c — `arm` is the host's and is answered with a
            // Readiness MEASUREMENT, never a state name (5.15a).
            #expect(report.armsAnswered > 0,
                    "the host armed and this device did not answer\n\(transcript)")
            // 7.1d / 5.12c — every onset is emitted, promoted or not.
            #expect(report.candidatesNominated == 2, "\(transcript)")
            // `MSG` 9.1 — the stored Session was offered and answered.
            #expect(report.offersSent.count == 1, "offered \(report.offersSent)")
            #expect(report.offerVerdicts.isEmpty == false,
                    "the host answered no offer\n\(transcript)")
            #expect(report.replayCompleted,
                    "the accepted Session did not finish replaying\n\(transcript)")
        }
    }

    /// **IOP-6 (wave 2)** — both peers nominate.
    ///
    /// ⛔ **I8 / 5.12c.** The host is started with `--nominate-acoustic`, so it
    /// owns its own microphone Source and nominates alongside this device: two
    /// Candidates of the same `basis` from two peers, both emitted, and the
    /// arbiter's job is to decide between them rather than to see only one. A
    /// device that never carried the counterpart's Candidates could not tell a
    /// host that nominates from one that does not.
    @Test("IOP-6 — a host that nominates from its own acoustic Source",
          .timeLimit(.minutes(4)))
    func bothPeersNominate() async throws {
        try await runRow(hostVariable: "HOST_ACOUSTIC",
                         summary: "interop-acoustic-summary.json",
                         session: "ses:interop:wave2-acoustic") { report, transcript in
            #expect(report.sessionId != nil, "\(transcript)")
            #expect(report.candidatesNominated == 2, "\(transcript)")
            // ⛔ The row. The host's own nominations reached this device.
            #expect(report.candidatesReceived.isEmpty == false,
                    """
                    an acoustic host nominated nothing this device saw — 5.12c \
                    makes every nomination emitted, whoever made it
                    \(transcript)
                    """)
        }
    }

    /// One row: dial the given listener over the shipping transport, record a
    /// stored Session first, write the summary whatever happens, then assert.
    ///
    /// ⚠ **The summary is written before the assertions**, so a failed row still
    /// leaves evidence. A wave-2 row whose only artefact is a red test is not
    /// evidence about interoperability.
    private func runRow(hostVariable: String, summary: String, session: String,
                        assert body: (ConformanceHarness.Report, String) -> Void)
        async throws {
        guard let endpoint = Self.endpoint(hostVariable),
              let pskText = Self.value("PSK") else {
            withKnownIssue("no PPCP_INTEROP_\(hostVariable)/PSK — run `make interop`",
                           isIntermittent: true) {
                Issue.record("skipped")
            }
            return
        }
        guard let tlsKey = Self.hex(pskText) else {
            Issue.record("PSK must be hex; got \(pskText.count) characters")
            return
        }
        let identityText = Self.value("IDENTITY") ?? ""
        let identity = Self.hex(identityText) ?? Data(identityText.utf8)
        let credentials = try FixedPskCredentials(tlsKey: tlsKey, identity: identity)

        // ⛔ **Hostless first, then hosted.** A device that only ever ran with a
        // host would never produce the stored Session the second half offers, and
        // the offer is the half `MSG` §9.1 exists for.
        let root = URL.documentsDirectory
            .appendingPathComponent("interop-bundles-\(hostVariable)", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SessionStore(root: root)
        let device = CaptureDeviceFactory.create()
        let distance = MicToBallDistance()
        let stored = try InteropBundleFixture.record(
            shots: 1, into: store, device: device, distance: distance,
            sessionId: session)

        let harness = ConformanceHarness(device: device, distance: distance,
                                         offering: store, credentials: credentials)
        var failure: String?
        var report = ConformanceHarness.Report()
        do {
            // ⚠ `nominateOnlyOnceConvertible` — the lesson IOP-2 taught in wave 1:
            // a Candidate nominated before a relation exists is one the host
            // excludes and retains (8.2d), and it is never arbitrated.
            report = try await harness.run(against: endpoint, seconds: 30,
                                           injectSwings: 1,
                                           nominateOnlyOnceConvertible: true)
        } catch {
            failure = String(describing: error)
        }

        try Self.write(summary: report, to: summary,
                       storedSessionId: stored.bundle.sessionId,
                       endpoint: endpoint, failure: failure)

        #expect(failure == nil, "the dial or the run failed: \(failure ?? "")")
        let transcript = report.transcript.joined(separator: "\n")
        // `RV` 5.4k — the mode is surfaced. ⛔ On this path it must NOT be the
        // direct path's "no TLS": that would mean the plaintext transport was
        // used against a production listener.
        #expect(report.security.contains("no TLS") == false,
                "the shipping transport must negotiate TLS\n\(report.security)")
        #expect(report.errorCodes.isEmpty, "\(transcript)")
        guard failure == nil else { return }
        body(report, transcript)
    }

    /// The row's evidence, as JSON. ⛔ `RV` 7.2b — no key material, no identity
    /// and no peer address beyond what the operator typed.
    static func write(summary report: ConformanceHarness.Report,
                      to name: String,
                      storedSessionId: String,
                      endpoint: PeerEndpoint,
                      failure: String?) throws {
        var json: [String: Any] = [
            "row": name,
            "endpoint": "\(endpoint.host):\(endpoint.port)",
            "security": report.security,
            "peer_id": report.peerId,
            "counterpart_peer_id": report.counterpartPeerId ?? NSNull(),
            "negotiated_version": report.negotiatedVersion ?? NSNull(),
            "session_id": report.sessionId ?? NSNull(),
            "timebase_ref": report.timebaseRefId ?? NSNull(),
            // ⛔ `false` on a simulator: no camera Source was declared, and every
            // Capture below is `absent` for that reason.
            "declared_camera": report.declaredCamera,
            "declares": [
                "profiles": report.declaredProfiles,
                "source_kinds": report.declaredSourceKinds,
                "camera_conventions": report.declaredConventions,
                "camera_geometries": report.declaredGeometries,
                "offset_provenances": report.declaredOffsetProvenances
            ],
            "streams_opened": report.streamsOpened,
            "candidates_tx": report.candidatesNominated,
            "candidates_rx": report.candidatesReceived,
            "shots_minted_locally": report.shotsMinted,
            "shots_rx": report.shotsReceived.map { arrival in
                [
                    "shot_id": arrival.shotId,
                    "t0_ns": arrival.t0Ns,
                    "t0_timebase": arrival.t0TimebaseId,
                    "authority": arrival.authority,
                    "converted_to_capture_ns": arrival.convertedToCaptureNs ?? NSNull()
                ] as [String: Any]
            },
            "captures_announced": report.capturesAnnounced,
            "arms_answered": report.armsAnswered,
            "sync_events": report.syncEvents,
            "relation_updates": report.relationUpdates,
            "heartbeats": report.heartbeats,
            "offers_tx": report.offersSent,
            "offers_accepted": report.offerVerdicts,
            "replay_completed": report.replayCompleted,
            "stored_session_offered": storedSessionId,
            "errors": report.errorCodes,
            "dropped_events": report.droppedEvents
        ]
        if let failure { json["failure"] = failure }
        let data = try JSONSerialization.data(withJSONObject: json,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: summaryFile(name))
    }
}

// MARK: - The composed app against a real PinPointStudio

/// The **shipping** path — `AppModel`, its delegate, its recording session —
/// driven against a real PinPointStudio over real TLS, from the simulator.
///
/// ⛔ **Why this exists at all.** `make conform` proves the composition against
/// `ppcp-sim`, which is the right instrument for conformance and the wrong one
/// for interoperability: it is the same library at both ends. The other half —
/// does PinPointStudio's arbiter, its readiness state machine and its import
/// ledger agree with ours — has until now cost a phone, a network and a person
/// standing in a bay for every attempt.
///
/// ⛔ **It does not cost a phone.** The iOS Simulator runs as a process on this
/// Mac and shares its network stack, so `127.0.0.1` here is PinPointStudio's own
/// loopback. Everything that is not a camera can be exercised on one machine, in
/// about a minute, as often as you like:
///
///     make interop-app HOST=127.0.0.1:<port> PSK=<64 hex> IDENTITY=<identity>
///
/// ⚠ **What still needs a phone, and why.** A simulator enumerates no camera, so
/// it declares no camera Source: no clip, no preview pixels, and CT-S3's
/// foreign-declaration row is unreachable because there is no local declaration
/// for a foreign one to differ from. Arm, readiness, `session_open`, sync,
/// offers, `capture_request` answering and `session_resume` are all reachable.
@Suite("The composed app against PinPointStudio", .serialized)
@MainActor
struct AppAgainstStudioTests {

    @Test("E3.3/E3.4 — a real host opens a Session, arms, and the app answers")
    func theAppAnswersARealStudio() async throws {
        guard let endpoint = InteropTests.endpoint("HOST"),
              let pskText = InteropTests.value("PSK"),
              let tlsKey = InteropTests.hex(pskText) else {
            withKnownIssue("no PPCP_INTEROP_HOST/PSK — run `make interop-app`",
                           isIntermittent: true) {
                Issue.record("skipped")
            }
            return
        }
        let identityText = InteropTests.value("IDENTITY") ?? ""
        let identity = InteropTests.hex(identityText) ?? Data(identityText.utf8)
        let credentials = try FixedPskCredentials(tlsKey: tlsKey, identity: identity)

        // ⚠ The shipping connector and the shipping transport. `RV` 5.2f — there
        // is no plaintext branch in this path, which is the difference between
        // this row and the `ppcp-sim` ones.
        // ⚠ Three channels asked for up front rather than `openChannel(.preview)`
        // later: 2.1d permits both, and a simulator has no camera to preview, so
        // this proves PinPointStudio accepts the third `link_bind` at all —
        // which is the half of preview that does not need pixels.
        let transport = try await PpcpConnector()
            .connect(to: endpoint, credentials: credentials,
                     channels: PpcpChannel.required + [.preview])

        let root = URL.documentsDirectory
            .appendingPathComponent("app-vs-studio", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let model = AppModel(device: CaptureDeviceFactory.create(),
                             store: SessionStore(root: root))
        let declaration = try PpcpDeclaration(
            ConformanceHarness.declarationWithoutACamera(peerId: PeerIdentity.current),
            allowingNoCameraSource: true)

        await model.connect(transport: transport,
                            sessionId: "ses:app-vs-studio",
                            hostDisplayName: "PinPointStudio",
                            declaration: declaration)
        let link = try #require(model.link, "no link was composed")
        #expect(link.hasSettled, "hello and declare did not cross: \(link.phase)")
        #expect(model.hostLinkError == nil)

        // PinPointStudio opens the Session at `declare` and arms from its own
        // control. Give it both, plus the sync burst.
        try await Task.sleep(for: .seconds(12))

        print("APP-VS-STUDIO security=\(link.securitySummary)")
        print("APP-VS-STUDIO version=\(link.negotiatedVersion ?? "—") "
              + "counterpart=\(link.counterpartPeerId ?? "—")")

        // ⛔ The Session reached the app, with 5.10e's two parameters on it.
        let hostSession = try #require(link.hostSession,
                                       "session_open never reached the app")
        #expect(hostSession.hasArbitration)
        print("APP-VS-STUDIO session=\(hostSession.sessionId) "
              + "ref=\(hostSession.timebaseRefId) "
              + "hold=\(hostSession.issueHoldNs)ns "
              + "window=\(hostSession.coincidenceWindowNs)ns")

        // ⚠ **Reported, not asserted.** Whether Studio armed us during the window
        // is its operator's business, and a row that failed because nobody
        // pressed a button would be a row nobody trusts. What matters is that if
        // it did arm, we answered — and `capabilityError` is the proof the arm
        // ran, since a simulator can never reach warm.
        print("APP-VS-STUDIO armed=\(model.capabilityError != nil) "
              + "blocker=\(model.currentBlocker()?.rawValue ?? "none") "
              + "state=\(model.hostLink.state.rawValue)")
        if let clock = model.hostLink.clock {
            print("APP-VS-STUDIO clock=\(clock.agreementText) drift=\(clock.driftText)")
        }

        await model.disconnect()
        #expect(model.link == nil)
    }
}
