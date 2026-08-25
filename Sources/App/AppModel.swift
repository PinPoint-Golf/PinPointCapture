//  AppModel.swift
//  The composition root's state.
//
//  This is the one place that knows about both the Platform layer and the Core
//  state the UI renders. Screens receive Core values and hand back closures; none
//  of them reaches a capture device, and none of them owns navigation.
//
//  ⚠ Partly skeleton. Device capability is real (D2), and since **D4** arming
//  opens a real hostless recording session: a `DevicePeer`, a
//  `SessionBundleWriter` over a real file, a declaration built from the hardware,
//  and the Streams `CORE` §5.11 says this device has. Shot detection (D5) and the
//  live link (D6) do not exist yet, so no Capture is announced from here — what
//  is real is the session, its Streams and its `readiness`, which is exactly what
//  7.3b says a hostless bundle carries.
//
//  Everything still fixture is labelled as such below.

import Foundation
import Observation
import CaptureCore

@MainActor
@Observable
public final class AppModel {

    // MARK: Real, measured on this device

    /// ⚠ REQ-FPS-1 / REQ-CAP-1. Enumerated from the hardware at launch, never a
    /// spec-sheet lookup. This is the one value on A1 and A7 that is genuinely
    /// about the phone in your hand.
    public private(set) var capability: DeviceCapability
    public private(set) var storage: StorageHeadroom
    /// ⚠ `internal(set)` **so the arm path can be tested at all.** `warmUp`
    /// gates on `canCapture`, and a simulator never has it — which means every
    /// rule `arm()` enforces after that gate, including the one §9.2 turns on
    /// (an `armed` peer must actually be retaining), is unreachable in a test.
    /// The setter stays out of the public surface; nothing in the app writes it
    /// but `refreshPermissions`.
    public internal(set) var permissions: Permissions
    public private(set) var capabilityError: String?

    /// E1.1's ring instrument, sampled while armed. ⛔ The exit criterion is a
    /// measurement — "twenty fragments, rolling, **at the claimed rate**" — and
    /// `maxInterArrivalNs` is the field that separates a steady 150 fps from an
    /// average one. Without a readout a device run produces an impression.
    public private(set) var ringStats = RingStats()

    /// What the last completed retention measured. ⛔ Kept because
    /// `stopRetaining` destroys the live counters, and disarming is exactly when
    /// somebody wants to read them. Also what E10.1's diagnostic bundle will
    /// want, which is why it is on the model and not only in a debug view.
    public private(set) var lastRunRingStats: RingStats?

    // MARK: Fixture state — replaced as each subsystem lands

    /// ⛔ **Starts `cold`, not at a fixture.** It was `PreviewFixtures.armed`, so
    /// a freshly launched app on a device with no usable camera reported itself
    /// armed and retaining nothing — §9.2's one thing that must not be quietly
    /// wrong. Found by the D4 test that asserts arming is not a claim.
    public var captureStatus: CaptureStatus = CaptureStatus(state: .cold)

    /// The live link, when one is up. ⛔ Owned here rather than by `RootView`:
    /// a link that dies with a view hierarchy is a link that dies on a screen
    /// rotation.
    public private(set) var link: HostLinkSession?

    /// ⛔ **`none`, and it stays `none` until a host link exists.** It used to be
    /// assigned `PreviewFixtures.connected` the moment anyone tapped the
    /// discovered host on B1 — an app that reported a paired Studio, a measured
    /// clock offset and a transfer queue, with no socket open anywhere. The live
    /// link is E3; until it lands this value has exactly one honest setting.
    public var hostLink: HostLink = HostLink(state: .none)

    /// The open session. ⚠ Empty until `arm()`, and its shots are minted, not
    /// invented.
    public private(set) var session: Session = Session(name: "", start: .distantPast,
                                                       shots: [])

    /// ⛔ Nil until transfer exists (E3.4). A queue with nothing behind it is a
    /// progress bar for work nobody is doing.
    public var transferQueue: TransferQueue?

    /// ⚠ Starts claiming **nothing**. Three of its rows need pose detection that
    /// does not exist (E8.2); `light` is filled by the self-test.
    public var framing: FramingStatus = FramingStatus()
    public var audioRetention: AudioRetention = .aroundImpactOnly
    public var captureContext: CaptureContext = .standalone

    // MARK: The microphone-to-ball distance (D7)

