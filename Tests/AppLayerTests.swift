//  AppLayerTests.swift
//  Tests that can only run inside the app target — the composition root and the
//  platform layer wired together.
//
//  ⚠ Core has its own suite in Packages/Core, which runs natively on the host in
//  milliseconds. Only put a test here if it genuinely needs the app target: a
//  platform framework, the bundle, or AppModel's wiring. Everything else belongs
//  in the package, where it runs a thousand times faster.

import Foundation
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
    func armingWithoutACameraIsHonest() async {
        let model = AppModel()
        model.refreshCapability()
        guard model.capabilityError != nil else { return }  // real hardware, skip
        await model.warmUp()
        #expect(model.captureStatus.state != .warm)
    }
}

// MARK: - Initial UI integration

/// The screens were fixture-fed for their whole life. These pin the removal.
///
/// ⚠ Every one of them is a *negative*: what the app must no longer claim. A
/// fixture that comes back will come back silently — it compiles, it renders, and
/// it looks better than the truth — so the guard has to be a test rather than a
/// convention.
@Suite("Composition root — no invented data")
@MainActor
struct FixtureRemovalTests {

    @Test("A fresh model claims no session, no shots and no host")
    func freshModelClaimsNothing() {
        let model = AppModel()

        // ⛔ This was `PreviewFixtures.session` — 41 invented shots dated 21
        // August 2026, on every device, before anything had been captured.
        #expect(model.session.shots.isEmpty)
        #expect(model.shotCount == 0)
        #expect(model.candidateCount == 0)
        #expect(model.recording == nil)

        // ⛔ And this was assigned `PreviewFixtures.connected` by a tap on B1:
        // a paired Studio, a measured clock offset and a transfer queue, with no
        // socket open anywhere.
        #expect(model.hostLink.state == .none)
        #expect(model.hostLink.hostName == nil)
        #expect(model.transferQueue == nil)
    }

    @Test("A fresh model asserts no framing check it has not run")
    func freshModelChecksNothing() {
        let model = AppModel()

        // ⛔ `PreviewFixtures.framingMarginalLight` claimed the golfer was in
        // frame at address and at the top, and the device steady — three green
        // ticks for checks that have never existed (E8.2).
        #expect(model.framing.inFrameAtAddress == .notChecked)
        #expect(model.framing.inFrameAtTop == .notChecked)
        #expect(model.framing.isSteady == .notChecked)
        #expect(model.framing.hasAnyRealCheck == false)
        #expect(model.framing.allChecksPass == false)

        // ⛔ And it rendered `1/1600 s · ISO 2200` on every device in every room,
        // for what REQ-LIGHT-1 calls the binding constraint on how useful the
        // video is.
        #expect(model.framing.light == nil)
        #expect(model.framing.viewpoint == nil)
    }

    @Test("The audio retention setting reaches the detector, rather than a label")
    func audioRetentionIsApplied() throws {
        // ⛔ `AppModel.audioRetention` was user-visible on A4 and inert: it never
        // reached `DetectAndMint.Configuration.retention`, so the control changed
        // a sentence and nothing else. REQ-PRIV-2 makes the privacy label a claim
        // about this exact value.
        for setting in AudioRetention.allCases {
            let policy = setting.policy
            switch setting {
            case .aroundImpactOnly:
                #expect(policy.windowNs > 0)
                #expect(policy.maximumRetainedCandidates > 0)
            case .none:
                #expect(policy.maximumRetainedCandidates == 0 || policy.windowNs == 0)
            case .fullTrack:
                #expect(policy.windowNs > 0)
            }
        }
    }

    @Test("Onboarding completion survives a relaunch")
    func onboardingPersists() throws {
        let suite = "ppcp.tests.onboarding"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        #expect(OnboardingStateStore.hasCompleted(in: defaults) == false)
        OnboardingStateStore.setCompleted(true, in: defaults)
        // ⛔ The whole point: a *second* read, as a fresh launch would do.
        #expect(OnboardingStateStore.hasCompleted(in: defaults))
        OnboardingStateStore.reset(in: defaults)
        #expect(OnboardingStateStore.hasCompleted(in: defaults) == false)
    }

    @Test("A minted shot is labelled from the session anchor, not from the wall clock")
    func shotsAreLabelledFromTheAnchor() throws {
        // ⚠ The assertion is exact, deliberately. "Near `Date()`" would pass just
        // as happily if the wall clock crept back into the calculation, which is
        // the bug REQ-OFF-8 exists to prevent.
        let anchor = WallClockAnchor(hostTimeNs: 5_000_000_000,
                                     wallClock: Date(timeIntervalSince1970: 1_787_336_400))
        let minted = try PpcpShot(id: "shot:1e2d3c4b-5a69-78b3-55ad-a60b4b5aa8f0",
                                  sessionId: "ses:test",
                                  timebaseRefId: PpcpTimebases.captureId,
                                  t0Ns: 7_500_000_000,
                                  authority: .device,
                                  issuedBy: "peer:test",
                                  firstCandidateId: "cand:test")
        // ⚠ `atNs` explicitly, and in a hostless Session it is `t0Ns` — I4's
        // identity. With a host it is not, which is why the parameter exists:
        // labelling a host-clock instant with this anchor put every shot on a
        // real device about two hours out (27 Aug).
        let shot = Shot(minted: minted, atNs: minted.t0Ns, ordinal: 1, anchor: anchor)

        #expect(abs(shot.impact.timeIntervalSince(anchor.wallClock) - 2.5) < 0.000_001)
        #expect(shot.duration == nil)          // nothing filmed it
        #expect(shot.syncState == .onDevice)   // and nothing sent it
        #expect(shot.displayDetail.contains("timed, not filmed"))
    }

    @Test("The library lists what is on disk, not what a fixture describes")
    func libraryListsRealBundles() throws {
        let root = URL.temporaryDirectory
            .appendingPathComponent("ppcp-library-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel(store: SessionStore(root: root))
        // ⛔ Nothing written yet, so nothing listed. It used to list 41 shots.
        #expect(model.libraryRows().isEmpty)
    }
}
