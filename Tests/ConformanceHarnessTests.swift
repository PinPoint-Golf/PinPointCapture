//  ConformanceHarnessTests.swift
//  D9 — this device's peer against `libppcp`'s `ppcp-sim`, over `RV` §2's direct
//  path.
//
//  ⛔ **This is the first test in this repository whose counterpart this
//  repository did not write.** Every `pass` before it was asserted against
//  another part of this application or against a fixture — which `CONF` §2c calls
//  the single-implementation trap in as many words: "an implementation talking
//  only to itself never makes the check". `ppcp-sim` refuses a `shot` naming a
//  Shot already seen with a different `t0`, a message no declared profile
//  confers, a first frame that is not `link_bind`, and a frame whose channel
//  disagrees with its header. None of those refusals is reachable from a loopback
//  against ourselves.
//
//  ⚠ **How to run it.** `make conform` starts the simulator peer, hands the port
//  in, and runs this. Without a port in the environment the test **skips** rather
//  than fails, so `make test-app` stays green on a machine with no `libppcp`
//  checkout — a test that failed for a missing tool would be a red suite that
//  says nothing about conformance.
//
//      make conform
//      # or, by hand:
//      ../libppcp/build/dev/tools/ppcp-sim/ppcp-sim --role host --listen 0 \
//          --port-file /tmp/p --declaration ../libppcp/tools/scenarios/reference-host.json \
//          --scenario reference-host --expect violations=0 &
//      TEST_RUNNER_PPCP_CONFORM_PORT=$(cat /tmp/p) make test-app
//
//  Spec: `CONF` §2a, §2c, CT-S5 (device); `RV` §2, §9a. Plan D9.

import Foundation
import Testing
import CaptureCore
@testable import PinPointCapture

@Suite("D9 — the conformance harness", .serialized)
struct ConformanceHarnessTests {

    /// The port `ppcp-sim` bound, handed in by `make conform`.
    ///
    /// ⚠ `TEST_RUNNER_`-prefixed variables are forwarded to a test runner with the
    /// prefix stripped; the unprefixed name is read too so the suite can be driven
    /// from a scheme's environment as well.
    static var port: UInt16? {
        let environment = ProcessInfo.processInfo.environment
        let raw = environment["PPCP_CONFORM_PORT"]
            ?? environment["TEST_RUNNER_PPCP_CONFORM_PORT"]
        guard let raw, let value = UInt16(raw), value > 0 else { return nil }
        return value
    }

    /// The port `ppcp-conform` is listening on, handed in by `make conform`.
    ///
    /// ⚠ **`ppcp-conform` listens and this device dials**, which is the `--listen`
    /// shape rather than `--connect`: the harness is a connector and has no
    /// plaintext listener, and `RV` 2c1 is easier to hold when there is nothing
    /// to accept on.
    static var toolPort: UInt16? {
        let environment = ProcessInfo.processInfo.environment
        let raw = environment["PPCP_CONFORM_TOOL_PORT"]
            ?? environment["TEST_RUNNER_PPCP_CONFORM_TOOL_PORT"]
        guard let raw, let value = UInt16(raw), value > 0 else { return nil }
        return value
    }

    /// Which `ppcp-sim` scenario is on the other end, so an assertion can depend
    /// on what that scenario *does*. ⚠ `reference-host` when unset, which is what
    /// `make conform` starts by default.
    static var scenario: String {
        let environment = ProcessInfo.processInfo.environment
        return environment["PPCP_CONFORM_SCENARIO"]
            ?? environment["TEST_RUNNER_PPCP_CONFORM_SCENARIO"]
            ?? "reference-host"
    }

    /// Which `CONF` §5 interoperability row this invocation is running.
    ///
    /// ⛔ **One row per invocation, and the gate is not tidiness.** `ppcp-sim`
    /// serves one link; a suite where three tests each dialled the same listener
    /// would have two of them measuring a peer that had already finished. So
    /// `make conform ROW=<name>` runs exactly one of the rows below and the
    /// others return immediately.
    static var row: String {
        let environment = ProcessInfo.processInfo.environment
        return environment["PPCP_CONFORM_ROW"]
            ?? environment["TEST_RUNNER_PPCP_CONFORM_ROW"]
            ?? "d9"
    }