    /// `CORE` 8.1d — what every Candidate's raw instant is corrected by, and the
    /// setting Mark asked for on 23 August 2026.
    ///
    /// ⚠ **It takes effect on the next arm, not on the open Session.** A Session
    /// whose Candidates were corrected by two different distances would be a
    /// record nobody can reason about: `tof_correction` travels per Candidate, so
    /// the two would be individually honest and collectively incomparable. The
    /// setting screen says so.
    public var micToBallDistance: MicToBallDistance = MicToBallDistanceStore.load() {
        didSet { MicToBallDistanceStore.save(micToBallDistance) }
    }

    /// Whether the user has ever chosen one. ⛔ A screen shows a default
    /// differently from a choice — "1.5 m (assumed)" is not "1.5 m" — because a
    /// default that reads as a measurement is A12's failure mode.
    public var micToBallDistanceWasChosen: Bool { MicToBallDistanceStore.hasBeenSet() }

    /// ⛔ Persisted. It was a plain `false`, so every launch replayed all seven
    /// onboarding screens — including the permission sequence, whose design rests
    /// on being asked once and in order.
    public var hasCompletedOnboarding: Bool = OnboardingStateStore.hasCompleted() {
        didSet { OnboardingStateStore.setCompleted(hasCompletedOnboarding) }
    }

    private let device: any CaptureDevice
    private let permissionsService = PermissionsService()

    // MARK: The recording session (D4)

    /// `CORE` §9 — the open Session, written to a bundle as it happens. `nil`
    /// when nothing is being recorded.
    public private(set) var recording: HostlessRecordingSession?
    /// ⛔ Surfaced rather than swallowed. A session that failed to open is a
    /// session whose swings are not being kept, and §9.2 makes that the one thing
    /// the UI must not be quiet about.
    public private(set) var recordingError: String?

    private let store: SessionStore

    /// D5's microphone, feeding D5's detector. ⛔ Started on `arm` and stopped on
    /// `disarm`: `REQ-PRIV-4` and 7.2 make a microphone that runs outside a
    /// session a thing this application must not have.
    private var microphone: MicrophoneOnsetSource?
    /// The mint pump. 8.2i's deadline is a *local* deadline, so something has to
    /// tick it even when nothing is heard.
    private var mintTicker: Task<Void, Never>?
    /// Thermal, storage and battery, at `CORE` 7.4a's heartbeat cadence.
    private var healthTicker: Task<Void, Never>?

    public init(device: any CaptureDevice = CaptureDeviceFactory.create(),
                store: SessionStore = SessionStore(
                    root: URL.documentsDirectory.appendingPathComponent("sessions",
                                                                       isDirectory: true))) {
        self.device = device
        self.store = store
        // Seeded so the first frame renders; replaced by `refreshCapability()`.
        self.capability = DeviceCapability(modelIdentifier: "", modelName: "This device",
                                           claimed: [])
        self.storage = StorageHeadroom(estimatedSessions: 0, freeBytes: 0)
        self.permissions = permissionsService.current()
    }

    // MARK: Capability

    /// ⚠ Runs before any permission is granted, and must: `AVCaptureDevice`
    /// discovery lists formats without authorisation. A1 is the first screen the
    /// user sees, and it has to be honest about the device before asking for
    /// anything.
    public func refreshCapability() {
        do {
            capability = try device.enumerateCapability()
            capabilityError = nil
            if let best = capability.bestMode {
                storage = device.storageHeadroom(forMode: best)
            }
        } catch {
            // A device with no usable camera still gets a working screen that says
            // so, rather than an empty card or a crash.
            capabilityError = String(describing: error)
        }
    }

    /// REQ-CAP-2. Measure what the device actually sustains, and fold it into the
    /// triple so A7 shows claimed and measured together.
    ///
    /// ⚠ REQ-ENC-4: this short run is a *demonstration that the measurement path
    /// works*, not the sustained test. The real figure needs ~40 minutes under
    /// thermal load; a cold three-second sample will read optimistically high and
    /// must never be presented as the sustained rate once capture is real.
    public func runSelfTest(seconds: TimeInterval = 3, mode requested: VideoMode? = nil) async {
        guard permissions.canCapture, let mode = requested ?? activeMode else { return }
        do {
            let measured = try await device.measureSustainedRate(mode: mode, duration: seconds)
            capability.measured = measured
            captureStatus.achievedFPS = measured.achievedFPS
            captureStatus.thermal = measured.thermalAtEnd
            // ⛔ **A6's light row, from the run that just happened.** It was a
            // fixture: `1/1600 s · ISO 2200` was rendered on every device
            // regardless of the room. REQ-LIGHT-1 calls achievable exposure "the
            // binding constraint on how useful the video is", so an invented one
            // is the worst single value this application could show.
            //
            // ⚠ `nil` where the run observed no exposure or ISO — the screen then
            // says the light was not assessed, rather than showing a guess.
            framing.light = LightAssessment.from(measured)
        } catch {
            capabilityError = String(describing: error)
        }
    }

