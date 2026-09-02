//  DevicePeerLive.swift
//  The L9–L11 half of the device peer: clock synchronisation, liveness, the
//  transfer table, nomination and markup.
//
//  ⚠ **Everything here is a thin call through to `libppcp`, and that is the
//  point.** The rules these functions carry — I21's one-estimator-per-timebase,
//  I18's refusal to compose, 7.4c's three missed intervals, 8.4b's "only a
//  receiver says `confirmed`", I26's "a Candidate names a Source this peer
//  declared" — are all held inside the engine. This file allocates no policy and
//  re-checks nothing: a wrapper that re-implemented one of them would be the
//  second implementation `CONF` §2c describes, and it would drift.
//
//  ⛔ **No `ppcp_msg` is assembled by hand except where the library has no
//  originator**, and there is exactly one such message (`session_resume`, see
//  `SessionResume.swift` and F-D6-1). Every other call takes the body's own
//  struct, which is what `message.h` asks a Swift caller to prefer.
//
//  Spec: `CORE` §5.12, §5.18, §6.3, §7.4, §8.2–8.4, §5.14f–g; `MSG` §4.3, §5.4,
//  §6, §7, §8, §9.0–9.2. Plan D5, D6, D8.

import Foundation
import CPPCP

// MARK: - Reading a `ppcp_id`

/// A `ppcp_id` is a fixed `char[65]` with a length, not a C string: it may carry
/// bytes that are not valid UTF-8 (`RV` §5.3 relies on exactly that for PSK
/// identities), so it is decoded by length and never with `String(cString:)`.
func ppcpString(_ id: ppcp_id) -> String {
    var value = id
    return withUnsafeBytes(of: &value.v) { raw in
        String(decoding: raw.prefix(Int(value.len)), as: UTF8.self)
    }
}

/// ⚠ `present: false` is **not** thirty-two zero bytes. `CORE` 5.1: absence never
/// means zero, and a digest of all zeros is a value a receiver could compare
/// against.
func ppcpDigestData(_ digest: ppcp_digest) -> Data? {
    guard digest.present else { return nil }
    var value = digest
    return withUnsafeBytes(of: &value.value) { Data($0) }
}

// MARK: - Detect (CORE §5.12, MSG §7)

public extension DevicePeer {

    /// `MSG` 7.1 — `candidate`. **Every** nomination, winners and losers alike
    /// (7.1d, I8): withholding one a detector did not believe destroys the only
    /// evidence that explains why detection fired.
    ///
    /// ⛔ I26 / 5.12a is checked by the library before a wire sees it — the
    /// `source_id` must name a Source **this peer declared**, on a Timebase it
    /// declared, with `at` expressed in that timebase. This wrapper does not
    /// re-check it; `ppcp_peer_nominate` refuses.
    func nominate(_ candidate: PpcpCandidate) throws {
        let peer = try handleForLive()
        try candidate.withValue { try check(ppcp_peer_nominate(peer, $0)) }
    }

    /// `MSG` 7.2 — `shot`. Sent immediately on minting (8.2j), so a counterpart
    /// learns of it without waiting for a payload.
    func send(shot: PpcpShot) throws {
        var value = shot.value
        try check(ppcp_peer_shot(try handleForLive(), &value))
    }

    /// `MSG` 9.3 — `shot_link`. A **Core** message: 8.3f reconciles a Shot minted
    /// during a link outage this way, and 9.3g makes it assertable by peers that
    /// implement no bundle handling at all.
    func send(shotLink: PpcpShotLink) throws {
        var value = shotLink.value
        try check(ppcp_peer_shot_link(try handleForLive(), &value))
    }

    /// `CORE` 8.4b / `MSG` 7.3b — the answer to a `capture_request` for an
    /// interval the ring no longer holds.
    ///
    /// ⛔ **Not an `error`.** "An absent capture is a result, not a failure"
    /// (I10): absence is asserted by the owner, never inferred by a receiver from
    /// a payload that did not arrive.
    func captureAbsent(captureId: String, shotId: String, streamId: String,
                       reason: String = PpcpAbsentReason.outsideBuffer,
                       inReplyTo: UInt64) throws {
        try check(ppcp_peer_capture_absent(try handleForLive(), captureId, shotId,
                                           streamId, reason, inReplyTo))
    }
}

