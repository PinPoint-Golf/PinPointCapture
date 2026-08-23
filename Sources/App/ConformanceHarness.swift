//  ConformanceHarness.swift
//  D9 — this device's peer, driven by somebody else's.
//
//  ⛔ **DEBUG ONLY, and the whole file compiles out of a release build.** It
//  dials `RV` §2's **direct** path over plaintext TCP, which `PpcpDirectTransport`
//  explains and which nothing on a rendezvous path may do (5.2f).
//
//  ⚠ **What was blocked, and by what.** `ppcp-sim` has existed since L13 and this
//  application could not reach it: the simulator offers plaintext TCP or TLS 1.3
//  `psk_ke`, and Apple's `Network.framework` cannot negotiate a TLS 1.3 external
//  PSK at all — measured, twice, on two operating systems (F-D1-1, F-D6-4). So
//  CT-S5 (device), CT-S4 (6), CT-S3, CT-S7 (4) and four interop rows were all
//  blocked on a transport rather than on effort. This is the transport.
//
//  ⛔ **Nothing here is a second implementation of anything.** The declaration is
//  the device's own (`AVFoundationCaptureDevice`), the detector is the shipping
//  one, the Candidate comes out of `CandidateFactory` with the user's
//  microphone-to-ball distance applied, and the frames are `libppcp`'s. The only
//  synthetic input is the audio — `CONF` §2a's *injected* method — and the only
//  synthetic transport is the socket. A harness that posted a hand-built
//  `candidate` would look identical from the far end and would assert nothing.
//
//  ⚠ **What it does NOT do, said here rather than discovered later.** It extracts
//  no clip: `RingBufferRecorder` needs a camera and a simulator has none, so a
//  minted Shot's Capture is announced `absent` / `outside_buffer` — which is a
//  **result** and not a failure (I10, 8.4b), and is exactly what a device whose
//  ring no longer holds the interval must say.
//
//  Spec: `RV` §2, §9a; `CONF` §2a, §2c; `MSG` §3–§8. Plan D9.

#if DEBUG

import Foundation
import CaptureCore