    /// A6's *Use 120 fps*, as a real measurement.
    ///
    /// Picks the best claimed mode at or below `fps` and re-runs the self-test on
    /// it. ⛔ The verdict is whatever the room gives back — this method cannot
    /// return "good", it can only measure.
    public func remeasure(atMost fps: Double) async {
        guard permissions.canCapture else { return }
        let candidates = capability.claimed.filter { $0.fps <= fps }
        // Best available at or below the cap: rate first, then resolution — the
        // same ordering `bestMode` uses, for the same reasons (REQ-FPS-1).
        guard let mode = candidates.max(by: { ($0.fps, $0.height) < ($1.fps, $1.height) })
        else { return }
        preferredMode = mode
        await runSelfTest(mode: mode)
    }

    /// The mode the user chose, where they chose one. ⚠ `nil` means "whatever the
    /// device ranks best", which is the normal case.
    public private(set) var preferredMode: VideoMode?

    /// What `arm()` and the preview should open.
    public var activeMode: VideoMode? { preferredMode ?? capability.bestMode }

    // MARK: Permissions

    /// A4's order is the design: camera and microphone first because they are
    /// obvious, local network last and framed as a host choice, so a refusal reads
    /// as a decision about hosts rather than a broken app (REQ-DISC-6).
    public func requestCapturePermissions() async {
        if permissions.camera == .notRequested {
            permissions.camera = await permissionsService.requestCamera()
        }
        if permissions.microphone == .notRequested {
            permissions.microphone = await permissionsService.requestMicrophone()
        }
    }

    /// A4's *Allow local network* tap.
    ///
    /// ⛔ There is no API to grant or to read this. iOS shows its prompt the first
    /// time the app actually browses or connects, and never tells us the answer.
    /// So the honest recorded state after asking is `.unknown` — not `.allowed` —
    /// and the real answer arrives later, as a connection that fails, which
    /// surfaces as B6 (REQ-DISC-6).
    public func noteLocalNetworkRequested() {
        permissions.localNetwork = .unknown
    }

    public func refreshPermissions() {
        permissions = permissionsService.current(localNetwork: permissions.localNetwork)
    }

    // MARK: Capture lifecycle

    /// REQ-STATE-2. Warm exists so arming costs no AE/AF settling.
    /// ⛔ **The two guards used to `return` silently, and that is what made *Arm*
    /// a dead button** (Mark, 25 August 2026, on a phone). `arm()` calls this and
    /// then refuses to proceed unless the state reached `.warm`, so a device that
    /// could not warm up produced no state change, no error and no sentence —
    /// the golfer tapped Arm and nothing whatever happened. §9.2 makes capture
    /// the thing that must not be quietly wrong, and a silent guard on the path
    /// to arming is exactly that.
    public func warmUp() {
        guard permissions.canCapture else {
            // ⚠ Names the remedy, not the API. Both are needed: the camera for
            // the frames and the microphone for the impact that times them.
            capabilityError = "Camera and microphone access are both needed "
                + "before this device can capture. Settings — PinPointCapture."
            return
        }
        guard let mode = activeMode else {
            capabilityError = "No usable capture format was found on this device."
            return
        }
        do {
            try device.warmUp(mode: mode)
            captureStatus.state = .warm
            // ⚠ Cleared on success, or a solved problem stays on screen for the
            // rest of the session.
            capabilityError = nil
        } catch {
            capabilityError = String(describing: error)
        }
    }

