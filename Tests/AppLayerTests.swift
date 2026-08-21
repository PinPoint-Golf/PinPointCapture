//  AppLayerTests.swift
//  Tests that can only run inside the app target — the composition root and the
//  platform layer wired together.
//
//  ⚠ Core has its own suite in Packages/Core, which runs natively on the host in
//  milliseconds. Only put a test here if it genuinely needs the app target: a
//  platform framework, the bundle, or AppModel's wiring. Everything else belongs
//  in the package, where it runs a thousand times faster.

import Testing
import CaptureCore
@testable import PinPointCapture

@Suite("Composition root")
@MainActor
struct AppModelTests {

    /// ⚠ The simulator has no camera. That is not an edge case to skip — it is
    /// the same code path as a real device whose camera is unavailable, and the
    /// app must stay renderable rather than crash or show an empty card.
    ///
    /// A1 is the first screen a user ever sees, so "this device cannot do the
    /// job" has to be something it can say out loud (REQ-FPS-1).
    @Test("A device with no usable camera degrades to a screen that says so")
    func noCameraIsReportedNotCrashed() {
        let model = AppModel()
        model.refreshCapability()

        if model.capabilityError == nil {
            // Real hardware: enumeration succeeded and must be self-consistent.
            #expect(model.capability.claimed.isEmpty == false)
            #expect(model.capability.bestMode != nil)
        } else {
            // No camera: the error is recorded and A1 still has a sentence.
            #expect(model.capability.claimed.isEmpty)
            #expect(model.capability.summarySentence.isEmpty == false)
            #expect(model.capability.clearsGate() == false)
        }
    }

    /// ⛔ REQ-PORT-4. The factory is the only way a capture device is built, so a
    /// second platform is a new case there and nothing else.
    @Test("The factory produces a capture device on this platform")
    func factoryProducesADevice() {
        let device = CaptureDeviceFactory.create()
        // Thermal state is always answerable, with or without a camera.
        #expect(ThermalState.allCases.contains(device.thermalState))
    }

    /// ⚠ Capture needs camera and microphone. Nothing else gates it — a refused
    /// local network costs a golfer a network, not a session.
    @Test("The model starts without claiming permissions it has not been granted")
    func permissionsStartHonest() {
        let model = AppModel()
        #expect(model.permissions.localNetwork == .unknown
                || model.permissions.localNetwork == .notRequested)
    }

    /// ⚠ REQ-STATE-1 / §9.2. Arming without a usable camera must not leave the
    /// UI claiming it is armed when nothing is being retained.
    @Test("Arming without a camera does not claim to be capturing")
    func armingWithoutACameraIsHonest() {
        let model = AppModel()
        model.refreshCapability()
        guard model.capabilityError != nil else { return }  // real hardware, skip
        model.warmUp()
        #expect(model.captureStatus.state != .warm)
    }
}