// MARK: - Markup (CORE §5.18, MSG §9.0)

public extension DevicePeer {

    /// `MSG` 9.0a — `annotation`, and it is the **only** content in PPCP that
    /// travels in either direction. Markup confers it; a peer that has not
    /// declared Markup is refused by C2 inside the library.
    func annotate(_ annotation: PpcpAnnotation) throws {
        try annotation.withValue { value in
            try check(ppcp_peer_annotate(try handleForLive(), value))
        }
    }
}

// MARK: - Clock synchronisation (CORE §6.3, MSG §6)

public extension DevicePeer {

    /// I21 / 6.1d — **one probe sequence per local timebase**, each relation
    /// declared directly. ⛔ There is no composition anywhere in this path: a peer
    /// needing A→C measures it, and 5.4c forbids deriving it from A→B and B→C.
    ///
    /// - Parameter remoteTimebaseId: `nil` is the ordinary case — 6.1b says a
    ///   prober does not know which clock a responder stamps on until the first
    ///   `sync_reply` says so.
    func addSyncTimebase(_ localTimebaseId: String,
                         remote remoteTimebaseId: String? = nil) throws {
        try check(ppcp_peer_sync_add_timebase(try handleForLive(), localTimebaseId,
                                              remoteTimebaseId))
    }

    var syncTimebaseCount: Int { peerHandle.map(ppcp_peer_sync_count) ?? 0 }

    /// Queues one `sync_probe` on `localTimebaseId`, reading `t1` from the clock
    /// this peer was built with.
    func syncProbe(_ localTimebaseId: String) throws {
        try check(ppcp_peer_sync_probe(try handleForLive(), localTimebaseId))
    }

    /// 6.1c — the accurate path. An embedding that can stamp closer to the socket
    /// than a clock read at decode time supplies all four timestamps itself.
    ///
    /// ⚠ On `Network.framework` "closer to the socket" is `NWConnection`'s receive
    /// completion handler, which is the earliest point the application can reach.
    /// The residence time between the kernel and that handler is *included* in the
    /// measurement, and the honest consequence is a wider `offset_sigma_ns`, never
    /// a corrected one.
    func syncObserve(_ localTimebaseId: String,
                     t1: Int64, t2: Int64, t3: Int64, t4: Int64) throws {
        try check(ppcp_peer_sync_observe(try handleForLive(), localTimebaseId,
                                         t1, t2, t3, t4))
    }

    /// Erratum E2 — a probe **aimed at a named responder clock**.
    ///
    /// ⚠ `sync_probe.timebase_id` names the responder's clock, and a responder
    /// that declares it answers on it. Sequences are keyed on the **pair**, so a
    /// local clock probing two remote ones is two sequences, two estimators and
    /// two directly-declared relations — I21 and 5.4.1a, with nothing composed
    /// (I18). ⛔ The single-remote `addSyncTimebase` remains correct for this
    /// device, which has one clock and meets hosts that have one.
    func addSyncTarget(_ localTimebaseId: String, remote remoteTimebaseId: String) throws {
        try check(ppcp_peer_sync_add_target(try handleForLive(), localTimebaseId,
                                            remoteTimebaseId))
    }

    func syncProbe(_ localTimebaseId: String, to remoteTimebaseId: String) throws {
        try check(ppcp_peer_sync_probe_to(try handleForLive(), localTimebaseId,
                                          remoteTimebaseId))
    }

    func syncObserve(_ localTimebaseId: String, to remoteTimebaseId: String,
                     t1: Int64, t2: Int64, t3: Int64, t4: Int64) throws {
        try check(ppcp_peer_sync_observe_to(try handleForLive(), localTimebaseId,
                                            remoteTimebaseId, t1, t2, t3, t4))
    }

