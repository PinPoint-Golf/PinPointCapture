//  AppModel.swift
//  The composition root's state.
//
//  This is the one place that knows about both the Platform layer and the Core
//  state the UI renders. Screens receive Core values and hand back closures; none
//  of them reaches a capture device, and none of them owns navigation.
//
//  ⚠ Skeleton scope. Capture is not yet running: the ring buffer, the encoder,
//  shot detection and the transport do not exist. Everything except device
//  capability is fixture state, and is labelled as such below so nothing here is
//  mistaken for a working capture path.

import Foundation
import Observation

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

    public var captureStatus: CaptureStatus = PreviewFixtures.armed
    public var hostLink: HostLink = HostLink(state: .none)
    public var session: Session = PreviewFixtures.session
    public var transferQueue: TransferQueue = PreviewFixtures.transferQueue
    public var framing: FramingStatus = PreviewFixtures.framingMarginalLight
    public var audioRetention: AudioRetention = .aroundImpactOnly
    public var captureContext: CaptureContext = .standalone

    public var hasCompletedOnboarding = false

    private let device: any CaptureDevice
    private let permissionsService = PermissionsService()

    public init(device: any CaptureDevice = CaptureDeviceFactory.create()) {
        self.device = device
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

    public func arm() {
        warmUp()
        captureStatus.state = .armed
    }

    /// The local override of a host-controlled state (REQ-STATE-1).
    public func disarm() {
        device.goCold()
        captureStatus.state = .cold
    }

    /// Exposed so the preview view can attach. It hands over the *device*, not the
    /// session — `AVCaptureSession` never becomes reachable from a view model.
    public var captureDevice: any CaptureDevice { device }
}
