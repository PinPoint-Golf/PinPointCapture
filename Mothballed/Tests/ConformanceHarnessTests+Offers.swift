//  Mothballed with `SessionOfferService` (#122). Lifted verbatim out of `Tests/ConformanceHarnessTests.swift`
//  (suite `ConformanceHarnessTests`); put it back inside that suite if the offer path returns.

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

        // ⛔ **`MSG` 4.1a1 / 9.1b (erratum E28) — the row F-S5-3 produced, from
        // the EXPORTER's side.**
        //
        // ⚠ **This device imports nothing here, and asserting that it did was a
        // defect in an earlier version of this test.** `ppcp_event.imported` is
        // set on the peer that *receives* a replayed Session; this device is the
        // one replaying, so its own imported-Session accessors stay empty and
        // must. What E28 gives the exporter is the property F-S5-3 violated: a
        // replay must not disturb the live Session it travels over.
        #expect(report.importedFrames == 0,
                """
                this device exported a Session and imported none, so no frame \\
                should have arrived flagged imported
                \\(transcript)
                """)

        // ⛔ The live Session is untouched by the replay — `CORE` 4.1a and I16
        // make `timebase_ref` immutable for the life of a Session, and before the
        // fix a replayed `session_open` naming a different Session rebound it on
        // whichever end received it.
        #expect(report.sessionId?.isEmpty == false, "\\(transcript)")
        #expect(report.timebaseRefId == "tb:host",
                "the live timebase_ref moved during a replay\\n\\(transcript)")

        // ⛔ **The symptom, asserted directly.** In S5 wave 2 every `shot` that
        // arrived after a replay carried `t0` in the *exporting* Session's clock
        // (`tb:hosttime`) while the live Session declared `tb:host`, so this
        // device's conversion silently became the identity. With E28 on both
        // ends, a Shot issued over this live Session is expressed in this live
        // Session's reference clock and in no other.
        for arrival in report.shotsReceived {
            #expect(arrival.t0TimebaseId == report.timebaseRefId,
                    """
                    a Shot arrived in \\(arrival.t0TimebaseId) while the live \\
                    Session's timebase_ref is \\(report.timebaseRefId ?? "—") — \\
                    that is F-S5-3 returning
                    \\(transcript)
                    """)
        }
    }
