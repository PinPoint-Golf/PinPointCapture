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
#if canImport(UIKit)
import UIKit
#endif
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
    /// The live `preview` Stream, for as long as a host wants one.
    ///
    /// ⚠ **On the model, not on `RecordingSession`.** It is opened at connect
    /// and outlives every arm and disarm on that link (#108).
    public private(set) var livePreview: LivePreview?

    public private(set) var recording: RecordingSession?
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
    /// Keeps `hostLink` current with `HostLinkSession.hostLink` while a link is
    /// up — see `startHostLinkPolling()`.
    private var hostLinkTicker: Task<Void, Never>?
    /// E3.2/REQ-SYNC-2 — the thermal reading `refreshHealth()` last saw, so a
    /// *change* (not every 1 Hz tick) is what triggers a fresh sync burst.
    private var lastThermalStateForSync: ThermalState?

    /// Capture id → the `Shot` it belongs to.
    ///
    /// ⛔ **The join nothing kept.** `PpcpShot.captureIds` is filled when the clip
    /// is extracted and was then discarded, so a `payload_ack` naming a Capture
    /// had no route back to the row on screen. ⚠ Cleared with the session, not
    /// grown for the life of the app.
    private var shotIdByCapture: [String: UUID] = [:]

    /// Candidate id → the instant this device's microphone heard that ball.
    ///
    /// ⛔ **REQ-SYNC-4's other operand.** The Candidate's `atNs` is
    /// time-of-flight corrected and lives only in the detection; the host's `t0`
    /// arrives later, on `shot`. Nothing kept the first, so the subtraction had
    /// nothing to subtract. ⚠ Removed on use — a residual is per shot, and a
    /// stale entry would attach one swing's hearing to another's arbitration.
    private var heardInstantByCandidate: [String: Int64] = [:]

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
        // ⛔ **`VideoMode.isWorseForCapture`, and it used to be a second
        // comparator written out here** (#102). This one ranked on
        // `(fps, height)` while `bestMode` ranked on
        // `(fps, height, -lens.captureRank)` — so between the wide and the
        // ultra-wide offering the identical mode, this path picked whichever
        // the dictionary happened to yield last. Measured: the format dump
        // computed `ultraWide`, a later run of the same code chose `wide`. A
        // capture lens decided by hash order.
        guard let mode = candidates.max(by: VideoMode.isWorseForCapture) else { return }
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
    public func warmUp() async {
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
            try await device.warmUp(mode: mode)
            captureStatus.state = .warm
            // ⭐ **The health tick starts HERE, not at `arm`, and CR-02 §4a is
            // why.** `DeviceStatus` exists to answer "can this Source be used at
            // all" — 5.20b makes it reachable *earlier* than `Readiness` and not
            // derivable from it — and the residual gap CR-02 was granted to
            // close was named as "nothing before `arm`". A tick that only ran
            // while armed would rebuild that gap in the very package meant to
            // fill it: a camera taken by another application, or a light cut for
            // heat, would go unreported for the whole time an operator is
            // framing the shot, which is when they can still do something about
            // it. ⚠ `arm()` calls this too and it is idempotent.
            startHealthPolling()
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
    public func arm() async {
        // ⛔ **Re-entrancy, and it is not theoretical.** Every statement below is
        // preceded by an `await`, and `startRecording`'s own `recording == nil`
        // guard is separated from its assignment by two more — so two arms in
        // flight both pass every check and both open this device's Streams on
        // the *same* link peer. 5.1a fixes a Stream's identity for its lifetime
        // and `peer_stream_add` enforces it, so the loser gets
        // `PPCP_ERR_INVALID` and the session reports "nothing is being
        // recorded" while the winner's ring runs happily.
        //
        // ⚠ Evidence it happens: PinPointStudio's log, 27 Aug 17:03:08 — a
        // fourth stream dialled and never `link_bind`-ed, timed out at their
        // end. Two concurrent `openPreviewChannel()` calls, one attached and one
        // abandoned. ⛔ Set **before** the first suspension point, or the guard
        // is the bug it is guarding against.
        guard isArming == false else { return }
        isArming = true
        defer { isArming = false }

        await warmUp()
        // ⛔ `warmUp` has stated the reason by now — it no longer fails silently
        // — so this returns to a screen that can say what happened.
        // ⛔ **Every exit from here reports.** An `arm` that leaves a host
        // holding the `settled: false` it got in reply, with no settled and no
        // blocker ever following, is an arm with no terminal state — which is
        // the same hole as sending no `readiness` at all (PinPointStudio, 27 Aug).
        guard captureStatus.state == .warm else { reportReadiness(); return }
        await startRecording()
        guard let recording, let mode = activeMode else { reportReadiness(); return }
        // ⛔ REQ-BUF-1, and the same rule the comment above states for warm-up:
        // a device that cannot retain must not reach `armed`. This is the half
        // that used to be missing — the state said `armed` and the ring held
        // nothing, on every device, because nothing ever started one.
        do {
            try device.startRetaining(mode: mode)
        } catch {
            capabilityError = String(describing: error)
            stopRecording()
            reportReadiness()
            return
        }
        startDetecting()
        // REQ-META-1 / REQ-CLIP-1 — attitude and gravity. ⛔ Started with the
        // session and stopped with it, for the same privacy reason the
        // microphone is (7.2, REQ-PRIV-4): a motion sensor running outside a
        // capture session is something this application must not have.
        recording.startMetadata()
        // A real Session, opened now, holding the shots this arm produces.
        session = Session(name: Self.sessionName(for: recording.anchor.wallClock),
                          start: recording.anchor.wallClock,
                          shots: [])
        startHealthPolling()
        // ⛔ **`.armed` is NOT set here, and that is the whole of #101.**
        // `CaptureState.armed` means "running, locked, settled and retaining
        // into the ring buffer", and `startRetaining` returning says only that
        // the writer opened. Measured on an iPhone 16: the sensor delivers its
        // first frame ~75 ms later where the format was already active, and
        // **~8.85 s later where `warmUp` had to change it** — a known
        // AVFoundation reconfiguration cost. For that whole window the app said
        // `armed` over a ring receiving nothing, which is the §9.2 failure #98
        // was also an instance of.
        beginSettling()
    }

    // MARK: Settling (#101)

    /// True between `arm()` and the ring actually receiving frames.
    ///
    /// ⚠ A separate flag rather than a fourth `CaptureState`: the state means
    /// what it has always meant, and every screen that reads `.armed` keeps
    /// being right without being touched.
    public private(set) var isSettling = false

    /// True from the first line of `arm()` until it returns.
    ///
    /// ⚠ Distinct from `isSettling`, which only becomes true at the *end* of a
    /// successful arm — far too late to keep a second one out.
    private var isArming = false

    /// How long the last arm took to produce frames. ⛔ **A measurement**, and
    /// the one `assumedSettleMs` was written waiting for.
    public private(set) var measuredSettleNs: Int64?

    private var settleTask: Task<Void, Never>?

    /// ⚠ 50 ms, so a camera that is already running is armed within ~100 ms and
    /// the pause is invisible in the ordinary case.
    nonisolated static let settlePollMs = 50
    /// ⛔ Longer than the worst measured reconfiguration (8.85 s) with margin. A
    /// timeout that fired early would turn a slow arm into a failed one.
    nonisolated static let settleTimeoutNs: Int64 = 15_000_000_000

    /// Reach `.armed` when the ring is receiving, and not before.
    ///
    /// ⚠ **Frames must be ARRIVING, not merely non-zero.** A count left over
    /// from a previous run would satisfy "greater than zero" instantly; two
    /// consecutive increases is the cheapest evidence that the sensor is
    /// actually delivering now.
    private func beginSettling() {
        settleTask?.cancel()
        isSettling = true
        let startedAt = MachClock.hostTimeNs
        settleTask = Task { @MainActor [weak self] in
            var previous = -1
            var rising = 0
            while Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(Self.settlePollMs))
                guard let self, self.recording != nil else { return }

                let frames = self.device.ringStats.framesAppended
                rising = frames > previous && previous >= 0 ? rising + 1 : 0
                previous = frames

                if rising >= 2 {
                    self.measuredSettleNs = MachClock.hostTimeNs - startedAt
                    self.isSettling = false
                    self.captureStatus.state = .armed
                    self.reportReadiness()
                    return
                }
                if MachClock.hostTimeNs - startedAt > Self.settleTimeoutNs {
                    // ⛔ Reported, not waited out and not pretended past. A
                    // camera that never delivered is a camera that cannot arm.
                    self.isSettling = false
                    self.capabilityError = """
                        The camera did not start delivering frames. Try again, or \
                        move to a mode this device can sustain.
                        """
                    // ⛔ The host is told before the teardown, because `disarm`
                    // deliberately says nothing (see its own note) and this is
                    // the last moment an honest answer can be given.
                    //
                    // ⛔ **`source_not_delivering`, and the distinction is not
                    // pedantry.** This used to say `no_source`, which tells a
                    // golfer looking at a phone with a camera in it that there is
                    // no camera — sending them to fix the wrong thing. The
                    // camera exists, is permitted and was configured; it
                    // delivered nothing inside 15 s, which is a different fault
                    // with a different remedy. Registry addition under 10.3a,
                    // raised with PinPointStudio rather than coined here,
                    // because they render the string verbatim.
                    self.reportReadiness(blocked: .sourceNotDelivering)
                    self.disarm()
                    return
                }
            }
        }
    }

    /// `CORE` 7.3c — recorded once `settled` is true, which is what settling is.
    ///
    /// ⛔ **It used to go out at session open**, before a single frame had
    /// arrived, carrying `exposureHasSettled: true` and an *assumed* estimate.
    /// 5.15a makes readiness a measurement; that one was a hope.
    /// `CORE` 7.3c / `MSG` 5.2a — "when it is armed, and **again whenever
    /// `settled` changes**".
    ///
    /// ⛔ **Both halves, and the second one is not optional.** This used to write
    /// to the bundle alone, which was invisible even once a host existed. Worse,
    /// the only measurement a host ever saw was the immediate answer to `arm`,
    /// carrying `settled: false` and a nine-second estimate — so PinPointStudio's
    /// screen would show *Arming — 9000 ms* and never leave it. An arm with no
    /// terminal state is the same hole as sending no `readiness` at all, reached
    /// a different way (raised by PinPointStudio, 27 Aug 2026).
    private func reportReadiness(blocked override: ReadinessMeasurement.Blocker? = nil) {
        var measurement = currentReadiness()
        if let override { measurement.blocked = override }
        if let recording {
            do {
                try recording.report(measurement)
            } catch {
                recordingError = String(describing: error)
            }
        }
        // ⚠ Unsolicited, and that is the point — 7.3c makes the *change* the
        // trigger, not the request.
        if let link {
            Task { await link.report(measurement) }
        }
    }

    /// "Wednesday range" — the session title on C3.
    nonisolated static func sessionName(for start: Date) -> String {
        let day = DateFormatter()
        day.dateFormat = "EEEE"
        return "\(day.string(from: start)) session"
    }

    /// The local override of a host-controlled state (REQ-STATE-1).
    ///
    /// ⛔ **No `readiness` is sent from here, and that is a decision.** The
    /// obvious move is to report on the way down, since `settled` changes. But a
    /// `Readiness` can say only *settled* or *not settled, ready in N ms* — and
    /// a device that has just been disarmed is neither. Sending `settled: false`
    /// with an estimate would tell a host this device is **arming**, which is the
    /// opposite of what happened, and 5.15a forbids the state name that would
    /// have said so plainly.
    ///
    /// ⚠ So a locally-disarmed device cannot tell a host it has stopped. That is
    /// a genuine expressiveness gap of the same shape as the `shot_disposition`
    /// one: no way to state a terminal negative. `blocked_reason` does not fit —
    /// nothing is blocked. Raised with PinPointStudio 27 Aug 2026; their arming
    /// timeout is the honest interim on their side.
    public func disarm() {
        settleTask?.cancel()
        settleTask = nil
        isSettling = false
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
        // ⛔ Trap 7 — the baseline belongs to the Stream that is closing with
        // this arm. Carrying it into the next one would subtract a count taken
        // against a recorder that no longer exists.
        discardBaselineByStream.removeAll()
        lastBufferMargin = nil
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
    ///
    /// ⛔ **Which regime this Session opens in is decided here and never again.**
    /// A host that opened a Session before the arm gets a hosted recording; an
    /// arm with no host gets a hostless one, and a host arriving later does not
    /// convert it — `Session.timebase_ref` is immutable (I16) and the bundle's
    /// `session_open` is already written. The hostless Session it leaves behind
    /// is what `SessionOfferService` exists to hand over.
    private func startRecording() async {
        guard recording == nil else { return }
        shotIdByCapture.removeAll()
        heardInstantByCandidate.removeAll()
        transferQueue = nil
        do {
            // ⚠ The host's Session id, where there is one: every Stream, Capture
            // and Shot in the bundle has to agree with it.
            let hosted = try? await link?.openHostedSession(
                promotion: DetectAndMint.defaultPromotion())
            let sessionId = link?.hostSession?.sessionId
                ?? "ses:\(UUID().uuidString.lowercased())"
            let session = try RecordingSession(
                store: store, device: device,
                sessionId: sessionId,
                control: hosted.map(RecordingSession.Control.hosted) ?? .hostless,
                // ⛔ **The mode, not `activeMode?.id`** (#102). `id` names a
                // mode to this app — `1920x1080@240.0-wide` — and the profile
                // the declaration actually emits is `1920x1080@240`, so every
                // Stream this app opened named a profile that did not exist
                // (5.11a, I5). `RecordingSession` now derives both the
                // Source and the profile from the mode itself.
                mode: activeMode,
                micToBall: micToBallDistance,
                // ⛔ A4's setting, finally reaching the thing it names. It has
                // been user-visible and inert since the first build, and
                // REQ-PRIV-2 makes the privacy label a claim about *this* value.
                retention: audioRetention.policy)
            recording = session
            recordingError = nil
            updateIdleTimer()

            // ⛔ The link's Streams are the recording session's own records, so
            // the wire and the bundle name one `profile_id` and one `opened_at`.
            if hosted != nil {
                try await session.openHostedStreams()
                // REQ-SESS-5/6 — payload follows the announce on its own channel,
                // at whatever rate the socket allows.
                session.startTransferring()
                // ⛔ **Preview is NOT opened here any more.** It belongs to the
                // link, not to a recording session — `LivePreview`, opened when
                // the host asks for it at connect. Opening it from arm made a
                // picture conditional on a golfer pressing Capture, which is the
                // opposite of what preview is for (5.11.2, #108).
            }

            // ⚠ **`readiness` is NOT reported here** — see `reportReadiness()`.
            // 7.3c confers it through Capture, and 5.15a makes it a measurement:
            // sending it at session open said `settled` before the sensor had
            // delivered a frame.

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
    /// - Parameter listener: ⛔ **`true` only for a link the HOST dialled**, which
    ///   today means the cable and nothing else (`RV` 2d inverts — design §3).
    ///   The device then sends no `hello`; `libppcp` answers the host's.
    public func connect(transport: any PeerTransport,
                        sessionId: String,
                        hostDisplayName: String?,
                        declaration: PpcpDeclaration? = nil,
                        listener: Bool = false) async {
        await disconnect()
        do {
            let session = try HostLinkSession(transport: transport,
                                              sessionId: sessionId,
                                              hostDisplayName: hostDisplayName,
                                              device: device,
                                              declaration: declaration,
                                              listener: listener)
            link = session
            updateIdleTimer()
            // ⛔ Commands come back this way. State is still polled — see
            // `startHostLinkPolling` — and the two are deliberately separate.
            session.delegate = self
            // ⛔ `MSG` 9.1 — what this device already holds, offered to the host
            // it just reached. ⚠ The read closure is here because `CaptureCore`
            // opens no file (ground rule 8); the store is the app's.
            await session.attachOfferStore(store) { bundle in
                try Data(contentsOf: bundle.bundleFile)
            }
            hostLink = session.hostLink
            await session.open()
            hostLink = session.hostLink
            if case .failed(let message) = session.phase {
                hostLinkError = message
            }
            startHostLinkPolling()
        } catch {
            hostLinkError = String(describing: error)
            hostLink = HostLink(state: .lost)
        }
    }

    /// ⛔ **`HostLinkSession.hostLink` moves continuously once E3.2's ticker
    /// starts (`linkState`/`clockAgreement` update on every sync tick) — nothing
    /// re-read it into this `@Observable` copy after the two assignments in
    /// `connect()`.** Found live against real PinPointStudio: the burst had
    /// converged (`hasEst=true`, 23 exchanges) while B3 still showed "Pairing"
    /// and every telemetry row dashed, because `hostLink` was frozen at the
    /// snapshot taken the instant `open()` returned.
    private func startHostLinkPolling() {
        hostLinkTicker?.cancel()
        hostLinkTicker = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                guard let self, let link = self.link else { return }
                self.hostLink = link.hostLink

                // ⛔ **THE LINK DYING IS A LEVEL, AND THIS IS THE ONLY PLACE THAT
                // ALREADY WATCHES IT.** A transport that dies while this app stays
                // foregrounded — PinPointStudio restarted, cable pulled, WiFi blip
                // — only changes what `HostLinkSession` REPORTS: `phase` moves to
                // closed/failed and the state reads `.lost`. Nothing cleared
                // `AppModel.link` on that path, so the app sat holding a dead
                // session, `beginSearchingForHost()`'s `link == nil` guard refused
                // to start a search, the wired listener stayed down, and the phone
                // was stranded until somebody backgrounded and reopened it.
                //
                // ⚠ Tearing the dead session down here is what makes BOTH paths
                // recover: `disconnect()` clears `link`, and `linkDidEnd()` then
                // re-arms the browse and the cable.
                if link.hostLink.state == .lost {
                    PpcpLog.linkPhase("lost", detail: self.hostLinkError ?? "no error reported")
                    await self.disconnect(.cancelled)
                    self.linkDidEnd()
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// ⚠ Idempotent, and safe to call when nothing is up.
    public func disconnect(_ reason: ChannelCloseReason = .normal) async {
        hostLinkTicker?.cancel()
        hostLinkTicker = nil
        guard let link else { return }
        // ⛔ 5.11j — preview is live-only, so its Stream dies with the link that
        // carried it. Nothing to resume, nothing to keep.
        stopPreview()
        await link.close(reason)
        self.link = nil
        updateIdleTimer()
        hostLink = HostLink(state: .none)
        hostLinkError = nil
    }

    /// ⛔ **Backgrounding drops the socket, so say so.** iOS suspends the
    /// connection and a link that claimed to be up on return would be exactly the
    /// dishonesty these screens were just cleared of. Reconnection is E3.5.
    /// Whether the app is foregrounded. ⚠ Tracked explicitly because BOTH
    /// reconnection paths are now level-driven and a level needs a value to read;
    /// a scene-phase callback alone is an edge, which is the shape of defect this
    /// file has now been bitten by twice.
    public private(set) var isActive = false

    /// The app became active. Starts both level loops and does the one-shot work
    /// that genuinely belongs on this transition.
    public func sceneDidBecomeActive() {
        isActive = true
        // ⛔ **HERE, NOT INSIDE beginSearchingForHost() — THERE ARE TWO LOOPS.**
        // The guard was first written one level down and did not work, because
        // `startWiredReconcile()` is a SIBLING call, not a nested one: a 2 s
        // level loop that publishes wired presence and lets the host dial in
        // over usbmux, entirely independently of the browse. `make test-device`
        // requires a connected phone, so the cable is always there and that
        // second path always ran.
        //
        // The app must not fight its own tests: `DeviceSessionTests` is
        // app-HOSTED, so this process's own AppModel exists alongside the one
        // each test builds, and a second dial from one peer id is refused by
        // PinPointStudio's §6.1 rule. Suppressing both loops leaves the link
        // entirely to the test.
        if Self.isUnderTest {
            // Said out loud: a search that silently did nothing is the other
            // half of this bug.
            PpcpLog.reconnect("suppressed", detail: "under test — the test owns the link")
            return
        }
        startWiredReconcile()
        beginSearchingForHost()
    }

    public func linkDidEnterBackground() async {
        isActive = false
        // ⛔ And the search stops with it. A browse behind a suspended app spends
        // radio on `RV` §3's convenience path and could only produce a link the
        // next suspension drops again.
        stopSearchingForHost()
        // ⛔ **And the wired listeners with it.** A suspended app cannot complete
        // a handshake, so a presence record it is still serving would send the
        // host to a port that accepts a connection and then says nothing —
        // which is `PpcpListener`'s bind timeout, five seconds of it, per dial.
        await stopWiredListening()
        guard link != nil else { return }

        // ⛔ **An open recording keeps its link.** 7.4d — losing the host must
        // not cost a captured frame, and dropping it *deliberately* because
        // someone glanced at another app is the same cost taken on purpose. A
        // hosted Session's Mint engine lives on the link peer, so disconnecting
        // under one does not merely lose the host: it stops this device minting
        // at all, and every subsequent tick fails with `channelClosed`.
        //
        // ⚠ Observed on hardware, 27 Aug: switching apps for ten seconds ended
        // the session and left "Nothing is being recorded" over a ring that was
        // still perfectly healthy. iOS may suspend us and kill the socket
        // anyway — that is the *link* being lost, which 7.4c and `HostLinkDriver`
        // already handle honestly. This is about not doing it to ourselves.
        guard recording == nil else { return }

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
    /// ⛔ **THE APP MUST NOT FIGHT ITS OWN TESTS.** `DeviceSessionTests` is
    /// app-HOSTED: it runs inside this process, builds its own `AppModel` and
    /// dials the host itself. With the app's automatic search also running there
    /// are TWO dials from one phone, PinPointStudio keeps the first and closes
    /// the second as a duplicate (its design §6.1, "one phone, one link"), and
    /// the test's link is the one that dies -- so `session_open` never reaches
    /// it and every hosted assertion fails on a fault that is not in the
    /// product.
    ///
    /// Measured 1 Sept: `aHostedSwingProducesAClip` failed at
    /// `await link.hostSession` on every run, against a host whose log said
    /// "keeping the one it has and closing the newcomer" each time. The suite
    /// exists to take the person out of the hardware loop and could not, because
    /// nothing here knew it was under test.
    static var isUnderTest: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["PPC_NO_AUTOCONNECT"] == "1"
    }

    public func beginSearchingForHost() {
        // ⛔ **The cable is not the radio, and this is not part of the browse.**
        // It is here because this is the moment §3 already decided on — the app
        // became active with no link up — and because a second entry point for
        // the same moment is a second thing to forget. `beginWiredListening()`
        // guards itself; a device holding no pairing publishes nothing.
        beginWiredListening()
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

    /// ⛔ **A LINK THAT ENDS WHILE THE APP IS ON SCREEN USED TO LEAVE IT DORMANT
    /// FOR EVER**, on either transport, until somebody backgrounded the app and
    /// reopened it. Found on the Linux port, 30 Aug 2026, and it accounted for
    /// most of two days' friction: every host restart needed a manual app
    /// restart, which twice sent the investigation after host faults that did
    /// not exist.
    ///
    /// ⚠ **The machinery was always there and merely unarmed.** The reconnect
    /// sweep widens (3 s, then 2/5/10 s, then every 30 s) and explicitly *"does
    /// not stop, because the host may be switched on at any moment while the user
    /// waits"* — it just never started, because the coordinator fires on exactly
    /// two edges and *a link ending while already active is neither of them*.
    ///
    /// Called wherever a link is torn down. Idempotent, and a no-op in the
    /// background, where a browse would only spend radio on a link the next
    /// suspension drops.
    public func linkDidEnd() {
        guard isActive, link == nil else { return }
        PpcpLog.reconnect("re-arming after a link ended while foregrounded")
        beginSearchingForHost()   // guards itself; also re-arms the cable
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

    // MARK: The wired path (design §5, §6)

    /// The presence listener and the per-pairing `PpcpListener`s behind it.
    /// ⛔ Owned here for the same reason `link` is: a listener that dies with a
    /// view hierarchy is a listener that dies on a screen rotation.
    private var wiredListener: WiredPresenceListener?
    private var wiredTask: Task<Void, Never>?
    /// The pairing-set generation the running listener published. A change means
    /// the record on the wire is stale — see ``reconcileWiredListening()``.
    private var wiredPairingGeneration: UInt64 = 0
    private var wiredReconcileTask: Task<Void, Never>?
    /// ⚠ Two seconds, matching the host's own wired retry: the phone should be
    /// listening within about one of the host's probes of becoming eligible.
    /// The tick itself is free — it reads no file unless something must change.
    private static let wiredReconcileSeconds = 2

    /// Why wired is unavailable, when someone goes looking.
    ///
    /// ⛔ **A diagnosis, never a banner** (`RV` 3.6a, design §6.2). An unplugged
    /// phone, a charge-only cable and a taken presence port are ordinary states of
    /// the world, and the shape of this is `reconnectDiagnosis` — deliberately,
    /// because it is the same kind of statement about the same kind of silence.
    public private(set) var wiredDiagnosis: String?

    /// Publishes this device on the cable: one `PpcpListener` per held pairing,
    /// then the presence record naming them (C3/C5).
    ///
    /// ⛔ **Idempotent, and it holds no opinion about whether a cable exists.**
    /// iOS gives an app no way to tell a data-capable host from a dumb charger —
    /// `UIDevice.batteryState == .charging` is true for a wall socket and there is
    /// no public API behind it (design §6.1). So this device simply listens on
    /// loopback and lets the host, which *can* see a usbmux `Attached`, decide.
    /// Nothing here is spent on a radio and nothing is advertised.
    /// ⛔ **THE CABLE IS UNREACHABLE UNLESS THIS IS RUNNING, so it is driven by a
    /// LEVEL and not by an edge.** Found on the Linux port, 30 Aug 2026: the
    /// listener came up only when the app entered its connect flow — becoming
    /// active, or the find-host button — so PinPointStudio spent whole sessions
    /// knocking every two seconds on a closed port and getting
    /// `no presence record … (Number=3)`. "Restart the capture app" was the
    /// universal remedy all day, and that is what masked it.
    ///
    /// ⚠ This is the SAME defect the host had one repo over, where the wired path
    /// fired only on a usbmux `Attached` event and so never fired in the ordinary
    /// sequence. It was fixed there by checking the level on a timer rather than
    /// trusting an edge, and this is the device's half of the same lesson.
    ///
    /// The rule this reconciles to, evaluated every ``wiredReconcileSeconds``:
    /// **a pairing is held, no link is up, and the app is active ⇒ the listener
    /// is up and publishing the CURRENT pairing set.** Anything else ⇒ it is down.
    private func reconcileWiredListening() {
        guard isActive, link == nil else {
            if wiredListener != nil { Task { await stopWiredListening() } }
            return
        }
        // ⛔ The pairing set changes without the cable moving — a re-pair is the
        // everyday case — and a record naming the OLD set makes the host answer
        // "none of which resolves to a pairing this host holds" and give up.
        // Restart on a change rather than re-reading the file every tick.
        let gen = PairingSecretStore.currentGeneration()
        if wiredListener != nil, gen != wiredPairingGeneration {
            Task { @MainActor in
                await stopWiredListening()
                beginWiredListening()
            }
            return
        }
        if wiredListener == nil { beginWiredListening() }
    }

    /// Starts the reconcile loop. Idempotent; runs for the life of the app.
    private func startWiredReconcile() {
        guard wiredReconcileTask == nil else { return }
        wiredReconcileTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                self?.reconcileWiredListening()
                try? await Task.sleep(for: .seconds(Self.wiredReconcileSeconds))
                if self == nil { return }
            }
        }
    }

    public func beginWiredListening() {
        guard wiredListener == nil, link == nil else { return }
        // Remembered so the reconcile can tell a stale record from a fresh one
        // without reading the store on every tick.
        wiredPairingGeneration = PairingSecretStore.currentGeneration()
        // `RV` 4.4d — untrusted display text, and it is ours. ⚠ On iOS 16+ this
        // is the model name for an app without the entitlement, which is exactly
        // the amount of information this record should carry.
        #if canImport(UIKit)
        let label = UIDevice.current.name
        #else
        let label: String? = nil
        #endif
        let listener = WiredPresenceListener(displayLabel: label)
        wiredListener = listener
        wiredTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let held: [WiredPresenceListener.HeldPairing]
            do {
                // ⛔ 5.1c — re-derived from `PRK` on each start, never stored.
                held = try PairingSecretStore.pairings().compactMap { row in
                    guard let keys = try PairingSecretStore.keys(forSession: row.sessionId) else {
                        return nil
                    }
                    return WiredPresenceListener.HeldPairing(sessionId: row.sessionId,
                                                             hostDisplayName: row.displayName,
                                                             keys: keys)
                }
            } catch {
                // ⛔ *Erratum E56* again — a store that could not be read is not a
                // store that is empty, and the two must not be conflated here
                // either.
                self.wiredDiagnosis = String(describing: error)
                self.wiredListener = nil
                return
            }
            guard Task.isCancelled == false else { return }
            do {
                _ = try await listener.start(pairings: held) { [weak self] wired in
                    PpcpLog.wiredPresence("host dialled in",
                                          detail: "session=\(wired.sessionId)")
                    await self?.adoptWiredLink(wired)
                }
                PpcpLog.wiredPresence("up", detail: "\(held.count) pairing(s) published")
                self.wiredDiagnosis = nil
            } catch {
                // ⚠ Including a taken presence port, which is survivable by
                // design: the host reads a record it cannot parse and treats this
                // device as not wired.
                PpcpLog.wiredPresence("FAILED to start", detail: String(describing: error))
                self.wiredDiagnosis = String(describing: error)
                await listener.stop()
                self.wiredListener = nil
            }
        }
    }

    /// ⚠ Idempotent, and safe to call when nothing is up.
    public func stopWiredListening() async {
        wiredTask?.cancel()
        wiredTask = nil
        guard let wiredListener else { return }
        PpcpLog.wiredPresence("down")
        self.wiredListener = nil
        await wiredListener.stop()
    }

    /// A link PinPointStudio dialled over the cable.
    ///
    /// ⛔ **`listener: true`** — the host is the initiator here, so this device
    /// sends no `hello` (`RV` 2d inverted; see `HostLinkSession.wired`).
    private func adoptWiredLink(_ wired: WiredPresenceListener.WiredLink) async {
        // ⛔ **Design §6.1 rule 1: never a second link, on either transport.** The
        // incumbent has the sync history, and a rule with no comparison in it
        // cannot oscillate.
        guard link == nil else {
            await wired.transport.close(.cancelled)
            return
        }
        stopSearchingForHost()
        await connect(transport: wired.transport,
                      sessionId: wired.sessionId,
                      hostDisplayName: wired.hostDisplayName,
                      listener: true)
        // ⛔ The record names ports that are now serving a link, and §6.1 rule 1
        // says there will not be a second one. Stop publishing until the link
        // ends; `beginSearchingForHost()` starts it again on the next activation.
        await stopWiredListening()
    }

    /// ⛔ **iOS blocks USB data on a device that has been locked for over an
    /// hour** (USB Restricted Mode, design §9.5), and this app never touched the
    /// idle timer — so at a range a wired session died for no visible reason, and
    /// the first symptom was a dropped link rather than anything naming the cause.
    ///
    /// ⚠ It is owed to the capture path independently of the cable: capture needs
    /// the foreground and the screen, and a phone that auto-locks mid-session
    /// stops recording. The link is included as well as the recording because
    /// backgrounding drops the link, and a dropped wired link is expensive.
    private func updateIdleTimer() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = (recording != nil || link != nil)
        #endif
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

    /// C3's swipe-to-delete. ⛔ Device-local only — there is no host-side
    /// deletion or sync-state tracking yet, so this removes the bundle this
    /// phone holds and nothing else.
    /// ⛔ **`try?` here was the whole bug.** A delete that failed looked exactly
    /// like one that worked: the row stayed, nothing was said, and the sessions
    /// "came back". Reported on hardware 27 Aug — the same shape as `warmUp`
    /// shipping a dead *Arm* for weeks because a guard returned silently. When a
    /// refusal can happen, it has to say so.
    ///
    /// ⛔ **And the session being recorded right now is in this list**, with an
    /// open file handle on it. Removing its directory underneath the writer
    /// leaves a `RecordingSession` appending to an unlinked inode — bytes going
    /// nowhere, and a bundle that reappears the moment anything re-reads the
    /// store. Refused explicitly, with the remedy named.
    public func deleteRecordedBundle(sessionId: String) {
        guard let bundles = try? store.bundles(),
              let bundle = bundles.first(where: { $0.sessionId == sessionId }) else {
            recordingError = "That session is no longer on this phone."
            return
        }
        if let recording, recording.sessionId == sessionId {
            recordingError = "That session is still recording. End the session first, then delete it."
            return
        }
        do {
            try store.delete(bundle)
            recordingError = nil
        } catch {
            recordingError = "Could not delete that session: \(error)"
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
        // REQ-SYNC-2's third trigger — oscillator frequency shifts with
        // temperature, so a changed thermal state restarts the estimator's
        // window rather than waiting for the next maintenance probe.
        if let previous = lastThermalStateForSync, previous != health.thermal,
           let link {
            Task { await link.notifyThermalEvent() }
        }
        lastThermalStateForSync = health.thermal
        if let mode = activeMode {
            storage = device.storageHeadroom(forMode: mode)
        }

        // `PPCP-MSG` 12.2a — a torch state nobody commanded.
        //
        // ⛔ **Above the `armed` guard below, and it matters.** A torch is warm-
        // state hardware: an operator lights it to check framing long before
        // anything is retaining, and a thermal cutoff does not wait for an arm.
        // Polling it only while armed would make the one case CB4 names —
        // asynchronous drift — invisible for most of the time it can happen.
        //
        // ⚠ **Observable here and nowhere else yet.** Emitting `actuator_state`
        // on the wire is D15; this makes the change *visible*, which is D14's
        // whole obligation. The property is what D15 will read.
        let nowNs = MachClock.hostTimeNs
        if let change = device.torchChangeSincePoll() {
            lastAutonomousTorchChange = change
            torch = change.state
            // `PPCP-MSG` 12.2a — a change no acknowledged command caused, so it
            // is the message's own case rather than a correction.
            if let link, let actuator = link.declaration.actuators.first {
                Task { [weak link, state = change.state] in
                    await link?.sendActuatorState(actuatorId: actuator.id,
                                                  isOn: state.on,
                                                  sinceNs: change.observedAtNs)
                }
            }
        }
        // `PPCP-MSG` 5.5 — above the `armed` guard, and that is the point of
        // CR-02 §4a. See the ⭐ in `warmUp`.
        refreshDeviceStatus(nowNs: nowNs)
        // E1.1's instrument, sampled at the same 1 Hz. ⚠ Cheap by construction —
        // `ringStats` is a struct copy of plain integers read through the sample
        // queue, and it is NOT on the frame path.
        guard captureStatus.state == .armed else { return }
        ringStats = device.ringStats
        // `PPCP-MSG` 5.6 — below the guard, because a ring margin needs a ring:
        // 5.21c confines `buffer_status` to a `shot_windowed` Stream and there
        // is none until this device is retaining.
        refreshBufferStatus()

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

    // MARK: The torch (CORE §5.19, PPCP-MSG §12)

    /// What the torch is **actually** doing, as last observed or last commanded.
    ///
    /// ⛔ `nil` is "not known", not "off" (`CORE` §5.1's last paragraph). Nothing
    /// has read the hardware until the first command or the first tick with a
    /// warm device, and a `false` there would be a claim nobody measured — the
    /// same mistake `bufferSeconds` was fixed for (E1.1).
    public private(set) var torch: TorchState?

    /// The most recent change **no acknowledged command caused** (12.2a).
    ///
    /// ⚠ **What D15 sends `actuator_state` from.** D14 stops at making it
    /// observable, deliberately: the emission has a message catalogue behind it
    /// that `libppcp` does not have yet, and a half-wired sender would be worse
    /// than none.
    public private(set) var lastAutonomousTorchChange: TorchChange?

    /// `CORE` 5.19a — what this device declares in `Peer.actuators`.
    ///
    /// ⚠ A method rather than a computed property, because it reads the hardware
    /// and an `@Observable` computed property is read on every view invalidation.
    public func torchCapability() -> TorchCapability { device.torchCapability() }

    /// `PPCP-MSG` 12.1 — command the torch and take the achieved state back.
    ///
    /// ⛔ **The result is the ack, and it is not the request.** Trap 3: a
    /// command that was accepted is not a command that was achieved, and the
    /// caller — a UI switch today, D15's `actuator_command_ack` tomorrow —
    /// reflects what came back rather than what went in.
    @discardableResult
    public func setTorch(_ request: TorchRequest) -> TorchOutcome {
        let outcome = device.setTorch(request)
        // ⚠ Only on `applied`. A refusal changed nothing, so overwriting the
        // observed state with anything at all would be inventing a reading.
        if let achieved = outcome.achieved { torch = achieved }
        return outcome
    }

    // MARK: CR-02 statistics — MSG 5.5 / 5.6

    /// The last status **emitted** per Source, so the next tick can tell a change
    /// from a repeat.
    ///
    /// ⛔ **`since` is when `available` CHANGED, not when it was read** (5.20).
    /// Keeping the whole status rather than only the value is what lets the
    /// instant survive the ticks in between; re-stamping it every second would
    /// make the field say "one second ago" forever.
    private var lastSourceStatus: [String: SourceStatus] = [:]

    /// The last margin emitted, so 5.6c's on-change discipline has something to
    /// compare against.
    private var lastBufferMargin: BufferMargin?

    /// ⛔ **Trap 7 — `discarded_since_open` is per Stream open and
    /// `RingStats.fragmentsEvicted` is per ARM.** The recorder is built by
    /// `startRetaining`, so its counter resets every time a golfer arms while
    /// the wire field must not. This is the baseline subtracted from it, taken
    /// the first time a margin is assembled for a Stream and held until that
    /// Stream closes.
    private var discardBaselineByStream: [String: Int] = [:]

    /// `CORE` 5.21 `retention_target` — what the ring is *trying* to hold.
    ///
    /// ⚠ The two constants that actually decide it, multiplied here rather than
    /// written as a third constant that could disagree with them.
    static let ringRetentionTargetNs =
        Int64(Double(RingBufferRecorder.fragmentCapacity)
              * RingBufferRecorder.fragmentSeconds * 1_000_000_000)

    /// `PPCP-MSG` 5.5 — emit a `device_status` for every declared Source whose
    /// availability moved since the last tick.
    ///
    /// ⛔ **On change and never per tick** (5.5a). The tick notices; the message
    /// reports what moved.
    ///
    /// ⚠ **Two layers, and they are separate reads.** The hardware answers
    /// `in_use` and `disconnected` through the port; `permission_denied`,
    /// `thermal_limit` and `storage_full` are read where this application
    /// already reads them, and are overlaid. ⛔ Overlaid *first*, in the order
    /// `currentBlocker()` states and for the same reason: a thermal warning
    /// shown for a camera the user never granted is noise.
    ///
    /// ⛔ **`no_source` is not in the vocabulary** (5.20d, erratum E64). The
    /// event only ever fires for an already-declared Source, so a value naming
    /// its own precondition's negation could never be true. A device with no
    /// camera declares none and emits nothing for one.
    private func refreshDeviceStatus(nowNs: Int64) {
        // ⚠ Nothing to tell without a counterpart, and the declaration comes
        // from the LINK — `recording?.declaration` is nil until a golfer presses
        // Capture, which is the mistake #108 was.
        guard let link else { return }
        let hardware = device.sourceHardwareAvailability()
        for source in link.declaration.sources {
            let availability: SourceAvailability
            if let overlay = unavailableOverlay(forSourceKind: source.kind) {
                availability = .unavailable(overlay)
            } else if let observed = hardware[source.id] {
                availability = observed
            } else {
                // ⛔ Absence is "not known" (`CORE` §5.1), never an implied
                // "available". The microphone and the IMU land here: nothing on
                // this platform answers 5.20's question about them without
                // inventing an answer.
                continue
            }
            guard lastSourceStatus[source.id]?.availability != availability else { continue }
            let status = SourceStatus(sourceId: source.id, availability: availability,
                                      sinceNs: nowNs)
            lastSourceStatus[source.id] = status
            Task { [weak link] in await link?.sendDeviceStatus(status) }
        }
    }

    /// The reasons this application already reads, mapped onto 5.20's registry.
    ///
    /// ⚠ **Per kind, because the permissions are.** A denied microphone says
    /// nothing about the camera and the wire is per Source, so folding them
    /// would report a fault against hardware that has none.
    private func unavailableOverlay(forSourceKind kind: String) -> SourceUnavailableReason? {
        switch kind {
        case "camera" where permissions.camera != .allowed: return .permissionDenied
        case "microphone" where permissions.microphone != .allowed: return .permissionDenied
        default: break
        }
        // ⛔ 5.8's ordinal vocabulary, and `critical` is the level at which this
        // device stops — matching `currentBlocker()` exactly, because two
        // thresholds for one fact eventually disagree.
        if captureStatus.thermal == .critical { return .thermalLimit }
        if storage.freeBytes > 0,
           Self.storageFloor.verdict(freeBytes: UInt64(storage.freeBytes)) == .refuseToArm {
            return .storageFull
        }
        return nil
    }

    /// `PPCP-MSG` 5.6 — the ring's standing margin on the `shot_windowed` Stream.
    ///
    /// ⛔ **`shot_windowed` only** (5.21c). The `metadata` and `audio` Streams
    /// are `continuous` and have no ring to have a margin in; the video Stream
    /// is the one this reports, and the library refuses the others anyway.
    private func refreshBufferStatus() {
        guard let link, let stream = recording?.videoStream,
              stream.continuity == .shotWindowed,
              let retainedFromNs = ringStats.retainedFromNs else { return }
        // ⛔ Trap 7 — the baseline, taken once per Stream open. `fragmentsEvicted`
        // resets per arm and the wire field is per Stream open.
        let baseline = discardBaselineByStream[stream.id] ?? {
            discardBaselineByStream[stream.id] = ringStats.fragmentsEvicted
            return ringStats.fragmentsEvicted
        }()
        // ⛔ **Evictions only** (5.21a, trap 7). `framesDroppedEncoderBusy` is
        // deliberately absent: those frames are accounted for in the Capture's
        // `achieved_summary` and counting them here would count them twice.
        let discarded = UInt64(max(ringStats.fragmentsEvicted - baseline, 0))
        // ⛔ Trap 8 — `gapBuckets`/`largestGaps` do NOT go on the wire. They are
        // receiver-side aggregation over repeated readings of these four fields.
        let margin = BufferMargin(streamId: stream.id,
                                  retainedFromNs: retainedFromNs,
                                  retentionTargetNs: Self.ringRetentionTargetNs,
                                  discardedSinceOpen: discarded,
                                  lastDiscardSinceNs: ringStats.lastDiscardStartNs,
                                  lastDiscardDurationNs: ringStats.lastDiscardStartNs
                                      .flatMap { start in
                                          ringStats.lastDiscardEndNs.map { $0 - start }
                                      })
        // ⛔ On change (5.6c). A ring that has not moved has nothing to report,
        // and `retained_from` moving every half second is exactly the change the
        // field is for.
        guard margin != lastBufferMargin else { return }
        lastBufferMargin = margin
        Task { [weak link] in await link?.sendBufferStatus(margin) }
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
            Task { @MainActor [weak self] in await self?.observe(window) }
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
                await self?.pumpMint()
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
    func observe(_ window: AudioWindow) async {
        guard let recording else { return }
        do {
            let detections = try await recording.observe(window)
            candidateCount += detections.count
            // REQ-SYNC-4's first operand, kept until the host arbitrates. ⚠ The
            // Candidate's `atNs` is already time-of-flight corrected, which is
            // what makes the eventual subtraction a clock residual rather than a
            // measurement of how far away the ball was.
            for detection in detections {
                heardInstantByCandidate[detection.candidate.id] = detection.candidate.atNs
            }
        } catch {
            recordingError = String(describing: error)
        }
    }

    func pumpMint() async {
        guard let recording else { return }
        do {
            // ⛔ **Capture time.** The conversion into the Session's reference
            // clock belongs to `RecordingSession`, which is the only place that
            // knows whether the two are the same clock (5.13c, I4).
            let minted = try await recording.pumpMint(nowNs: MachClock.hostTimeNs)
            guard minted.isEmpty == false else { return }
            // ⛔ **The shots the library shows, from the shots the Mint engine
            // issued.** `minted` was counted and discarded, and C1 and C3
            // rendered `PreviewFixtures.session` — 41 invented shots dated 21
            // August, on every device, forever.
            for entry in minted {
                let shot = entry.shot
                shotCount += 1
                // ⚠ Surfaced on screen, because a diagnostic nobody can read on
                // a range is a diagnostic that does not exist.
                if let diagnostic = entry.clipDiagnostic { recordingError = diagnostic }
                let row = Shot(
                    // ⛔ **Capture time.** `shot.t0Ns` is in the host's
                    // `timebase_ref` (5.13c); the anchor labels instants on this
                    // device's clock. Using the wire value put every shot on a
                    // real device roughly two hours out (27 Aug).
                    minted: shot, atNs: entry.captureT0Ns,
                    ordinal: shotCount,
                    anchor: recording.anchor,
                    // ⛔ `nil`. Nothing records a clip (E1.1), and a duration
                    // here would be a measurement claim about video that does
                    // not exist.
                    duration: nil)
                session.shots.append(row)
                // ⛔ The join. Kept here because this is the only moment both
                // ids exist together: `capture_announce` has gone out by now
                // and a `payload_ack` naming that Capture has nowhere else to
                // land.
                for captureId in shot.captureIds { shotIdByCapture[captureId] = row.id }
                // ⛔ 8.3f — a Shot minted while the host was unreachable is one
                // `session_resume` must name on reconnect, unrenumbered (4.3c).
                // Capture never stopped (7.4d); this is how the host finds out
                // what it missed rather than being handed a tidied history.
                if let link, link.isOutage {
                    Task { await link.recordMintedDuringOutage(shot.id) }
                }
            }
            // ⛔ **Refreshed on minting, not only on the host's answer.** The
            // announce has already put a row in the library's transfer table
            // marked `pending`, and until now nothing read it until a
            // `payload_ack` or a `capture_committed` arrived — so with a host
            // that never acks, and neither `ppcp-sim` nor PinPointStudio does
            // today, a queued shot stayed invisible on C3 for the whole session.
            refreshTransferState()
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
        updateIdleTimer()
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
    /// ⛔ **It has been measured now, and it was wrong by most of an order of
    /// magnitude** (#101, iPhone 16, 25 August 2026):
    ///
    ///     no format change     ~75 ms
    ///     format change     ~8,850 ms
    ///
    /// ⚠ **This constant is now only the fallback**, used where an arm has not
    /// yet produced a measurement of its own. What actually goes on the wire is
    /// `measuredSettleNs` from the arm that just happened — see
    /// `reportReadiness()` — which is what 5.15a asks for and what the previous
    /// comment here was waiting for.
    ///
    /// ⚠ Left at the pessimistic end deliberately: a first arm that under-promises
    /// and beats it is better than one that promises a second and takes nine.
    nonisolated static let assumedSettleMs: UInt32 = 9_000

    /// Exposed so the preview view can attach. It hands over the *device*, not the
    /// session — `AVCaptureSession` never becomes reachable from a view model.
    public var captureDevice: any CaptureDevice { device }
}

// MARK: - Under host control (E3.3, E3.4, E3.5)

/// The commands half of the live link. State still arrives by polling
/// `HostLinkSession.hostLink`; this is what the host *asks for*.
///
/// ⚠ **Every method here is a call site, and this file's history says that is
/// the thing to check.** Three defects on 25 August were all "written, correct,
/// never called", and this target cannot test for one — so the methods that are
/// not built yet say so out loud rather than being empty.
@MainActor
extension AppModel: HostLinkSessionDelegate {

    public func hostLink(_ link: HostLinkSession, didOpenSession sessionId: String,
                         parameters: PpcpSessionParameters) {
        // ⛔ **A new counterpart has been told nothing** (5.5a). The on-change
        // rule is per receiver, not per fact: keeping the previous emissions
        // would mean this host never learns a Source's availability until it
        // happens to move. Cleared so the next tick states the current value
        // once, and then goes quiet again.
        lastSourceStatus.removeAll()
        // ⛔ Nothing *captures* here. PinPointStudio opens the Session at
        // `declare`, long before an arm, and a Session opened now would be one
        // the host's arbitration parameters could not reach. `startRecording`
        // reads `link.hostSession` when the arm actually happens.
        refreshHostLink()
        // ⛔ **`ENC` 2.1d's third channel, at session open and not at arm.**
        // Preview's whole use is setup and framing (5.11.2), which happens
        // before anything is captured — so the channel it needs has to exist
        // before anything is armed. This was called from `startRecording`, which
        // is why a host asking for preview at connect got a picture only after a
        // golfer pressed Capture, if at all (#108).
        //
        // ⚠ Opened unconditionally, not on demand: a host's `stream_open`
        // arrives immediately after `session_open` and dialling a channel takes
        // a round trip. A channel with no preview Stream on it costs nothing.
        Task { [weak link] in await link?.openPreviewChannel() }
    }

    public func hostLinkDidRequestArm(_ link: HostLinkSession) -> ReadinessMeasurement {
        // ⚠ `arm()` guards its own re-entry; this is only about not queueing a
        // Task per repeated `arm` from a host that sends several.
        // ⛔ **The measurement is the answer and it goes back now** (5.2a,
        // 5.15a), before the camera is touched — so a host learns what this
        // device *is* rather than waiting on what it is about to do.
        let measurement = currentReadiness()
        // REQ-STATE-1 — the host controls capture. The local button stays; this
        // is the other half of that, and it has never existed before.
        if captureStatus.state != .armed, isSettling == false {
            Task { await self.arm() }
        }
        return measurement
    }

    public func hostLinkDidRequestDisarm(_ link: HostLinkSession) {
        guard captureStatus.state == .armed || isSettling else { return }
        disarm()
    }

    public func hostLink(_ link: HostLinkSession, didRequestStream streamId: String,
                         sourceId: String, profileId: String,
                         kind: String) async -> StreamVerdict {
        // ⛔ **The declaration comes from the LINK, not from `recording`.** It
        // used to be read off `recording?.declaration`, which is `nil` until a
        // golfer presses Capture — so every `stream_open` arriving at connect
        // was refused before it reached any of the logic below, preview included
        // (#108). The link has held a complete declaration since `hello`.
        let declaration = link.declaration
        guard let source = declaration.sources.first(where: { $0.id == sourceId }) else {
            // 5.11a / I5 — a Stream names a Source this peer actually declared.
            return .refused(reason: "no_such_source")
        }
        guard let profile = source.profiles.first(where: { $0.id == profileId }) else {
            // ⛔ 5.11a / I5 — a Stream names a profile the declaration actually
            // carries. Refusing an undeclared one is what stops a Stream
            // existing for a mode this camera cannot enter.
            return .refused(reason: "no_such_profile")
        }
        // ⛔ **5.11l, and it is the refusal with an answer both ends can test.**
        // A preview profile describes a *derived view* — a decimation of what
        // the capture Stream is already producing — and 5.11m makes
        // `intrinsics: none` the positive declaration that identifies one. A
        // consumer MUST NOT select one for capture and an owner MUST refuse it;
        // honouring it silently would hand an operator 640×360 where they asked
        // for a capture format.
        if kind != PpcpStreamKind.preview, profile.intrinsics == PpcpDeclaration.Intrinsics.none {
            return .refused(reason: "preview_profile_not_for_capture")
        }

        // ⛔ **The preview case, and it is the LEGAL one** (5.11l). A preview
        // profile is activatable on a `kind: preview` Stream and nowhere else,
        // so this is the request the specification expects rather than the one
        // it forbids — and 5.11.2 puts opening it with "the consumer that wants
        // it", which is why the host originating it raises none of the `ENC`
        // 7a/7b ownership problem that keeps *capture* Streams ours: a preview
        // Capture is never written to a bundle (5.11j), so there is no file to
        // keep consistent.
        if kind == PpcpStreamKind.preview {
            return await openPreview(streamId: streamId, source: source,
                                     profile: profile, on: link)
        }
        // ⛔ **Everything else is refused too, for now, and deliberately.**
        // Honouring a format choice means closing the Stream this device already
        // opened and opening another (5.1b), reconfiguring the camera mid-session
        // — which costs up to 8.85 s (#101) — and recording the result in this
        // device's own bundle. `ENC` §7 has no way for a peer to record an entity
        // it participates in but did not originate, which is the same gap as the
        // hosted `session_open` and the host-opened Stream, now in a third place.
        // ⚠ PinPointStudio asked to be refused freely rather than have a profile
        // accepted that cannot be honoured, and shows the reason to the operator.
        //
        // ⛔ **`not_needed` is the wrong word and there is no right one.** 5.11a1's
        // vocabulary — `thermal_limit`, `storage_full`, `not_needed`,
        // `calibration_changed` — has no value for *declined, not built yet*.
        // Fourth instance of the same shape: no way to state a terminal negative.
        return .refused(reason: "not_needed")
    }

    public func hostLink(_ link: HostLinkSession, didCommandActuator actuatorId: String,
                         isOn: Bool) async -> ActuatorVerdict {
        // ⛔ **12.1d is the engine's, not ours.** `peer_on_actuator_command`
        // answers `error`/`not_declared` for an Actuator this peer never
        // declared before any event exists, so an id reaching here is one this
        // device declared. The guard below is therefore about *which* declared
        // Actuator, and this phone has exactly one.
        guard link.declaration.actuators.contains(where: { $0.id == actuatorId }) else {
            return .refused(reason: ActuatorRefusalReason.noActuator.rawValue)
        }
        // ⭐ **12.1c — the achieved state comes from here and from nowhere
        // else, and since libppcp L30 it is what goes on the wire.**
        // `setTorch` sets `torchMode` and then reads `isTorchActive` back off
        // the `AVCaptureDevice`, and `TorchOutcome.applied` cannot be
        // constructed without that reading. `ActuatorVerdict.init(_:)` carries
        // `state.on` — the light — rather than `state.modeIsOn` — the switch —
        // so a torch the platform has cut for heat acks what it is doing and not
        // what it was told.
        //
        // ⛔ **This returns for every outcome, which is how `MSG` 1c is kept.**
        // `setTorch` neither throws nor suspends and `TorchOutcome` has two
        // cases, so no permission, no `activeDevice`, an unsupported mode and a
        // thrown `lockForConfiguration` all arrive here as a `refused` carrying
        // a 12.1b reason. There is no path out of this method that answers
        // nothing.
        let outcome = setTorch(isOn ? .on : .off)
        return ActuatorVerdict(outcome)
    }

    public func hostLink(_ link: HostLinkSession, didIssueShot shotId: String,
                         t0Ns: Int64, t0TimebaseId: String, candidateIds: [String]) {
        // ⛔ **REQ-SYNC-4 — the residual, and it needs the instant this device
        // HEARD the ball.** That is the Candidate's own `atNs`, already corrected
        // for time of flight, and the only place it survives is the detection
        // that produced it. ⚠ Skipped where no candidate matches: a residual
        // against a Shot this device did not nominate would be measuring the
        // host's clock against nothing.
        //
        // ⚠ **Matched by Candidate, not by time.** The Shot names the nominations
        // it arbitrated over — winners and losers both — so the join is exact.
        // Pairing the nearest candidate to `t0` would work until two phones or a
        // host microphone nominated the same ball, which is the ordinary case.
        let heard = candidateIds.compactMap { heardInstantByCandidate.removeValue(forKey: $0) }
        guard let heardAtNs = heard.first else { return }
        Task { [weak self] in
            _ = await self?.link?.reportResidual(shotId: shotId, heardAtNs: heardAtNs,
                                                 issuedT0Ns: t0Ns,
                                                 t0TimebaseId: t0TimebaseId)
        }
    }

    public func hostLink(_ link: HostLinkSession, didRequestCapture shotId: String,
                         t0Ns: Int64, t0TimebaseId: String,
                         streamIds: [String], preNs: Int64, postNs: Int64,
                         replyTo: UInt64) async {
        // ⚠ Nothing armed is not silence: 7.3b makes an absent Capture the
        // answer, and `RecordingSession` is where the ring and the peer both
        // are. With no session there is no Stream to anchor one to, so this is
        // the one case that genuinely has nothing to say.
        await recording?.serveCaptureRequest(shotId: shotId, t0Ns: t0Ns,
                                             t0TimebaseId: t0TimebaseId,
                                             preNs: preNs, postNs: postNs,
                                             replyTo: replyTo)
    }

    public func hostLinkTransfersChanged(_ link: HostLinkSession) {
        refreshTransferState()
    }

    /// Per-shot and per-session progress, from the library's own table.
    ///
    /// ⛔ **`.inStudio` comes from `capture_committed` and from nothing else.**
    /// 5.14h makes it the receiver's statement that it holds the bytes and 8.4b
    /// forbids an owner claiming it — so a send completing is `delivered`, and
    /// the difference between "sent" and "kept" is the whole reason the two
    /// states exist. ⚠ Nothing had ever mutated `Shot.syncState` after minting.
    func refreshTransferState() {
        guard let recording else { return }
        let rows = recording.transferRows
        guard rows.isEmpty == false else { return }

        var remaining: Int64 = 0
        var pending: [UUID] = []
        var current: Int?

        for row in rows {
            let state = Self.syncState(for: row)
            // ⚠ Still owing: neither confirmed by the receiver nor given up on.
            // A failed transfer is not "queued" — it needs a decision, not a
            // progress bar — and a confirmed one is done.
            let stillOwing: Bool = switch state {
            case .onDevice, .sending, .delivered: true
            case .inStudio, .failed: false
            }

            if let shotId = shotIdByCapture[row.captureId],
               let index = session.shots.firstIndex(where: { $0.id == shotId }) {
                session.shots[index].syncState = state
                if stillOwing {
                    pending.append(shotId)
                    if case .sending = state { current = session.shots[index].ordinal }
                }
            }

            if stillOwing, let bytes = row.bytes {
                let acked = Int64(row.ackedIndex.map { Int64($0) + 1 } ?? 0)
                    * Int64(PayloadTransferQueue.chunkBytes)
                remaining += max(0, Int64(bytes) - acked)
            }
        }

        transferQueue = TransferQueue(
            pendingShotIDs: pending,
            // ⚠ The user's pause survives a refresh; it is the one field of this
            // struct that is not derived.
            isPaused: transferQueue?.isPaused ?? false,
            bytesRemaining: remaining,
            currentShotOrdinal: current,
            totalShots: session.shots.count)
    }

    /// ⛔ **`progress` is recomputed because the library hardcodes zero.** The
    /// arithmetic itself lives on `ShotSyncState` so that it exists once and a
    /// native test can reach it — this is only which row it is applied to.
    nonisolated static func syncState(for row: PpcpTransferRow) -> ShotSyncState {
        guard case .sending = row.state else { return row.state }
        return ShotSyncState.sending(bytes: row.bytes, ackedIndex: row.ackedIndex,
                                     chunkBytes: PayloadTransferQueue.chunkBytes)
    }

    public func hostLinkDidLoseLink(_ link: HostLinkSession) {
        // ⛔ **7.4d — capture does not stop, and `armed` is never dropped here.**
        // REQ-STATE-3 scopes the keepalive lapse to warm → cold, which is a
        // battery mechanism, not a capture one.
        //
        // ⛔ **And a device holding an open `preview` Stream is not idle.** Going
        // cold under it would stop the camera, and nothing would start it again
        // when the link came back — the host asked once, at session open, and
        // 5.11.2 gives it no reason to ask twice. Leaving the camera running
        // costs the outage's frames and no more: `LivePreview` finds the
        // interval unaccounted for on the first frame after the link returns and
        // sheds it, which is 5.11c3's `absent` rather than a silence.
        guard captureStatus.state == .warm, livePreview == nil else { return }
        device.goCold()
        captureStatus.state = .cold
        stopHealthPolling()
    }

    public func hostLinkDidRestoreLink(_ link: HostLinkSession) {
        // ⛔ **NOTHING HERE, AND THAT IS THE DESIGN — read this before adding
        // anything.** This body said "Not built" until 29 Aug 2026, beside a
        // reconnect sequence that `0485bd3` had already built somewhere else.
        // The comment outlived the work it described and cost a planning round.
        //
        // `MSG` 4.3's sequence lives in `HostLinkSession.startSyncTicking`,
        // which calls `HostLinkDriver.resume` while `isAwaitingResyncBurst`:
        // `session_resume` first (4.3a, never `session_open`), then a fresh sync
        // burst, then `publishRelations` (6.1f), and only then
        // `queue.resumeAfterLinkLoss()`. 4.3b requires exactly that order,
        // because payload sent against the relation that drifted through the
        // outage is read at the wrong instant.
        //
        // ⚠ **It cannot live here**, and that is the substantive reason rather
        // than a tidiness one: `resume` returns `false` while the burst is still
        // converging and must be called again — the tick does that every 100 ms,
        // and a one-shot delegate callback fires once. The gap a person reads is
        // `HostLinkSession.gapOnRestore`, already computed before this is called.
        //
        // ⚠ So the delegate exists for `AppModel` to react to the link coming
        // back, and today it has nothing to react with: capture never stopped
        // (7.4d), and a device that went cold on the lapse stays cold until
        // someone arms it.
    }

    /// What this device can honestly say about itself right now.
    ///
    /// ⚠ **A measurement, never a state name** (5.2b). `settled` and an estimate
    /// in milliseconds is the whole vocabulary; `armed`/`warm`/`cold` never cross.
    func currentReadiness() -> ReadinessMeasurement {
        let estimate = measuredSettleNs.map { UInt32($0 / 1_000_000) }
            ?? Self.assumedSettleMs
        // ⚠ **`settled` only from `.armed`, and that is conservative on purpose.**
        // 5.15a would let a settled `.warm` device answer `true` — the question
        // is "would the next shot be settled", not "are you recording". But
        // nothing measures AE/AF convergence while warm; `isSettling` runs only
        // across an arm. So a warm device answers `false` with an estimate,
        // which costs a host one `Arming` tick and never claims a convergence
        // this device has not watched happen. #101 is what claiming it looks
        // like: `armed` was reported over a ring receiving nothing for 8.85 s.
        return ReadinessMeasurement.measuring(
            captureStatus.state,
            exposureHasSettled: captureStatus.state == .armed && isSettling == false,
            settleEstimateMs: estimate,
            blocked: currentBlocker())
    }

    /// Why this device will not arm, where it will not.
    ///
    /// ⛔ **This is what makes `arm` a contract rather than a hope.** Without a
    /// blocker there is no terminal answer on the failure path: a host holds the
    /// `settled: false` it got in reply to `arm` and waits for a settled that is
    /// never coming, because the camera was never going to start. Raised by
    /// PinPointStudio, 27 Aug 2026, and they were right that it is not polish.
    ///
    /// ⚠ **Ordered, and the order is a claim.** The first one that fires is the
    /// one reported, so it has to be the one a person would act on: permission
    /// before hardware, hardware before storage, storage before heat. A thermal
    /// warning shown to someone who never granted camera access is noise.
    ///
    /// ⛔ `blocked_reason` is an **open registry** (5.15) and PinPointStudio
    /// carries whatever we send verbatim to a screen a golfer may read — so
    /// these values are the vocabulary as `ReadinessMeasurement.Blocker` spells
    /// them, and never a sentence of our own.
    func currentBlocker() -> ReadinessMeasurement.Blocker? {
        if permissions.canCapture == false { return .permissionDenied }
        if activeMode == nil { return .noSource }
        if storage.freeBytes > 0,
           Self.storageFloor.verdict(freeBytes: UInt64(storage.freeBytes)) == .refuseToArm {
            return .storageFull
        }
        // ⛔ 5.8's ordinal vocabulary, not the platform's. `critical` is the only
        // level at which this device refuses; `serious` is a warning and capture
        // continues, because 7.4d's "capture degrades last" applies to heat as
        // much as to the link.
        if captureStatus.thermal == .critical { return .thermalLimit }
        return nil
    }

    /// REQ-BUF-2 — the floor below which arming is refused rather than attempted.
    nonisolated static let storageFloor = StorageFloor()

    // MARK: - Preview (#108)

    /// Honours a host's `stream_open` for a `preview` Stream, or says why not.
    ///
    /// ⛔ **This is the whole of "a picture is there before anything is
    /// pressed".** PinPointStudio sends this immediately after `session_open`,
    /// so everything it needs must be reachable with nothing armed: the
    /// declaration off the link, the camera warmed here rather than by `arm()`,
    /// and `Routing.warm` feeding the tap.
    ///
    /// ⚠ **A refusal is a first-class answer and the host shows the reason to an
    /// operator verbatim**, so these are words a person can act on.
    /// ⛔ 5.11a1's vocabulary — `thermal_limit`, `storage_full`, `not_needed`,
    /// `calibration_changed` — has no value for *no camera permission* or *no
    /// preview profile*, and `not_needed` would be a lie about whose problem it
    /// is. The in-vocabulary reasons are used where they fit and the rest are
    /// stated plainly; recorded as a deviation, and it is the fifth instance of
    /// the same gap.
    private func openPreview(streamId: String, source: PpcpDeclaration.SourceView,
                             profile: PpcpDeclaration.ProfileView,
                             on link: HostLinkSession) async -> StreamVerdict {
        // ⛔ **EVERY REFUSAL NAMES ITSELF, ON THE DEVICE.**  The host is told the
        // reason and shows it, but the host is not always who is looking — and
        // eight different guards below returned eight different words into the
        // same silence.  On 28 Aug 2026 `src:camera:wide` was refused by one of
        // them and neither end could say which.
        let verdict = await openPreviewInner(streamId: streamId, source: source,
                                             profile: profile, on: link)
        switch verdict {
        case .opened:
            print("[preview] OPENED source=\(source.id) profile=\(profile.id)")
        case .refused(let reason):
            print("[preview] REFUSED source=\(source.id) reason=\(reason)")
        }
        return verdict
    }

    private func openPreviewInner(streamId: String, source: PpcpDeclaration.SourceView,
                                  profile: PpcpDeclaration.ProfileView,
                                  on link: HostLinkSession) async -> StreamVerdict {
        // ⛔ 5.11m — `intrinsics: none` is the positive declaration that
        // identifies a preview profile, and `PreviewFrameTap` produces exactly
        // the one this device declares. A `preview` Stream naming a capture
        // profile would be a Stream we could not produce what it promises on.
        guard profile.intrinsics == PpcpDeclaration.Intrinsics.none else {
            return .refused(reason: "not_a_preview_profile")
        }

        // ⛔ **ONE CAMERA, ONE PREVIEW — AND A SECOND SOURCE IS REFUSED, NOT
        // SERVED BY STOPPING THE FIRST.** This device holds a single
        // `CaptureDevice` and a single `AVCaptureSession`. 5.6d makes each
        // physical lens its own Source, but only one of them is *running* at a
        // time, so "a preview per Source" is not something this hardware can
        // honour however the slot below is written.
        //
        // ⛔ Until 27 August that slot was replaced unconditionally, and the
        // comment on it said "one Source" while the code enforced "one device".
        // PinPointStudio asks about **both** cameras at `declare` — one
        // `stream_open` per camera Source, milliseconds apart — so the second
        // request destroyed the first preview immediately after creating it,
        // and both were acked `opened`. `src:camera:wide` is asked for first and
        // was therefore the one Source that could never produce a picture, which
        // is exactly the symptom that was reported: Set crop on the wide camera,
        // black, for eight minutes, with no error at either end.
        //
        // ⚠ **Refusing is the conformant answer and the only honest one.**
        // 5.11.2: "a peer that does not offer a suitable profile simply refuses,
        // and nothing else changes." Answering `opened` and then producing
        // nothing is the silence `MSG` E18 1c exists to prevent — a consumer
        // cannot tell it apart from a Stream that is working.
        //
        // ⛔ **And the lens is NOT switched to satisfy a request.**
        // `Lens.captureRank` states the rule: "lens choice is
        // calibration-affecting and forbidden to change within a session". A
        // preview that reconfigured the camera would move the calibration of the
        // very capture it exists to frame.
        guard let active = activeMode else {
            return .refused(reason: "no_usable_capture_format")
        }
        guard source.id == active.sourceId else {
            return .refused(reason: "not_the_active_camera "
                                    + "(running camera is \(active.sourceId))")
        }
        // ⚠ Checked separately from the lens so that a `preferredMode` change
        // mid-session cannot silently orphan a preview that is already running:
        // the Stream that exists keeps the camera, and the newcomer is told so.
        if let running = livePreview, running.stream.sourceId != source.id {
            return .refused(reason: "another_source_previewing")
        }
        guard permissions.canCapture else {
            return .refused(reason: "camera_permission_denied")
        }
        // 5.11i — preview is the first thing to lose, so a device already too hot
        // to capture does not spend the budget on a picture.
        if captureStatus.thermal == .critical {
            return .refused(reason: "thermal_limit")
        }
        guard let sessionId = link.hostSession?.sessionId else {
            // ⛔ 5.11a — a Stream belongs to a Session, and this arrives after
            // `session_open` on every host that follows 5.11.2. Refusing beats
            // inventing a Session id the host never opened.
            return .refused(reason: "no_session")
        }
        // ⚠ 5.11h — preview payload may not share the shot payload's channel, so
        // without the third channel there is no preview to open. Ordinarily
        // already dialled at session open; this is the retry, not the first try.
        if link.hasPreviewChannel == false, await link.openPreviewChannel() == false {
            return .refused(reason: "no_preview_channel")
        }

        // ⛔ **The camera has to be running, and nothing else would start it.**
        // `warmUp` is what `arm()` pays for; preview-only mode pays the same
        // price and REQ-STATE-2 is why it is paid here rather than on the frame
        // path. ⚠ Skipped where capture already has the camera: re-warming an
        // armed device would reconfigure it mid-session, which is #101's stall.
        if captureStatus.state == .cold {
            await warmUp()
            guard captureStatus.state == .warm else {
                return .refused(reason: "camera_unavailable")
            }
        }

        // A host re-asking about the SAME Source replaces what it asked for last
        // time; two preview Streams on one Source would pay the frame path twice
        // for one picture. ⚠ The guards above are what make this line mean that:
        // anything reaching here names the Source that is already previewing, or
        // there is no preview at all.
        livePreview?.stop(reason: "not_needed")

        let record = PpcpStreamRecord(
            id: streamId, sessionId: sessionId, sourceId: source.id,
            kind: PpcpStreamKind.preview, profileId: profile.id,
            timebaseId: source.timebaseId,
            // ⛔ Fixed by §5.11's own table — a preview is a view of time
            // passing, not a window around a shot.
            continuity: .continuous, openedAtNs: MachClock.hostTimeNs)
        do {
            let preview = try await link.openPreview(record, device: device)
            preview.start()
            livePreview = preview
            return .opened
        } catch {
            // ⚠ Named rather than swallowed: `libppcp: invalid argument
            // (openStream)` on a device tells nobody which Stream it was.
            recordingError = "Preview could not be opened: \(error)"
            return .refused(reason: "stream_open_failed (\(String(describing: error)))")
        }
    }

    /// What the live preview Stream is called, and how much of its interval has
    /// been accounted for. ⚠ Read through the model so a caller is not obliged to
    /// hop actors for two integers.
    var previewStreamId: String? { livePreview?.stream.id }
    var previewSegmentsAnnounced: Int { livePreview?.segmentsAnnounced ?? 0 }

    /// ⛔ Preview dies with the link that carries it. 5.11j makes it live-only,
    /// so there is nothing to resume and nothing to keep.
    func stopPreview(reason: String = "not_needed") {
        livePreview?.stop(reason: reason)
        livePreview = nil
    }
}