    /// ✅ **F-D6-2 closed** (`libppcp` `e52647e`) — 6.1c on the **responder**
    /// side.
    ///
    /// The prober has always had `ppcp_peer_sync_observe`; the responder had
    /// nothing, so the engine read its clock while *decoding* the probe — later
    /// than reception by however long the bytes sat in a buffer — and again while
    /// building the reply, earlier than transmission. The residence time this
    /// device could have removed was folded into the measurement instead.
    ///
    /// ⚠ **Call this immediately before the `feed` carrying the probe.** The
    /// stamps apply to the next probe answered and are then forgotten, so a call
    /// that turns out to carry no probe costs nothing — which is what makes it
    /// safe to stamp every socket read.
    func syncReplyStamps(t2Ns: Int64, t3Ns: Int64) throws {
        try check(ppcp_peer_sync_reply_stamps(try handleForLive(), t2Ns, t3Ns))
    }

    /// 6.1c's escape, **made expressible**: a responder that cannot distinguish
    /// reception from transmission sets `t3 == t2` and *by doing so declares* that
    /// residence time is included rather than removed.
    ///
    /// ⛔ A **setting**, not two clock reads that happened to agree — that is the
    /// distinction the finding was about, and it is why this is a property of the
    /// implementation rather than a value passed per probe.
    func setZeroResidence(_ on: Bool) throws {
        try check(ppcp_peer_sync_set_zero_residence(try handleForLive(), on))
    }

    var zeroResidence: Bool {
        peerHandle.map(ppcp_peer_sync_zero_residence) ?? false
    }

    /// 6.3c — a burst of 10–20 exchanges on connect, after a network change, and
    /// after a thermal event. A thermal event restarts the estimator's window as
    /// well: oscillator frequency shifts with temperature, so the **fit** is stale
    /// and not merely the offset.
    enum SyncTrigger: Sendable, Hashable {
        case connect, networkChange, thermalEvent

        var c: ppcp_sync_trigger {
            switch self {
            case .connect: PPCP_SYNC_ON_CONNECT
            case .networkChange: PPCP_SYNC_ON_NETWORK_CHANGE
            case .thermalEvent: PPCP_SYNC_ON_THERMAL_EVENT
            }
        }
    }

    func syncTrigger(_ why: SyncTrigger) throws {
        try check(ppcp_peer_sync_trigger(try handleForLive(), why.c))
    }

    /// Queues whatever is due — burst probes and the maintenance probe of 6.3g.
    ///
    /// ⛔ 6.3d — this cadence is the **sync** cadence, and nothing in it consults
    /// `heartbeat_interval_ms`. Liveness has its own pump.
    @discardableResult
    func syncPump(nowNs: Int64) throws -> Int {
        var probes = 0
        try check(ppcp_peer_sync_pump(try handleForLive(), nowNs, &probes))
        return probes
    }

    /// 6.1f — publishes the current estimate for every registered timebase that
    /// has one, as a single `relation_update`. Filtered, never stepped (6.3e).
    @discardableResult
    func publishRelations() throws -> Int {
        var count = 0
        try check(ppcp_peer_publish_relations(try handleForLive(), &count))
        return count
    }

    /// The general form: a relation this peer measured itself and the wire never
    /// carried — a device's camera-to-microphone mapping, for instance.
    func publish(relations: [ppcp_timebase_relation]) throws {
        guard relations.isEmpty == false else { return }
        var values = relations
        let peer = try handleForLive()
        try values.withUnsafeBufferPointer { buffer in
            try check(ppcp_peer_relation_update(peer, buffer.baseAddress, buffer.count))
        }
    }

    /// `MSG` 6.2 / `CORE` 6.3h — the per-shot residual between this peer's
    /// acoustic fiducial and its network clock estimate.
    func syncResidual(shotId: String, timebaseId: String,
                      residualNs: Int64, basis: String = "acoustic") throws {
        try check(ppcp_peer_sync_residual(try handleForLive(), shotId, timebaseId,
                                          residualNs, basis))
    }

    /// Whether an estimator for `localTimebaseId` has produced offset **and**
    /// rate. ⚠ 6.3a: a one-shot handshake does not satisfy the requirement, and
    /// the library reports `NOT_FOUND` rather than an optimistic relation until
    /// two exchanges separated in time exist.
    func syncHasEstimate(_ localTimebaseId: String) -> Bool {
        guard let peer = peerHandle,
              let estimator = ppcp_peer_sync_estimator_for(peer, localTimebaseId)
        else { return false }
        return ppcp_sync_estimator_has_estimate(estimator)
    }