    /// REQ-STATE-3 — arm, and open the Session that will hold what it captures.
    ///
    /// ⛔ **Arming is not a claim.** It used to set `.armed` whatever `warmUp`
    /// did, so a device with no camera reported itself armed and retaining
    /// nothing. §9.2 makes capture the thing that must not be quietly wrong.
    public func arm() {
        warmUp()
        // ⛔ `warmUp` has stated the reason by now — it no longer fails silently
        // — so this returns to a screen that can say what happened.
        guard captureStatus.state == .warm else { return }
        startRecording()
        guard let recording, let mode = activeMode else { return }
        // ⛔ REQ-BUF-1, and the same rule the comment above states for warm-up:
        // a device that cannot retain must not reach `armed`. This is the half
        // that used to be missing — the state said `armed` and the ring held
        // nothing, on every device, because nothing ever started one.
        do {
            try device.startRetaining(mode: mode)
        } catch {
            capabilityError = String(describing: error)
            stopRecording()
            return
        }
        startDetecting()
        // REQ-META-1 / REQ-CLIP-1 — attitude and gravity. ⛔ Started with the
        // session and stopped with it, for the same privacy reason the
        // microphone is (7.2, REQ-PRIV-4): a motion sensor running outside a
        // capture session is something this application must not have.
        recording.startMetadata()
        captureStatus.state = .armed
        // A real Session, opened now, holding the shots this arm produces.
        session = Session(name: Self.sessionName(for: recording.anchor.wallClock),
                          start: recording.anchor.wallClock,
                          shots: [])
        startHealthPolling()
    }

    /// "Wednesday range" — the session title on C3.
    nonisolated static func sessionName(for start: Date) -> String {
        let day = DateFormatter()
        day.dateFormat = "EEEE"
        return "\(day.string(from: start)) session"
    }

    /// The local override of a host-controlled state (REQ-STATE-1).
    public func disarm() {
        stopDetecting()
        recording?.stopMetadata()
        stopHealthPolling()
        stopRecording()
        // ⛔ **Read the counters BEFORE stopping.** `stopRetaining` drops the
        // recorder and its stats go with it, so a disarm would otherwise erase
        // the measurement of the run that just happened — which is the only
        // moment anybody wants to read it.
        ringStats = device.ringStats
        lastRunRingStats = ringStats
        // ⛔ Before `goCold`, which removes the session's outputs. `goCold` calls
        // this too for the paths that do not come through here, and it is
        // idempotent — but the ordering is stated at both ends rather than left
        // to one of them remembering.
        device.stopRetaining()
        device.goCold()
        captureStatus.state = .cold
        session.end = Date()
    }

    /// `CORE` 4.1b / 7.3b — a hostless `session_open`, its Streams, and a
    /// `readiness`. ⛔ No `arm` frame: that is conferred by **Live** and nobody
    /// sent one (7.3b).
    private func startRecording() {
        guard recording == nil else { return }
        do {
            let session = try HostlessRecordingSession(
                store: store, device: device,
                sessionId: "ses:\(UUID().uuidString.lowercased())",
                videoProfileId: activeMode?.id,
                micToBall: micToBallDistance,
                // ⛔ A4's setting, finally reaching the thing it names. It has
                // been user-visible and inert since the first build, and
                // REQ-PRIV-2 makes the privacy label a claim about *this* value.
                retention: audioRetention.policy)
            recording = session
            recordingError = nil

            // 7.3c — `readiness` is conferred by **Capture**, so a hostless peer
            // records it without declaring Live. ⛔ A measurement, never a state
            // name (5.15a): `ReadinessMeasurement.measuring` is one-way.
            try session.report(ReadinessMeasurement.measuring(
                .armed, exposureHasSettled: true,
                settleEstimateMs: Self.assumedSettleMs))

            // 7.3d — the gap is recorded when the interruption ends.
            device.observeInterruptions { [weak self] interruption in
                self?.record(interruption)
            }
        } catch {
            recordingError = String(describing: error)
        }
    }

    // MARK: The host link (E3.1)

    /// Composes a peer and a pump over a transport the rendezvous walk
    /// established, and drives `MSG` 3.1/3.3's handshake.
    ///
    /// ⚠ **Takes a transport rather than dialling one.** The rendezvous owns
    /// dialling (`RV` §4's order is normative and lives there); this owns what
    /// happens *after* a socket exists. It is also the seam a test uses to hand
    /// in a pipe instead of a network.
    public func connect(transport: any PeerTransport,
                        sessionId: String,
                        hostDisplayName: String?,
                        declaration: PpcpDeclaration? = nil) async {
        await disconnect()
        do {
            let session = try HostLinkSession(transport: transport,
                                              sessionId: sessionId,
                                              hostDisplayName: hostDisplayName,
                                              device: device,
                                              declaration: declaration)
            link = session
            hostLink = session.hostLink
            await session.open()
            hostLink = session.hostLink
            if case .failed(let message) = session.phase {
                hostLinkError = message
            }
        } catch {
            hostLinkError = String(describing: error)
            hostLink = HostLink(state: .lost)
        }
    }

