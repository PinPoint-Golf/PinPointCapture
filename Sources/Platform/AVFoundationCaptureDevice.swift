//  AVFoundationCaptureDevice.swift
//  The iOS/iPadOS implementation of `CaptureDevice`.
//
//  ⚠ This file, and files like it, are the ONLY place `AVFoundation` types may
//  appear. Everything returned from here is a Core type (REQ-PORT-3).

import AVFoundation
import Foundation

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
    private let sampleQueue = DispatchQueue(label: "uk.co.pinpointgolf.capture.samples",
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
                    deliversIntrinsics: false
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

        try? await Task.sleep(for: .seconds(duration))

        let result = probe.result()
        let device = activeDevice

        return MeasuredCapability(
            mode: mode,
            achievedFPS: result.achievedFPS,
            droppedFrames: result.dropped,
            thermalAtEnd: thermalState,
            measuredAt: Date(),
            exposureSeconds: device.map { CMTimeGetSeconds($0.exposureDuration) },
            iso: device.map { Double($0.iso) }
        )
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
