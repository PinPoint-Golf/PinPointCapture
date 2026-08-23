//  LiveLinkTests.swift
//  D6 — sync, liveness, the transfer queue, the zero-host regime, and the offer
//  of a stored Session.
//
//  Rows exercised: CT-I18 (device), CT-I21, CT-I38, CT-S4 (7), CT-S5 (device).

import Foundation
import Testing
import CPPCP
@testable import CaptureCore

@Suite("The live link — CORE §5.14g, §6.3, §7.4, §8.3; MSG §4.3, §6, §8, §9.1")
struct LiveLinkTests {

    static let peerId = "peer:d6-device"
    static let sessionId = "ses:d6"
    static let timebase = "tb:hosttime"

    static let videoStream = PpcpStreamRecord(
        id: "str:video", sessionId: sessionId, sourceId: "src:camera:wide",
        kind: PpcpStreamKind.video, profileId: "1920x1080@150",
        timebaseId: timebase, continuity: .shotWindowed, openedAtNs: 0)

    static let previewStream = PpcpStreamRecord(
        id: "str:preview", sessionId: sessionId, sourceId: "src:camera:wide",
        kind: PpcpStreamKind.preview, profileId: "640x360@30",
        timebaseId: timebase, continuity: .continuous, openedAtNs: 0)

    static func peer() throws -> DevicePeer { try DevicePeer(peerId: peerId) }

    static let clip = Data((0..<1_200).map { UInt8($0 % 251) })

    static func shotCapture(_ id: String, completeness: PpcpCaptureRecord.Completeness = .complete)
        -> PpcpCaptureRecord {
        PpcpCaptureRecord(
            id: id, anchor: .shot("sht:1"), streamId: videoStream.id,
            timebaseId: timebase, completeness: completeness,
            intervalNs: completeness == .absent ? nil : 1_000_000_000..<2_000_000_000,
            absentReason: completeness == .absent ? PpcpAbsentReason.outsideBuffer : nil,
            digest: completeness == .absent ? nil : SessionBundleWriter.digest(of: clip),
            bytes: completeness == .absent ? nil : UInt64(clip.count))
    }

    // MARK: CT-I38 / 5.14g — the four exits, and no fifth

    /// ⛔ **The predicate is `ppcp_transfer_is_evictable` and nothing else.** A
    /// `complete` + `pending` shot Capture is **not** evictable: no receiver has
    /// confirmed it, and 5.14g1 says a peer's own retention policy MUST NOT extend
    /// the list — "shot-anchored payload is never sheddable by policy".
    @Test("A pending shot Capture is not evictable, and an absent one is")
    func evictionIsTheLibrarysDecision() throws {
        let peer = try Self.peer()
        try peer.openStream(Self.videoStream)
        try peer.announce(Self.shotCapture("cap:pending"))
        try peer.announce(Self.shotCapture("cap:absent", completeness: .absent))

        let queue = PayloadTransferQueue(peer: peer)
        // Exit 1 is unreachable without a `capture_committed`; exit 2 is the
        // absent one, which has no payload to evict and no digest for a commit to
        // name.
        #expect(queue.evictable(from: ["cap:pending", "cap:absent"]) == ["cap:absent"])

        // ⚠ The negative half is the load-bearing one: a device under storage
        // pressure that asked this question and got "cap:pending" back would drop
        // a swing the consumer has not received.
        #expect(peer.isEvictable(captureId: "cap:pending") == false)
    }

    /// 5.14g exit 3 — `payload_abort`/`already_present` is equivalent to a commit
    /// **for this purpose**, because the receiver demonstrably holds the payload.
    @Test("already_present releases a Capture the owner could not otherwise evict")
    func alreadyPresentIsAnExit() throws {
        let peer = try Self.peer()
        try peer.openStream(Self.videoStream)
        try peer.announce(Self.shotCapture("cap:1"))
        #expect(peer.isEvictable(captureId: "cap:1") == false)

        try peer.withHandleThrowing { handle in
            let table = UnsafeMutablePointer(mutating: ppcp_peer_transfers(handle))
            var id = ppcp_id()
            try check(ppcp_id_set_z(&id, "cap:1"))
            try check(ppcp_transfer_on_already_present(table, &id))
        }
        #expect(peer.isEvictable(captureId: "cap:1"))
    }

