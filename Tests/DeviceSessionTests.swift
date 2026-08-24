//  DeviceSessionTests.swift
//  The device run — E1.1, E1.2 and E1.3's camera halves, and B14.
//
//  ⛔ **This suite exists so the device session produces NUMBERS rather than an
//  impression.** Everything here has been provable on a simulator except the one
//  thing that matters: what a real sensor and a real hardware encoder do at
//  1080p at the claimed rate. Reading that off a screen and typing it into a
//  document is how a measurement becomes a recollection.
//
//  ⚠ **Every test skips cleanly with no physical camera**, so `make test-app` on
//  a simulator stays green. `enumerateCapability` throwing `noPhysicalCameraFound`
//  is the discriminator, and it is the same check the app itself makes.
//
//  Run:  xcodebuild test -destination "id=<device-udid>" \
//          -only-testing:PinPointCaptureTests/DeviceSessionTests
//
//  Spec: REQ-BUF-1, REQ-CAP-3, REQ-FPS-2, REQ-OPT-1..7, REQ-CLIP-1;
//  `PPCP-RV` B14, 11.11e, 11.11f.

import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import Testing
import CaptureCore
@testable import PinPointCapture

@Suite("Device run — the camera halves, and B14")
struct DeviceSessionTests {

    /// `nil` when there is no physical camera, which is how every test here skips.
    static func liveCapability() -> DeviceCapability? {
        try? AVFoundationCaptureDevice().enumerateCapability()
    }

    /// The physical device the session is using, read fresh so its **current**
    /// lock state is observed rather than a captured one.
    static func backCamera(_ lens: Lens) -> AVCaptureDevice? {
        let type: AVCaptureDevice.DeviceType = switch lens {
        case .ultraWide: .builtInUltraWideCamera
        case .telephoto: .builtInTelephotoCamera
        default: .builtInWideAngleCamera
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [type], mediaType: .video, position: .back).devices.first
    }

    // MARK: E1.1 — the ring, on a real sensor