    /// ⚠ Idempotent, and safe to call when nothing is up.
    public func disconnect(_ reason: ChannelCloseReason = .normal) async {
        guard let link else { return }
        await link.close(reason)
        self.link = nil
        hostLink = HostLink(state: .none)
        hostLinkError = nil
    }

    /// ⛔ **Backgrounding drops the socket, so say so.** iOS suspends the
    /// connection and a link that claimed to be up on return would be exactly the
    /// dishonesty these screens were just cleared of. Reconnection is E3.5.
    public func linkDidEnterBackground() async {
        // ⛔ And the search stops with it. A browse behind a suspended app spends
        // radio on `RV` §3's convenience path and could only produce a link the
        // next suspension drops again.
        stopSearchingForHost()
        guard link != nil else { return }
        await disconnect(.cancelled)
        hostLink = HostLink(state: .lost)
    }

    // MARK: Reconnection without a code (RV §3)

    /// Whether a browse is running. ⚠ Not "whether a host exists" — see
    /// ``reconnectSilence`` for what the search has actually found out.
    public private(set) var isSearchingForHost = false

    /// ⛔ **3.6a — this is NOT an error and must never be rendered as one.** What
    /// the last completed sweep had to say: how many sweeps, how long, and how
    /// many pairings were offered to the resolver. `nil` before the first sweep
    /// completes and whenever a host was reached.
    ///
    /// ⚠ **The wording is deliberately absent.** "Looking for your host" and
    /// "your host has not appeared — the network may not carry it" are the same
    /// outcome to §3 and different sentences to a person, and where the line
    /// falls is a UX decision. This property is the seam that makes the decision
    /// possible; it does not make it.
    public private(set) var reconnectSilence: Silence?

    /// ⛔ Set when a discovered host answered and refused the pairing (7.4d, most
    /// often a revocation at the other end) or could not be reached. Distinct
    /// from silence: something was there.
    public private(set) var reconnectDiagnosis: String?

    private var reconnectTask: Task<Void, Never>?

    /// ⚠ **When this runs, and it is a decision.** On the app becoming active
    /// with no link up. Not in the background, and not while a link exists —
    /// `search()` stops of its own accord the moment one does.
    ///
    /// ⛔ Idempotent. Two searches would be two browses and, worse, two dials to
    /// the same host.
    public func beginSearchingForHost() {
        guard reconnectTask == nil, link == nil else { return }
        isSearchingForHost = true
        reconnectDiagnosis = nil
        let coordinator = ReconnectCoordinator()
        reconnectTask = Task { [weak self] in
            for await outcome in await coordinator.search() {
                guard let self else { return }
                if await self.adopt(outcome) { break }
            }
            await self?.searchEnded()
        }
    }

    public func stopSearchingForHost() {
        reconnectTask?.cancel()
        reconnectTask = nil
        isSearchingForHost = false
    }

    /// - Returns: whether the search is over.
    private func adopt(_ outcome: ReconnectOutcome) async -> Bool {
        switch outcome {
        case .connected(let host):
            // ⚠ A code may have been scanned while this was browsing. The link
            // that is already up wins; dropping it to install this one would be
            // the search fighting the user.
            guard link == nil else {
                await host.transport.close(.cancelled)
                return true
            }
            reconnectSilence = nil
            // ⛔ Exactly the seam the pairing-code walk uses. §5 does not know
            // which of §3 or §4 found the host, and 11.1a is the clause that
            // says it must not.
            await connect(transport: host.transport,
                          sessionId: host.sessionId,
                          hostDisplayName: host.hostDisplayName)
            return true

        case .notFound(let silence):
            // ⛔ 3.6a — recorded, never raised. `hostLink` is untouched: a search
            // that found nothing has not lost anything.
            reconnectSilence = silence
            return false

        case .noPairingsHeld:
            // Nothing has ever been paired, so there is nothing to reconnect to
            // and no amount of waiting changes it. ⚠ Not a silence: the network
            // was never asked.
            reconnectSilence = nil
            return true

        case .hostRefusedThePairing(_, let reason):
            reconnectDiagnosis = reason
            return false

        case .couldNotReachHost(_, let reason):
            reconnectDiagnosis = reason
            return false

        case .pairingStoreUnreadable(let reason):
            // ⛔ *Erratum E56* — deliberately NOT folded into `.noPairingsHeld`.
            // The store exists and could not be read; the commonest cause is a
            // phone not unlocked since boot. Returning `false` keeps the search
            // alive, because unlike "never paired" this one resolves itself.
            reconnectDiagnosis = reason
            return false
        }
    }

