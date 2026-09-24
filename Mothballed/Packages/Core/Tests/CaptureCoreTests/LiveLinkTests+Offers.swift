//  Mothballed with `SessionOfferService` (#122). Lifted verbatim out of `Packages/Core/Tests/CaptureCoreTests/LiveLinkTests.swift`
//  (suite `LiveLinkTests`); put it back inside that suite if the offer path returns.

    /// A bundle big enough that one `feed` cannot clear it into the peer's
    /// 64 KiB outbound queue — which is the only way to reach the code path that
    /// was wrong.
    static func offeredBundle() throws -> Data {
        let clip = Data((0..<40_000).map { UInt8($0 % 251) })
        return try SessionBundleTests.writeBundle(
            streams: [SessionBundleTests.videoStream],
            captures: [(SessionBundleTests.capture("cap:a", bytes: UInt64(clip.count),
                                                   digest: SessionBundleWriter.digest(of: clip)), clip),
                       (SessionBundleTests.capture("cap:b", bytes: UInt64(clip.count),
                                                   digest: SessionBundleWriter.digest(of: clip)), clip)])
    }

    static func offerService(_ source: ByteSource, peer: DevicePeer) throws
        -> (SessionOfferService, SessionStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ppcp-offer-\(UUID().uuidString)", isDirectory: true)
        let store = try SessionStore(root: root)
        try store.makeBundle(sessionId: SessionBundleTests.sessionId,
                             mintingPeerId: SessionBundleTests.peerId)
        return (SessionOfferService(peer: peer, store: store,
                                    read: { try source.read($0) }), store)
    }

    /// ⛔ **The defect PinPointStudio's ask found before either side ran anything.**
    ///
    /// `pumpReplay` held its position in the bundle as a **local**, so a pump that
    /// stopped on a full outbound queue threw the offset away. The next call
    /// re-read the whole file and re-fed it **from byte zero**, into a
    /// `BundleReplay` that had already consumed part of it. Two symptoms: the file
    /// is re-read once per pump, and the host is sent frames it has already had.
    ///
    /// ⚠ The read count is what this asserts, because it is the half that is
    /// observable from outside the library. `bundle.h`'s own call sequence is a
    /// loop over the file advancing by `consumed` — one read, many feeds.
    @Test("A replay reads its bundle once, however many pumps it takes")
    func replayReadsItsBundleOncePerReplay() throws {
        let peer = try Self.peer()
        let source = ByteSource(try Self.offeredBundle())
        let (service, _) = try Self.offerService(source, peer: peer)

        try service.received(PpcpSessionAccept(sessionId: SessionBundleTests.sessionId,
                                               verdict: .accept, haveDigests: []),
                             fromHost: "peer:host")
        #expect(source.reads == 1, "the bundle is read when the replay begins")

        var pumps = 0
        while try service.pumpReplay(hostPeerId: "peer:host") == false {
            pumps += 1
            // Drain, exactly as an embedding between ticks would.
            _ = try peer.drain(.control)
            _ = try peer.drain(.bulk)
            #expect(pumps < 200, "replay made no progress")
        }

        #expect(pumps > 0, """
                the bundle cleared in one pump, so this test never reached the \
                path it exists for — make the fixture bigger
                """)
        #expect(source.reads == 1,
                "re-read once per pump is the defect; it must stay at one")
        #expect(service.disposition(ofSession: SessionBundleTests.sessionId,
                                    forHost: "peer:host") == .replayed)
    }

    /// The other half of the same defect: nothing stood the service down when the
    /// link died mid-replay, so it went on pumping at a dead peer.
    ///
    /// ⚠ A replay is **not** resumable across links — `BundleReplay` holds the
    /// `have_digests` from a `session_accept` that belonged to the link that went
    /// — so the honest recovery is to drop it and offer the Session again. The
    /// disposition stays `.accepted`, which `offerAll` does not skip.
    @Test("A link lost mid-replay drops it, and the Session is offered again")
    func aLostLinkDropsTheReplayAndReOffers() throws {
        let peer = try Self.peer()
        let source = ByteSource(try Self.offeredBundle())
        let (service, _) = try Self.offerService(source, peer: peer)

        try service.received(PpcpSessionAccept(sessionId: SessionBundleTests.sessionId,
                                               verdict: .accept, haveDigests: []),
                             fromHost: "peer:host")
        #expect(try service.pumpReplay(hostPeerId: "peer:host") == false,
                "the fixture should not clear in one pump")

        service.linkLost()

        // Nothing in flight: a pump is now a no-op rather than a push at a corpse.
        #expect(try service.pumpReplay(hostPeerId: "peer:host") == true)
        #expect(service.disposition(ofSession: SessionBundleTests.sessionId,
                                    forHost: "peer:host") == .accepted,
                "not `.replayed` — it never finished")

        // And the Session is offered again on the next link.
        _ = try peer.drain(.control)
        let offered = try service.offerAll(toHost: "peer:host")
        #expect(offered.map(\.sessionId) == [SessionBundleTests.sessionId])
    }

