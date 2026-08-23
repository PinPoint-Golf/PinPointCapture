//  PeerLinkPump.swift
//  The thing D2–D6 never had: bytes moving between a `PeerTransport` and a
//  `ppcp_peer`.
//
//  ⚠ **Every suite before S4 fed the engine by hand.** `DevicePeer` had `feed`,
//  `drain`, `drainPeek` and `drainCommit`, `PpcpTransport` had a TLS link, and
//  nothing in the application joined them: a test wrote `try a.feed(try b.drain(.control))`
//  and called that a link. That is why `AppModel` could compose a hostless session
//  and not a hosted one, and why D9's harness is the first place a device peer
//  meets a counterpart it did not build.
//
//  ⛔ **`drainPeek` / write / `drainCommit`, never `drain`.** `CORE` T2 makes the
//  transport's backpressure real: `ByteChannel.send` does not return until the
//  bytes are taken, and a short write on a socket that took fewer would be bytes
//  `drain` has already forgotten. The peek/commit pair is the library's answer to
//  exactly that and it is the only pair used here.
//
//  ⛔ **One frame at a time into the engine.** `DevicePeer.feed` already walks the
//  buffer frame by frame (F-L13-1); this class hands it whatever the socket
//  returned and re-presents the tail, because `ENC` §3 is length-prefixed and TCP
//  is free to split a frame anywhere.
//
//  ⚠ **The pumps are separate and stay separate** (`CORE` 6.3d): liveness has its
//  own cadence and sync has its own, and this drives both from one tick without
//  letting either set the other's rate — `livenessPump` and `syncPump` decide for
//  themselves what is due.
//
//  Spec: `CORE` §3 (T1–T5), §6.3, §7.4; `ENC` §2.1, §3; `MSG` §5.4, §6. Plan D9.

import Foundation
import CPPCP

/// What arrived on a link, in the vocabulary this application reasons in.
///
/// ⚠ **Translated rather than passed through.** `ppcp_event` carries a borrowed
/// `ppcp_msg` whose nested pointers live four events at most (`peer.h`), and a C
/// union member read the obvious way costs a 48 KB stack temporary (F-D3-1). So
/// the few fields this application acts on are lifted out while the pointer is
/// alive and everything else is reported by name. ⛔ The consequence is
/// deliberate: an event this enum does not name is an event the app cannot act
/// on, which is a smaller failure than one it acts on from a dangling pointer.
public enum PeerLinkEvent: Sendable, Hashable {
    case hello
    case connected(version: String?)
    /// `MSG` 3.3 — the counterpart declared. ⚠ Only its `Peer.id`: the nested
    /// Sources point into the engine's arena and are valid only until it declares
    /// again (3.3a), so nothing here holds them.
    case declared(peerId: String)
    /// `MSG` 4.1 — read `sessionParameters` for the arbitration parameters (I16).
    case sessionOpened(sessionId: String)
    case sessionJoined(sessionId: String)
    case sessionClosed(reason: String?)
    case streamOpened(streamId: String)
    /// `CORE` 5.2a / `MSG` 5.2a — answer with a Readiness **measurement**.
    case armRequested
    case disarmRequested
    /// `CORE` 8.4 — answer it, and never with an `error` (I10).
    case captureRequested(shotId: String, streamIds: [String],
                          preNs: Int64, postNs: Int64, replyTo: UInt64)
    case candidateReceived(id: String)
    case shotReceived(id: String)
    case sessionOffered(PpcpSessionOffer)
    case sessionAccepted(PpcpSessionAccept)
    /// 7.4c — three consecutive missed intervals. ⛔ Capture does not stop (7.4d).
    case linkLost
    case linkRestored
    case heartbeat
    case sync
    case relationUpdate
    case payload
    case capture
    /// `MSG` 10 — `code` is safe to show; ⛔ nothing else about it is (`RV` 7.2b).
    ///
    /// ⚠ **Whether it was fatal is not carried, because this cannot know.**
    /// `ppcp_body_error` has no such field: `peer.h` puts it on `ppcp_event.status`,
    /// which `DevicePeer.nextEvent` does not expose. Reporting a guess would be
    /// worse than reporting the code alone.
    case protocolError(code: String)
    /// `MSG` 1b / I13 — carried, not dropped, and not fatal.
    case unknownMessage(type: String)
    /// Anything this application does not act on, by its `ppcp_event_kind`.
    case other(kind: Int32)
    /// The transport went away. ⛔ Not a protocol event: it is the socket, and it
    /// is reported apart so a screen can tell "the host said goodbye" from "the
    /// Wi-Fi dropped" without reading a log.
    case transportClosed(ChannelCloseReason)
}