    private func searchEnded() {
        reconnectTask = nil
        isSearchingForHost = false
    }

    /// Refreshes the observable link state from the session. ⚠ Called on the
    /// event loop's cadence; `HostLinkSession` is `@Observable` and the app-wide
    /// `HostLink` is a projection of it.
    public func refreshHostLink() {
        guard let link else { return }
        hostLink = link.hostLink
    }

    /// A handshake that failed, surfaced rather than swallowed.
    public private(set) var hostLinkError: String?

    // MARK: The session library (C3)

    /// The sessions actually on this phone.
    ///
    /// ⛔ **`SessionStore.bundles()` had no caller outside tests.** The library
    /// screen rendered `PreviewFixtures.session` — 41 invented shots dated 21
    /// August — while real bundles accumulated in the container, unlisted.
    ///
    /// ⚠ Ids, dates and sizes only. What is *inside* a bundle needs the reader
    /// and a projection over a peer (E4.1), and the screen states that rather
    /// than implying the rows are complete.
    public func libraryRows() -> [RecordedBundle] {
        guard let bundles = try? store.bundles() else { return [] }
        return bundles.map { bundle in
            let values = try? bundle.directory.resourceValues(
                forKeys: [.contentModificationDateKey])
            return RecordedBundle(
                sessionId: bundle.sessionId,
                fileDate: values?.contentModificationDate ?? .distantPast,
                byteCount: Self.directorySize(bundle.directory))
        }
    }

