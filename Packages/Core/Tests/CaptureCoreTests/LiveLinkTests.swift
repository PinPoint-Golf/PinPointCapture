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

    // MARK: 5.11.2 — a preview segment that is actually PRODUCED

    /// ⛔ **THE TEST THAT DID NOT EXIST, AND IT IS WHY NOTHING WORKED.**
    ///
    /// Every preview test in this repository asserted a REFUSAL — that a preview
    /// Capture announced `pending` is rejected, that a shed is `absent` and never
    /// a gap. Not one asserted that a segment can be produced at all. So when
    /// `PreviewProducer.deliver` built its record with `segment()`'s default
    /// `.pending` and assigned `.present` on the *next line* — unreachable,
    /// because `StreamCoverage` enforces 8.1i inside `segment()` and threw first
    /// — the suite stayed green while **no preview frame had ever left this
    /// application**. A green suite was testing the guard that was firing.
    /// Found on device 28 Aug 2026, after two days of a black tile.
    @Test("A preview segment is produced, not merely refused when malformed")
    func previewDeliversASegment() throws {
        let peer = try Self.peer()
        let stream = PpcpStreamRecord(
            id: "str:preview:live", sessionId: Self.sessionId,
            sourceId: "src:camera:wide", kind: PpcpStreamKind.preview,
            profileId: PpcpDeclaration.previewProfileId, timebaseId: Self.timebase,
            continuity: .continuous, openedAtNs: 1_000_000_000)
        try peer.openStream(stream)
        let producer = try PreviewProducer(peer: peer, stream: stream,
                                           mintId: { "cap:prev:1" })

        // ⚠ The first frame lands a couple of milliseconds after the Stream
        // opens, which is what the device actually does: the tap goes on
        // immediately and AVFoundation delivers ~2 ms later.
        let outcome = try producer.deliver(endingAtNs: 1_002_000_000,
                                           payload: Data(repeating: 0x5a, count: 4_000))
        #expect(outcome == .sent(captureId: "cap:prev:1"))
        #expect(producer.accountedThroughNs == 1_002_000_000)
        #expect(producer.unaccountedNs(asOf: 1_002_000_000) == nil)
    }

    /// ⛔ **A REAL PREVIEW FRAME IS BIGGER THAN ONE CHUNK.**
    ///
    /// 640×360 at JPEG q0.6 is ~35 kB and `PayloadTransferQueue.chunkBytes` is
    /// 32 kB. `ppcp_peer_payload_chunk` refuses `len > chunk_bytes`, so a
    /// producer that sent the whole frame as index 0 — which this one did —
    /// failed on nearly every frame. ⚠ And only on *nearly* every frame: a
    /// simple enough scene compresses under 32 kB and goes through, so the
    /// symptom was intermittent and scene-dependent, which is worse than broken.
    @Test("A frame larger than one chunk is delivered whole")
    func previewChunksAFrameBiggerThanOneChunk() throws {
        let peer = try Self.peer()
        let stream = PpcpStreamRecord(
            id: "str:preview:big", sessionId: Self.sessionId,
            sourceId: "src:camera:wide", kind: PpcpStreamKind.preview,
            profileId: PpcpDeclaration.previewProfileId, timebaseId: Self.timebase,
            continuity: .continuous, openedAtNs: 0)
        try peer.openStream(stream)
        let producer = try PreviewProducer(peer: peer, stream: stream,
                                           mintId: { "cap:prev:big" })

        let oversize = Int(PayloadTransferQueue.chunkBytes) + 3_610   // a real ~35 kB frame
        let frame = Data((0 ..< oversize).map { UInt8($0 % 251) })
        #expect(try producer.deliver(endingAtNs: 100_000_000, payload: frame)
                == .sent(captureId: "cap:prev:big"))
    }

    /// A preview Stream is a *stream*: it keeps producing. ⚠ Sustained delivery
    /// is also what proves libppcp reclaims transfer entries — before
    /// `a9785bb` the 128-entry table filled and the announce after it failed
    /// with `PPCP_ERR_LIMIT`, taking capture down with it (5.11i inverted).
    @Test("Preview keeps producing well past the transfer table's size")
    func previewSustainsDelivery() throws {
        let peer = try Self.peer()
        let stream = PpcpStreamRecord(
            id: "str:preview:many", sessionId: Self.sessionId,
            sourceId: "src:camera:wide", kind: PpcpStreamKind.preview,
            profileId: PpcpDeclaration.previewProfileId, timebaseId: Self.timebase,
            continuity: .continuous, openedAtNs: 0)
        try peer.openStream(stream)
        let producer = try PreviewProducer(peer: peer, stream: stream)

        let frame = Data(repeating: 0x7f, count: 20_000)
        // Four table-fulls at ~10 fps — a minute of somebody framing a shot.
        for i in 1 ... 512 {
            _ = try producer.deliver(endingAtNs: Int64(i) * 100_000_000, payload: frame)
            _ = try peer.drain(.preview)          // the embedding takes the bytes away
            _ = try peer.drain(.control)
        }
        #expect(producer.accountedThroughNs == 512 * 100_000_000)
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

        // ⛔ **`MSG` 8.3f's SHOULD is 262144 and this is NOT it** (F-E1-1, #98).
        // The assertion used to read `== 262_144` on the grounds that the value
        // is the specification's and not a tuning parameter — which was right,
        // and which is why the deviation is asserted here rather than quietly
        // dropped: `libppcp` encodes each originated message into a 64 KiB
        // per-channel queue, so it cannot send its own specification's
        // recommendation and every clip payload failed `PPCP_ERR_NOSPACE`.
        //
        // ⚠ Pinned as an INEQUALITY, not a second copy of the constant. What
        // matters is that whatever we send is a size the engine will accept;
        // when the queue grows, `PayloadTransferQueue.chunkBytes` goes back to
        // 262144 and this still holds.
        #expect(Int(PayloadTransferQueue.chunkBytes)
                    <= SessionBundleWriter.maximumOriginableChunkBytes,
                "F-E1-1 — a chunk libppcp will not originate is #98 all over again")
    }

    /// ⛔ **A clip is read from disk once per transfer, not once per pump.**
    ///
    /// `advance` called `job.payload()` on every pass. A pass clears at most one
    /// 32 KiB chunk into libppcp's 64 KiB per-channel queue, so a 25 MB clip was
    /// read about eight hundred times — on the same actor that runs `feed`,
    /// `flush`, liveness and sync. The budget cannot fix it: the budget bounds
    /// bytes *sent*, and the read happened before any of them were.
    ///
    /// ⚠ Sibling of the `pumpReplay` defect below: both held a position or a
    /// payload as a local across a call that is designed to return part-way.
    @Test("A payload is read once per transfer, however many pumps it takes")
    func aPayloadIsReadOncePerTransfer() throws {
        let peer = try Self.peer()
        try peer.openStream(Self.videoStream)

        // Big enough that one pump cannot clear it into the engine's queue.
        let clip = Data((0..<400_000).map { UInt8($0 % 251) })
        try peer.announce(Self.shotCapture("cap:big", completeness: .complete))
        let source = ByteSource(clip)

        let queue = PayloadTransferQueue(peer: peer)
        try queue.enqueue(TransferJob(captureId: "cap:big", bytes: UInt64(clip.count),
                                      digest: SessionBundleWriter.digest(of: clip)) {
            try source.read(SessionBundle(sessionId: "s", mintingPeerId: "p",
                                          directory: URL(filePath: "/dev/null")))
        })

        var pumps = 0
        while queue.pendingCaptureIds.isEmpty == false {
            _ = try queue.pump(budgetBytes: 32 << 10)
            pumps += 1
            _ = try peer.drain(.bulk)
            #expect(pumps < 100, "the transfer made no progress")
        }

        #expect(pumps > 1, """
                the clip cleared in one pump, so this never reached the path it \
                exists for — make the fixture bigger
                """)
        #expect(source.reads == 1,
                "one read per transfer; \(pumps) pumps must not mean \(pumps) reads")
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
    /// `session_open`.
    ///
    /// ✅ F-D6-1 closed: `ppcp_peer_session_resume` exists, so this is no longer
    /// the one message assembled as a `ppcp_msg` by hand.
    ///
    /// ⛔ **The Session is opened first, and that is the clause rather than test
    /// setup.** 4.3a is about a peer "reconnecting to a Session it was previously
    /// joined to": there is no such thing as resuming a Session this peer never
    /// held, and the resume now refuses one rather than inventing a
    /// `timebase_ref` for it (5.1 — absence never means zero, applied to an
    /// identifier).
    @Test("session_resume is queued as a session_resume, with its shots and pendings")
    func sessionResumeIsWellFormed() throws {
        let peer = try Self.peer()
        try peer.openSession(PpcpSessionRecord(id: Self.sessionId,
                                               timebaseRef: Self.timebase))
        _ = try peer.drain(.control)   // the `session_open` itself
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

    /// ⛔ **`MSG` 4.3b's ORDER, which nothing asserted until 29 Aug 2026.**
    ///
    /// `sendSessionResume` — the *message* — has been tested since D6. The
    /// **sequence** had no test at all: `grep isAwaitingResyncBurst` and
    /// `grep resumeAfterLinkLoss` over both test targets returned nothing. So a
    /// refactor that resumed the queue before the burst converged would have been
    /// green, and the symptom would be shots landing on the relation that drifted
    /// through the outage — wrong timestamps in Studio, which is the last place
    /// anyone would trace back to a reconnect ordering.
    ///
    /// The clause: *"a synchronisation burst runs before any queued payload
    /// resumes"*. At 20 ppm the relation drifts about 1.2 ms per minute, so a
    /// device that spent the reconnect's bandwidth on payload first would be
    /// putting bytes on a timeline it had not re-measured.
    ///
    /// ⚠ **Driven by the clock alone** — three missed heartbeat intervals, per
    /// 7.4c, with a host peer's own `livenessPump` queueing the beats. No socket,
    /// no sleeping, no waiting.
    @Test("MSG 4.3b — session_resume goes first and no payload moves until the burst converges")
    func reconnectSendsResumeBeforeAnyPayload() throws {
        let peer = try Self.peer()
        try peer.addSyncTimebase(Self.timebase)
        try peer.openSession(PpcpSessionRecord(id: Self.sessionId,
                                               timebaseRef: Self.timebase))
        _ = try peer.drain(.control)

        // A host, only so that something legitimately originates `heartbeat` —
        // 7.4a makes it the host's message and a capture peer never sends one.
        let host = try DevicePeer(peerId: "peer:host", role: .host)
        try host.openSession(PpcpSessionRecord(id: Self.sessionId,
                                               timebaseRef: Self.timebase))
        _ = try host.drain(.control)

        func beat(at nowNs: Int64) throws {
            try host.livenessPump(nowNs: nowNs)
            _ = try peer.feed(try host.drain(.control), on: .control)
            try peer.livenessPump(nowNs: nowNs)
        }

        // ⛔ **A payload genuinely IN FLIGHT when the link goes, which is the only
        // case 4.3b is about.** The first version of this test enqueued the 1.2 kB
        // `Self.clip`, which fits in one 32 kB chunk and therefore *finished* on the
        // first pump — so `resumeAfterLinkLoss` had nothing to resume, and the test
        // passed against a deliberately reordered `resume`. Three chunks, pumped
        // with a one-chunk budget, leaves it begun and unfinished.
        try peer.openStream(Self.videoStream)
        let big = Data((0 ..< (Int(PayloadTransferQueue.chunkBytes) * 3))
            .map { UInt8($0 % 251) })
        try peer.announce(PpcpCaptureRecord(
            id: "cap:resume", anchor: .shot("sht:1"), streamId: Self.videoStream.id,
            timebaseId: Self.timebase, completeness: .complete,
            intervalNs: 1_000_000_000..<2_000_000_000, absentReason: nil,
            digest: SessionBundleWriter.digest(of: big), bytes: UInt64(big.count)),
                         isPreview: false)

        let queue = PayloadTransferQueue(peer: peer)
        try queue.enqueue(TransferJob(captureId: "cap:resume",
                                      bytes: UInt64(big.count),
                                      digest: SessionBundleWriter.digest(of: big),
                                      payload: { big }))
        _ = try queue.pump(budgetBytes: Int(PayloadTransferQueue.chunkBytes))
        // ⚠ Begun and unfinished, or `resumeAfterLinkLoss` has nothing to resume
        // and this test proves nothing — which is how it first passed.
        #expect(queue.pendingCaptureIds.contains("cap:resume"))
        _ = try peer.drain(.bulk)

        let interval = Int64(try #require(peer.sessionParameters).heartbeatIntervalMs) * 1_000_000
        #expect(interval > 0, "7.4c counts in heartbeat intervals; zero would count nothing")
        let driver = HostLinkDriver(peer: peer, timebaseId: Self.timebase)
        let t0: Int64 = 10_000_000_000

        try beat(at: t0)
        #expect(peer.isLinkLost == false)

        // 7.4c — three consecutive missed intervals, and this is the fourth.
        try peer.livenessPump(nowNs: t0 + interval * 4)
        #expect(peer.isLinkLost, "three missed intervals is a lost link")
        #expect(try driver.pump(nowNs: t0 + interval * 4) == .lost)
        #expect(driver.isAwaitingResyncBurst, "8.3f — the regime is entered for the duration")

        // The link comes back.
        let back = t0 + interval * 5
        try beat(at: back)
        #expect(peer.isLinkLost == false)
        // ⚠ **Still `.lost`, and that is `derive`'s first guard rather than a
        // defect.** 8.3g — a Session with no arbitration parameters is the
        // zero-host case, so the state machine short-circuits before reaching
        // `.resyncing`. B3's *Back* therefore needs a Session a **host** opened,
        // which this peer cannot open for itself: `ppcp_peer_session_open`
        // refuses `has_arbitration` from any peer that is not `role: host`.
        // ⛔ The reconnect MECHANISM below does not care — `isAwaitingResyncBurst`
        // is set on the transition, not on the label — and the mechanism is what
        // 4.3b is about.
        #expect(try driver.pump(nowNs: back) == .lost)
        #expect(driver.isAwaitingResyncBurst)

        _ = try peer.drain(.control)
        _ = try peer.drain(.bulk)
        let converged = try driver.resume(sessionId: Self.sessionId, peerId: Self.peerId,
                                          queue: queue, nowNs: back)

        // ⛔ Nothing is answering probes, so the burst CANNOT have converged —
        // and that is exactly the window in which payload must not move.
        #expect(converged == false)
        let control = try peer.drain(.control)
        #expect(control.isEmpty == false)
        #expect(try Self.decodeFirst(control).type == PPCP_MT_SESSION_RESUME, """
                4.3a — the FIRST thing on the wire after a reconnect is \
                session_resume, so the host learns what exists before anything large moves
                """)
        #expect(try peer.drain(.bulk).isEmpty, """
                4.3b — no payload until the burst has converged. A `payload_resume` \
                here means bytes are being put on a relation that drifted through the outage
                """)
    }

    /// 4.3a — a Session this peer never joined cannot be resumed. ⛔ The refusal
    /// is the point: the alternative is a `session_resume` carrying a
    /// `timebase_ref` nobody set, which is the silent zero I16 and 5.1 exist to
    /// prevent.
    @Test("A Session that was never opened cannot be resumed")
    func resumeWithoutASessionIsRefused() throws {
        let peer = try Self.peer()
        #expect(throws: PpcpLibraryError.self) {
            try peer.sendSessionResume(sessionId: Self.sessionId, peerId: Self.peerId,
                                       mintedShots: [], pendingCaptures: [])
        }
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

    // MARK: REQ-SYNC-4 — the per-shot residual

    /// ⛔ **The residual, and what it must never be measured against.**
    ///
    /// `sync_residual` (`MSG` 6.2) is the difference between when this device
    /// *heard* the ball and when the host says it *happened*. Both numbers
    /// existed for months and nothing subtracted them, so B3's *Checked on last
    /// impact* and C1's `sync` rail rendered "—" on every device.
    ///
    /// ⚠ **8.2i1 is the whole of this test.** A conversion with no relation
    /// answers `nil`, and a residual computed against a substituted zero is not
    /// a small residual — it is the *entire* offset between two unrelated clocks,
    /// reported as though the acoustic detector had been that wrong. It would
    /// poison exactly the series REQ-MIC-4 wants to estimate time-of-flight from.
    @Test("A residual is refused where the clocks have no relation, not zeroed")
    func residualNeedsARelation() throws {
        let peer = try Self.peer()
        try peer.addSyncTimebase(Self.timebase)

        // No exchange has happened, so there is no relation to convert through.
        #expect(peer.syncHasEstimate(Self.timebase) == false)
        let converted = try peer.instant(1_000_000_000, on: Self.timebase,
                                         expressedIn: "tb:host")
        #expect(converted == nil, """
                8.2i1 — no relation means no answer. A zero here would be \
                reported as a residual and believed
                """)

        // ⛔ **And the library does NOT refuse the wire call — checked, not
        // assumed.** `sync_residual` is accepted for a Shot in a Session that was
        // never opened, against a timebase with no relation, carrying any number
        // at all. So nothing below the application will stop a meaningless
        // residual reaching a host: the `instant(_:on:expressedIn:) == nil` guard
        // in `HostLinkSession.reportResidual` is the only thing standing between
        // 8.2i1 and a poisoned series, and it must stay there.
        #expect(throws: Never.self) {
            try peer.syncResidual(shotId: "sht:1", timebaseId: Self.timebase,
                                  residualNs: 1_000)
        }
    }

    /// The arithmetic itself, which is a subtraction and must stay one.
    ///
    /// ⚠ The Candidate's instant is **already** time-of-flight corrected
    /// (`CandidateFactory` subtracts it), which is what makes the difference a
    /// statement about the *clocks* rather than about how far away the ball was.
    /// Subtracting ToF twice would look like a residual that grew with distance.
    @Test("The residual is heard-minus-issued, in the host's own terms")
    func residualIsASubtraction() {
        // The device heard the ball at 10.000 s on its own clock; converted into
        // the host's terms that is 10.004 s; the host issued t0 at 10.000 s.
        let heardInHostTerms: Int64 = 10_004_000_000
        let issuedT0Ns: Int64 = 10_000_000_000
        let residualNs = heardInHostTerms - issuedT0Ns
        #expect(residualNs == 4_000_000)
        #expect(Double(residualNs) / 1_000_000 == 4.0, "4 ms, as B3 renders it")

        // ⚠ Signed, and the sign carries meaning: negative is this device
        // hearing the strike *before* the host placed it.
        #expect((9_996_000_000 - issuedT0Ns) == -4_000_000)
    }

    // MARK: MSG 9.1 — a replay that is interrupted, and a link that dies under one

    /// Counts how often the bundle was read, because that is the observable half
    /// of the defect below.
    final class ByteSource: @unchecked Sendable {
        let bytes: Data
        private(set) var reads = 0
        init(_ bytes: Data) { self.bytes = bytes }
        func read(_: SessionBundle) throws -> Data { reads += 1; return bytes }
    }

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
