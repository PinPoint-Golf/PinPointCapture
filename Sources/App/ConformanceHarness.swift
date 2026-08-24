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
        /// I16 / 8.2 — the deadline the Session actually set, so "the deadline did
        /// not fire" can be told from "the deadline is longer than this run".
        public var issueHoldNs: Int64?
        public var hasArbitration = false
        /// ⛔ Whether "now" could ever be expressed in `Session.timebase_ref`.
        /// `false` means 8.2i1 held and the pump correctly did **not** run — which
        /// is a different fact from a deadline that has not yet arrived, and the
        /// two look identical from `shotsMinted == 0`.
        public var referenceInstantAvailable = false
        /// 5.13c — the timebase `Shot.t0` is expressed in. ⚠ The **Session's**,
        /// which with a host is the host's clock and not this device's.
        public var timebaseRefId: String?
        /// Whether the hardware enumerated a camera. ⛔ `false` on a simulator,
        /// and the row says what that costs.
        public var declaredCamera = true
        /// `MSG` 6.2 — how many `relation_update` frames arrived. ⚠ A host with
        /// three declared clocks publishes three (I21, 6.1d), and a device that
        /// received one has no way to express an instant on the other two.
        public var relationUpdates: Int = 0
        /// `MSG` §7.1 — Candidates the **counterpart** nominated.
        ///
        /// ⛔ I8 / 5.12c: a host owning its own acoustic Source nominates
        /// alongside this device, and both nominations are emitted. A device that
        /// only ever saw its own would have no way to tell a host that nominates
        /// from one that does not — which is the whole of IOP-6.
        public var candidatesReceived: [String] = []

        // MARK: The imported Session (MSG 4.1a1 / 9.1b, erratum E28)

        /// How many frames of a **replayed** Session crossed this link.
        public var importedFrames: Int = 0
        /// The imported Session's own id and reference clock. ⛔ Recorded beside
        /// `sessionId` and `timebaseRefId` rather than instead of them: the whole
        /// of E28 is that an import leaves the live Session untouched, and a
        /// report that carried one number could not show it.
        public var importedSessionId: String?
        public var importedTimebaseRefId: String?

        // MARK: What the counterpart's Shots said, and what this device made of them
        //
        // ⛔ **I22, from the receiving side.** 5.13c puts `Shot.t0` in
        // `Session.timebase_ref`, which against a host is the *host's* clock and
        // not this device's. A device that took the number as-is would be wrong
        // by an offset nobody measured and would not know it. So both readings
        // are recorded — the one that arrived and the one this device converted
        // it to — and the row asserts that they are the pair a conversion
        // produces rather than the same number twice.

        /// One `shot` as it arrived, and what this device converted it to.
        public struct ShotArrival: Sendable, Hashable {
            public var shotId: String
            /// As it arrived: `Shot.t0` in `Session.timebase_ref`.
            public var t0Ns: Int64
            public var t0TimebaseId: String
            /// 8.3d — who decided. A `shot` from a `role: host` peer says `host`.
            public var authority: String
            /// The same instant on **this device's** capture clock, or `nil`
            /// where no relation existed to express it (5.4b, 8.2i1). ⛔ Never a
            /// zero offset substituted to make it expressible.
            public var convertedToCaptureNs: Int64?
        }
        public var shotsReceived: [ShotArrival] = []

        // MARK: The stored Sessions this device offered (MSG §9.1)

        public var offersSent: [String] = []
        /// `sessionId` → the host's verdict, as `SessionOfferService` recorded it.
        public var offerVerdicts: [String: String] = [:]
        /// Whether every accepted bundle finished replaying onto the live link.
        public var replayCompleted = false

        // MARK: I19 — what this device declared, read back off its own declaration

        public var declaredProfiles: [String] = []
        public var declaredSourceKinds: [String] = []
        /// The `timing.convention` of every camera profile this device declared.
        /// ⛔ `nominal_frame_start` on a phone, and never `start`: A12 and I19
        /// make it what the hardware is, not what the counterpart uses.
        public var declaredConventions: [String] = []
        public var declaredGeometries: [String] = []
        public var declaredOffsetProvenances: [String] = []
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
    /// IOP-1 — the stored Sessions this device offers once a host has declared.
    /// ⛔ `nil` leaves the run byte-identical to D9's, which is why it is opt-in:
    /// the D9 claim was measured without an offer on the wire and a harness that
    /// started offering unconditionally would invalidate it silently.
    private let offering: SessionStore?
    /// Wave 2 — the PSK a scanned pairing code would have produced.
    ///
    /// ⛔ **Non-`nil` switches the transport to the SHIPPING one.** `PpcpConnector`
    /// is `Network.framework` with `RV` §5's TLS profile and there is no plaintext
    /// branch in that file; `PpcpDirectConnector` is the `DEBUG`-only plaintext
    /// path `RV` §2's `direct` case permits and which `ppcp-sim` speaks. The two
    /// are different types precisely so a fallback between them cannot exist
    /// (5.2f).
    private let credentials: (any PpcpCredentials)?
    private var report = Report()
    /// `Session.timebase_ref`, once a Session exists.
    private var referenceTimebaseId = PpcpTimebases.captureId
    private var offers: SessionOfferService?

    public init(device: any CaptureDevice, distance: MicToBallDistance,
                offering: SessionStore? = nil,
                credentials: (any PpcpCredentials)? = nil) {
        self.device = device
        self.distance = distance
        self.offering = offering
        self.credentials = credentials
    }

    /// Dials the counterpart and runs until `seconds` elapse or the link closes.
    ///
    /// - Parameter injectSwings: how many synthetic swings to put through the
    ///   real detector. ⛔ Zero is a legitimate run: the handshake, the Session
    ///   and the sync exchange are the part CT-S5 asks for.
    /// - Parameter nominateOnlyOnceConvertible: hold the injected swing until an
    ///   instant on this device's clock can be expressed in `Session.timebase_ref`.
    ///
    ///   ⛔ **Measured, not guessed** (S5, IOP-2): with this off, the swing goes
    ///   in on the first loop iteration after `session_open` — hundreds of
    ///   milliseconds before the first `relation_update` has crossed — and the
    ///   host cannot convert the Candidate's instant into `timebase_ref`. 8.2d
    ///   says it excludes and **retains** it, which is what `ppcp-sim` did:
    ///   `arbiter observed 2, retained 2, issued 0`. So no Shot was ever issued,
    ///   and the row that exists to watch a device convert an issued `t0` had
    ///   nothing to convert.
    ///
    ///   ⚠ **A parameter and not a change of default**, because D9's claim was
    ///   measured with the old sequencing and changing it here would silently
    ///   invalidate a run nobody re-made. It is also the honest order: a golfer
    ///   swings seconds after the bay's host has appeared, not 250 ms after.
    public func run(against endpoint: PeerEndpoint,
                    seconds: Double = 6,
                    injectSwings: Int = 1,
                    nominateOnlyOnceConvertible: Bool = false) async throws -> Report {

        let peerId = PeerIdentity.current
        report.peerId = peerId

        // ⛔ The device's own declaration. A harness that declared something
        // convenient would be conformance evidence about a fixture.
        let honest = try Self.honestDeclaration(of: device, peerId: peerId)
        let declaration = honest.declaration
        report.declaredCamera = honest.hasCamera

        // I19 — read back off the declaration this device is about to put on the
        // wire, so the row asserts what was SENT rather than what a fixture says.
        report.declaredProfiles = declaration.declaredProfiles
        report.declaredSourceKinds = declaration.sources.map(\.kind)
        for source in declaration.sources where source.kind == "camera" {
            for profile in source.profiles {
                report.declaredConventions.append(String(describing: profile.convention))
                report.declaredGeometries.append(
                    profile.geometry.map { String(describing: $0) } ?? "—")
                report.declaredOffsetProvenances.append(
                    profile.offsetProvenance.map { String(describing: $0) } ?? "—")
            }
        }

        let peer = try DevicePeer(
            peerId: peerId,
            role: .capture,
            // `CORE` 6.1b — the clock this peer stamps `t1` with when it probes
            // and `t2`/`t3` with when it answers. On iOS there is one answer.
            clock: PpcpDeviceClock { PpcpTimebases.now(timebaseId: $0) },
            health: { DeviceHealthService.current() },
            syncTimebase: PpcpTimebases.captureId)

        let transport: any PeerTransport
        if let credentials {
            // ⛔ The shipping transport, unchanged: two TLS 1.2 PSK connections,
            // `link_bind` first on each (`ENC` 2.1a), no plaintext branch to fall
            // back to (`RV` 5.2f).
            transport = try await PpcpConnector().connect(to: endpoint,
                                                          credentials: credentials)
        } else {
            transport = try await PpcpDirectConnector().connect(to: endpoint)
        }
        report.security = transport.security.summary
        let pump = PeerLinkPump(peer: peer, transport: transport,
                                nowNs: { MachClock.hostTimeNs })
        await pump.start()

        // `MSG` 3.1/3.3 — `hello` then a complete declaration snapshot.
        try await pump.perform { peer in
            try peer.hello()
            try peer.declare(declaration)
        }
        // ⛔ **Not read here.** F-S5-4, found by the S5 wave-2 run: at this point
        // `hello` has been *sent* and `hello_accept` has not arrived, so there is
        // no agreed version to read and the report said `null` for a link that had
        // certainly agreed one. It is read on `.connected` below instead.

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

                case .connected:
                    // `MSG` 3.2 — the version is agreed at `hello_accept` and
                    // readable from here on (F-S5-4).
                    report.negotiatedVersion =
                        try? await pump.perform { $0.negotiatedVersion }

                case .importedFrame(_, let sessionId, let timebaseRefId):
                    // ⛔ **`MSG` 4.1a1 / 9.1b (erratum E28) — an imported frame
                    // ends here and reaches nothing else.** These are the frames
                    // of a Session this device *offered*, replayed onto the live
                    // link by design (`ENC` 7a); they are not this Session's. They
                    // are counted, their Session is recorded, and they are handed
                    // to no mint pump, no arbiter and no conversion — which is
                    // what F-S5-3 found two implementations both failing to do.
                    report.importedFrames += 1
                    report.importedSessionId = sessionId
                    report.importedTimebaseRefId = timebaseRefId

                case .declared(let counterpart):
                    report.counterpartPeerId = counterpart

                case .sessionAccepted(let accept):
                    guard let offers, let host = report.counterpartPeerId else { break }
                    report.offerVerdicts[accept.sessionId] =
                        String(describing: accept.verdict)
                    try await pump.perform { _ in
                        try offers.received(accept, fromHost: host)
                    }
                    // `ENC` 7a — the stored bundle's own frames, renumbered into
                    // the live sequence and put back on the link. Pumped here and
                    // again on every tick below, because `feed` stops when the
                    // outbound queue is full and the drain is the pump's.
                    report.replayCompleted = try await pump.perform { _ in
                        try offers.pumpReplay(hostPeerId: host)
                    }

                case .shotReceived(let id, let t0Ns, let t0TimebaseId, let authority):
                    // ⛔ **The conversion, not a substitution.** The instant
                    // arrives on the Session's reference clock; expressing it on
                    // this device's capture clock is the only way a ring could be
                    // asked for the right interval, and `nil` where no relation
                    // exists is 8.2i1's honest answer rather than a zero offset.
                    let converted = try? await pump.perform { peer in
                        try peer.instant(t0Ns, on: t0TimebaseId,
                                         expressedIn: PpcpTimebases.captureId)
                    }
                    report.shotsReceived.append(Report.ShotArrival(
                        shotId: id, t0Ns: t0Ns, t0TimebaseId: t0TimebaseId,
                        authority: String(describing: authority),
                        convertedToCaptureNs: converted ?? nil))

                case .candidateReceived(let id):
                    report.candidatesReceived.append(id)

                case .relationUpdate:
                    // ⚠ **`CORE` 8.2d1 (erratum E29) — and on this side it is a
                    // no-op, stated rather than silently skipped.** E29 requires
                    // an arbiter to RECONSIDER a Candidate it excluded for want
                    // of a relation, once that relation arrives, and
                    // `ppcp_arbiter_reconsider()` is what an embedding calls
                    // here. **This application builds no arbiter**: it declares
                    // `core, capture, detect, mint, live, offline, markup` and
                    // not Arbitrate, and I20 gives arbitration to a peer with
                    // `role: host` and to no other — `ppcp_arbiter_new` refuses
                    // this peer outright. So there is nothing on the device side
                    // to call and no hidden obligation being skipped.
                    //
                    // ⚠ The device's own half of the same problem is already
                    // structural: `ppcp_mint_pump` re-tests `8.2i1` on every
                    // pump ("a relation may have arrived since the nomination"),
                    // so a Candidate this peer could not express when it made it
                    // becomes mintable the moment it can. That is E29's rule on
                    // the minting side, and it needed no call.
                    report.relationUpdates += 1

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
                // ⚠ Read BEFORE the swing rather than after it: whether "now" can
                // be expressed in `Session.timebase_ref` is what gates the
                // nomination, and reading it afterwards would gate the second
                // swing on the first swing's answer.
                let convertible = await referenceInstantIsAvailable(pump: pump)
                let mayNominate = nominateOnlyOnceConvertible == false || convertible
                if pendingSwings > 0, report.sessionId != nil, mayNominate {
                    pendingSwings -= 1
                    try await observe(detect, pump: pump)
                }
                await mint(detect, pump: pump)
            }
            // 6.3c's burst and 7.4c's liveness are on their own cadences and
            // neither is this loop's; the tick pumps both.
            await pump.tickOnce()

            // ⛔ **6.1f — publish the relation this peer measured.** The harness
            // did not, and `HostLinkDriver` on the real path always has. It
            // matters beyond politeness: a peer's own estimate reaches its
            // relation set only through `ppcp_peer_publish_relations`
            // (`libppcp` `src/ppcp_peer.c:1942`), and without it
            // `ppcp_relations_convert` has nothing to convert "now" into
            // `Session.timebase_ref` with — which is 8.2i1 refusing, correctly,
            // for a reason the embedding created.
            //
            // ⚠ **Not claimed as the fix for CT-S4 (6).** The verifying run has
            // not been made and the other candidates are not excluded; see the
            // entry in `docs/conformance/ppcp-conformance.md`. It is here because 6.1f asks
            // for it whether or not it changes that row.
            _ = try? await pump.perform { try $0.publishRelations() }

            // `MSG` 9.1 — offered once a host has declared **and** a Session
            // exists. ⚠ Both, and in that order: the peer id is what the
            // per-(host, session) disposition is keyed on, and offering before a
            // Session is offering to a peer that has not said what it is yet.
            if let host = report.counterpartPeerId, report.sessionId != nil {
                try await offerStoredSessions(to: host, pump: pump)
            }

            // The replay makes progress only as the outbound queue drains, so it
            // is pumped on the loop rather than once at accept time.
            if let offers, let host = report.counterpartPeerId,
               report.replayCompleted == false, report.offerVerdicts.isEmpty == false {
                report.replayCompleted = (try? await pump.perform { _ in
                    try offers.pumpReplay(hostPeerId: host)
                }) ?? false
            }
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

    /// `MSG` 9.1 — offer every stored Session this host has not dispositioned.
    ///
    /// ⛔ Nothing happens where `offering` is `nil`, which is D9's shape and is
    /// why that claim survives this file gaining an offer path.
    private func offerStoredSessions(to hostPeerId: String,
                                     pump: PeerLinkPump) async throws {
        guard let store = offering, offers == nil else { return }
        let service = try await pump.perform { peer in
            SessionOfferService(peer: peer, store: store) { bundle in
                try Data(contentsOf: bundle.bundleFile)
            }
        }
        offers = service
        let offered = try await pump.perform { _ in
            try service.offerAll(toHost: hostPeerId)
        }
        report.offersSent = offered.map(\.sessionId)
        report.transcript.append("offered \(offered.count) stored session(s)")
    }

    /// This hardware's own declaration, and whether it enumerated a camera.
    ///
    /// ⚠ **A simulator has no camera, and the honest declaration says so.**
    /// `CORE` §5.2 lets a Peer own no Source of a given kind — "a Peer owning
    /// none participates fully" — so this declares the microphone and the IMU and
    /// no camera Source, which is what this hardware actually enumerated. ⛔ It
    /// does **not** invent a 1080p150 camera to make a run look complete: the
    /// whole value of a conformance harness is that it declares what is there.
    ///
    /// The consequence is stated on the row rather than hidden: everything
    /// downstream of a camera Source — the video Stream, a Capture with
    /// `achieved_frames`, CT-S7 (4)'s conversion — is not exercised by a simulator
    /// run and needs a phone.
    static func honestDeclaration(of device: any CaptureDevice, peerId: String) throws
        -> (declaration: PpcpDeclaration, hasCamera: Bool) {
        do {
            return (try PpcpDeclaration(
                device.ppcpDeclarationInput(peerId: peerId, viewpoint: nil)), true)
        } catch CaptureDeviceError.noPhysicalCameraFound {
            return (try PpcpDeclaration(try declarationWithoutACamera(peerId: peerId),
                                        allowingNoCameraSource: true), false)
        } catch {
            throw HarnessError.declarationUnavailable(String(describing: error))
        }
    }

    /// The declaration a device with no camera makes.
    ///
    /// ⚠ Assembled here rather than by loosening `AVFoundationCaptureDevice`,
    /// because `enumerateCapability()` refusing a device with no camera is
    /// **correct** for A1's capability card and for arming: a phone whose camera
    /// failed must not report itself able to capture. What a harness needs is a
    /// different question — "declare what this hardware is" — and answering it
    /// here keeps the shipping path unchanged.
    static func declarationWithoutACamera(peerId: String) throws
        -> PpcpDeclarationInput {
        let identifier = DeviceProfiles.currentIdentifier
        guard let timing = DeviceProfiles.ppcp(for: identifier) else {
            throw HarnessError.declarationUnavailable("no timing profile for \(identifier)")
        }
        return PpcpDeclarationInput(
            peerId: peerId,
            profiles: PpcpProfileSet.device,
            timebases: PpcpTimebases.all,
            captureTimebaseId: PpcpTimebases.captureId,
            // ⛔ Empty, because that is what was enumerated. A12.
            capability: DeviceCapability(modelIdentifier: identifier,
                                         modelName: DeviceProfiles.profile(for: identifier)
                                             .marketingName,
                                         claimed: []),
            timing: timing,
            clipCodec: "hevc",
            declaresMicrophone: true,
            declaresIMU: true,
            viewpoint: nil,
            product: ("Apple", DeviceProfiles.profile(for: identifier).marketingName,
                      ProcessInfo.processInfo.operatingSystemVersionString))
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

        // ⛔ **`Session.timebase_ref` is the SESSION's, not this device's.** 5.13c
        // puts `Shot.t0` in `Session.timebase_ref`, and with a host that is the
        // host's clock. Taking this peer's own capture timebase instead is the
        // identity only in the hostless case (I4) — with a host it is a different
        // clock, and a `t0` stamped on it is wrong by the offset nobody measured.
        let timebaseRef = peer.sessionParameters?.timebaseRefId ?? PpcpTimebases.captureId
        report.timebaseRefId = timebaseRef
        referenceTimebaseId = timebaseRef
        report.issueHoldNs = peer.sessionParameters?.issueHoldNs
        report.hasArbitration = peer.sessionParameters?.hasArbitration ?? false

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
            videoClip: { requested in
                RetainedClip(extraction: Self.nothingRetained(requested),
                             exposure: .noExposure)
            })
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

    /// Whether an instant on this device's capture clock can be expressed in
    /// `Session.timebase_ref` at all (5.4b, 8.2i1).
    ///
    /// ⛔ `false` is a **fact about the relation set**, not a failure: before
    /// 6.3a's burst has produced an offset and a rate there is nothing to convert
    /// with, and a peer in that state does not mint and — see the parameter above
    /// — should not expect a host to arbitrate for it either.
    private func referenceInstantIsAvailable(pump: PeerLinkPump) async -> Bool {
        let reference = referenceTimebaseId
        let now: Int64? = try? await pump.perform { peer in
            try peer.instant(MachClock.hostTimeNs, on: PpcpTimebases.captureId,
                             expressedIn: reference)
        }
        if now != nil { report.referenceInstantAvailable = true }
        return now != nil
    }

    /// 8.2i's deadline, read in `Session.timebase_ref`.
    ///
    /// ⛔ **The instant is converted, not substituted.** 8.2i1 and 5.4b: a peer
    /// that cannot express "now" in the reference timebase does not mint, and it
    /// certainly does not pass its own clock reading off as the reference one. A
    /// relation exists only once 6.3a's burst has produced offset **and** rate,
    /// so before that this returns nothing and the Candidates stay retained —
    /// which is exactly 8.2i's "held until the deadline" rather than a failure.
    private func mint(_ detect: DetectAndMint, pump: PeerLinkPump) async {
        let reference = referenceTimebaseId
        let nowRef: Int64? = try? await pump.perform { peer in
            try peer.instant(MachClock.hostTimeNs,
                             on: PpcpTimebases.captureId,
                             expressedIn: reference)
        }
        guard let nowRef else { return }
        report.referenceInstantAvailable = true
        let minted = try? await pump.perform { _ in
            try detect.pump(nowRefNs: nowRef)
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