    /// The exchanges folded into `localTimebaseId`'s estimator so far — what B3's
    /// "twenty round trips" progress row is counting.
    func syncExchangeCount(_ localTimebaseId: String) -> Int {
        guard let peer = peerHandle,
              let estimator = ppcp_peer_sync_estimator_for(peer, localTimebaseId)
        else { return 0 }
        return ppcp_sync_estimator_count(estimator)
    }

    /// The relation `localTimebaseId` currently estimates, or `nil` before 6.3a is
    /// satisfied.
    func syncRelation(_ localTimebaseId: String) -> ppcp_timebase_relation? {
        guard let peer = peerHandle,
              let estimator = ppcp_peer_sync_estimator_for(peer, localTimebaseId)
        else { return nil }
        var relation = ppcp_timebase_relation()
        guard ppcp_sync_estimator_relation(estimator, &relation) == PPCP_OK else { return nil }
        return relation
    }

    /// The relations this peer holds. ⛔ Mutable on purpose — an embedding that
    /// measured a relation the wire never carried puts it here — but nothing in it
    /// composes: `ppcp_relations_convert` applies **at most one** relation and
    /// refuses when it holds no direct one (I18, 5.4c, 8.2i1).
    func withRelations<T>(_ body: (UnsafeMutablePointer<ppcp_relation_set>) throws -> T)
        throws -> T {
        guard let peer = peerHandle, let relations = ppcp_peer_relations(peer) else {
            throw PpcpLibraryError(PPCP_ERR_INVALID)
        }
        return try body(relations)
    }

    /// An instant on one of this peer's clocks, expressed in another.
    ///
    /// ⛔ **The call a Mint pump needs, and the reason it exists here rather than
    /// in the app layer.** 5.13c puts `Shot.t0` in `Session.timebase_ref`, which
    /// with a host is the *host's* clock; 8.2i's deadline is therefore read in a
    /// timebase this device does not own. Doing the conversion at the call site
    /// would need `ppcp_instant` above `CaptureCore`, and the `import CPPCP` fence
    /// is worth more than the two lines it saves.
    ///
    /// - Returns: `nil` where the instant cannot be expressed — no relation, or an
    ///   `unrelated` one. ⛔ **Never a zero offset substituted to make it
    ///   expressible** (5.4b, 8.2i1): a peer that cannot say when now is does not
    ///   mint, and the Candidates stay retained.
    func instant(_ nowNs: Int64, on from: String, expressedIn to: String) throws -> Int64? {
        // I4 — the identity is a shared id, not a relation, so it needs no
        // conversion and asserts none.
        guard from != to else { return nowNs }
        var instant = ppcp_instant()
        try check(ppcp_instant_make_z(&instant, from, nowNs))
        return try convert(instant, to: to)?.ns
    }

    /// The one relation `instant` would apply for `from` → `to`, or `nil` where
    /// the set holds none. ⚠ For diagnostics: a conversion that landed in the
    /// wrong place is explained by the relation it went through — its offset,
    /// its slope, and above all **how long ago it was observed**, because
    /// `ppcp_relation_apply` extrapolates the slope from `observed_at`.
    func relation(from: String, to: String) throws -> ppcp_timebase_relation? {
        var fromId = ppcp_id(), toId = ppcp_id()
        try check(ppcp_id_set_z(&fromId, from))
        try check(ppcp_id_set_z(&toId, to))
        return try withRelations { relations in
            ppcp_relations_find(relations, &fromId, &toId).map { $0.pointee }
        }
    }

    /// `CORE` 5.4's uncertainty of expressing `nowNs` in `to`, in nanoseconds:
    /// the offset sigma and the skew sigma grown over the interval since the
    /// relation was observed. `nil` where there is no relation to evaluate.
    func sigmaNs(_ nowNs: Int64, on from: String, expressedIn to: String) throws -> Double? {
        guard from != to else { return 0 }
        var instant = ppcp_instant()
        try check(ppcp_instant_make_z(&instant, from, nowNs))
        var toId = ppcp_id()
        try check(ppcp_id_set_z(&toId, to))
        return try withRelations { relations in
            var sigma = 0.0
            let result = ppcp_relations_sigma_ns(relations, &instant, &toId, &sigma)
            if result == PPCP_ERR_NOT_FOUND || result == PPCP_ERR_INVALID { return nil }
            try check(result)
            return sigma
        }
    }

