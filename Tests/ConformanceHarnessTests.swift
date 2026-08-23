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

    /// Which `ppcp-sim` scenario is on the other end, so an assertion can depend
    /// on what that scenario *does*. ⚠ `reference-host` when unset, which is what
    /// `make conform` starts by default.
    static var scenario: String {
        let environment = ProcessInfo.processInfo.environment
        return environment["PPCP_CONFORM_SCENARIO"]
            ?? environment["TEST_RUNNER_PPCP_CONFORM_SCENARIO"]
            ?? "reference-host"
    }

    /// CT-S5 (device), first half: the device peer completes `ENC` §2.1's bind on
    /// both channels, the `MSG` §3 handshake, joins the Session the host opens,
    /// opens a Stream per declared Source, and answers the host's sync and `arm` —
    /// with the simulator reporting **no** violation of any rule it checks.
    @Test("A full session against a synthetic host, over the direct path")
    func aSessionAgainstPpcpSim() async throws {
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
        if Self.scenario == "silent-host" {
            #expect(report.shotsMinted >= 1,
                    "8.2i's deadline did not fire against a silent host\n\(transcript)")
        }
    }
}