    // MARK: 5.11j / MSG 8.1i — preview is never queued

    /// ⛔ A preview Capture announced `transfer: pending` is refused by the
    /// **library**, at the announce. "What could not be delivered promptly is
    /// discarded and announced `absent` with `not_retained`; a queue told nothing
    /// else fills with the cheapest data in the session."
    @Test("A preview Capture cannot be announced pending, and never reaches a queue")
    func previewIsNeverQueued() throws {
        let peer = try Self.peer()
        try peer.openStream(Self.previewStream)

        let pending = PpcpCaptureRecord(
            id: "cap:preview", anchor: .segment(startNs: 0, endNs: 1_000_000_000),
            streamId: Self.previewStream.id, timebaseId: Self.timebase,
            completeness: .complete, transfer: .pending)
        #expect(throws: PpcpLibraryError.self) {
            try peer.announce(pending, isPreview: true)
        }

        // The shed form is what a preview segment is *supposed* to look like.
        let shed = PpcpCaptureRecord(
            id: "cap:preview", anchor: .segment(startNs: 0, endNs: 1_000_000_000),
            streamId: Self.previewStream.id, timebaseId: Self.timebase,
            completeness: .absent, absentReason: PpcpAbsentReason.notRetained)
        #expect(throws: Never.self) { try peer.announce(shed, isPreview: true) }
        #expect(peer.transfer(of: "cap:preview")?.isPreview == true)
    }

    // MARK: 5.14g1 / REQ-OFF-2 — refuse to arm, never shed

    /// ⛔ The answer to storage pressure is a `readiness` that is **not settled**,
    /// `blocked_by: storage_full` — a measurement, not a state name (5.15a) — and
    /// not the eviction of an unconfirmed clip.
    @Test("Under storage pressure the device refuses to arm rather than shedding")
    func storagePressureRefusesToArm() throws {
        let floor = StorageFloor()
        #expect(floor.verdict(freeBytes: 1 << 30) == .refuseToArm)
        #expect(floor.verdict(freeBytes: 3 << 30) == .armableWithWarning)
        #expect(floor.verdict(freeBytes: 8 << 30) == .armable)

        var readiness = try floor.readiness(freeBytes: 1 << 30)
        #expect(readiness.settled == false)
        try check(ppcp_readiness_validate(&readiness))
        #expect(readiness.has_blocked_reason)
        #expect(ppcpString(readiness.blocked_reason) == PpcpReadiness.blockedStorageFull)
    }

    // MARK: MSG 8.3a/8.3d — the queue, and resumption

    @Test("Chunks go out in ascending index and payload_end closes the transfer")
    func queueSendsInOrder() throws {
        let peer = try Self.peer()
        try peer.openStream(Self.videoStream)
        try peer.announce(Self.shotCapture("cap:1"))

        let queue = PayloadTransferQueue(peer: peer)
        let clip = Self.clip
        try queue.enqueue(TransferJob(captureId: "cap:1", bytes: UInt64(clip.count),
                                      digest: SessionBundleWriter.digest(of: clip)) { clip })
        let spent = try queue.pump()
        #expect(spent == clip.count)
        #expect(queue.pendingCaptureIds.isEmpty)
        #expect(peer.pending(.bulk) > 0)

        // `MSG` 8.3f — the SHOULD value, taken as written rather than tuned.
        #expect(PayloadTransferQueue.chunkBytes == 262_144)
    }

    /// 8.3d — "resumption restarts from the chunk **after** the last acknowledged
    /// index, not from the beginning", and the index comes from the library's
    /// table rather than from a count the queue kept.
    @Test("Resumption reads the acked index out of the library's transfer table")
    func resumeUsesTheLibrarysAckedIndex() throws {
        let peer = try Self.peer()
        try peer.openStream(Self.videoStream)
        try peer.announce(Self.shotCapture("cap:1"))
        let queue = PayloadTransferQueue(peer: peer)
        let clip = Self.clip
        try queue.enqueue(TransferJob(captureId: "cap:1", bytes: UInt64(clip.count),
                                      digest: SessionBundleWriter.digest(of: clip)) { clip })

        // Nothing acknowledged yet: `MSG` 4.3's pending entry carries no index, and
        // ⛔ that is not the same fact as "index 0 was acknowledged".
        let pending = queue.pendingForResume
        #expect(pending.count == 1)
        #expect(pending[0].ackedIndex == nil)
        #expect(pending[0].bytes == UInt64(clip.count))
    }

    // MARK: MSG 4.3 — session_resume

    /// 4.3a — a reconnecting peer sends `session_resume` and **not**
    /// `session_open`. ⚠ F-D6-1: `libppcp` has no originator for it, so this is
    /// the one message assembled as a `ppcp_msg` by hand.
    @Test("session_resume is queued as a session_resume, with its shots and pendings")
    func sessionResumeIsWellFormed() throws {
        let peer = try Self.peer()
        try peer.sendSessionResume(sessionId: Self.sessionId, peerId: Self.peerId,
                                   mintedShots: ["sht:a", "sht:b"],
                                   pendingCaptures: [
                                       PendingCapture(captureId: "cap:1",
                                                      digest: SessionBundleWriter
                                                          .digest(of: Self.clip),
                                                      bytes: 1_200, ackedIndex: 3)
                                   ])
        let frames = try peer.drain(.control)
        #expect(frames.isEmpty == false)

        // Read back through the library's own decoder — 4.3c says the ids are not
        // renumbered, so the assertion is that they arrive as they left.
        let decoded = try Self.decodeFirst(frames)
        #expect(decoded.type == PPCP_MT_SESSION_RESUME)
        #expect(decoded.mintedShots == ["sht:a", "sht:b"])
        #expect(decoded.pendingCount == 1)
        #expect(decoded.firstAckedIndex == 3)
    }

    // MARK: CORE 8.3g — an unreachable host is not no host

    /// I16 / 8.3g — `timebase_ref`, `coincidence_window_ns` and `issue_hold_ns` are
    /// **unchanged** when the link goes; what changes is that no arbitration
    /// occurs.
    ///
    /// ⚠ **The regime is a property of a Session, not of a peer**, and the library
    /// is right to say so: with no `session_open` at all `ppcp_peer_zero_host` is
    /// `false`, because there is nothing to mint into and 8.3a's two entry
    /// conditions are both about a Session — one with no host in its roster, and
    /// one whose host has stopped answering. This test asserts that reading
    /// deliberately, because the tempting one ("no session, therefore no host,
    /// therefore mint") is how a peer ends up minting before it has joined.
    @Test("The zero-host regime is a property of a Session, not of a peer")
    func zeroHostNeedsASession() throws {
        let peer = try Self.peer()
        #expect(peer.sessionParameters == nil)
        #expect(peer.isZeroHost == false)
        #expect(peer.isLinkLost == false)
        #expect(peer.missedHeartbeats == 0)

        // ✅ **F-D6-3 closed, 23 August 2026** (`libppcp` 42a690a). A hostless
        // `session_open` this peer ORIGINATES is now adopted into its own state:
        // `ppcp_peer_session_open` sets `session_params` as well as `has_session`,
        // so `CORE` 4.1b's case — the frame a capture peer records in its own
        // bundle, and the entry-level product's normal mode — reads back its own
        // parameters, and 8.3g's first entry condition is true for the peer that
        // is in it.
        try peer.openSession(PpcpSessionRecord(id: Self.sessionId,
                                               timebaseRef: Self.timebase))
        let parameters = try #require(peer.sessionParameters)
        #expect(parameters.sessionId == Self.sessionId)
        #expect(parameters.timebaseRefId == Self.timebase)
        // I16 / 5.10e — a hostless Session carries **no** arbitration parameters,
        // and the two that are conditional are the two that are absent.
        #expect(parameters.hasArbitration == false)
        #expect(parameters.coincidenceWindowNs == 0)
        #expect(parameters.issueHoldNs == 0)
        // 8.3a's first entry condition: a Session with no host in its roster.
        #expect(peer.isZeroHost)
    }

    /// **F-D6-3, and what it used to cost.** Before `libppcp` 42a690a,
    /// `ppcp_mint_pump` took the hostless branch only because `issue_hold_ns` and
    /// the heartbeat margin both read as zero when there were no parameters to
    /// read — a coincidence, not a design. A hostless `session_open` carrying a
    /// `heartbeat_interval_ms`, which 5.10e permits since only the two
    /// *arbitration* parameters are conditional, would have taken the **hosted**
    /// branch and held every Candidate for a deadline no host will ever answer.
    ///
    /// ⚠ The test is kept and inverted rather than deleted: it now asserts that
    /// minting works **for the right reason** — `zero_host` is true, so 8.3a–c is
    /// the branch taken because the predicate says so.
    @Test("8.3a — a self-opened hostless Session mints because zero_host says so")
    func hostlessMintTakesTheHostlessBranch() throws {
        let peer = try Self.peer()
        try peer.openSession(PpcpSessionRecord(id: Self.sessionId,
                                               timebaseRef: Self.timebase))
        let mint = try DeviceMint(peer: peer, promotion: { _ in true })
        #expect(throws: Never.self) { _ = try mint.pump(nowRefNs: 10_000_000_000) }
        #expect(peer.isZeroHost)
    }

    // MARK: CT-I21 / 6.1d — one estimator per timebase, and no composition

    @Test("Sync runs once per local timebase and refuses a second registration")
    func oneEstimatorPerTimebase() throws {
        let peer = try Self.peer()
        try peer.addSyncTimebase("tb:hosttime")
        try peer.addSyncTimebase("tb:continuous")
        #expect(peer.syncTimebaseCount == 2)
        // I21 — a timebase already registered is refused rather than replaced: a
        // second estimator for one clock is two answers to one question.
        #expect(throws: PpcpLibraryError.self) { try peer.addSyncTimebase("tb:hosttime") }

        // 6.3a — offset **and** rate. Nothing is published from a standing start.
        #expect(peer.syncHasEstimate("tb:hosttime") == false)
        #expect(peer.syncRelation("tb:hosttime") == nil)
        #expect(peer.syncExchangeCount("tb:hosttime") == 0)
    }

    /// 8.2i1 / 5.4b — a conversion with no relation **fails**; it never falls back
    /// to a zero offset. ⛔ This is the clause that stops a peer minting a Shot
    /// whose `t0` it has no conformant way to express.
    @Test("Converting into a timebase this peer holds no relation to is refused")
    func conversionWithoutARelationFails() throws {
        let peer = try Self.peer()
        var instant = ppcp_instant()
        try check(ppcp_instant_make_z(&instant, "tb:hosttime", 1_000_000_000))
        #expect(try peer.convert(instant, to: "tb:host-studio") == nil)
        // The identity is the identity and is not asserted as a relation (I4).
        let same = try peer.convert(instant, to: "tb:hosttime")
        #expect(same?.ns == 1_000_000_000)
    }

    // MARK: ENC §2.1 — the link binder (F-D3-3)

    /// ⚠ **The channel comes from the frame header.** A stream-per-connection
    /// listener has no channel of its own to supply, and 2.1b forbids inferring one
    /// from arrival order or from the transport address.
    @Test("The binder takes the channel from the header and refuses a second claim")
    func linkBinderTakesTheChannelFromTheHeader() throws {
        let binder = PpcpLinkBinder()
        let linkId = try PpcpLinkId(bytes: Data((0..<16).map { UInt8($0) }))

        let control = try PpcpLinkBind.frame(linkId: linkId, channel: .control)
        let bound = try #require(try binder.offer(control))
        #expect(bound.channel == .control)
        #expect(bound.consumed == control.count)
        #expect(bound.linkId == linkId)
        #expect(binder.isReady(link: bound.link))
        #expect(binder.linkCount == 1)

        // 2.1d — a bulk channel opened later with the same `link_id` joins it.
        let bulk = try PpcpLinkBind.frame(linkId: linkId, channel: .bulk)
        let second = try #require(try binder.offer(bulk))
        #expect(second.link == bound.link)
        #expect(second.channel == .bulk)
        #expect(binder.linkCount == 1)

        // 2.1c — "…a `link_id` that names a link that already holds that channel".
        #expect(throws: TransportError.self) { _ = try binder.offer(bulk) }

        // A partial frame is not a refusal; it is a request for more bytes.
        #expect(try binder.offer(control.prefix(4)) == nil)
    }

    // MARK: MSG 9.1 — offering a stored Session

    /// ⛔ Session identity is `session_id` **plus** `minting_peer_id` (8.5c), and
    /// the offer carries both.
    @Test("session_offer and session_accept round-trip through the library")
    func sessionOfferRoundTrips() throws {
        let peer = try Self.peer()
        let offer = PpcpSessionOffer(sessionId: Self.sessionId,
                                     mintingPeerId: Self.peerId,
                                     completeness: .partial,
                                     bytesEstimate: 1_073_741_824)
        try peer.offer(offer)
        let frames = try peer.drain(.control)
        let decoded = try Self.decodeFirst(frames)
        #expect(decoded.type == PPCP_MT_SESSION_OFFER)
        #expect(decoded.sessionId == Self.sessionId)

        // The host half, which `CaptureCore` also carries so the loopback tests
        // can host both roles until `ppcp-sim` exists.
        let host = try DevicePeer(peerId: "peer:host", role: .host)
        try host.accept(PpcpSessionAccept(sessionId: Self.sessionId, verdict: .accept,
                                          haveDigests: [SessionBundleWriter
                                              .digest(of: Self.clip)]),
                        inReplyTo: 1)
        #expect(host.pending(.control) > 0)
    }

    // MARK: Decoding, through the library

    struct Decoded {
        var type: ppcp_msg_type
        var sessionId: String
        var mintedShots: [String]
        var pendingCount: Int
        var firstAckedIndex: UInt32?
    }

    /// ⛔ Decoded with `ppcp_msg_decode`, never with a parser written here: a
    /// second decoder in a *test* is the worst place for one, because it would
    /// agree with the encoder it is meant to be checking.
    static func decodeFirst(_ frames: Data) throws -> Decoded {
        try frames.withUnsafeBytes { raw -> Decoded in
            var header = ppcp_frame_header()
            var payload: UnsafePointer<UInt8>?
            var consumed = 0
            try check(ppcp_frame_read(raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                                      &header, &payload, &consumed))
            let bytes = MemoryLayout<ppcp_msg>.stride
            let scratch = UnsafeMutableRawPointer.allocate(
                byteCount: bytes, alignment: MemoryLayout<ppcp_msg>.alignment)
            scratch.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
            defer { scratch.deallocate() }
            let message = scratch.assumingMemoryBound(to: ppcp_msg.self)
            try check(ppcp_msg_decode(payload, Int(header.payload_len),
                                      ppcp_cbor_limits_for_channel(header.channel),
                                      nil, message))

            var decoded = Decoded(type: message.pointee.type, sessionId: "",
                                  mintedShots: [], pendingCount: 0, firstAckedIndex: nil)
            switch message.pointee.type {
            case PPCP_MT_SESSION_RESUME:
                withUnsafeMutablePointer(to: &message.pointee.body) { body in
                    body.withMemoryRebound(to: ppcp_body_session_resume.self,
                                           capacity: 1) { resume in
                        decoded.sessionId = ppcpString(resume.pointee.session_id)
                        decoded.pendingCount = resume.pointee.pending_count
                        withUnsafeBytes(of: &resume.pointee.minted_shots) { ids in
                            let base = ids.bindMemory(to: ppcp_id.self)
                            decoded.mintedShots = (0..<resume.pointee.minted_shot_count)
                                .map { ppcpString(base[$0]) }
                        }
                        withUnsafeBytes(of: &resume.pointee.pending) { list in
                            let base = list.bindMemory(to: ppcp_pending_capture.self)
                            if resume.pointee.pending_count > 0, base[0].has_acked_index {
                                decoded.firstAckedIndex = base[0].acked_index
                            }
                        }
                    }
                }
            case PPCP_MT_SESSION_OFFER:
                withUnsafeMutablePointer(to: &message.pointee.body) { body in
                    body.withMemoryRebound(to: ppcp_body_session_offer.self,
                                           capacity: 1) { offer in
                        decoded.sessionId = ppcpString(offer.pointee.session_id)
                    }
                }
            default:
                break
            }
            return decoded
        }
    }
}

extension DevicePeer {
    /// ⚠ Test-only. The engine handle is `internal` for a reason — nothing outside
    /// `CaptureCore` gets one — and a throwing form is needed where the assertion
    /// is about a library call's result rather than about our wrapper's.
    func withHandleThrowing(_ body: (OpaquePointer) throws -> Void) throws {
        guard let peer = peerHandle else { throw PpcpLibraryError(PPCP_ERR_INVALID) }
        try body(peer)
    }
}