    /// The ports the two `CONF` §5 rows dial. ⚠ **Two counterparts, one
    /// simulator launch**: `make conform-iop` starts a `ppcp-sim` per row on its
    /// own port and runs this suite once, because booting, installing and
    /// launching a simulator costs tens of seconds and the rows cost sixteen.
    static func iopPort(_ name: String) -> UInt16? {
        let environment = ProcessInfo.processInfo.environment
        let raw = environment["PPCP_\(name)_PORT"]
            ?? environment["TEST_RUNNER_PPCP_\(name)_PORT"]
        guard let raw, let value = UInt16(raw), value > 0 else { return nil }
        return value
    }

    /// Where the IOP-1 / IOP-3 bundles are written inside the app container, so
    /// `make pull-bundles` knows where to find them.
    static var bundleRoot: URL {
        URL.documentsDirectory.appendingPathComponent("interop-bundles", isDirectory: true)
    }

    /// CT-S5 (device), first half: the device peer completes `ENC` §2.1's bind on
    /// both channels, the `MSG` §3 handshake, joins the Session the host opens,
    /// opens a Stream per declared Source, and answers the host's sync and `arm` —
    /// with the simulator reporting **no** violation of any rule it checks.
    @Test("A full session against a synthetic host, over the direct path")
    func aSessionAgainstPpcpSim() async throws {
        guard Self.row == "d9" else { return }
        guard let port = Self.port else {
            // ⛔ Skipped, not failed. See the note at the top.
            withKnownIssue("no ppcp-sim port in the environment — run `make conform`",
                           isIntermittent: true) {
                Issue.record("skipped")
            }
            return
        }

        let harness = ConformanceHarness(device: CaptureDeviceFactory.create(),
                                         distance: MicToBallDistance())
        let report = try await harness.run(
            against: PeerEndpoint(host: "127.0.0.1", port: port),
            seconds: 8, injectSwings: 1)

        // ⚠ The transcript is attached to every failure, because a conformance
        // failure whose message is "expected true" costs an hour.
        let transcript = report.transcript.joined(separator: "\n")

        // `RV` 5.4k — the mode is surfaced, and on this path it is honest about
        // there being none.
        #expect(report.security == "no TLS, none — no forward secrecy", "\(transcript)")

        // `MSG` §3 — a wire version was agreed and the counterpart declared.
        #expect(report.counterpartPeerId != nil, "\(transcript)")

        // `MSG` 4.1 — the host opened a Session and this peer joined it.
        #expect(report.sessionId != nil, "\(transcript)")

        // §5.11 — a Stream per declared Source.
        //
        // ⚠ **A simulator has no camera**, so this peer declares no camera Source
        // and opens no `video` Stream. That is the honest declaration and it is
        // asserted rather than papered over: the run covers the handshake, the
        // Session, the `audio` and `metadata` Streams, the sync exchange and the
        // nomination path. Everything downstream of a camera Source needs a phone
        // and is recorded as such in `docs/ppcp-conformance.md`.
        #expect(report.streamsOpened.isEmpty == false, "\(transcript)")

        // ⛔ No `error` frame came back. `ppcp-sim` answers `error` for a message
        // no declared profile confers (I24) and for a malformed frame, and this is
        // the assertion that catches both.
        #expect(report.errorCodes.isEmpty, "\(transcript)")

        // F-L13-1 — `peer.h`: "a conformance harness asserts it is zero".
        #expect(report.droppedEvents == 0, "\(transcript)")

        // CT-I8 / 5.12c — every nomination is emitted. The injected swing carries
        // an impact and a ball-into-screen 9 ms behind it, and **both** are
        // Candidates: suppressing the second is what Draft 1 forced and what
        // 5.12c now forbids.
        #expect(report.candidatesNominated == 2, "\(transcript)")

        // CT-S4 (6) / 8.2i — **a host that answers nothing**. The deadline that
        // fires is the device's own and it fires whether or not a host is there,
        // so the Shot is minted locally with `authority: device` (8.3a–c, I23).
        // ⛔ Asserted only against the scenario that produces it: `reference-host`
        // arbitrates, and a device that minted under one would be minting Shots a
        // host had not issued, which is the defect 8.2i exists to close.
        //
        // ⚠ **The two ways this can be zero are not the same fact**, and asserting
        // only `shotsMinted` conflates them: a deadline that has not arrived, and
        // a peer that cannot express "now" in `Session.timebase_ref` at all
        // (8.2i1 — in which case not minting is *correct*). Both are asserted so
        // a failure names which one it is.
        if Self.scenario == "silent-host" {
            #expect(report.hasArbitration,
                    "a silent host still opens an arbitrating Session\n\(transcript)")
            #expect(report.referenceInstantAvailable,
                    """
                    8.2i1: no relation to Session.timebase_ref \
                    (\(report.timebaseRefId ?? "—")), so the mint pump correctly \
                    never ran — the deadline cannot fire at all
                    \(transcript)
                    """)
            #expect(report.shotsMinted >= 1,
                    """
                    8.2i's deadline did not fire against a silent host; \
                    issue_hold was \(report.issueHoldNs.map(String.init) ?? "unknown") ns
                    \(transcript)
                    """)
        }
    }

    /// **The D9 claim.** `ppcp-conform` drives this device through every row of
    /// `PPCP-CONF` §3 and §4 that applies to a `capture` peer with this profile
    /// set, asserting on the wire through `ppcp-sim` — and the verdict is the
    /// **tool's exit code**, not this test's.
    ///
    /// ⛔ **This test is not the assertion.** It is the device answering the
    /// telephone: `ppcp-conform` spawns one counterpart per row, sequentially, on
    /// one port, so all this has to do is keep dialling until the rows run out.
    /// A test that asserted anything about the outcome here would be the
    /// implementation grading its own paper, which is the whole thing `CONF` §2c
    /// says not to do — `make conform` reads the exit code.
    ///
    /// ⚠ Between rows the tool tears one counterpart down and starts the next, so
    /// a dial is refused for a moment. That is expected and retried; a run of
    /// refusals long enough to mean "the rows are finished" ends the loop.
    @Test("ppcp-conform drives the device through every applicable row",
          .timeLimit(.minutes(5)))
    func ppcpConformDrivesTheDevice() async throws {
        guard let port = Self.toolPort else {
            withKnownIssue("no ppcp-conform port in the environment — run `make conform`",
                           isIntermittent: true) {
                Issue.record("skipped")
            }
            return
        }

        let endpoint = PeerEndpoint(host: "127.0.0.1", port: port)
        let deadline = Date().addingTimeInterval(300)
        // ⛔ **Patient before the first row, impatient after the last**, and the
        // asymmetry is the whole fix. A simulator takes tens of seconds to boot,
        // install and launch; `ppcp-conform` gives each row 5–8 s and moves on.
        // The first version was impatient at both ends, so every row expired
        // waiting for a device that was still starting up and all four failed
        // with "timed out waiting for two bound channels" — the same class of
        // mistake as starting the counterpart before the build.
        //
        // ⚠ `make conform` also delays starting the tool until this loop is
        // running. Both halves are needed: the delay stops rows being burned, and
        // this patience covers a simulator slower than the delay allowed for.
        let firstConnection = Date().addingTimeInterval(120)
        var sessions = 0
        var consecutiveRefusals = 0

        while sessions < 16, Date() < deadline,
              sessions == 0 ? Date() < firstConnection : consecutiveRefusals < 12 {
            let harness = ConformanceHarness(device: CaptureDeviceFactory.create(),
                                             distance: MicToBallDistance())
            do {
                // Long enough to outlast the longest row (`run_ms` is 5–8 s).
                let report = try await harness.run(against: endpoint, seconds: 9,
                                                   injectSwings: 1)
                sessions += 1
                consecutiveRefusals = 0
                // ⛔ Printed, never asserted on. The tool is the instrument; this
                // is here so a failing row has a device-side trace beside it.
                print("ppcp-conform row \(sessions): \(report.transcript.count) events, "
                      + "\(report.candidatesNominated) candidates, "
                      + "\(report.shotsMinted) shots, "
                      + "session \(report.sessionId ?? "—")")
            } catch {
                consecutiveRefusals += 1
                try? await Task.sleep(for: .milliseconds(400))
            }
        }

        // The one thing worth asserting here: the device answered at all. If it
        // never connected, the tool's rows all failed for a reason that has
        // nothing to do with conformance and the report would mislead.
        #expect(sessions > 0, "the device never completed a session against ppcp-conform")
    }

    // MARK: - CONF §5 interoperability, wave 1

    /// **IOP-2** — this device against a host that declares camera conventions it
    /// does not share.
    ///
    /// `three-timebase-host.json` is two machine-vision cameras, each on its own
    /// clock, each declaring `timing.convention: start` and
    /// `geometry.kind: global` — a declaration no phone can make and the shape
    /// `CONF` §2c says an implementation talking to itself never meets. The
    /// Session's `timebase_ref` is the **host's** clock, so every `Shot.t0` that
    /// arrives is an instant on a clock this device does not own.
    ///
    /// ⛔ **What is proved here is I22 from the RECEIVING side.** 5.13c puts
    /// `Shot.t0` in `Session.timebase_ref`; a device that took the number and
    /// handed it to its own ring would ask for an interval wrong by an offset
    /// nobody measured, and nothing would say so. The assertion is that the
    /// instant arrived on the host's timebase, that this device converted it to
    /// its own, and that the two readings are *different* — a conversion that
    /// returned its input would pass an equality test and prove nothing.
    ///
    /// ⚠ **And I19 only as far as a simulator can carry it.** I19 is "declare
    /// what this hardware is"; a simulator enumerates no camera, so the camera
    /// half of the declaration — `nominal_frame_start`, `rolling_shutter`,
    /// provenance `assumed` — is not on the wire in this run and the row says so.
    /// What *is* asserted is that the device did not borrow the host's
    /// convention to make the pairing look tidy.
    ///
    ///     make conform SCENARIO=reference-host DECL=three-timebase-host ROW=iop2
    @Test("IOP-2 — a host with foreign camera conventions and three clocks",
          .timeLimit(.minutes(2)))
    func iop2AgainstAForeignHost() async throws {
        guard let port = Self.iopPort("IOP2") ?? (Self.row == "iop2" ? Self.port : nil) else {
            withKnownIssue("no ppcp-sim port in the environment — run `make conform`",
                           isIntermittent: true) {
                Issue.record("skipped")
            }
            return
        }

        let harness = ConformanceHarness(device: CaptureDeviceFactory.create(),
                                         distance: MicToBallDistance())
        // ⚠ Longer than D9's eight seconds: the host waits for the first
        // `relation_update` exchange before it nominates or arbitrates
        // (`sim_run_steps.inc`, STEP_OFFER's 700 ms), then holds for
        // `issue_hold_ns` before it issues. A window that ended first would
        // report "no Shot arrived" about the clock rather than about the device.
        let report = try await harness.run(
            against: PeerEndpoint(host: "127.0.0.1", port: port),
            seconds: 20, injectSwings: 1, nominateOnlyOnceConvertible: true)
        let transcript = report.transcript.joined(separator: "\n")

        #expect(report.sessionId != nil, "\(transcript)")
        #expect(report.errorCodes.isEmpty, "\(transcript)")

        // 5.13c — the Session's reference clock is the HOST's, and this device
        // does not own it. ⛔ If this ever reads as this device's capture
        // timebase, every assertion below is measuring the identity.
        #expect(report.timebaseRefId == "tb:host",
                "Session.timebase_ref should be the host's clock\n\(transcript)")

        // I19 — what this device declared, and what it did NOT.
        #expect(report.declaredSourceKinds.contains("camera") == report.declaredCamera,
                "a camera Source is declared exactly when one was enumerated\n\(transcript)")
        // ⛔ Not `start`, ever, on this hardware. Empty on a simulator, which is
        // the honest zero rather than a borrowed value.
        #expect(report.declaredConventions.contains("start") == false,
                "this device must not adopt the host's convention\n\(transcript)")

        // I21 / 6.1d — the host declares three timebases and publishes a relation
        // for each; a device that saw none cannot express anything at all.
        #expect(report.relationUpdates > 0,
                "no relation_update arrived from a three-clock host\n\(transcript)")

        // 7.1d / 5.12c — both nominations, on the device's own clock.
        #expect(report.candidatesNominated == 2, "\(transcript)")

        // ⛔ **The row.** A Shot issued by the host, its `t0` on the host's clock,
        // converted here onto this device's.
        #expect(report.shotsReceived.isEmpty == false,
                """
                the host issued no Shot in 16 s; issue_hold was \
                \(report.issueHoldNs.map(String.init) ?? "unknown") ns
                \(transcript)
                """)
        for arrival in report.shotsReceived {
            #expect(arrival.t0TimebaseId == report.timebaseRefId,
                    "Shot.t0 must be in Session.timebase_ref (5.13c)\n\(transcript)")
            #expect(arrival.authority == "host",
                    "a Shot from a role: host peer carries authority: host (8.3d)\n\(transcript)")
            #expect(arrival.convertedToCaptureNs != nil,
                    """
                    8.2i1: t0 could not be expressed on this device's capture \
                    clock, so no interval could be asked for
                    \(transcript)
                    """)
            #expect(arrival.convertedToCaptureNs != arrival.t0Ns,
                    """
                    the conversion returned its input — the two clocks are not \
                    the same clock and a reading that did not move was not converted
                    \(transcript)
                    """)
        }
    }

    /// **IOP-1** — this device against the reference host, end to end, including a
    /// **session offer of a stored Session and its replay**.
    ///
    /// ⛔ **The device offers; the host chooses.** That is the user's decision of
    /// 22 August 2026 and `MSG` §9.1's shape: there is no file picker anywhere in
    /// this application. Two hostless Sessions are recorded first — one with a
    /// single minted Shot, one with two — through the same
    /// `CaptureSessionRecorder` a range session uses, and then offered.
    ///
    /// ⚠ **Every Capture in them is `absent` / `outside_buffer`, and that is a
    /// result rather than a failure** (I10, 8.4b). A simulator has no camera and
    /// no ring; the manifest asserts `partial` and means it.
    ///
    ///     make conform SCENARIO=reference-host ROW=iop1 \
    ///          EXPECT=violations=0,offers_rx=2,accepts_rx=0
    @Test("IOP-1 — the reference host, plus an offer of a stored Session",
          .timeLimit(.minutes(2)))
    func iop1OffersAStoredSession() async throws {
        guard let port = Self.iopPort("IOP1") ?? (Self.row == "iop1" ? Self.port : nil) else {
            withKnownIssue("no ppcp-sim port in the environment — run `make conform`",
                           isIntermittent: true) {
                Issue.record("skipped")
            }
            return
        }

        // A clean library each run: `makeBundle` is idempotent on the ids (I34),
        // so a stale directory from a previous run would be re-offered and the
        // count assertion would be about history rather than about this run.
        let root = Self.bundleRoot
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SessionStore(root: root)
        let device = CaptureDeviceFactory.create()
        let distance = MicToBallDistance()

        let one = try InteropBundleFixture.record(
            shots: 1, into: store, device: device, distance: distance,
            sessionId: "ses:interop:one-shot")
        let two = try InteropBundleFixture.record(
            shots: 2, into: store, device: device, distance: distance,
            sessionId: "ses:interop:two-shots")

        // IOP-3 / IOP-10 — what PinPointStudio is asked to import. Asserted here
        // rather than only over the wire, because a bundle with no Shot in it is
        // a bundle that says nothing about minting.
        #expect(one.shotIds.count == 1, "the one-shot bundle minted \(one.shotIds.count)")
        #expect(two.shotIds.count == 2, "the two-shot bundle minted \(two.shotIds.count)")
        #expect(try store.bundles().count == 2)

        // ⛔ And they read back through the library's own reader before anything
        // is offered: a bundle this device cannot read is not one to hand over.
        for bundle in [one.bundle, two.bundle] {
            let bytes = try Data(contentsOf: bundle.bundleFile)
            #expect(SessionStore.hasBundleMagic(bytes), "ENC §7 — PPCPBNDL")
            let reader = try SessionBundleReader()
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + 4096, bytes.count)
                try reader.feed(bytes[offset..<end])
                offset = end
            }
            #expect(reader.manifestOrdered, "ENC 7c — the manifest precedes every payload")
            // ⛔ `partial` is what was asserted, and a reader that answered
            // `complete` would be inferring from what it found (I10).
            #expect(try reader.finish() == .partial)
        }

        let harness = ConformanceHarness(device: device, distance: distance,
                                         offering: store)
        let report = try await harness.run(
            against: PeerEndpoint(host: "127.0.0.1", port: port),
            seconds: 20, injectSwings: 1, nominateOnlyOnceConvertible: true)
        let transcript = report.transcript.joined(separator: "\n")

        #expect(report.sessionId != nil, "\(transcript)")
        #expect(report.errorCodes.isEmpty, "\(transcript)")
        #expect(report.counterpartPeerId == "sim:host", "\(transcript)")

        // `MSG` 9.1 — both Sessions offered, exactly once each.
        #expect(Set(report.offersSent) == Set([one.bundle.sessionId, two.bundle.sessionId]),
                "offered \(report.offersSent)\n\(transcript)")

        // `MSG` 9.1 / `ENC` 7a — the host accepted, and the stored bundle's own
        // frames went back onto the live link renumbered into its sequence.
        #expect(report.offerVerdicts.isEmpty == false,
                "the host answered no offer\n\(transcript)")
        for (sessionId, verdict) in report.offerVerdicts {
            #expect(verdict == "accept", "\(sessionId) → \(verdict)\n\(transcript)")
        }
        #expect(report.replayCompleted,
                "an accepted Session did not finish replaying\n\(transcript)")
    }
}
