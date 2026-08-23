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
    public private(set) var permissions: Permissions
    public private(set) var capabilityError: String?

    // MARK: Fixture state — replaced as each subsystem lands

    /// ⛔ **Starts `cold`, not at a fixture.** It was `PreviewFixtures.armed`, so
    /// a freshly launched app on a device with no usable camera reported itself
    /// armed and retaining nothing — §9.2's one thing that must not be quietly
    /// wrong. Found by the D4 test that asserts arming is not a claim.
    public var captureStatus: CaptureStatus = CaptureStatus(state: .cold)
    public var hostLink: HostLink = HostLink(state: .none)
    public var session: Session = PreviewFixtures.session
    public var transferQueue: TransferQueue = PreviewFixtures.transferQueue
    public var framing: FramingStatus = PreviewFixtures.framingMarginalLight
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

    public var hasCompletedOnboarding = false

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
    public func runSelfTest(seconds: TimeInterval = 3) async {
        guard permissions.canCapture, let mode = capability.bestMode else { return }
        do {
            let measured = try await device.measureSustainedRate(mode: mode, duration: seconds)
            capability.measured = measured
            captureStatus.achievedFPS = measured.achievedFPS
            captureStatus.thermal = measured.thermalAtEnd
        } catch {
            capabilityError = String(describing: error)
        }
    }

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
    public func warmUp() {
        guard permissions.canCapture, let mode = capability.bestMode else { return }
        do {
            try device.warmUp(mode: mode)
            captureStatus.state = .warm
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
        guard captureStatus.state == .warm else { return }
        startRecording()
        guard recording != nil else { return }
        startDetecting()
        captureStatus.state = .armed
    }

    /// The local override of a host-controlled state (REQ-STATE-1).
    public func disarm() {
        stopDetecting()
        stopRecording()
        device.goCold()
        captureStatus.state = .cold
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
                videoProfileId: capability.bestMode?.id,
                micToBall: micToBallDistance)
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
            shotCount += minted.count
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