/// One conformance run against a counterpart peer.
public actor ConformanceHarness {

    /// What the run observed, in the order it observed it.
    public struct Report: Sendable {
        public var peerId: String = ""
        /// `RV` 5.4k — "no TLS, none — no forward secrecy" on this path, and it
        /// says so rather than reporting an unknown mode.
        public var security: String = ""
        public var counterpartPeerId: String?
        public var negotiatedVersion: String?
        public var sessionId: String?
        public var streamsOpened: [String] = []
        public var candidatesNominated: Int = 0
        public var shotsMinted: Int = 0
        public var capturesAnnounced: Int = 0
        public var armsAnswered: Int = 0
        public var syncEvents: Int = 0
        public var heartbeats: Int = 0
        public var errorCodes: [String] = []
        /// F-L13-1 — ⛔ non-zero is a defect in this application's feed loop.
        public var droppedEvents: UInt64 = 0
        /// One line per event, for the debug screen and for a failure message.
        public var transcript: [String] = []

        /// The single assertion a caller makes: the handshake completed, a
        /// Session was joined, at least one Stream opened, and no `error` frame
        /// came back.
        public var reachedASession: Bool {
            sessionId != nil && streamsOpened.isEmpty == false && errorCodes.isEmpty
        }
    }

    public enum HarnessError: Error, Sendable {
        case declarationUnavailable(String)
    }

    private let device: any CaptureDevice
    private let distance: MicToBallDistance
    private var report = Report()

    public init(device: any CaptureDevice, distance: MicToBallDistance) {
        self.device = device
        self.distance = distance
    }

    /// Dials the counterpart and runs until `seconds` elapse or the link closes.
    ///
    /// - Parameter injectSwings: how many synthetic swings to put through the
    ///   real detector. ⛔ Zero is a legitimate run: the handshake, the Session
    ///   and the sync exchange are the part CT-S5 asks for.
    public func run(against endpoint: PeerEndpoint,
                    seconds: Double = 6,
                    injectSwings: Int = 1) async throws -> Report {

        let peerId = PeerIdentity.current
        report.peerId = peerId

        // ⛔ The device's own declaration. A harness that declared something
        // convenient would be conformance evidence about a fixture.
        let declaration: PpcpDeclaration
        do {
            declaration = try PpcpDeclaration(
                device.ppcpDeclarationInput(peerId: peerId, viewpoint: nil))
        } catch {
            throw HarnessError.declarationUnavailable(String(describing: error))
        }

        let peer = try DevicePeer(
            peerId: peerId,
            role: .capture,
            // `CORE` 6.1b — the clock this peer stamps `t1` with when it probes
            // and `t2`/`t3` with when it answers. On iOS there is one answer.
            clock: PpcpDeviceClock { PpcpTimebases.now(timebaseId: $0) },
            health: { DeviceHealthService.current() },
            syncTimebase: PpcpTimebases.captureId)

        let transport = try await PpcpDirectConnector().connect(to: endpoint)
        report.security = transport.security.summary
        let pump = PeerLinkPump(peer: peer, transport: transport,
                                nowNs: { MachClock.hostTimeNs })
        await pump.start()

        // `MSG` 3.1/3.3 — `hello` then a complete declaration snapshot.
        try await pump.perform { peer in
            try peer.hello()
            try peer.declare(declaration)
        }
        report.negotiatedVersion = try? await pump.perform { $0.negotiatedVersion }

        let deadline = Date().addingTimeInterval(seconds)
        var pendingSwings = injectSwings
        var detect: DetectAndMint?
        var sink: LiveDetectionSink?
        var queue: PayloadTransferQueue?

        // ⚠ Events are taken in batches with a deadline around the wait rather
        // than iterated until the peer closes: a counterpart that says nothing is
        // a legitimate scenario (`silent-host`, CT-S4 (6)), and a loop that waited
        // for it to speak would hang on exactly the row it exists for.
        var closed = false
        while Date() < deadline, closed == false {
            for event in await pump.takeEvents(waitingUpTo: 0.25) {
                record(event)
                switch event {
                case .sessionOpened(let sessionId), .sessionJoined(let sessionId):
                    guard report.sessionId == nil else { break }
                    report.sessionId = sessionId
                    let built = try await open(session: sessionId, declaration: declaration,
                                               peer: peer, pump: pump)
                    queue = built.queue
                    sink = built.sink
                    detect = built.detect

                case .armRequested:
                    // `CORE` 5.15a — a **measurement**, never a state name, and
                    // the library's constructor is the only way to one.
                    try await pump.perform { peer in
                        try peer.reportReadiness(
                            ReadinessMeasurement.measuring(
                                .armed, exposureHasSettled: true,
                                settleEstimateMs: AppModel.assumedSettleMs).ppcpReadiness(),
                            streamIds: [])
                    }
                    report.armsAnswered += 1

                case .captureRequested(let shotId, let streamIds, _, _, let replyTo):
                    // ⛔ 8.4b — `outside_buffer`, and it is a **result**. A
                    // simulator has no camera, so the ring holds nothing;
                    // answering with an `error` is what I10 forbids.
                    try await pump.perform { peer in
                        try peer.captureAbsent(
                            captureId: "cap:\(UUID().uuidString.lowercased())",
                            shotId: shotId, streamId: streamIds.first ?? "",
                            inReplyTo: replyTo)
                    }

                case .declared(let counterpart):
                    report.counterpartPeerId = counterpart

                case .sync:
                    report.syncEvents += 1

                case .heartbeat:
                    report.heartbeats += 1

                case .protocolError(let code):
                    report.errorCodes.append(code)

                case .transportClosed:
                    closed = true

                default:
                    break
                }
            }

            // One swing, once a Session and its Streams exist. ⛔ After the batch
            // rather than inside it: `session_open` and `stream_open_ack` can
            // arrive in the same read, and nominating before the Streams are
            // acknowledged is a Candidate naming a Stream the counterpart has not
            // seen.
            if let detect {
                if pendingSwings > 0, report.sessionId != nil {
                    pendingSwings -= 1
                    try await observe(detect, pump: pump)
                }
                await mint(detect, pump: pump)
            }
            // 6.3c's burst and 7.4c's liveness are on their own cadences and
            // neither is this loop's; the tick pumps both.
            await pump.tickOnce()
        }

        // Drain whatever the transfer queue still holds, so a `payload_end`
        // reaches the counterpart before the link goes.
        if let queue {
            _ = try? await pump.perform { _ in try? queue.pump() }
        }
        report.capturesAnnounced = sink?.announced.count ?? 0
        report.droppedEvents = (try? await pump.perform { $0.droppedEventCount }) ?? 0
        await pump.stop(.normal)
        return report
    }

    // MARK: The Session

    private struct Built {
        let queue: PayloadTransferQueue
        let sink: LiveDetectionSink
        let detect: DetectAndMint
    }

    /// Opens a Stream per declared Source and builds the detect/mint pipeline on
    /// them.
    ///
    /// ⚠ §5.11's continuity table is normative and followed rather than chosen:
    /// `video` and `audio` are `shot_windowed`, `metadata` is `continuous`.
    private func open(session sessionId: String, declaration: PpcpDeclaration,
                      peer: DevicePeer, pump: PeerLinkPump) async throws -> Built {
        let openedAt = MachClock.hostTimeNs
        var streams: [PpcpStreamRecord] = []
        for source in declaration.sources {
            let kind: String
            let continuity: PpcpStreamRecord.Continuity
            switch source.kind {
            case "camera": kind = PpcpStreamKind.video; continuity = .shotWindowed
            case "microphone": kind = PpcpStreamKind.audio; continuity = .shotWindowed
            case "imu": kind = PpcpStreamKind.metadata; continuity = .continuous
            default: continue
            }
            guard let profile = source.profileIds.first else { continue }
            streams.append(PpcpStreamRecord(
                id: "str:\(kind):\(source.id)", sessionId: sessionId,
                sourceId: source.id, kind: kind, profileId: profile,
                timebaseId: source.timebaseId, continuity: continuity,
                openedAtNs: openedAt))
        }

        // ⚠ Copied out of the `var` before the closure: a captured mutable
        // binding is not `Sendable`, and the list is finished by this point.
        let opened = streams
        try await pump.perform { peer in
            for stream in opened { try peer.openStream(stream) }
            // I21 / 6.1d — one probe sequence per **local** timebase, and 6.3c's
            // burst on connect.
            try peer.addSyncTimebase(PpcpTimebases.captureId)
            try peer.syncTrigger(.connect)
        }
        report.streamsOpened = streams.map(\.id)

        let audio = streams.first { $0.kind == PpcpStreamKind.audio }
        let video = streams.first { $0.kind == PpcpStreamKind.video } ?? audio
        guard let audio, let video else {
            throw HarnessError.declarationUnavailable("no audio Source to nominate on")
        }

        let queue = PayloadTransferQueue(peer: peer)
        let sink = LiveDetectionSink(peer: peer, queue: queue)
        let factory = CandidateFactory(declaration: declaration,
                                       sourceId: audio.sourceId,
                                       // 6.1d — a microphone has no `format`, so
                                       // no profile and no conversion.
                                       profileId: nil,
                                       timeOfFlight: distance.timeOfFlight)
        let mint = try DeviceMint(peer: peer,
                                  promotion: DetectAndMint.defaultPromotion())
        let detect = DetectAndMint(
            peer: peer, sink: sink, mint: mint, factory: factory,
            configuration: DetectAndMint.Configuration(
                sessionId: sessionId, peerId: report.peerId,
                timebaseRefId: PpcpTimebases.captureId,
                audioStream: audio, videoStream: video),
            promotion: DetectAndMint.defaultPromotion(),
            // ⛔ Both extractions answer `absent` / `outside_buffer`: there is no
            // camera and no ring here, and 8.4b says that is a result.
            extractAudio: { requested in Self.nothingRetained(requested) },
            extractVideo: { requested in Self.nothingRetained(requested) },
            videoExposure: { _ in .lockedConstant(0) })
        return Built(queue: queue, sink: sink, detect: detect)
    }

    // MARK: The swing

    private func observe(_ detect: DetectAndMint, pump: PeerLinkPump) async throws {
        let window = SyntheticAudio.oneSwing(timebaseId: PpcpTimebases.captureId,
                                             startNs: MachClock.hostTimeNs)
        let detections = try await pump.perform { _ in try detect.observe(window) }
        report.candidatesNominated += detections.count
        report.transcript.append("nominated \(detections.count) candidate(s)")
    }

    private func mint(_ detect: DetectAndMint, pump: PeerLinkPump) async {
        let minted = try? await pump.perform { _ in
            try detect.pump(nowRefNs: MachClock.hostTimeNs)
        }
        guard let minted, minted.isEmpty == false else { return }
        report.shotsMinted += minted.count
        report.transcript.append("minted \(minted.count) shot(s)")
    }

    /// ⛔ 8.4b — "an absent capture is a result, not a failure" (I10). A
    /// simulator holds no frames, and saying so is the conformant answer; an
    /// invented clip would be the one thing a harness must never produce.
    private static func nothingRetained(_ requested: Range<Int64>) -> ClipExtraction {
        ClipExtraction.nothingRetained(requested)
    }

    // MARK: Transcript

    private func record(_ event: PeerLinkEvent) {
        report.transcript.append(String(describing: event))
    }

}

#endif
