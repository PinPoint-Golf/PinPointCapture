//  Mothballed with `SessionOfferService` (#122). Lifted verbatim out of `Tests/AppAgainstStudioTests.swift`
//  (suite `AppAgainstStudioTests`); put it back inside that suite if the offer path returns.

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