    /// 8.2i1's test, one call. `nil` where the instant cannot be expressed in
    /// `to` — no relation, or an `unrelated` one — and ⛔ **never a zero offset
    /// substituted to make it expressible** (5.4b).
    func convert(_ instant: ppcp_instant, to timebaseId: String) throws -> ppcp_instant? {
        var to = ppcp_id()
        try check(ppcp_id_set_z(&to, timebaseId))
        return try withRelations { relations in
            var input = instant
            var output = ppcp_instant()
            let result = ppcp_relations_convert(relations, &input, &to, &output)
            if result == PPCP_ERR_NOT_FOUND || result == PPCP_ERR_INVALID { return nil }
            try check(result)
            return output
        }
    }
}

// MARK: - Liveness (CORE §7.4, §8.3g, MSG §5.4)

public extension DevicePeer {

    /// Drives liveness from the embedding's clock, because the library owns no
    /// timer. Call at least once per heartbeat interval.
    ///
    /// ⚠ A **capture** peer never originates `heartbeat` — 7.4a makes it the
    /// host's — but it still pumps, because three missed intervals is a conclusion
    /// this peer reaches about the host and not one the host tells it.
    func livenessPump(nowNs: Int64) throws {
        try check(ppcp_peer_liveness_pump(try handleForLive(), nowNs))
    }

    /// 7.4c — `lost` after three consecutive missed intervals.
    var isLinkLost: Bool { peerHandle.map { ppcp_peer_link_state($0) == PPCP_LINK_LOST } ?? false }

    var missedHeartbeats: Int {
        Int(peerHandle.map(ppcp_peer_missed_heartbeats) ?? 0)
    }

    /// 8.3g — "a Session with an unreachable host is not a Session with no host".
    /// True when this peer must mint under 8.3a–c: either the Session has no host
    /// in its roster, or the host has been unreachable for three heartbeat
    /// intervals.
    var isZeroHost: Bool { peerHandle.map(ppcp_peer_zero_host) ?? true }

    /// `MSG` 4.1a1 / 9.1b (erratum E28) — the **imported** Session, where one has
    /// been replayed onto this link, and `nil` where none has.
    ///
    /// ⛔ **The live Session's own identity and `timebase_ref` are untouched by an
    /// import**, which is what `CORE` 4.1a and I16 require and what F-S5-3 found
    /// them not to be: a replayed `session_open` naming a different Session used
    /// to rebind the live one, so every subsequent `t0` came out in the exporting
    /// device's clock. An instant on an imported frame is expressed in
    /// `importedTimebaseRefId` and in nothing else.
    var importedSessionId: String? {
        guard let peer = peerHandle, let id = ppcp_peer_imported_session_id(peer) else {
            return nil
        }
        return ppcpString(id.pointee)
    }

    var importedTimebaseRefId: String? {
        guard let peer = peerHandle,
              let id = ppcp_peer_imported_timebase_ref(peer) else { return nil }
        return ppcpString(id.pointee)
    }

    /// I16 / 8.3g — the Session parameters as they arrived, **unchanged** by the
    /// link doing anything. `nil` before a `session_open`.
    var sessionParameters: PpcpSessionParameters? {
        guard let peer = peerHandle, let params = ppcp_peer_session_params(peer) else {
            return nil
        }
        return PpcpSessionParameters(params.pointee)
    }
}

/// The two arbitration parameters and the reference timebase, read back exactly
/// as `session_open` carried them.
///
/// ⛔ **A tolerance and a deadline are different quantities** (`CORE` 8.2):
/// `coincidenceWindowNs` answers "are these two nominations the same event?";
/// `issueHoldNs` answers "how long do I wait before deciding?". Collapsing them
/// into one number forces a host to choose between a tolerance that is too wide
/// and a hold that is too short.
public struct PpcpSessionParameters: Sendable, Hashable {
    public let sessionId: String
    public let timebaseRefId: String
    public let hasArbitration: Bool
    public let coincidenceWindowNs: Int64
    public let issueHoldNs: Int64
    public let heartbeatIntervalMs: UInt32