    private nonisolated static func directorySize(_ directory: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    // MARK: Device health (CORE 7.4a/b)

    /// ⛔ **`DeviceHealthService` had no caller outside the debug harness.** C1's
    /// `heat` row and B3's temperature row rendered whatever the self-test last
    /// saw, frozen — so a device throttling under a long session reported
    /// `nominal` indefinitely. 7.4b exists so degradation is *reported* rather
    /// than silently accepted, and a frozen reading is the silent case.
    ///
    /// ⚠ Deliberately not cached, per that file's own comment.
    public func refreshHealth() {
        let health = DeviceHealthService.current()
        captureStatus.thermal = health.thermal
        if let mode = activeMode {
            storage = device.storageHeadroom(forMode: mode)
        }
        // E1.1's instrument, sampled at the same 1 Hz. ⚠ Cheap by construction —
        // `ringStats` is a struct copy of plain integers read through the sample
        // queue, and it is NOT on the frame path.
        guard captureStatus.state == .armed else { return }
        ringStats = device.ringStats

        // ⛔ The `metadata` Stream's segments, on the same tick. A `continuous`
        // Stream must account for its whole open interval (I36) and
        // `close(completeness: .complete)` refuses a Session with an unaccounted
        // tail — so this has to run on a clock, not on samples arriving. It is a
        // no-op until a segment is actually due.
        do {
            try recording?.pumpMetadata(nowNs: MachClock.hostTimeNs)
        } catch {
            // §9.2 — a Stream that stopped accounting for itself is not a
            // cosmetic failure, and the close will refuse rather than lie.
            recordingError = String(describing: error)
        }
    }

    private func startHealthPolling() {
        healthTicker?.cancel()
        healthTicker = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                self?.refreshHealth()
                // 7.4a's default heartbeat. Cheap enough for it, per
                // `DeviceHealthService`'s own note.
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopHealthPolling() {
        healthTicker?.cancel()
        healthTicker = nil
    }

    // MARK: Detect (D5, composed here for the first time)

    /// Starts the microphone and the mint pump.
    ///
    /// ⛔ **`DetectAndMint` had no caller before S4.** D5 built the detector, the
    /// Candidate factory and the Mint engine with a full test suite, and nothing
    /// in `Sources/` ever fed one a sample — so a shipping session recorded its
    /// Streams and its `readiness` and never a Candidate. This is the wire.
    private func startDetecting() {
        guard permissions.microphone == .allowed else { return }
        let source = MicrophoneOnsetSource(timebaseId: PpcpTimebases.captureId) {
            [weak self] window in
            // ⚠ Called on the **audio render thread**. Nothing here does more
            // than hop: 7.4d makes capture the thing that must not degrade, and a
            // Swift allocation on that thread is how a dropout gets caused
            // somewhere else.
            Task { @MainActor [weak self] in self?.observe(window) }
        }
        do {
            try source.start()
            microphone = source
        } catch {
            // ⛔ Surfaced. A session detecting nothing is a session whose swings
            // are not being timed, and §9.2 makes that the one thing the UI must
            // not be quiet about.
            recordingError = String(describing: error)
            return
        }
        mintTicker = Task { @MainActor [weak self] in
            while Task.isCancelled == false, self?.recording != nil {
                self?.pumpMint()
                // 8.2i's deadline is a local one and fires whether or not a host
                // answers, so the pump runs on its own clock rather than on the
                // arrival of audio.
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopDetecting() {
        mintTicker?.cancel()
        mintTicker = nil
        microphone?.stop()
        microphone = nil
    }

    /// One window of audio, all the way to nomination.
    ///
    /// ⚠ `internal` rather than private so a test can inject a window: a
    /// simulator has no microphone worth timing, and `CONF` §2a's *injected*
    /// method is what that case is for.
    func observe(_ window: AudioWindow) {
        guard let recording else { return }
        do {
            let detections = try recording.observe(window)
            candidateCount += detections.count
        } catch {
            recordingError = String(describing: error)
        }
    }

    func pumpMint() {
        guard let recording else { return }
        do {
            let minted = try recording.pumpMint(nowRefNs: MachClock.hostTimeNs)
            guard minted.isEmpty == false else { return }
            // ⛔ **The shots the library shows, from the shots the Mint engine
            // issued.** `minted` was counted and discarded, and C1 and C3
            // rendered `PreviewFixtures.session` — 41 invented shots dated 21
            // August, on every device, forever.
            for shot in minted {
                shotCount += 1
                session.shots.append(Shot(
                    minted: shot,
                    ordinal: shotCount,
                    anchor: recording.anchor,
                    // ⛔ `nil`. Nothing records a clip (E1.1), and a duration
                    // here would be a measurement claim about video that does
                    // not exist.
                    duration: nil))
            }
        } catch {
            recordingError = String(describing: error)
        }
    }

    /// What the open Session has produced. ⚠ Counts rather than a shot list: the
    /// records are the bundle's, and a second copy in a view model is a second
    /// copy to disagree.
    public private(set) var candidateCount = 0
    public private(set) var shotCount = 0

    private func stopRecording() {
        guard let session = recording else { return }
        recording = nil
        candidateCount = 0
        shotCount = 0
        do {
            // ⛔ `partial`, asserted (I10). This session ended because a user
            // disarmed it, and nothing here knows whether every swing was caught.
            // `complete` is a claim, and a claim nobody can back is the failure
            // I10 exists to prevent.
            try session.close(completeness: .partial, closedAtNs: nil)
        } catch {
            recordingError = String(describing: error)
        }
    }

    private func record(_ interruption: InterruptionRecord) {
        do {
            try recording?.record(interruption)
        } catch {
            recordingError = String(describing: error)
        }
    }

    /// `CORE` 5.15 `estimated_ready_ms`.
    ///
    /// ⛔ **Assumed, and it is A12's rule applied to a number nobody measured.**
    /// Rebuilding a capture session costs roughly a second plus AE/AF settling
    /// (REQ-STATE-2), and "roughly" is the whole problem: this figure has not been
    /// through a rig. It is a peer's own estimate, which is what §5.15 asks for,
    /// and it must be replaced by a measurement before anyone reads it as one.
    nonisolated static let assumedSettleMs: UInt32 = 1_200

    /// Exposed so the preview view can attach. It hands over the *device*, not the
    /// session — `AVCaptureSession` never becomes reachable from a view model.
    public var captureDevice: any CaptureDevice { device }
}
