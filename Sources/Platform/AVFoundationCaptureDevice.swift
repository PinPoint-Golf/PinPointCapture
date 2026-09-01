//  AVFoundationCaptureDevice.swift
//  The iOS/iPadOS implementation of `CaptureDevice`.
//
//  ⚠ This file, and files like it, are the ONLY place `AVFoundation` types may
//  appear. Everything returned from here is a Core type (REQ-PORT-3).

import AVFoundation
import Foundation
import CaptureCore

/// ⚠ `NSObject` because this class is now the capture session's sample-buffer
/// delegate itself (see **The frame path**), and `setSampleBufferDelegate`
/// requires `NSObjectProtocol`. It is the delegate rather than vending one so
/// that there is exactly one owner of the frame path and no way for a consumer
/// to unhook another.
public final class AVFoundationCaptureDevice: NSObject, CaptureDevice,
                                              AVCaptureVideoDataOutputSampleBufferDelegate,
                                              @unchecked Sendable {

    /// ⛔ REQ-OPT-5. PHYSICAL devices only — never `.builtInDualCamera`,
    /// `.builtInDualWideCamera` or `.builtInTripleCamera`.
    ///
    /// A virtual multi-lens device switches physical lenses automatically on
    /// scene and focus distance. It would silently change the intrinsics
    /// mid-session, which invalidates calibration without reporting anything.
    private static let physicalDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera,
        .builtInUltraWideCamera,
        .builtInTelephotoCamera
    ]

    private let session = AVCaptureSession()
    /// `CORE` 7.3d. Held here because the session it observes is held here.
    private var interruptions: InterruptionMonitor?
    /// ⛔ `.userInteractive`, matching PinPointStudio's `ThreadPolicy::apply`
    /// for `ThreadRole::Capture` (`src/Buffer/thread_policy.cpp:106`). It was
    /// `.userInitiated`, which is the tier PPS gives its *merger* thread — one
    /// below the capture callback. At 150 fps the budget is 6.7 ms per frame and
    /// the frame the scheduler defers is not late, it is gone.
    private let sampleQueue = DispatchQueue(label: "org.pinpointstudio.capture.samples",
                                            qos: .userInteractive)
    private var activeDevice: AVCaptureDevice?
    /// REQ-BUF-1's ring, held here because the sample path that feeds it is here.
    /// ⛔ `nil` until `startRetaining`.
    private var recorder: RingBufferRecorder?

    /// `CORE` §5.11.2 — the preview tap, when a host has a channel for one.
    ///
    /// ⛔ **Owned by `sampleQueue`, like `recorder` and `routing`.** Its `offer`
    /// is called from the frame callback and reads two integers it owns; nothing
    /// about preview may cost the capture path a lock or an allocation.
    private var previewTap: PreviewFrameTap?

    /// `CORE` §5.8's thermal timeline. ⛔ Written and uncalled until E1.3 — the
    /// health service read `ProcessInfo.thermalState` per tick and nothing kept
    /// the series, so every Capture carried an empty `thermal` and REQ-CLIP-1's
    /// "thermal state timeline" was a field nobody filled. Held here because a
    /// Capture's timeline must cover the *Capture's* interval, and this is what
    /// knows when that was.
    private let thermalTimeline = ThermalTimeline(timebaseId: PpcpTimebases.captureId)

    /// ⛔ **Where every delivered frame goes, and the only thing that decides.**
    ///
    /// One `AVCaptureVideoDataOutput`, one delegate — this class — and a state
    /// that says who receives. The alternative, two outputs with opposite
    /// discard policies, became legal in iOS 16 (`AVCaptureSession.h`: "this
    /// restriction no longer applies to AVCaptureVideoDataOutputs") and is still
    /// wrong here: a session computes a non-zero `hardwareCost` only once a
    /// second video data output is added, `> 1.0` refuses to start, and 1080p150
    /// already sits on the thermal axis that binds first.
    ///
    /// ⚠ Mutually exclusive by construction. Self-testing while retaining would
    /// flip `alwaysDiscardsLateVideoFrames` under a live ring, which is the one
    /// combination that must not be representable.
    /// ⚠ Internal rather than private **so the discard invariant can be
    /// tested**. `discardsLateFrames` is the single line where REQ-CAP-3 and
    /// §9.2 pull in opposite directions, and it is not reachable on a simulator
    /// through `warmUp` — which needs a camera. A test that cannot see this
    /// enum cannot check the one thing most worth checking.
    enum Routing {
        /// Warm: locked and settled, nothing consuming frames but the preview.
        case warm
        /// REQ-BUF-1. Frames go to the ring, and late frames are NOT discarded.
        case retaining
        /// REQ-CAP-2/CAP-3. Frames go to the probe, and late frames ARE
        /// discarded, because the self-test wants drops to be visible.
        case selfTesting(FrameRateProbe)

        /// ⛔ The self-test and the capture path want opposite answers and the
        /// reason is §9.2: capture is non-recoverable, replay is repeatable, so
        /// capture degrades last and must never be the place a frame is thrown
        /// away. Deriving the flag from the state is what stops the two
        /// requirements overwriting each other.
        var discardsLateFrames: Bool {
            if case .retaining = self { return false }
            return true
        }
    }

    /// ⛔ **Owned by `sampleQueue`, like `recorder`.** Every write goes through
    /// `sampleQueue.async` and every read on the frame path is already on that
    /// queue, so the two are serialised by the queue itself and the 6.7 ms
    /// budget pays for no lock. Callers outside the frame path read through
    /// `sampleQueue.sync`.
    private var routing: Routing = .warm

    public override init() { super.init() }

    // MARK: - Enumeration (REQ-FPS-1, REQ-CAP-1)

    public func enumerateCapability() throws -> DeviceCapability {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.physicalDeviceTypes,
            mediaType: .video,
            position: .back
        )

        guard !discovery.devices.isEmpty else { throw CaptureDeviceError.noPhysicalCameraFound }

        // ⛔ **Collapse pixel encodings, NEVER rates** (#102). The key used to be
        // (lens, resolution) and kept only the fastest mode for each — so a phone
        // reporting 1920x1080 at 30, 60, 120 and 240 declared **only 240**, and
        // every slower rate ceased to exist as far as the rest of the
        // application was concerned. `Use 120 fps` on the framing check therefore
        // fell through to 3840x2160 @ 60 on the ultra-wide camera: a different
        // rate, a different resolution and a different lens than the button said.
        //
        // ⚠ The original reasoning was right about the wrong thing. "A device
        // reports dozens of formats that differ only in pixel encoding and photo
        // capability" — true, and 110 formats do still collapse to 40 here. But
        // that argument is about the **capability card**, one sentence built from
        // `bestMode`, and it was never an argument about what may be *selected*.
        //
        // ⛔ 1920x1080 @ 120 is also the only 1080p mode on an iPhone 16 that
        // delivers per-frame intrinsics (240 delivers none — measured, #19). The
        // old key discarded the one mode that makes REQ-OPT-7 reachable at a
        // usable rate.
        var best: [String: VideoMode] = [:]

        for device in discovery.devices {
            let lens = Self.lens(for: device.deviceType)
            for format in device.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard let maxRate = format.videoSupportedFrameRateRanges
                    .map(\.maxFrameRate).max(), maxRate > 0 else { continue }

                let mode = VideoMode(
                    width: Int(dims.width),
                    height: Int(dims.height),
                    fps: maxRate,
                    lens: lens,
                    // ⚠ Intrinsics delivery is a property of a live
                    // AVCaptureConnection, not of a format, so it cannot honestly
                    // be claimed at enumeration time. It is enabled and confirmed
                    // in warmUp(mode:) (REQ-OPT-7).
                    deliversIntrinsics: false,
                    // ── The PPCP CaptureProfile fields (D2) ──────────────────
                    //
                    // ⚠ Taken from the SAME `AVCaptureDevice.Format` the rate and
                    // dimensions come from, in the same pass. REQ-FPS-1: what the
                    // hardware actually offers, never a spec sheet — and a second
                    // walk to fill in `optical` later would be a second chance to
                    // read a different format than the one that won.
                    pixelFormat: Self.fourCC(format.formatDescription),
                    // ⚠ Both halves or neither — a range built from one
                    // readable end and a substituted other end would declare an
                    // exposure capability this camera does not have.
                    exposureRangeNs: Self.range(format.minExposureDuration,
                                                format.maxExposureDuration),
                    // ⚠ ISO is a `Float` on this platform and an int64 on the
                    // wire (`CORE` 5.7 `optical`). Rounded toward the interior of
                    // the range — up at the bottom, down at the top — so the
                    // declared range is never wider than the one the device
                    // actually offers.
                    isoRange: Int64(format.minISO.rounded(.up))
                        ... Int64(format.maxISO.rounded(.down))
                )

                // ⚠ `fps` is in the key. Two formats of the same geometry and
                // rate differing only in pixel encoding still collapse; two
                // rates never do.
                let key = "\(lens.rawValue)-\(dims.width)x\(dims.height)@\(maxRate)"
                if best[key] != nil { continue }
                best[key] = mode
            }
        }

        let identifier = DeviceProfiles.currentIdentifier
        return DeviceCapability(
            modelIdentifier: identifier,
            modelName: DeviceProfiles.profile(for: identifier).marketingName,
            claimed: best.values.sorted {
                ($0.height, $0.fps) > ($1.height, $1.fps)
            },
            measured: nil
        )
    }

    /// The format's media subtype as the four-character code the platform names
    /// it by — `420v`, `420f`, `x422`.
    ///
    /// ⛔ `CORE` 5.7 `format.pixel_format` is an open-registry `Kind`, and this is
    /// the platform's own spelling handed over unchanged. Nothing in Core parses
    /// it (5.2c's principle applied one field down: a consumer that inferred
    /// behaviour from it would be inferring what the protocol requires be
    /// declared).
    private static func fourCC(_ description: CMFormatDescription) -> String {
        let code = CMFormatDescriptionGetMediaSubType(description)
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A `CMTime` the platform gave us, in nanoseconds — or `nil` where it is
    /// not a number.
    ///
    /// ⛔ **`Int64(_:)` TRAPS on NaN, AND THIS CRASHED THE APP ON ARM**
    /// (25 August 2026, reproduced on an iPhone 16). `CMTimeGetSeconds` returns
    /// NaN for an invalid or indefinite `CMTime`, and `AVCaptureDevice.
    /// exposureDuration` is exactly that in the window between `warmUp()`
    /// locking exposure and the device settling. `AppModel.arm()` calls
    /// `warmUp()` and `startRetaining()` back to back with no settle, so the
    /// window is entered on every arm and the crash is a race the user wins most
    /// of the time. The device tests never saw it because they sleep two seconds
    /// between the two calls.
    ///
    /// ⚠ **`FrameTimeline.nanoseconds` has guarded this since it was written**
    /// — `guard time.isValid, time.isNumeric`. Two helpers with the same name
    /// doing the same job, one hardened and one not.
    ///
    /// ⚠ Optional rather than `?? 0`: zero nanoseconds is a *measurement* of an
    /// exposure no camera ever had, and `CORE` 5.8f is explicit that a value
    /// must not be used to mean "unknown". Absent means unknown.
    private static func nanoseconds(_ time: CMTime) -> Int64? {
        guard time.isValid, time.isNumeric else { return nil }
        return Int64((CMTimeGetSeconds(time) * 1_000_000_000).rounded())
    }

    /// A closed range from two platform `CMTime`s, or `nil` where either end is
    /// unreadable. See `nanoseconds(_:)`.
    private static func range(_ low: CMTime, _ high: CMTime) -> ClosedRange<Int64>? {
        guard let lowNs = nanoseconds(low), let highNs = nanoseconds(high),
              lowNs <= highNs else { return nil }
        return lowNs ... highNs
    }

    private static func lens(for type: AVCaptureDevice.DeviceType) -> Lens {
        switch type {
        case .builtInWideAngleCamera: .wide
        case .builtInUltraWideCamera: .ultraWide
        case .builtInTelephotoCamera: .telephoto
        default: .unknown
        }
    }

    // MARK: - Lifecycle

    /// Bring the session up locked and settled.
    ///
    /// The lock sequence is REQ-OPT-1..7 and every one of them is load-bearing:
    /// each unlocked control is a parameter that changes mid-session and makes
    /// two frames incomparable.
    public func warmUp(mode: VideoMode) async throws {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [Self.deviceType(for: mode.lens)],
            mediaType: .video,
            position: .back
        )
        guard let device = discovery.devices.first else {
            throw CaptureDeviceError.noPhysicalCameraFound
        }
        guard let format = Self.format(on: device, matching: mode) else {
            throw CaptureDeviceError.modeNotSupported
        }

        // ⛔ **The configuration is a scope of its own, and `startRunning` is
        // OUTSIDE it.** This used to be a bare `defer` running at the end of the
        // method while the last statement dispatched `startRunning()`
        // asynchronously — so the start could reach the session *before* the
        // defer committed, and AVFoundation throws `NSGenericException`:
        // "startRunning may not be called between calls to beginConfiguration
        // and commitConfiguration". ⚠ Unreachable on a simulator, which has no
        // camera and throws out of this method long before here; it crashed on
        // the first frame of the first device run (24 Aug 2026).
        try configure(session: session, device: device, format: format, mode: mode)

        // See `configure`'s note above its old lock lines: focus/exposure/WB
        // were left in continuous-auto there, deliberately unlocked, so they
        // can actually converge on the subject before REQ-OPT-2/3/4 freezes
        // them. This wait is what `warmUp` exists to absorb (REQ-STATE-2) —
        // `arm()` must never pay it.
        await waitForConvergence(of: device)
        try lockControls(on: device)

        if !session.isRunning {
            // Capture `self`, which is Sendable, rather than the session, which
            // is not. startRunning() blocks, so it must not run on the caller.
            sampleQueue.async { [weak self] in self?.session.startRunning() }
        }
    }

    /// Everything between `beginConfiguration` and `commitConfiguration`, and
    /// **nothing else** — see the note in `warmUp`.
    private func configure(session: AVCaptureSession, device: AVCaptureDevice,
                           format: AVCaptureDevice.Format, mode: VideoMode) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // ⛔ **Stated, not inherited.** Assigning `device.activeFormat` below is
        // documented to move the session to `.inputPriority` on its own, and
        // leaving it implicit means the session spends part of this block still
        // entitled to re-derive the format from a preset — which is one of the
        // documented ways to pay the capture-stream teardown twice. Saying it
        // first costs nothing and removes the question (#101).
        if session.sessionPreset != .inputPriority {
            session.sessionPreset = .inputPriority
        }

        session.inputs.forEach { session.removeInput($0) }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CaptureDeviceError.configurationFailed("cannot add camera input")
        }
        session.addInput(input)

        // ⚠ Reuse the session's existing output. Building a fresh one and only
        // adding it when `outputs` is empty leaves the connection settings below
        // applied to a detached object on every re-arm, so stabilisation and
        // intrinsics silently revert to their defaults.
        let output: AVCaptureVideoDataOutput
        if let existing = session.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }).first {
            output = existing
        } else {
            let fresh = AVCaptureVideoDataOutput()
            guard session.canAddOutput(fresh) else {
                throw CaptureDeviceError.configurationFailed("cannot add video output")
            }
            session.addOutput(fresh)
            output = fresh
        }

        // ⛔ **The flag is derived from `routing`, never written as a literal.**
        // It used to be `true` here with a comment saying the capture path would
        // have to revisit it; this is that revisit. The self-test wants late
        // frames DISCARDED so `didDrop` fires and REQ-CAP-3 can see degradation;
        // the ring wants them KEPT because §9.2 makes capture degrade last. Two
        // requirements, one property — so it moves with the state rather than
        // one of them quietly winning.
        output.alwaysDiscardsLateVideoFrames = routing.discardsLateFrames

        // ⚠ Set ONCE, here, and never reassigned. `measureSustainedRate` used to
        // seize this delegate and null it on the way out, which would have
        // silently disconnected the ring the first time anyone self-tested while
        // armed. The probe is now a consumer behind `routing`, not a rival
        // delegate.
        output.setSampleBufferDelegate(self, queue: sampleQueue)

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        device.activeFormat = format

        // Pin BOTH ends of the range. Setting only the max lets the device drop
        // rate under load without reporting it, which is precisely the silent
        // degradation REQ-CAP-3 exists to detect.
        let duration = CMTime(value: 1, timescale: CMTimeScale(mode.fps.rounded()))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration

        // ⛔ REQ-OPT-2/3/4 lock focus/exposure/WB, but NOT here and not yet.
        // `activeFormat` above resets AF/AE convergence, and locking in the same
        // pass freezes whatever transient state the sensor is in a moment after
        // the switch — never letting it actually focus on the subject. Force a
        // fresh convergence attempt against the NEW format instead; `warmUp`
        // awaits convergence, then calls `lockControls(on:)` to lock what
        // actually landed.
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }

        // ⛔ REQ-OPT-1. Stabilisation OFF. It warps geometry and destroys 2D shaft
        // measurement, and it is incompatible with per-frame intrinsics delivery.
        if let connection = output.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
            // REQ-OPT-7. Free calibration data; requires stabilisation off, which
            // is required anyway.
            if connection.isCameraIntrinsicMatrixDeliverySupported {
                connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
        }

        activeDevice = device
    }

    /// Poll, unlocked, until focus and exposure have converged on the format
    /// `configure(...)` just switched to — or until the bound below elapses.
    ///
    /// ⛔ **No `lockForConfiguration()` held here.** That call guards property
    /// *writes*; holding it across a wait for hardware convergence would
    /// serialise this against every other configuration caller for no reason
    /// `AVCaptureDevice` requires. `isAdjustingFocus`/`isAdjustingExposure` are
    /// safe to read without it.
    ///
    /// ⚠ Polling against `MachClock`, not KVO — this codebase has no KVO usage
    /// anywhere (`AppModel.beginSettling()` is the existing convergence-wait
    /// idiom) and this matches it.
    ///
    /// ⚠ Bounded so a device that never reports convergence (AVFoundation makes
    /// no completion guarantee) still reaches `lockControls(on:)` and arms —
    /// late and possibly soft, never stuck.
    private func waitForConvergence(of device: AVCaptureDevice) async {
        let startedAt = MachClock.hostTimeNs
        while device.isAdjustingFocus || device.isAdjustingExposure {
            if MachClock.hostTimeNs - startedAt > Self.convergenceTimeoutNs { return }
            try? await Task.sleep(for: .milliseconds(Self.convergencePollMs))
        }
    }

    /// ⚠ Cadence for `waitForConvergence`, matching `AppModel`'s settle-poll style.
    private static let convergencePollMs = 30
    /// ⛔ Bounded well under the existing 75ms-typical / 8.85s-worst-case arm
    /// budget. AF on a stationary subject in daylight converges in well under
    /// this in practice; chosen high enough not to cut off a slow convergence
    /// in dim light.
    private static let convergenceTimeoutNs: Int64 = 800_000_000

    /// REQ-OPT-2/3/4. Lock focus, exposure and white balance where they landed
    /// after `waitForConvergence` — a converged point now, not the transient
    /// state immediately after the format switch.
    ///
    /// ⛔ Device-only, no `session.beginConfiguration()`: nothing here touches
    /// the session graph, only device properties already legal to change on a
    /// running session.
    private func lockControls(on device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
        if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
        if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
    }

    public func goCold() {
        // ⛔ REQ-OPT-2/3/4 hold only while armed. Leaving the physical device
        // `.locked` after goCold hands the same lens to whatever uses it next
        // (the QR pairing scanner, or another app) already jammed.
        if let device = activeDevice, (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            // ⛔ And the torch, for exactly the argument above. Stopping the
            // session puts the light out on its own, but it leaves `torchMode`
            // latched `.on` — so the next `warmUp` would light it without anyone
            // commanding it, and the same lens handed to another app arrives
            // pre-switched. `CORE` §5.19 has no notion of an Actuator surviving
            // its peer going cold, and a light that comes back by itself is the
            // silent behaviour §9.2 exists to forbid.
            if device.hasTorch, device.isTorchModeSupported(.off) {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
        }
        // ⚠ The 12.2a baseline goes with it: `activeDevice` is about to be nil,
        // and a state carried across a teardown would diff the next session
        // against the last one.
        torchLock.lock()
        lastObservedTorch = nil
        torchLock.unlock()

        // ⛔ Retention ends before the outputs do. A writer left open across the
        // teardown below is one nothing will ever close, and its fragment files
        // outlive the process as orphans. `stopRetaining` is idempotent, so
        // callers that already did the right thing pay nothing.
        stopRetaining()
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        activeDevice = nil
    }

    // MARK: - The torch (CORE §5.19, PPCP-MSG §12)

    /// The last torch state this class observed, and whether a command of ours
    /// put it there.
    ///
    /// ⚠ **Guarded by its own lock, not by `sampleQueue`.** `sampleQueue` is the
    /// frame path at 150 fps and a 6.7 ms budget; nothing about a switch may
    /// take a lock that path holds. Not `@MainActor` either, because the port is
    /// not: `setTorch` is answered from a message handler and
    /// `torchChangeSincePoll` from the health tick, and those need not be the
    /// same isolation forever.
    private let torchLock = NSLock()
    /// ⛔ `nil` means "never read", which is different from "off": the first poll
    /// establishes the baseline and reports nothing, because a change needs a
    /// before as well as an after.
    private var lastObservedTorch: TorchState?

    /// `CORE` 5.19a — what this device declares in `Peer.actuators`.
    ///
    /// ⛔ **Reads the discovery session when there is no `activeDevice`**, and
    /// that is the point of it: the declaration is assembled at connect time,
    /// `activeDevice` is nil until `warmUp(mode:)`, and a torch that only exists
    /// once the camera is warm would be a torch this peer never declares — and
    /// 5.19a forbids commanding an undeclared one. So the hardware walk answers
    /// the declaration and the running session answers the command.
    ///
    /// ⛔ **`.back` only, and the flat `available: false` on a phone without one
    /// is 5.19c, not an error.** The front camera's "flash" is a screen
    /// brightness trick with no `AVCaptureDevice` torch behind it; declaring an
    /// Actuator for it would give a host a switch that answers `unsupported`
    /// every time.
    public func torchCapability() -> TorchCapability {
        let device = activeDevice ?? Self.torchBearingDevice()
        guard let device, device.hasTorch else { return .absent }
        return TorchCapability(present: true,
                               available: device.isTorchAvailable,
                               supportsOnOff: device.isTorchModeSupported(.on)
                                   && device.isTorchModeSupported(.off))
    }

    /// `CORE` 5.20 / `PPCP-MSG` 5.5 — per-Source hardware availability.
    ///
    /// ⛔ **The discovery walk, not `activeDevice`**, so this answers before
    /// `warmUp` (5.20b). A camera that is present, connected and not held by
    /// anything else is usable whether or not this application has opened it,
    /// and that is exactly the question `Readiness` cannot answer.
    ///
    /// ⛔ **`isConnected` polled rather than `wasDisconnectedNotification`
    /// observed**, and it is the same trade `torchChangeSincePoll` makes: this
    /// codebase runs no notification observers and no KVO (see
    /// `waitForConvergence`, which polls `MachClock` for the same reason), the
    /// caller is a 1 Hz tick that has to re-read the other reasons anyway, and
    /// an observer would add a lifetime to get an answer a second earlier. On
    /// this hardware the built-in cameras are never disconnected at all; the
    /// value exists for an external one.
    ///
    /// ⛔ **`in_use` is NOT reported here, and the reason is a platform gap
    /// rather than a decision.** `AVCaptureDevice.isInUseByAnotherApplication`
    /// is **macOS-only** — unavailable in iOS — and the nearest iOS signal,
    /// `AVCaptureSession.wasInterruptedNotification` with
    /// `videoDeviceInUseByAnotherClient`, answers a *different* question: it says
    /// "the session I already had was taken", which is only observable once
    /// there is a running session and is therefore unavailable in exactly the
    /// pre-`warmUp` window 5.20b exists for. `SourceUnavailableReason.inUse`
    /// stays in the vocabulary because it is 5.20's, and this platform does not
    /// produce it. ⛔ Absence is "not known" (`CORE` §5.1); a camera reported
    /// `available` here may still be held by another application, and the host
    /// learns that from the `interruption` this device already sends (7.3d).
    ///
    /// ⚠ **Cameras only.** The microphone and the IMU are declared Sources too,
    /// and `AVAudioSession` has no per-Source "somebody else has it" reading
    /// that maps onto 5.20's vocabulary without inventing one. They are absent
    /// from the dictionary, which is `CORE` §5.1's "absence means not known" and
    /// not a claim that they are fine.
    public func sourceHardwareAvailability() -> [String: SourceAvailability] {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: Self.physicalDeviceTypes,
                                                         mediaType: .video,
                                                         position: .back)
        var out: [String: SourceAvailability] = [:]
        for device in discovery.devices {
            // ⚠ The same `src:camera:<optics>` the declaration emits, built from
            // the same `Lens` — #102's lesson is that two spellings of one id
            // eventually disagree.
            let sourceId = "src:camera:\(Self.lens(for: device.deviceType).opticsName)"
            out[sourceId] = device.isConnected ? .available : .unavailable(.disconnected)
        }
        return out
    }

    /// The rear physical camera that carries the light, if this hardware has one.
    ///
    /// ⚠ `physicalDeviceTypes` rather than a `.builtInWideAngleCamera` literal,
    /// so REQ-OPT-5's "never a virtual multi-lens device" holds here too — and so
    /// a future phone that hangs the torch off a different assembly is found
    /// rather than missed.
    private static func torchBearingDevice() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: physicalDeviceTypes,
                                         mediaType: .video,
                                         position: .back)
            .devices.first(where: \.hasTorch)
    }

    /// `PPCP-MSG` 12.1 — switch the torch and report what it is **actually**
    /// doing (12.1c).
    ///
    /// ⛔ **No `session.beginConfiguration()`.** `torchMode` is a *device*
    /// property, the same class as the `focusMode` and `exposureMode` that
    /// `lockControls(on:)` sets — legal to change on a running session and
    /// nothing to do with the session graph. Wrapping it in a session
    /// configuration would stop and restart the capture graph to flip a light,
    /// which at 150 fps loses frames for no reason at all.
    ///
    /// ⛔ **`torchMode = .on`, never `setTorchModeOn(level:)`.** CB1 declares
    /// `control: on_off`, and CB4 records why the level API is the wrong one to
    /// reach for even in passing: it *throws* rather than clamping, so it cannot
    /// produce 12.1c's clamped-achieved-value case and can only produce an
    /// error nobody asked for.
    ///
    /// The failure map is 12.1b's registry and nothing outside it:
    /// - camera authorisation not granted → `permission_denied`
    /// - no torch, or no running session to command it through → `no_actuator`
    /// - a mode this driver will not take → `unsupported`
    /// - the light withdrawn while the device is hot → `thermal_limit`
    /// - withdrawn for any other reason, or the configuration lock refused
    ///   because another client holds the device → `busy`
    public func setTorch(_ request: TorchRequest) -> TorchOutcome {
        // ⚠ First, because it is the only refusal whose cause is not the
        // hardware. Without camera authorisation there is no `activeDevice`
        // either, and answering `no_actuator` for a torch that is physically
        // present would send an operator hunting a fault in the phone.
        guard PermissionsService().current().camera == .allowed else {
            return .refused(.permissionDenied)
        }
        // ⚠ `activeDevice`, not the discovery walk `torchCapability()` uses.
        // AVFoundation only lights a torch belonging to a *running* session, so
        // commanding the discovered device would report success over a light
        // that never came on — trap 3's shape, in the platform layer.
        //
        // ⚠ A declared torch on a cold device therefore answers `no_actuator`
        // rather than something warmer. It is the honest answer to "is there an
        // Actuator to command right now" and it is `busy`'s opposite: nothing
        // else holds the hardware, there is simply nothing holding it at all.
        guard let device = activeDevice, device.hasTorch else {
            return .refused(.noActuator)
        }
        let mode: AVCaptureDevice.TorchMode = request.wantsOn ? .on : .off
        guard device.isTorchModeSupported(mode) else { return .refused(.unsupported) }

        // ⛔ Only on the way **on**. A torch the platform has withdrawn must
        // still be switchable *off*: refusing that would leave the mode latched
        // on, so the light would come back by itself the moment the device
        // cooled — having been told to go out.
        if request.wantsOn && device.isTorchAvailable == false {
            return .refused(thermalState >= .serious ? .thermalLimit : .busy)
        }

        // ⚠ The `lockForConfiguration` / `defer unlock` idiom of
        // `lockControls(on:)`. A throw here means another client holds the
        // device, which is 12.1b's `busy` exactly.
        do {
            try device.lockForConfiguration()
        } catch {
            return .refused(.busy)
        }
        defer { device.unlockForConfiguration() }
        device.torchMode = mode

        // ⛔ **Read back, never echoed** (12.1c). `isTorchActive` is what the
        // hardware is doing; `torchMode` is only what it was told. They differ
        // when the light has been cut for heat, which is the one case CB4 says
        // actually occurs on this platform.
        let achieved = Self.readTorchState(of: device)

        // ⛔ Re-baseline, so 12.2a does not then report this as an autonomous
        // change: "not sent to confirm a command the requester already has an
        // acknowledgement for".
        torchLock.lock()
        lastObservedTorch = achieved
        torchLock.unlock()

        return .applied(achieved)
    }

    /// `PPCP-MSG` 12.2a — a change nobody commanded, since the last poll.
    ///
    /// ⚠ **Called from the 1 Hz health tick** (`AppModel.refreshHealth`), which
    /// is where every other cheap platform reading in this application is taken.
    /// Two boolean property reads, no lock on the device and no allocation —
    /// materially cheaper than the `storageHeadroom` call already on that tick.
    ///
    /// ⛔ **Consuming, and it re-baselines whether or not it reports.** A caller
    /// that polled without re-baselining would emit `actuator_state` once per
    /// tick for as long as the state stayed changed, which is exactly the
    /// per-tick-not-on-change mistake trap-adjacent D16 is warned about.
    public func torchChangeSincePoll() -> TorchChange? {
        guard let device = activeDevice, device.hasTorch else {
            // ⚠ Nothing to observe, and the baseline is dropped rather than
            // held: a device that went cold and comes back warm must establish a
            // fresh before, not diff against a state from another session.
            torchLock.lock()
            lastObservedTorch = nil
            torchLock.unlock()
            return nil
        }
        let now = Self.readTorchState(of: device)
        torchLock.lock()
        let previous = lastObservedTorch
        lastObservedTorch = now
        torchLock.unlock()
        // ⛔ The first read establishes a baseline and reports nothing. A change
        // needs a before as well as an after, and inventing one would announce a
        // torch that was off and stayed off.
        guard let previous, previous != now else { return nil }
        return TorchChange(state: now, observedAtNs: MachClock.hostTimeNs)
    }

    /// The two readings 12.1c distinguishes, taken together.
    ///
    /// ⚠ Read without `lockForConfiguration()`, deliberately and on the same
    /// grounds `waitForConvergence` reads `isAdjustingFocus` without it: that
    /// lock guards property *writes*.
    private static func readTorchState(of device: AVCaptureDevice) -> TorchState {
        TorchState(on: device.isTorchActive, modeIsOn: device.torchMode == .on)
    }

    // MARK: - Retention (REQ-BUF-1)

    /// Where the rolling buffer's fragments live.
    ///
    /// ⛔ **Application Support, not Caches.** The ring is regenerable, which is
    /// the textbook argument for Caches — and iOS may purge Caches under storage
    /// pressure *while the session is armed*. A ring that empties itself with no
    /// report is the silent failure §9.2 exists to forbid, and it would surface
    /// as `extractClip` answering `absent` for a swing the user watched happen.
    /// The directory is excluded from backup instead, and swept on each
    /// `startRetaining`.
    private static func ringDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("ring", isDirectory: true)
    }

    public func startRetaining(mode: VideoMode) throws {
        // ⚠ Built on the caller's thread, deliberately. Nothing can reach this
        // recorder until the `async` below installs it, so the throwing work —
        // directory creation, `AVAssetWriter.startWriting` — happens where it
        // can be reported, and the frame path never sees a half-built ring.
        let recorder = RingBufferRecorder(directory: try Self.ringDirectory(),
                                          queue: sampleQueue)
        try recorder.startRetaining(width: mode.width, height: mode.height,
                                    fps: mode.fps, bitrate: Self.provisionalBitrate)
        // REQ-OPT-3. The lock is the shipping configuration, so the exposure
        // numbers are `locked_constant` rather than `sampled` (5.8h).
        // ⛔ `nil` where the lock is not held OR the duration is not yet a
        // number — see `nanoseconds(_:)`. A `nil` here is not a degradation: it
        // makes the Capture's exposure `sampled` per frame rather than
        // `locked_constant`, which is 5.8h's weaker and truer claim.
        recorder.lockedExposureNs = activeDevice.flatMap {
            $0.exposureMode == .locked ? Self.nanoseconds($0.exposureDuration) : nil
        }

        // ⛔ Started here, not at the first Capture. Its own comment says why:
        // the first point is the state NOW, so a device that was already hot
        // when the session opened says so — which is the case REQ-ENC-4 is
        // about, and the one a timeline beginning at the first transition would
        // silently miss.
        thermalTimeline.start()

        sampleQueue.async { [weak self] in
            guard let self else { return }
            self.recorder = recorder
            self.routing = .retaining
            self.applyDiscardPolicy()
        }
    }

    /// ⚠ `sync`, not `async`, and the reason is `goCold`: it removes the
    /// session's outputs on the caller's thread immediately after calling this,
    /// so a deferred teardown would race the removal and could cancel a writer
    /// whose output had already gone. Not on the frame path, so the wait is free.
    public func stopRetaining() {
        thermalTimeline.stop()
        sampleQueue.sync {
            recorder?.stopRetaining()
            recorder = nil
            routing = .warm
            applyDiscardPolicy()
        }
    }

    public var ringStats: RingStats {
        sampleQueue.sync {
            guard let recorder else { return RingStats() }
            var stats = recorder.stats
            // `CORE` 5.21 `retained_from`, read off the ring beside the counters
            // so `buffer_status` is assembled from one consistent snapshot
            // rather than two reads a tick apart.
            stats.retainedFromNs = recorder.ring.retainedNs?.lowerBound
            return stats
        }
    }

    /// ⚠ Must run on `sampleQueue`, which owns `routing`.
    private func applyDiscardPolicy() {
        let discards = routing.discardsLateFrames
        for output in session.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }) {
            output.alwaysDiscardsLateVideoFrames = discards
        }
    }

    /// ⚠ **Provisional, and marked so deliberately.** REQ-BUF-3 requires the
    /// operating bitrate be set by measurement against shaft-detection RMSE and
    /// never by judgement; 50 Mbps is the capability spike's placeholder, chosen
    /// to sit between the sweep's endpoints. **E1.4 owns the real number and
    /// E-M2 produces it** — this level must not harden one.
    ///
    /// ⚠ It also sits above the 40 Mbps Main-tier cap at level 5.1, so whether
    /// VideoToolbox actually emits High tier must be read off the output rather
    /// than assumed.
    static let provisionalBitrate = 50_000_000

    private static func deviceType(for lens: Lens) -> AVCaptureDevice.DeviceType {
        switch lens {
        case .wide, .unknown: .builtInWideAngleCamera
        case .ultraWide: .builtInUltraWideCamera
        case .telephoto: .builtInTelephotoCamera
        }
    }

    private static func format(on device: AVCaptureDevice,
                               matching mode: VideoMode) -> AVCaptureDevice.Format? {
        device.formats.first { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(dims.width) == mode.width, Int(dims.height) == mode.height else {
                return false
            }
            return format.videoSupportedFrameRateRanges.contains {
                mode.fps <= $0.maxFrameRate + 0.001 && mode.fps >= $0.minFrameRate - 0.001
            }
        }
    }

    // MARK: - Self-test (REQ-CAP-2, REQ-FPS-2)

    public func measureSustainedRate(mode: VideoMode,
                                     duration: TimeInterval) async throws -> MeasuredCapability {
        try await warmUp(mode: mode)
        guard session.outputs.contains(where: { $0 is AVCaptureVideoDataOutput })
        else { throw CaptureDeviceError.configurationFailed("no video output") }

        // ⛔ A state change, not a delegate swap. This used to install the probe
        // as the output's delegate and null it on the way out — which, once the
        // ring is connected, silently disconnects the capture path and leaves
        // nothing listening. The probe is a consumer behind `routing` now.
        //
        // ⚠ The prior routing is restored rather than assumed to be `.warm`:
        // self-testing while armed must give the ring back, not drop it.
        let probe = FrameRateProbe()
        let previous = sampleQueue.sync { () -> Routing in
            let previous = routing
            routing = .selfTesting(probe)
            applyDiscardPolicy()
            return previous
        }
        defer {
            sampleQueue.sync {
                routing = previous
                applyDiscardPolicy()
            }
        }

        let thermalAtStart = thermalState
        try? await Task.sleep(for: .seconds(duration))

        let result = probe.result()
        let device = activeDevice

        return MeasuredCapability(
            mode: mode,
            achievedFPS: result.achievedFPS,
            droppedFrames: result.dropped,
            thermalAtEnd: thermalState,
            measuredAt: Date(),
            // ⛔ **`CORE` 5.8b, and the call is made HERE because here is where
            // the evidence is.** "`method: sustained` is used only for a
            // measurement taken under sustained thermal load. A short sample
            // taken during onboarding is `cold_sample`." The evidence that the
            // load was sustained is that the device got hotter — or was already
            // hot — over a run long enough to matter. A caller cannot be trusted
            // to pass this in: I28 exists because "without `method` the cold
            // number quietly becomes the displayed one", and a parameter is
            // exactly how that happens.
            //
            // ⚠ REQ-ENC-4 says the same thing in the product's words: "a
            // measurement taken from cold is not a measurement".
            method: Self.measurementMethod(duration: duration,
                                           thermalAtStart: thermalAtStart,
                                           thermalAtEnd: thermalState),
            durationSeconds: duration,
            // `CORE` 5.8a `observed_at` — an Instant, so in the capture timebase
            // and not the wall clock (I1, 5.3b). `measuredAt` beside it is a
            // label for a screen.
            observedHostTimeNs: MachClock.hostTimeNs,
            exposureSeconds: device.map { CMTimeGetSeconds($0.exposureDuration) },
            iso: device.map { Double($0.iso) }
        )
    }

    /// `CORE` 5.8b — was this run under sustained thermal load, or was it a cold
    /// sample?
    ///
    /// ⚠ **Two conditions, and the second is what makes the first honest.** A run
    /// has to be long enough for thermal behaviour to appear *and* has to have
    /// actually met some: a ten-minute run on a cold device in a cold room that
    /// never leaves `.nominal` has not demonstrated sustained anything, and
    /// 5.8b's consumer would be entitled to read `sustained` as though it had.
    /// Anything short of both is `cold_sample`, which is the safe direction —
    /// a consumer "MUST NOT treat it as a sustained figure", so the worst
    /// outcome of being conservative here is that a real measurement is
    /// under-claimed, and the worst outcome of the other error is a host
    /// accepting a device on a number that evaporates on the third swing.
    ///
    /// ⛔ The threshold is here, in the application, and not in the protocol
    /// (I14, 5.7d): PPCP carries the fact and never the judgement.
    private static let sustainedRunSeconds: TimeInterval = 600

    private static func measurementMethod(duration: TimeInterval,
                                          thermalAtStart: ThermalState,
                                          thermalAtEnd: ThermalState) -> MeasuredCapability.Method {
        guard duration >= sustainedRunSeconds else { return .coldSample }
        guard thermalAtEnd > .nominal || thermalAtEnd > thermalAtStart else { return .coldSample }
        return .sustained
    }

    // MARK: - The PPCP declaration (D2)

    /// Everything `PpcpDeclaration` needs, assembled from the real capture stack
    /// and the model's `DeviceProfiles.json` entry.
    ///
    /// ⚠ **This method is the whole of REQ-PORT-11's seam.** Above it: an
    /// `AVCaptureDevice.DiscoverySession` and a JSON file. Below it: nothing but
    /// Core types, which is why `CaptureCore` can build the declaration through
    /// `libppcp`'s structs without importing a framework. An Android port
    /// replaces this method and nothing else.
    ///
    /// ⛔ `product` carries the marketing name and nothing is ever inferred back
    /// from it (5.2c, I19). It is here because `CORE` 5.2 has a slot for it and a
    /// bug report is easier to read with it than without.
    public func ppcpDeclarationInput(peerId: String,
                                     viewpoint: PpcpViewpoint? = nil)
        throws -> PpcpDeclarationInput {
        let identifier = DeviceProfiles.currentIdentifier
        guard let timing = DeviceProfiles.ppcp(for: identifier) else {
            // ⛔ Not a fallback. A13/REQ-PORT-10 puts the timing in the data file
            // and I31 forbids inventing it, so a data file that failed to load is
            // a build problem that must surface as one — a declaration assembled
            // around a guessed readout is the silent bias CT-S7 exists to catch.
            throw CaptureDeviceError.configurationFailed(
                "no PPCP timing profile for \(identifier) and no _default in DeviceProfiles.json")
        }

        return PpcpDeclarationInput(
            peerId: peerId,
            profiles: PpcpProfileSet.device,
            timebases: PpcpTimebases.all,
            captureTimebaseId: PpcpTimebases.captureId,
            capability: try enumerateCapability(),
            timing: timing,
            clipCodec: Self.clipCodec,
            // ⚠ Both declared, and both on `tb:hosttime` — see the I4 note in
            // `PpcpDeclaration.plan`. The microphone is what D5's acoustic
            // nomination reads; the IMU is what D4's `metadata` Stream carries.
            declaresMicrophone: true,
            declaresIMU: true,
            // ⛔ 5.6e — absent unless something actually classified it. Nothing
            // does yet, and a `declared` viewpoint nobody declared would be a
            // self-report with no self behind it.
            viewpoint: viewpoint,
            // `CORE` 5.19a — enumerated here, from the hardware, at the moment
            // the declaration is assembled. This is the seam's whole job and the
            // Actuator half of it is no different from the Source half: what the
            // device *has*, never what the model is supposed to have.
            //
            // ⚠ **Empty on a phone with no rear flash, and on the simulator**,
            // which has no camera at all. 5.19c: a peer declaring no Actuators
            // participates fully. `torchCapability()` answers `.absent` there
            // and `actuatorDeclaration` is `nil`, so the list is empty rather
            // than this method throwing — the harness's
            // `declarationWithoutACamera` needs no special case for it.
            //
            // ⚠ Deliberately **not** derived from `capability` above: a torch is
            // not a capture mode and 5.19b keeps the two registries disjoint.
            // One walk each, and neither infers the other.
            actuators: [torchCapability().actuatorDeclaration].compactMap { $0 },
            product: ("Apple", DeviceProfiles.profile(for: identifier).marketingName,
                      ProcessInfo.processInfo.operatingSystemVersionString))
    }

    /// `CORE` §5.11.2 — start or stop taking preview frames off the capture path.
    ///
    /// ⚠ **Through `sampleQueue`, because that queue owns the tap.** Installing
    /// one from the MainActor while the callback is reading it is the race that
    /// shows up as a preview which stops after one frame.
    public func attachPreviewTap(_ tap: PreviewFrameTap?) {
        sampleQueue.async { [weak self] in
            guard let self else { return }
            // The tap clears its own in-flight flag where that flag is read.
            tap?.scheduleOnCaptureQueue = { [weak self] work in
                self?.sampleQueue.async(execute: work)
            }
            self.previewTap = tap
        }
    }

    // MARK: - The retained window (CORE 8.4b)

    /// The frames the ring actually holds around an interval.
    ///
    /// ⛔ **`absent` is a result, not a failure** (I10, 8.4b). A peer that is not
    /// retaining — cold, warm-but-not-armed, or armed on a device whose writer
    /// refused — answers `outside_buffer` and the Shot still exists. It never
    /// invents frames and it never throws. An implementation that returned a
    /// `present` extraction over no fragments is the single thing I10 is for.
    ///
    /// ⚠ Read through `sampleQueue` because that queue owns `recorder`: the ring
    /// is mutated at every segment boundary, and an extraction racing an
    /// eviction would name a fragment whose file has just been deleted.
    public func extractClip(_ requestedNs: Range<Int64>) -> ClipExtraction {
        sampleQueue.sync {
            guard let recorder, recorder.isRetaining else {
                return ClipExtraction.nothingRetained(requestedNs)
            }
            return recorder.ring.extract(requestedNs)
        }
    }

    /// E1.2 / E1.3 — the extraction **and** everything else the Capture needs.
    ///
    /// ⚠ Read through `sampleQueue` for the same reason `extractClip` is: that
    /// queue owns the recorder, and the ring is mutated at every segment
    /// boundary.
    ///
    /// ⛔ The thermal timeline is clipped to the Capture's own interval, not
    /// taken as one reading now — `CORE` §5.8 asks for a timeline over the
    /// interval, and a single sample at announce time would say nothing about
    /// what the device was doing while the swing happened.
    public func retainedClip(aroundNs t0: Int64, preNs: Int64,
                             postNs: Int64) -> RetainedClip {
        sampleQueue.sync {
            guard let recorder, recorder.isRetaining else {
                // ⛔ **`not_retained`, NOT `outside_buffer`, AND THE DIFFERENCE
                // COST A DAY.**  `nothingRetained`'s default reason is
                // `outside_buffer`, which says "that moment has rolled out of my
                // ring" -- a statement about WHEN.  This branch is not that: the
                // ring is not running at all, which is a statement about WHETHER,
                // and the two want completely different responses.
                //
                // Measured 1 Sept: PinPointStudio asked for a clip and was told
                // `outside_buffer` in ONE MILLISECOND, twice, for a 2000 ms
                // window and a 300 ms one.  That sent the investigation into ring
                // depth and the design's open question 4 -- when the truth was
                // that the phone had already disarmed and there was no ring to
                // ask.  A one-millisecond answer is a guard, not a search.
                //
                // 7.3b keeps this an absent Capture either way (I10: an answer,
                // never a failure); only the reason changes, and the reason is
                // the whole diagnostic value of the message.
                return RetainedClip.nothingRetained(
                    (t0 - Swift.max(0, preNs))..<(t0 + Swift.max(0, postNs)),
                    reason: PpcpAbsentReason.notRetained)
            }
            return recorder.retainedClip(
                aroundNs: t0, preNs: preNs, postNs: postNs,
                thermal: thermalTimeline.points(
                    covering: (t0 - Swift.max(0, preNs))..<(t0 + Swift.max(0, postNs))))
        }
    }

    /// `CORE` 5.7 `format.codec` — what a Capture from these profiles is encoded
    /// as when it reaches the host.
    ///
    /// ⚠ A reported ambiguity: 5.7 does not say whether `codec` describes what
    /// the Source *delivers* or what the payload is *encoded as*, and on this
    /// platform they differ — the video data output hands over uncompressed
    /// buffers in `format.pixel_format` and the clip is written as this. The
    /// receiver cares about this one. See the note in `Declaration.swift`.
    static let clipCodec = "hevc"

    // MARK: - Interruptions (CORE 7.3d)

    public func observeInterruptions(
        _ handler: @escaping @MainActor (InterruptionRecord) -> Void) {
        let monitor = InterruptionMonitor(onInterruption: handler)
        interruptions = monitor
        // ⚠ `isRetaining` is asked at the moment the interruption begins, not
        // captured: "recovered" means the peer got back to where it was, and
        // where it was retaining nothing there was nothing to get back to.
        let session = session
        Task { @MainActor in
            monitor.start(observing: session) { session.isRunning }
        }
    }

    // MARK: - The frame path

    /// ⛔ **Every delivered frame arrives here and nowhere else.**
    ///
    /// ⚠ No allocation, no actor hop, no `await`, no lock. At 150 fps the budget
    /// is 6.7 ms and `routing` is owned by the queue this runs on, so reading it
    /// costs nothing. A `Task` created on this path would be the reason the
    /// device reports drops the hardware did not have.
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        switch routing {
        case .warm:
            // ⛔ **Preview-only mode, and this case used to be a bare `break`
            // under a comment that said otherwise.** `Routing.warm`'s own
            // doc reads "nothing consuming frames but the preview" and the code
            // consumed nothing at all, so a preview Stream opened before arming
            // produced no picture — which is `CORE` 5.11k's *independent* mode,
            // and 5.11.2 calls setup and framing preview's main use.
            //
            // ⚠ Not counted here: the ring is the thing that counts what it did
            // and did not take, and there is no ring.
            // `RingStats.framesDroppedNotRetaining` covers the window where one
            // exists but is not yet retaining.
            previewTap?.offer(sampleBuffer,
                              atNs: FrameTimeline.nanoseconds(
                                  CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
        case .retaining:
            recorder?.append(sampleBuffer, device: activeDevice)
            // ⛔ **After the ring, always.** 5.11i: preview degrades before
            // transfer and transfer before capture, so the frame reaches the
            // thing that must not lose it first. ⚠ Two integer comparisons in
            // the ordinary case — see `PreviewFrameTap.offer`.
            previewTap?.offer(sampleBuffer,
                              atNs: FrameTimeline.nanoseconds(
                                  CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
        case .selfTesting(let probe):
            probe.observe(sampleBuffer)
        }
    }

    /// A frame the platform threw away before we saw it.
    ///
    /// ⛔ Only reachable while `alwaysDiscardsLateVideoFrames` is `true`, which
    /// by `Routing.discardsLateFrames` means only while self-testing. If this
    /// ever fires during `.retaining`, the flag did not follow the state and
    /// that is a bug this counter will expose rather than hide.
    public func captureOutput(_ output: AVCaptureOutput,
                              didDrop sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        switch routing {
        case .warm:
            break
        case .retaining:
            recorder?.appendDrop()
        case .selfTesting(let probe):
            probe.observeDrop()
        }
    }

    // MARK: - Preview

    /// Point a preview layer at this device's session.
    ///
    /// Deliberately takes the layer rather than vending the session: the session
    /// must not escape this layer, or `AVCaptureSession` becomes reachable from a
    /// view model and REQ-PORT-3 is quietly gone.
    func attachPreview(to layer: AVCaptureVideoPreviewLayer) {
        layer.session = session
    }

    // MARK: - Environment

    public var thermalState: ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    public func storageHeadroom(forMode mode: VideoMode) -> StorageHeadroom {
        let free = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0

        // §16.2: a session is ~50 shots × 3 s ≈ 150 s of video, ≈940 MB at
        // 50 Mbps. Rounded to 1 GB, which is the figure A7 quotes.
        let bytesPerSession: Int64 = 1_000_000_000
        return StorageHeadroom(estimatedSessions: Int(free / bytesPerSession),
                               freeBytes: free)
    }
}

/// Collects realised presentation timestamps on the sample queue.
///
/// ⚠ REQ-TIME-5 / REQ-FPS-2. The rate is derived from timestamp DELTAS, never
/// from a frame count over a wall-clock interval and never from the value the
/// platform reports back. Frames drop, and indices lie.
///
/// ⚠ No allocation, no actor hop and no `await` on this path. At 150 fps the
/// budget is 6.7 ms per frame; a `Task` created here would be the reason the
/// self-test reports drops that the hardware did not have.
/// ⚠ **No longer a delegate.** It was `AVCaptureVideoDataOutputSampleBufferDelegate`
/// and was installed on the output for the duration of a self-test, which meant
/// a self-test unhooked whatever else was listening. `AVFoundationCaptureDevice`
/// owns the delegate now and hands frames here while `routing` is
/// `.selfTesting`; this type kept its arithmetic and lost its claim on the
/// output.
final class FrameRateProbe: @unchecked Sendable {
    struct Result {
        var achievedFPS: Double
        var dropped: Int
    }

    private let lock = NSLock()
    private var first: Double?
    private var last: Double?
    private var count = 0
    private var dropped = 0

    func observe(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        lock.lock()
        if first == nil { first = pts }
        last = pts
        count += 1
        lock.unlock()
    }

    func observeDrop() {
        lock.lock()
        dropped += 1
        lock.unlock()
    }

    func result() -> Result {
        lock.lock()
        defer { lock.unlock() }
        guard let first, let last, count > 1, last > first else {
            return Result(achievedFPS: 0, dropped: dropped)
        }
        // count - 1 intervals span first..last.
        return Result(achievedFPS: Double(count - 1) / (last - first), dropped: dropped)
    }
}