    init(_ body: ppcp_body_session_open) {
        sessionId = ppcpString(body.session_id)
        timebaseRefId = ppcpString(body.timebase_ref)
        hasArbitration = body.has_arbitration
        coincidenceWindowNs = body.coincidence_window_ns
        issueHoldNs = body.issue_hold_ns
        // `CORE` 7.4a — the default is 1000 ms, and it is the *protocol's*
        // default rather than one invented here.
        heartbeatIntervalMs = body.has_heartbeat_interval
            ? body.heartbeat_interval_ms
            : UInt32(PPCP_DEFAULT_HEARTBEAT_MS)
    }
}

// MARK: - The transfer table (CORE §5.14f–g, MSG §8)

/// One row of the **owner's** view of where a Capture's payload has got to.
///
/// ⛔ `confirmed` is reachable only through a `capture_committed` that arrived
/// (8.4b). The library has no function that sets it, which is why
/// `ShotSyncState.inStudio` cannot be produced by optimism.
public struct PpcpTransferRow: Sendable, Hashable {
    public let captureId: String
    public let streamId: String
    public let completeness: PpcpCaptureRecord.Completeness
    public let state: ShotSyncState
    public let bytes: UInt64?
    public let ackedIndex: UInt32?
    /// 5.14g exit 3 — the receiver answered `payload_abort`/`already_present`,
    /// which for eviction is equivalent to a commit.
    public let alreadyPresent: Bool
    /// 5.14g exit 4 — **the protocol** permitted the owner to shed it.
    public let shedPermitted: Bool
    /// 5.11j — a preview Capture is live-only and is never queued.
    public let isPreview: Bool

    init(_ entry: ppcp_transfer_entry) {
        captureId = ppcpString(entry.capture_id)
        streamId = ppcpString(entry.stream_id)
        completeness = switch entry.completeness {
        case PPCP_PARTIAL: .partial
        case PPCP_ABSENT: .absent
        default: .complete
        }
        state = switch entry.transfer {
        case PPCP_TRANSFER_IN_FLIGHT: .sending(progress: 0)
        case PPCP_TRANSFER_PRESENT: .delivered
        case PPCP_TRANSFER_CONFIRMED: .inStudio
        case PPCP_TRANSFER_FAILED: .failed
        default: .onDevice
        }
        bytes = entry.has_bytes ? entry.bytes : nil
        ackedIndex = entry.has_acked_index ? entry.acked_index : nil
        alreadyPresent = entry.already_present
        shedPermitted = entry.shed_permitted
        isPreview = entry.preview
    }
}

public extension DevicePeer {

    /// The owner's transfer table, read-only. The transitions are the origination
    /// functions and the messages that arrive, and there is no setter here.
    var transfers: [PpcpTransferRow] {
        guard let peer = peerHandle, let table = ppcp_peer_transfers(peer) else { return [] }
        let count = ppcp_transfer_table_count(table)
        var rows: [PpcpTransferRow] = []
        rows.reserveCapacity(count)
        var value = table.pointee
        withUnsafeBytes(of: &value.entries) { raw in
            let base = raw.bindMemory(to: ppcp_transfer_entry.self)
            for index in 0..<count { rows.append(PpcpTransferRow(base[index])) }
        }
        return rows
    }

    func transfer(of captureId: String) -> PpcpTransferRow? {
        transfers.first { $0.captureId == captureId }
    }

    /// ⛔ **I38 / 5.14g, and it is the library's predicate rather than this
    /// application's.** Four exits and no fifth: `confirmed`, `absent`,
    /// `already_present`, or a clause of the specification that permitted the
    /// owner to shed it. A retention policy is **not** an exit (5.14g1), and a
    /// peer under storage pressure refuses to arm rather than dropping swings.
    ///
    /// ⚠ `ppcp_capture_is_evictable` exists too and answers over the entity alone,
    /// so it knows only exits 1 and 2. It is **not** the predicate an owner uses
    /// before deleting a file; this one is.
    func isEvictable(captureId: String) -> Bool {
        guard let peer = peerHandle, let table = ppcp_peer_transfers(peer) else { return false }
        var id = ppcp_id()
        guard ppcp_id_set_z(&id, captureId) == PPCP_OK else { return false }
        return ppcp_transfer_is_evictable(table, &id)
    }