    /// ⛔ **E1.1's exit criterion.** Twenty 0.5 s fragments on disk, rolling, at
    /// the claimed rate, with `alwaysDiscardsLateVideoFrames = false`.
    ///
    /// ⚠ The rate clause is the one a directory listing cannot answer, and
    /// `maxInterArrivalNs` is what answers it. A mean near the claimed rate with
    /// a max of several frame periods is a **failing** run — that is the whole
    /// reason the counters went in before the run rather than after it.
    @Test("E1.1 — twenty fragments roll at the claimed rate on real hardware")
    func ringRollsOnHardware() async throws {
        guard let capability = Self.liveCapability(), let mode = capability.bestMode else {
            print("SKIP — no physical camera"); return
        }
        let device = AVFoundationCaptureDevice()
        print("""

        ── device ──────────────────────────────────────────────
        model      \(capability.modelName) (\(capability.modelIdentifier))
        mode       \(mode.width)×\(mode.height) @ \(mode.fps) fps, \(mode.lens)
        bitrate    \(AVFoundationCaptureDevice.provisionalBitrate) bps (⚠ provisional, E1.4/E-M2)
        """)

        try device.warmUp(mode: mode)
        // Settle before retaining — REQ-STATE-2 is what warm is for.
        try await Task.sleep(for: .seconds(2))

        // ⛔ Read the locks AFTER warm, and again after the run. A lock that
        // silently released under load is the degradation this epic is about.
        let camera = try #require(Self.backCamera(mode.lens))
        let locksAtWarm = (focus: camera.focusMode, exposure: camera.exposureMode,
                           whiteBalance: camera.whiteBalanceMode)

        try device.startRetaining(mode: mode)
        // ⚠ Long enough to roll past capacity: 20 × 0.5 s plus settle.
        let heldSeconds = 15.0
        try await Task.sleep(for: .seconds(heldSeconds))

        let stats = device.ringStats
        let extraction = device.extractClip(
            (MachClock.hostTimeNs - 2_000_000_000)..<MachClock.hostTimeNs)
        let locksAfter = (focus: camera.focusMode, exposure: camera.exposureMode,
                          whiteBalance: camera.whiteBalanceMode)
        let thermal = device.thermalState
        device.stopRetaining()
        device.goCold()

        let meanFps = stats.meanInterArrivalNs > 0
            ? 1_000_000_000.0 / Double(stats.meanInterArrivalNs) : 0
        let maxGapMs = Double(stats.maxInterArrivalNs) / 1_000_000
        let periodMs = 1_000.0 / mode.fps

        print("""

        ── RingStats over \(heldSeconds) s ─────────────────────────────
        framesAppended            \(stats.framesAppended)
        realised rate             \(String(format: "%.1f", meanFps)) fps   (claimed \(mode.fps))
        ⛔ maxInterArrivalNs       \(String(format: "%.2f", maxGapMs)) ms   (one frame = \(String(format: "%.2f", periodMs)) ms)
        drop: encoder busy        \(stats.framesDroppedEncoderBusy)
        drop: not retaining       \(stats.framesDroppedNotRetaining)
        frag: written / evicted   \(stats.fragmentsWritten) / \(stats.fragmentsEvicted)
        frag: write failed        \(stats.fragmentsDroppedWriteFailed)
        frag: empty               \(stats.fragmentsDroppedEmpty)
        non-monotonic             \(stats.monotonicityViolations)
        held in ring              \(stats.fragmentsInRing(capacity: 20))/20
        extraction                \(extraction.isAbsent ? "ABSENT" : "present, \(extraction.frameTimestampsNs.count) frames")

        ── REQ-OPT-1..4 locks ──────────────────────────────────
        focus          \(Self.lockName(locksAtWarm.focus.rawValue)) → \(Self.lockName(locksAfter.focus.rawValue))
        exposure       \(Self.lockName(locksAtWarm.exposure.rawValue)) → \(Self.lockName(locksAfter.exposure.rawValue))
        whiteBalance   \(Self.lockName(locksAtWarm.whiteBalance.rawValue)) → \(Self.lockName(locksAfter.whiteBalance.rawValue))
        thermal        \(thermal)
        """)

        // ⛔ The exit criterion, asserted rather than eyeballed.
        #expect(stats.framesAppended > 0, "frames reached the ring")
        #expect(stats.fragmentsWritten > 20, "rolled past capacity")
        #expect(stats.fragmentsEvicted == stats.fragmentsWritten - 20)
        #expect(stats.framesDroppedNotRetaining == 0)
        #expect(stats.monotonicityViolations == 0)
        // ⚠ Two frame periods. One whole missed frame is the smallest gap that
        // costs an image, and this is the assertion the mean cannot make.
        #expect(maxGapMs < periodMs * 2,
                "max inter-arrival \(maxGapMs) ms against a \(periodMs) ms frame period")
        #expect(locksAfter.focus == .locked && locksAfter.exposure == .locked,
                "REQ-OPT-2/3 — locks held for the whole run")
    }

    /// ⛔ **`locked` is raw value 0, not 2.** `AVCaptureDevice.FocusMode`,
    /// `.ExposureMode` and `.WhiteBalanceMode` all order `locked` first, then
    /// the auto modes — so a run printing `0` is a run whose locks HELD. The
    /// first version of this file annotated the column `(2 = locked)` and would
    /// have had a reader conclude REQ-OPT-2/3 had failed on a passing run.
    /// Named rather than numbered, so the question cannot arise again.
    static func lockName(_ raw: Int) -> String {
        switch raw {
        case 0: "locked"
        case 1: "auto(once)"
        case 2: "continuousAuto"
        case 3: "custom"
        default: "?\(raw)"
        }
    }

    // MARK: E1.2 / E1.3 — a clip, and what describes it

    @Test("E1.2 / E1.3 — a real clip plays, and carries a real sidecar")
    func clipAndSidecarOnHardware() async throws {
        guard let capability = Self.liveCapability(), let mode = capability.bestMode else {
            print("SKIP — no physical camera"); return
        }
        let device = AVFoundationCaptureDevice()
        try device.warmUp(mode: mode)
        try await Task.sleep(for: .seconds(2))
        try device.startRetaining(mode: mode)
        try await Task.sleep(for: .seconds(6))

        let t0 = MachClock.hostTimeNs - 2_000_000_000
        let clip = device.retainedClip(aroundNs: t0, preNs: 1_500_000_000,
                                       postNs: 500_000_000)

        #expect(clip.extraction.isAbsent == false, "⛔ E1.2 — not `absent`")
        let payload = try #require(clip.payload, "a present Capture carries a provider")
        // ⛔ **Consumed while retention is still live**, and the first version of
        // this test got it wrong. The provider reads the ring; stopping first
        // tears down the writer and it answers `notRecording` — the same hazard
        // `HostlessRecordingSession.persist` exists to close for the shipping
        // path, arriving through the port surface where nothing documented it.
        let bytes = try payload()

        device.stopRetaining()
        device.goCold()

        let url = URL.temporaryDirectory.appendingPathComponent("device-clip.mp4")
        try bytes.write(to: url)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaCharacteristic: .visual)
        let duration = try await asset.load(.duration)

        // ⛔ REQ-BUF-3 / the capability spike: 50 Mbps is above the 40 Mbps
        // Main-tier cap at level 5.1, so whether VideoToolbox emitted High tier
        // must be read off the output rather than assumed. This is E-M2's input.
        var codecDescription = "—"
        if let track = tracks.first {
            let formats = try await track.load(.formatDescriptions)
            if let f = formats.first {
                let fourCC = CMFormatDescriptionGetMediaSubType(f)
                let chars = [24, 16, 8, 0].map { Character(UnicodeScalar((fourCC >> $0) & 0xFF)!) }
                let ext = CMFormatDescriptionGetExtensions(f) as? [String: Any] ?? [:]
                codecDescription = "\(String(chars))  ext keys: \(ext.keys.sorted().joined(separator: ", "))"
            }
        }

        print("""

        ── E1.2 the clip ───────────────────────────────────────
        bytes             \(bytes.count)  (\(String(format: "%.1f", Double(bytes.count) / 1_048_576)) MB)
        video tracks      \(tracks.count)
        duration          \(String(format: "%.3f", duration.seconds)) s
        codec             \(codecDescription)
        fragments         \(clip.extraction.fragments.count)

        ── E1.3 the sidecar ────────────────────────────────────
        frames            \(clip.extraction.frameTimestampsNs.count)
        realised rate     \(clip.extraction.realisedRateMillihertz.map { "\($0) mHz" } ?? "—")
        exposure          \(clip.exposure.provenance) \(Self.describe(clip.exposure))
        ⛔ intrinsics      \(Self.describe(clip.intrinsics))
        thermal points    \(clip.thermal.count)
        holes             \(clip.extraction.holesNs.count)
        """)

        #expect(tracks.count == 1, "⛔ E1.2's exit criterion — a playable MP4")
        #expect(duration.seconds > 0.5)

        // ⛔ **E1.3, and the assertion is the honest relationship rather than a
        // wish.** Measured 24 Aug on an iPhone 16: intrinsic matrix delivery is
        // available at 1080p30/60/120 and **NOT at 1080p240** — see
        // `intrinsicsAvailabilityByFormat`. REQ-FPS-1 ranks frame-rate first, so
        // the ranked best mode is the one mode where REQ-OPT-7 is unavailable.
        // Asserting `!= nil` unconditionally would fail forever on a correct
        // implementation; asserting nothing would let a real regression through.
        // So: where the platform offers them, they must arrive.
        let deliversIntrinsics = mode.fps <= 120
        if deliversIntrinsics {
            #expect(clip.intrinsics != nil,
                    "REQ-OPT-7 — available at \(mode.fps) fps, so they must arrive")
        } else {
            #expect(clip.intrinsics == nil,
                    "⚠ absent is correct at \(mode.fps) fps — and never synthesised")
        }

        if let thumbnail = try? await ClipThumbnail.jpeg(fromClipAt: url, atNs: 1_500_000_000) {
            print("thumbnail         \(thumbnail.count) bytes, JPEG magic \(thumbnail.prefix(2).map { String(format: "%02x", $0) }.joined())")
            #expect(thumbnail.isEmpty == false)
        } else {
            Issue.record("thumbnail generation failed on device")
        }
    }

    static func describe(_ exposure: ExposureObservation) -> String {
        switch exposure.values {
        case .constant(let ns): "\(ns) ns"
        case .perFrame(let v): "\(v.count) values, first \(v.first ?? 0) ns"
        }
    }

    static func describe(_ observation: IntrinsicsObservation?) -> String {
        switch observation {
        case .none: "⚠ NONE — not delivered"
        case .constant(let m): "constant (focus locked) fx=\(m.values[0]) fy=\(m.values[4]) cx=\(m.values[2]) cy=\(m.values[5])"
        case .perFrame(let v): "per-frame, \(v.count) matrices ⚠ (expected constant under the lock)"
        }
    }

    /// ⛔ **REQ-OPT-7 diagnostic.** The first device run found `intrinsics: NONE`
    /// at the ranked best mode. REQ-CLIP-1 lists intrinsics and `CORE` 5.8
    /// carries them per frame, so whether the platform offers them **at the rate
    /// this product wants** is a capability question the spike recorded on a
    /// guess. Measured here per format rather than asserted.
    @Test("REQ-OPT-7 — where intrinsic matrix delivery is actually available")
    func intrinsicsAvailabilityByFormat() throws {
        guard let capability = Self.liveCapability(), let best = capability.bestMode else {
            print("SKIP - no physical camera"); return
        }
        let camera = try #require(Self.backCamera(.wide))
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: camera)
        let output = AVCaptureVideoDataOutput()
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        let connection = try #require(output.connection(with: .video))

        print("\n== REQ-OPT-7 intrinsic matrix delivery, by format ==")
        print("ranked best mode: \(best.width)x\(best.height) @ \(best.fps)")

        // ⚠ Support is a property of the live CONNECTION given the active
        // format, so each format must be made active to ask the question.
        var rows: Set<String> = []
        for format in camera.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.height == 1080,
                  let rate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max()
            else { continue }
            try camera.lockForConfiguration()
            camera.activeFormat = format
            camera.unlockForConfiguration()
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
            let ok = connection.isCameraIntrinsicMatrixDeliverySupported
            let label = String(format: "  %4dx%4d @ %3d fps   ", dims.width, dims.height, Int(rate))
            rows.insert(label + (ok ? "YES intrinsics" : "NO  intrinsics"))
        }
        rows.sorted().forEach { print($0) }
        print("\n⚠ Stabilisation is off for every row - REQ-OPT-1 requires it")
        print("  anyway, and intrinsics delivery requires it, so it is not the cause.")
        session.stopRunning()
    }

    // MARK: B14 — the device run RV 5.4b requires

    /// ⛔ **`PPCP-RV` B14, the run that is a ship gate.** Discharged on macOS and
    /// on the simulator; 5.4b exists because this programme once accepted a
    /// desktop proxy for a device measurement and had to restore the clause.
    @Test("B14 — X25519 through CryptoKit, on the device, against RFC 7748 §6.1")
    func x25519OnDevice() throws {
        guard Self.liveCapability() != nil else { print("SKIP — not a device"); return }

        func hex(_ d: some ContiguousBytes) -> String {
            d.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        }
        func data(_ s: String) -> Data {
            var d = Data(); var i = s.startIndex
            while i < s.endIndex {
                let j = s.index(i, offsetBy: 2)
                d.append(UInt8(s[i..<j], radix: 16)!); i = j
            }
            return d
        }

        // RFC 7748 §6.1 — ⚠ the private keys are UNCLAMPED, which is 11.11e's point.
        let alice = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation:
            data("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))
        let bob = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation:
            data("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"))
        let shared = try alice.sharedSecretFromKeyAgreement(with: bob.publicKey)

        print("""

        ── B14 on device ───────────────────────────────────────
        alice public   \(hex(alice.publicKey.rawRepresentation))
        bob public     \(hex(bob.publicKey.rawRepresentation))
        shared secret  \(hex(shared))
        """)

        #expect(hex(alice.publicKey.rawRepresentation)
                == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        #expect(hex(bob.publicKey.rawRepresentation)
                == "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        #expect(hex(shared)
                == "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")

        // ⛔ 11.11f — this platform is the "throw" half, and the device must agree.
        var rejected = 0
        for raw in [String(repeating: "00", count: 32),
                    "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
                    "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"] {
            do {
                let pk = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: data(raw))
                let s = try alice.sharedSecretFromKeyAgreement(with: pk)
                print("⚠ small-order key RETURNED \(hex(s)) — not a throw on this device")
            } catch { rejected += 1 }
        }
        print("11.11f  small-order keys rejected: \(rejected)/3 (throw, never an all-zero Z)")
        #expect(rejected == 3)

        // §10.4's Z, through the platform's own primitive.
        let skI = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation:
            data("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"))
        let skA = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation:
            data("606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f"))
        let Z = try skI.sharedSecretFromKeyAgreement(with: skA.publicKey)
        print("RV 10.4  Z     \(hex(Z))")
        #expect(hex(Z) == "7c79d7b5f31b9aac367477f5f7c7a68b5c44cac28ed5c902a59ec48c02956a6a")
    }
}