/// Drives one `DevicePeer` over one `PeerTransport`.
///
/// ⚠ **An actor, and the peer never leaves it.** `DevicePeer` is
/// `@unchecked Sendable` over a C engine with no internal locking, so every call
/// into it has to be serialised by something. This is that something, and
/// `perform` is the only door.
public actor PeerLinkPump {

    /// `CORE` 7.4a — the protocol's own default heartbeat interval, which is the
    /// coarsest this may tick and still notice three missed ones.
    public static let defaultTickIntervalNs: Int64 = 100_000_000

    private let peer: DevicePeer
    private let transport: any PeerTransport
    /// A reading of the timebase the engine's clock is on. ⚠ Injected rather than
    /// read here: `CaptureCore` owns no clock (ground rule 8), and the one the
    /// engine stamps with is the embedding's choice (`CORE` 6.1b).
    private let nowNs: @Sendable () -> Int64

    private var tasks: [Task<Void, Never>] = []
    /// ⚠ **Unbounded, and deliberately.** A dropped event is a `session_open`
    /// nobody acted on, which is F-L13-1 arriving one layer higher; the engine
    /// now applies backpressure rather than dropping (L15) and this must not
    /// undo that by dropping instead.
    private var pending: [PeerLinkEvent] = []
    private var isFlushing = false
    private var flushAgain = false
    private var stopped = false

    public init(peer: DevicePeer, transport: any PeerTransport,
                nowNs: @escaping @Sendable () -> Int64) {
        self.peer = peer
        self.transport = transport
        self.nowNs = nowNs
    }

    /// Everything that has arrived since the last call, in arrival order.
    ///
    /// ⚠ **A drained queue rather than an `AsyncStream`**, because the consumer
    /// has to be able to call back into the peer between two events — answer an
    /// `arm`, open a Stream on a `session_open` — and an iterator that cannot
    /// cross an isolation boundary makes that awkward at exactly the point it
    /// matters. Taking a batch and acting on it is the shape the caller wants.
    public func takeEvents() -> [PeerLinkEvent] {
        harvest()
        let taken = pending
        pending.removeAll(keepingCapacity: true)
        return taken
    }

    /// Waits until an event is available or `seconds` elapse, then takes what
    /// there is. ⛔ An empty result is normal: a counterpart that says nothing is
    /// a scenario (`silent-host`), and a local deadline is the only thing that
    /// fires in it.
    public func takeEvents(waitingUpTo seconds: Double) async -> [PeerLinkEvent] {
        let deadline = Date().addingTimeInterval(seconds)
        while pending.isEmpty, stopped == false, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            harvest()
        }
        return takeEvents()
    }

    /// What this link negotiated (`RV` 5.4k).
    public nonisolated var security: NegotiatedSecurity { transport.security }

    // MARK: Running

    /// Starts the receive loops and the tick.
    ///
    /// - Parameter tickIntervalNs: how often liveness and sync are pumped. ⛔ Not
    ///   the heartbeat interval and not the sync cadence — both of those are the
    ///   library's, read from the Session (6.3d). This is only how often it is
    ///   asked.
    public func start(tickIntervalNs: Int64 = PeerLinkPump.defaultTickIntervalNs) {
        guard tasks.isEmpty, stopped == false else { return }
        for channel in channels() {
            tasks.append(Task { [weak self] in await self?.receiveLoop(channel) })
        }
        tasks.append(Task { [weak self] in
            while let self, await self.isRunning {
                await self.tickOnce()
                try? await Task.sleep(for: .nanoseconds(tickIntervalNs))
            }
        })
    }

    private var isRunning: Bool { stopped == false }

    private func channels() -> [any ByteChannel] {
        var found: [any ByteChannel] = [transport.control, transport.bulk]
        if let preview = transport.preview { found.append(preview) }
        return found
    }

    /// Attaches a `preview` channel that bound after the link came up
    /// (`ENC` 2.1d), so its bytes reach the engine like any other channel's.
    public func attachPreview(_ channel: any ByteChannel) {
        guard stopped == false else { return }
        tasks.append(Task { [weak self] in await self?.receiveLoop(channel) })
    }

    public func stop(_ reason: ChannelCloseReason = .normal) async {
        guard stopped == false else { return }
        stopped = true
        for task in tasks { task.cancel() }
        tasks.removeAll()
        await transport.close(reason)
        pending.append(.transportClosed(reason))
    }

    // MARK: The peer

    /// The only way to touch the engine. ⚠ Serialised by this actor, and the
    /// pending frames are pushed to the socket afterwards, so a caller never has
    /// to remember to flush.
    @discardableResult
    public func perform<T: Sendable>(_ body: @Sendable (DevicePeer) throws -> T) async throws -> T {
        let result = try body(peer)
        harvest()
        try await flush()
        return result
    }

    /// One tick: liveness, sync, then whatever they queued.
    public func tickOnce() async {
        guard stopped == false else { return }
        let now = nowNs()
        // ⛔ Failures are reported, not thrown out of a background task where
        // nothing could catch them. A peer that has closed stops answering and
        // `stop()` is what ends the loop.
        do {
            try peer.livenessPump(nowNs: now)
            try peer.syncPump(nowNs: now)
        } catch {
            harvest()
            return
        }
        harvest()
        try? await flush()
    }

    // MARK: Bytes in

    private func receiveLoop(_ channel: any ByteChannel) async {
        var residue = Data()
        while stopped == false, Task.isCancelled == false {
            let arrived: Data?
            let arrivedAtNs: Int64
            do {
                arrived = try await channel.receive()
                // `t2` — the first instant this application can observe.
                arrivedAtNs = nowNs()
            } catch is CancellationError {
                return
            } catch {
                await stop(.failed(String(describing: error)))
                return
            }
            guard let arrived else {
                // A clean end of stream on channel 0 is the counterpart leaving.
                if channel.channel == .control { await stop(.peerClosed) }
                return
            }
            residue.append(arrived)
            // ⛔ **6.1c on the responder side, and this is the earliest point it
            // can be done** (F-D6-2, closed by `libppcp` `e52647e`). `t2` is "as
            // close to reception as the implementation allows": on
            // `Network.framework` that is the receive completion handler, which
            // is where `arrivedAtNs` was read — everything before it is the
            // kernel's and unreachable. `t3` is read here, immediately before the
            // engine builds the reply, so the interval between them is the real
            // residence rather than an unmeasured one folded into the estimate.
            //
            // ⚠ Stamped on **every** read: the stamps apply to the next probe
            // answered and are forgotten otherwise, so a read carrying no probe
            // costs nothing. Deciding whether this buffer holds one would mean
            // parsing it here, which is the framing re-implementation the library
            // exists to prevent.
            try? peer.syncReplyStamps(t2Ns: arrivedAtNs, t3Ns: nowNs())
            do {
                // ⚠ `feed` returns what it consumed and leaves a trailing partial
                // frame behind: TCP splits wherever it likes, and a caller that
                // discarded the tail would desynchronise the stream with the
                // symptom appearing frames later.
                let consumed = try peer.feed(residue, on: channel.channel)
                if consumed > 0 { residue.removeFirst(consumed) }
            } catch {
                harvest()
                pending.append(.protocolError(code: "malformed"))
                await stop(.protocolViolation("feed refused"))
                return
            }
            harvest()
            try? await flush()
        }
    }

    // MARK: Bytes out

    /// Pushes every queued frame onto the wire, respecting the transport's
    /// backpressure.
    public func flush() async throws {
        // ⚠ Re-entrancy is real: an event handler calls `perform`, which flushes,
        // while a receive loop is already inside one. Two concurrent peek/commit
        // pairs on one channel would commit bytes the other wrote. One flush at a
        // time, and a second request re-runs it rather than being dropped.
        if isFlushing { flushAgain = true; return }
        isFlushing = true
        defer { isFlushing = false }

        repeat {
            flushAgain = false
            for channel in channels() {
                while true {
                    let queued = try peer.drainPeek(channel.channel)
                    guard queued.isEmpty == false else { break }
                    try await channel.send(queued)
                    // ⛔ Committed only after the transport took them. `send` does
                    // not return until it has, so the count is exact.
                    try peer.drainCommit(channel.channel, written: queued.count)
                }
            }
        } while flushAgain
    }

    // MARK: Events

    /// Moves the engine's events into the stream, translating the few this
    /// application acts on.
    public var hasPendingEvents: Bool { pending.isEmpty == false }

    private func harvest() {
        while let event = peer.nextEvent({ kind, msg in Self.translate(kind, msg) }) {
            pending.append(event)
        }
    }

    /// ⚠ Everything read out of `msg` is read **here**, while the pointer is
    /// alive, and nothing is carried out of it.
    private static func translate(_ kind: ppcp_event_kind,
                                  _ msg: UnsafePointer<ppcp_msg>?) -> PeerLinkEvent {
        switch kind {
        case PPCP_EVENT_HELLO: return .hello
        case PPCP_EVENT_CONNECTED: return .connected(version: nil)
        case PPCP_EVENT_DECLARE:
            guard let msg else { return .declared(peerId: "") }
            return .declared(peerId: body(msg, ppcp_body_declare.self) {
                ppcpString($0.pointee.peer.id)
            })
        case PPCP_EVENT_SESSION_OPEN:
            guard let msg else { return .sessionOpened(sessionId: "") }
            return .sessionOpened(sessionId: body(msg, ppcp_body_session_open.self) {
                ppcpString($0.pointee.session_id)
            })
        case PPCP_EVENT_SESSION_JOINED:
            guard let msg else { return .sessionJoined(sessionId: "") }
            return .sessionJoined(sessionId: body(msg, ppcp_body_session_joined.self) {
                ppcpString($0.pointee.session_id)
            })
        case PPCP_EVENT_SESSION_CLOSE:
            return .sessionClosed(reason: msg.map { m in
                body(m, ppcp_body_session_close.self) { ppcpString($0.pointee.reason) }
            })
        case PPCP_EVENT_STREAM_OPEN:
            guard let msg else { return .streamOpened(streamId: "") }
            return .streamOpened(streamId: body(msg, ppcp_body_stream_open.self) {
                ppcpString($0.pointee.stream.id)
            })
        case PPCP_EVENT_ARM: return .armRequested
        case PPCP_EVENT_DISARM: return .disarmRequested
        case PPCP_EVENT_CAPTURE_REQUEST:
            guard let msg else {
                return .captureRequested(shotId: "", streamIds: [], preNs: 0,
                                         postNs: 0, replyTo: 0)
            }
            let replyTo = msg.pointee.env.msg_id
            return body(msg, ppcp_body_capture_request.self) { request in
                var value = request.pointee
                let ids = withUnsafeBytes(of: &value.stream_ids) { raw -> [String] in
                    let base = raw.bindMemory(to: ppcp_id.self)
                    return (0..<request.pointee.stream_id_count).map { ppcpString(base[$0]) }
                }
                return .captureRequested(shotId: ppcpString(request.pointee.shot_id),
                                         streamIds: ids,
                                         preNs: request.pointee.pre_ns,
                                         postNs: request.pointee.post_ns,
                                         replyTo: replyTo)
            }
        case PPCP_EVENT_CANDIDATE:
            guard let msg else { return .candidateReceived(id: "") }
            return .candidateReceived(id: body(msg, ppcp_body_candidate.self) {
                ppcpString($0.pointee.candidate.id)
            })
        case PPCP_EVENT_SHOT:
            guard let msg else { return .shotReceived(id: "") }
            return .shotReceived(id: body(msg, ppcp_body_shot.self) {
                ppcpString($0.pointee.shot.id)
            })
        case PPCP_EVENT_SESSION_OFFER:
            guard let msg else { break }
            return .sessionOffered(body(msg, ppcp_body_session_offer.self) {
                PpcpSessionOffer($0.pointee)
            })
        case PPCP_EVENT_SESSION_ACCEPT:
            guard let msg else { break }
            return .sessionAccepted(body(msg, ppcp_body_session_accept.self) {
                PpcpSessionAccept($0.pointee)
            })
        case PPCP_EVENT_LINK_LOST: return .linkLost
        case PPCP_EVENT_LINK_RESTORED: return .linkRestored
        case PPCP_EVENT_HEARTBEAT: return .heartbeat
        case PPCP_EVENT_SYNC: return .sync
        case PPCP_EVENT_RELATION_UPDATE: return .relationUpdate
        case PPCP_EVENT_PAYLOAD: return .payload
        case PPCP_EVENT_CAPTURE: return .capture
        case PPCP_EVENT_ERROR:
            guard let msg else { return .protocolError(code: "") }
            // ⛔ `code` only. `MSG` 10 makes the code the machine-readable part and
            // `RV` 7.2b forbids anything else about a failure reaching a log.
            return body(msg, ppcp_body_error.self) {
                .protocolError(code: ppcpString($0.pointee.code))
            }
        case PPCP_EVENT_UNKNOWN:
            guard let msg else { return .unknownMessage(type: "") }
            return .unknownMessage(type: ppcpString(msg.pointee.type_name))
        default: break
        }
        return .other(kind: Int32(kind.rawValue))
    }

    /// ⛔ **The union is reached through one pointer to `body`, never by value.**
    /// F-D3-1: Swift imports a C union as computed properties, so `msg.pointee.body.x`
    /// is a get-modify-set of a 48 KB struct — enough to `SIGBUS` a test from a
    /// synchronous function doing nothing else. `body` itself is a stored property
    /// and therefore directly addressable, which is what makes this safe.
    private static func body<Body, T>(_ msg: UnsafePointer<ppcp_msg>,
                                      _ type: Body.Type,
                                      _ read: (UnsafePointer<Body>) -> T) -> T {
        let mutable = UnsafeMutablePointer(mutating: msg)
        return withUnsafeMutablePointer(to: &mutable.pointee.body) { field in
            field.withMemoryRebound(to: Body.self, capacity: 1) { read(UnsafePointer($0)) }
        }
    }
}