    /// `MSG` 8.3 — the acknowledgement a **receiver** sends per chunk. On the
    /// device this travels the other way only when the device is receiving, which
    /// it does for nothing today; it is here because a bundle replay is a transfer
    /// and the shape has to exist on both sides.
    func payloadAck(captureId: String, index: UInt32, channel: PpcpChannel = .bulk) throws {
        try check(ppcp_peer_payload_ack(try handleForLive(), channel.rawValue,
                                        captureId, index))
    }

    func payloadAbort(captureId: String, reason: String,
                      channel: PpcpChannel = .bulk) throws {
        try check(ppcp_peer_payload_abort(try handleForLive(), channel.rawValue,
                                          captureId, reason))
    }

    /// 8.3d — resumption restarts from the chunk **after** the last acknowledged
    /// index, never from the beginning.
    func payloadResume(captureId: String, fromIndex: UInt32,
                       channel: PpcpChannel = .bulk) throws {
        try check(ppcp_peer_payload_resume(try handleForLive(), channel.rawValue,
                                           captureId, fromIndex))
    }
}

// MARK: - Partial writes (the socket path)

public extension DevicePeer {

    /// ⚠ **`drain` dequeues, and a socket does not always take what it is given.**
    /// Under `CORE` T2 backpressure a write returns short and the bytes it did not
    /// take are bytes `drain` has already forgotten. This is the pair a socket
    /// wants: peek at what is queued, write what the socket accepts, commit
    /// exactly that many bytes.
    ///
    /// ⛔ `commit` removes exactly the byte count it is given, **not** a whole
    /// number of frames: a channel is an ordered byte stream and half a frame on
    /// the wire is half a frame the peer will reassemble.
    func drainPeek(_ channel: PpcpChannel) throws -> Data {
        guard let peer = peerHandle else { return Data() }
        var base: UnsafePointer<UInt8>?
        var length = 0
        let result = ppcp_peer_drain_peek(peer, channel.rawValue, &base, &length)
        if result == PPCP_ERR_NOT_FOUND { return Data() }
        try check(result)
        guard let base, length > 0 else { return Data() }
        return Data(bytes: base, count: length)
    }

    func drainCommit(_ channel: PpcpChannel, written: Int) throws {
        guard written > 0 else { return }
        try check(ppcp_peer_drain_commit(try handleForLive(), channel.rawValue, written))
    }

    /// True when the head of this channel's queue is mid-frame — the state a short
    /// write leaves behind, and the state `drain` refuses rather than handing out
    /// a fragment it would describe as a frame.
    func drainIsPartial(_ channel: PpcpChannel) -> Bool {
        peerHandle.map { ppcp_peer_drain_is_partial($0, channel.rawValue) } ?? false
    }
}

// MARK: - Offering a stored Session (MSG §9.1–9.2)

public extension DevicePeer {

    /// `MSG` 9.1 — the device offers a Session it holds. ⛔ **Not a file picker.**
    /// The user-facing flow is that a *connected* device offers what it has and
    /// the host chooses (plan §9, 22 August 2026); there is no import path from a
    /// document browser anywhere in this application.
    func offer(_ offer: PpcpSessionOffer) throws {
        var body = offer.value
        try check(ppcp_peer_session_offer(try handleForLive(), &body))
    }

    /// The host's half, here because `CaptureCore` hosts both roles in-process for
    /// the loopback tests until `ppcp-sim` (L13) exists.
    func accept(_ accept: PpcpSessionAccept, inReplyTo: UInt64) throws {
        try accept.withValue { body in
            try check(ppcp_peer_session_accept(try handleForLive(), body, inReplyTo))
        }
    }
}

// MARK: - Shared plumbing

extension DevicePeer {

    /// The engine handle, or a refusal. ⚠ Named apart from the private `handle()`
    /// inside `DevicePeer` because an extension cannot see it.
    func handleForLive() throws -> OpaquePointer {
        guard let peer = peerHandle else { throw PpcpLibraryError(PPCP_ERR_INVALID) }
        return peer
    }
}
