//  AVFoundationCaptureDevice.swift
//  The iOS/iPadOS implementation of `CaptureDevice`.
//
//  ⚠ This file, and files like it, are the ONLY place `AVFoundation` types may
//  appear. Everything returned from here is a Core type (REQ-PORT-3).

import AVFoundation
import Foundation
import CaptureCore

public final class AVFoundationCaptureDevice: CaptureDevice, @unchecked Sendable {

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
    private let sampleQueue = DispatchQueue(label: "org.pinpointstudio.capture.samples",
                                            qos: .userInitiated)
    private var activeDevice: AVCaptureDevice?

    public init() {}

    // MARK: - Enumeration (REQ-FPS-1, REQ-CAP-1)

    public func enumerateCapability() throws -> DeviceCapability {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.physicalDeviceTypes,
            mediaType: .video,
            position: .back
        )

        guard !discovery.devices.isEmpty else { throw CaptureDeviceError.noPhysicalCameraFound }

        // Collapse the format list to the best rate per (lens, resolution). A
        // device reports dozens of formats that differ only in pixel encoding and
        // photo capability; the capability card is about geometry and rate.
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
                    exposureRangeNs: Self.nanoseconds(format.minExposureDuration)
                        ... Self.nanoseconds(format.maxExposureDuration),
                    // ⚠ ISO is a `Float` on this platform and an int64 on the
                    // wire (`CORE` 5.7 `optical`). Rounded toward the interior of
                    // the range — up at the bottom, down at the top — so the
                    // declared range is never wider than the one the device
                    // actually offers.
                    isoRange: Int64(format.minISO.rounded(.up))
                        ... Int64(format.maxISO.rounded(.down))
                )

                let key = "\(lens.rawValue)-\(dims.width)x\(dims.height)"
                if let existing = best[key], existing.fps >= maxRate { continue }
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

    private static func nanoseconds(_ time: CMTime) -> Int64 {
        Int64((CMTimeGetSeconds(time) * 1_000_000_000).rounded())
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
    public func warmUp(mode: VideoMode) throws {
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

        session.beginConfiguration()
        defer { session.commitConfiguration() }

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
            // The self-test wants drops to be VISIBLE, so late frames are
            // discarded and `didDrop` fires (REQ-CAP-3). ⚠ The ring-buffer
            // capture path has the opposite requirement and must revisit this:
            // capture is non-recoverable (§9.2).
            fresh.alwaysDiscardsLateVideoFrames = true
            guard session.canAddOutput(fresh) else {
                throw CaptureDeviceError.configurationFailed("cannot add video output")
            }
            session.addOutput(fresh)
            output = fresh
        }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        device.activeFormat = format

        // Pin BOTH ends of the range. Setting only the max lets the device drop
        // rate under load without reporting it, which is precisely the silent
        // degradation REQ-CAP-3 exists to detect.
        let duration = CMTime(value: 1, timescale: CMTimeScale(mode.fps.rounded()))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration

        // REQ-OPT-2/3/4. Locked focus, exposure and white balance. A focus change
        // changes focal length and therefore the intrinsics; an exposure change
        // varies motion blur mid-swing.
        if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
        if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
        if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }

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
        if !session.isRunning {
            // Capture `self`, which is Sendable, rather than the session, which
            // is not. startRunning() blocks, so it must not run on the caller.
            sampleQueue.async { [weak self] in self?.session.startRunning() }
        }
    }

    public func goCold() {
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        activeDevice = nil
    }

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
        try warmUp(mode: mode)
        guard let output = session.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }).first
        else { throw CaptureDeviceError.configurationFailed("no video output") }

        let probe = FrameRateProbe()
        output.setSampleBufferDelegate(probe, queue: sampleQueue)
        defer { output.setSampleBufferDelegate(nil, queue: nil) }

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
            product: ("Apple", DeviceProfiles.profile(for: identifier).marketingName,
                      ProcessInfo.processInfo.operatingSystemVersionString))
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
private final class FrameRateProbe: NSObject,
                                    AVCaptureVideoDataOutputSampleBufferDelegate,
                                    @unchecked Sendable {
    struct Result {
        var achievedFPS: Double
        var dropped: Int
    }

    private let lock = NSLock()
    private var first: Double?
    private var last: Double?
    private var count = 0
    private var dropped = 0

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        lock.lock()
        if first == nil { first = pts }
        last = pts
        count += 1
        lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
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
