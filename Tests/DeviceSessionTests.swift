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

        try await device.warmUp(mode: mode)
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

    // MARK: #17 — where the 100 ms gap comes from

    /// ⛔ **The control run above mints no Shots, and that is the difference.**
    /// `ringRollsOnHardware` reports a max inter-arrival of one frame period on
    /// this phone, twice (24 and 25 August). The app reported **100.2 ms** — 24
    /// frame periods — on a run that minted four. This test is the same ring
    /// with the one thing the app does that the control does not.
    ///
    /// ⚠ **What the instrument actually measures matters here.**
    /// `RingStats.observeArrival` is fed `CMSampleBufferGetPresentationTimeStamp`
    /// — SENSOR time, not delivery time. A stalled delegate queue leaves the PTS
    /// series contiguous and would be invisible to it. So a gap in this number
    /// means frames the sensor produced never reached the counter, and the two
    /// candidates are `didDrop` and the `framesDroppedNotRetaining` guard.
    ///
    /// ⛔ **The mechanism under test.** `extractClip` and `retainedClip` both run
    /// `sampleQueue.sync` (`AVFoundationCaptureDevice.swift:592, 612`), and
    /// `sampleQueue` IS the sample-buffer delegate queue (`:281`). `pumpMint` is
    /// `@MainActor`, so every minted Shot blocks frame delivery from the main
    /// actor for as long as the extraction takes. With
    /// `alwaysDiscardsLateVideoFrames = false` the frames queue rather than
    /// discard — until the system drops them, which is a PTS gap.
    @Test("#17 — does extracting a clip stall the frame path?")
    func extractionStallsTheFramePath() async throws {
        guard let capability = Self.liveCapability(), let mode = capability.bestMode else {
            print("SKIP — no physical camera"); return
        }
        let device = AVFoundationCaptureDevice()
        try await device.warmUp(mode: mode)
        try await Task.sleep(for: .seconds(2))
        try device.startRetaining(mode: mode)
        // Fill the ring before asking it for anything.
        try await Task.sleep(for: .seconds(6))

        let before = device.ringStats
        print("""

        ── before any extraction ───────────────────────────────
        framesAppended            \(before.framesAppended)
        maxInterArrival           \(String(format: "%.2f", Double(before.maxInterArrivalNs) / 1e6)) ms
        """)

        // Four extractions, as four Shots would — on the MAIN ACTOR, which is
        // where `pumpMint` calls them from.
        var blockedMs: [Double] = []
        var payloadMs: [Double] = []
        var payloadBytes: [Int] = []
        for _ in 0..<4 {
            let t0 = MachClock.hostTimeNs
            let started = MachClock.hostTimeNs
            let clip = await MainActor.run {
                device.retainedClip(aroundNs: t0 - 1_500_000_000,
                                    preNs: 1_500_000_000, postNs: 1_500_000_000)
            }
            blockedMs.append(Double(MachClock.hostTimeNs - started) / 1e6)

            // E1.2's `persist` calls this on the main actor, OUTSIDE the sync.
            let payloadStart = MachClock.hostTimeNs
            let bytes = try? clip.payload?()
            payloadMs.append(Double(MachClock.hostTimeNs - payloadStart) / 1e6)
            payloadBytes.append(bytes?.count ?? 0)

            try await Task.sleep(for: .seconds(2))
        }

        let after = device.ringStats
        device.stopRetaining()
        device.goCold()

        let periodMs = 1_000.0 / mode.fps
        func fmt(_ xs: [Double]) -> String {
            xs.map { String(format: "%.1f", $0) }.joined(separator: ", ")
        }
        print("""

        ── after four extractions ──────────────────────────────
        framesAppended            \(after.framesAppended)
        ⛔ maxInterArrival           \(String(format: "%.2f", Double(after.maxInterArrivalNs) / 1e6)) ms   (one frame = \(String(format: "%.2f", periodMs)) ms)
        drop: encoder busy        \(after.framesDroppedEncoderBusy)
        drop: not retaining       \(after.framesDroppedNotRetaining)
        frag: write failed        \(after.fragmentsDroppedWriteFailed)
        non-monotonic             \(after.monotonicityViolations)

        retainedClip blocked (ms) \(fmt(blockedMs))
        payload() took (ms)       \(fmt(payloadMs))
        payload bytes             \(payloadBytes.map(String.init).joined(separator: ", "))
        """)

        // ⚠ No assertion on the gap yet — this run is what decides what the
        // assertion should be. It asserts only that the extraction worked.
        #expect(after.framesAppended > before.framesAppended)
    }

    /// ⛔ **The other thing `arm()` does that the control run does not: it starts
    /// the microphone, and it starts it AFTER the ring is already retaining.**
    ///
    /// `AppModel.arm()` runs `device.startRetaining(mode:)` and then
    /// `startDetecting()`, and `MicrophoneOnsetSource.start()` sets the shared
    /// `AVAudioSession` to `.record` / `.measurement` and activates it. Changing
    /// the audio session's category on a **running** `AVCaptureSession` forces a
    /// route change, and a route change is one of the few things that can make
    /// the sensor itself stop producing — which is what a gap in the PTS series
    /// means.
    ///
    /// ⚠ It would produce exactly ONE gap, early in the run, which is consistent
    /// with a reported **max** of 100.2 ms over a session that was otherwise fine.
    @Test("#17 — does starting the microphone stall the sensor?")
    func microphoneStartStallsTheSensor() async throws {
        guard let capability = Self.liveCapability(), let mode = capability.bestMode else {
            print("SKIP — no physical camera"); return
        }
        let device = AVFoundationCaptureDevice()
        try await device.warmUp(mode: mode)
        try await Task.sleep(for: .seconds(2))
        try device.startRetaining(mode: mode)
        try await Task.sleep(for: .seconds(5))

        let before = device.ringStats
        let periodMs = 1_000.0 / mode.fps

        // ⛔ The app's own order: retain first, then start detecting.
        let microphone = MicrophoneOnsetSource { _ in }
        let started = MachClock.hostTimeNs
        var micError: String?
        do { try microphone.start() } catch { micError = String(describing: error) }
        let startBlockedMs = Double(MachClock.hostTimeNs - started) / 1e6

        try await Task.sleep(for: .seconds(6))
        let after = device.ringStats
        microphone.stop()
        device.stopRetaining()
        device.goCold()

        print("""

        ── microphone start, mid-run ───────────────────────────
        mic error                 \(micError ?? "none")
        start() blocked (ms)      \(String(format: "%.1f", startBlockedMs))

        before mic: frames        \(before.framesAppended)
        before mic: maxGap        \(String(format: "%.2f", Double(before.maxInterArrivalNs) / 1e6)) ms
        ⛔ after mic:  maxGap        \(String(format: "%.2f", Double(after.maxInterArrivalNs) / 1e6)) ms   (one frame = \(String(format: "%.2f", periodMs)) ms)
        after mic:  frames        \(after.framesAppended)
        drop: encoder busy        \(after.framesDroppedEncoderBusy)
        drop: not retaining       \(after.framesDroppedNotRetaining)
        non-monotonic             \(after.monotonicityViolations)
        """)

        #expect(after.framesAppended > before.framesAppended)
    }

    /// ⛔ **The whole application, on the phone, for thirty seconds.**
    ///
    /// The three experiments above each isolate one thing `arm()` does and the
    /// ring survived all of them at 4.18 ms. This drives `AppModel` itself, so
    /// the run carries everything at once: the Session and its bundle, the
    /// microphone, CoreMotion at 100 Hz, the 1 Hz health tick and its metadata
    /// segments, minting, the ~19 MB clip written per Shot, and the detached
    /// thumbnail decode.
    ///
    /// ⚠ **Shots are minted from injected audio** — `CONF` §2a's method, and the
    /// same route the app's own microphone takes into `observe(_:)`. A test
    /// cannot clap.
    ///
    /// ⚠ No assertion on the gap. This run exists to find out whether the
    /// reported 100.2 ms reproduces at all; what it reports decides what #17
    /// should assert.
    ///
    /// ⚠ **Run at both rates** (Mark, 25 August): if the composition is simply
    /// past what this device sustains, 120 fps should be clean and 240 should
    /// not. If both degrade equally, the rate is not the variable and something
    /// in the composition is.
    @MainActor
    @Test("#17/#101 — the whole app composition, at both rates",
          arguments: [240.0, 120.0])
    func wholeAppCompositionOnHardware(_ cap: Double) async throws {
        guard Self.liveCapability() != nil else { print("SKIP — no physical camera"); return }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("e11-\(UUID().uuidString)", isDirectory: true)
        let model = AppModel(store: SessionStore(root: root))
        model.refreshCapability()
        // ⚠ Both arms go through `remeasure` so the self-test it runs is part of
        // both, and the only difference between them is the rate.
        //
        // ⛔ **And the lens is now reported, because it is not pinned** (#102).
        // `remeasure(atMost:)` breaks its tie on `(fps, height)` with no lens
        // term, while `bestMode` breaks the same tie preferring `wide` — so a
        // rate cap can silently select the ULTRA WIDE camera. The first version
        // of this test printed geometry and rate only, and would have compared
        // two different physical sensors without saying so.
        await model.remeasure(atMost: cap)
        let mode = model.activeMode
        let baseline = model.capability.bestMode
        await model.arm()

        // ⛔ #101 — `arm()` no longer claims `.armed` on return; it waits for the
        // ring. Report what the settle actually cost, which is the number
        // `assumedSettleMs` was written waiting for.
        let armStarted = MachClock.hostTimeNs
        while model.isSettling,
              MachClock.hostTimeNs - armStarted < AppModel.settleTimeoutNs + 1_000_000_000 {
            try await Task.sleep(for: .milliseconds(25))
        }
        print("""

        ── the settle (#101) ───────────────────────────────────
        measured settle           \(model.measuredSettleNs.map {
            String(format: "%.0f ms", Double($0) / 1e6) } ?? "never settled")
        state after settling      \(model.captureStatus.state)
        capabilityError           \(model.capabilityError ?? "none")
        """)

        guard model.captureStatus.state == .armed else {
            print("""

            ── app composition ─────────────────────────────────────
            ⛔ did not reach armed — state \(model.captureStatus.state)
            capabilityError  \(model.capabilityError ?? "none")
            recordingError   \(model.recordingError ?? "none")
            """)
            model.disarm()
            return
        }

        // ⛔ **Ten seconds of nothing before anything is asked of it** (Mark,
        // 25 August). If the ~8.8 s gap is an `AVCaptureSession` reconfiguration
        // overlapping the start of retaining, it lands inside this window and
        // `largestGaps` says so — its offsets are measured from the first frame
        // the ring saw, so a startup stall reads near zero and a sustained one
        // does not.
        try await Task.sleep(for: .seconds(10))
        let settled = model.ringStats

        // Four swings, spaced, injected as the microphone would deliver them.
        for index in 0..<4 {
            try await Task.sleep(for: .seconds(5))
            await model.observe(SyntheticAudio.oneSwing(timebaseId: PpcpTimebases.captureId,
                                                        startNs: MachClock.hostTimeNs))
        }
        try await Task.sleep(for: .seconds(8))

        let stats = model.ringStats
        let shots = model.shotCount
        let candidates = model.candidateCount
        let recordingError = model.recordingError
        model.disarm()

        let periodMs = stats.meanInterArrivalNs > 0
            ? Double(stats.meanInterArrivalNs) / 1e6 : 0
        print("""

        ── the whole app, 38 s on hardware ─────────────────────
        mode                      \(mode.map { "\($0.width)x\($0.height) @ \($0.fps) \($0.lens)" } ?? "none")  (cap \(cap))
        bestMode would have been  \(baseline.map { "\($0.width)x\($0.height) @ \($0.fps) \($0.lens)" } ?? "none")
        ⚠ same lens as baseline?   \(mode?.lens == baseline?.lens ? "yes" : "NO — not comparable")
        shots / candidates        \(shots) / \(candidates)
        recordingError            \(recordingError ?? "none")

        framesAppended            \(stats.framesAppended)
        realised rate             \(String(format: "%.1f", periodMs > 0 ? 1_000 / periodMs : 0)) fps
        ⛔ maxInterArrival           \(String(format: "%.2f", Double(stats.maxInterArrivalNs) / 1e6)) ms   (mean period \(String(format: "%.2f", periodMs)) ms)
        drop: encoder busy        \(stats.framesDroppedEncoderBusy)
        drop: not retaining       \(stats.framesDroppedNotRetaining)
        frag: written / evicted   \(stats.fragmentsWritten) / \(stats.fragmentsEvicted)
        frag: write failed        \(stats.fragmentsDroppedWriteFailed)
        frag: empty               \(stats.fragmentsDroppedEmpty)
        non-monotonic             \(stats.monotonicityViolations)

        ── the first 10 s, before any load ─────────────────────
        frames                    \(settled.framesAppended)
        maxInterArrival           \(String(format: "%.2f", Double(settled.maxInterArrivalNs) / 1e6)) ms
        drop: encoder busy        \(settled.framesDroppedEncoderBusy)
        gaps over 10 ms           \(settled.notableGapCount)

        ── gap distribution over the whole run ─────────────────
        \(Self.histogram(stats))
        gaps over 10 ms           \(stats.notableGapCount)
        largest, and WHEN:
        \(Self.whenTheGapsHappened(stats))
        """)

        try? FileManager.default.removeItem(at: root)
        #expect(stats.framesAppended > 0)
    }

    /// ⛔ **#101's bisect: which of the app's per-Shot side effects costs the
    /// frames?** The whole-app run reports 156 fps, an 8.9 s gap and 650
    /// encoder-busy drops; the isolated ring reports 239.5 fps and zero. This
    /// adds ONE candidate at a time to the otherwise idle ring.
    ///
    /// ⚠ The `.atomic` write and the thumbnail decode are the two things a Shot
    /// triggers that touch the same hardware the encoder is using — the disk and
    /// the video decoder. Neither is on the frame path, which is exactly why
    /// they were not suspected first.
    @Test("#101 — which per-Shot side effect costs the frames?",
          arguments: ["baseline", "atomicWrite", "thumbnail", "both"])
    func perShotSideEffects(_ variant: String) async throws {
        guard let capability = Self.liveCapability(), let mode = capability.bestMode else {
            print("SKIP — no physical camera"); return
        }
        let device = AVFoundationCaptureDevice()
        try await device.warmUp(mode: mode)
        try await Task.sleep(for: .seconds(2))
        try device.startRetaining(mode: mode)
        try await Task.sleep(for: .seconds(6))

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("e101-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Four "Shots", five seconds apart, as the whole-app run had.
        for index in 0..<4 {
            let t0 = MachClock.hostTimeNs - 1_500_000_000
            var clip = device.retainedClip(aroundNs: t0, preNs: 1_500_000_000,
                                           postNs: 1_500_000_000)
            let bytes = (try? clip.payload?()) ?? nil
            let url = dir.appendingPathComponent("clip-\(index).mp4")

            if variant == "atomicWrite" || variant == "both", let bytes {
                // ⚠ Exactly what `RecordingSession.persist` does, on the
                // main actor, with `.atomic`.
                try await MainActor.run { try bytes.write(to: url, options: .atomic) }
            }
            if variant == "thumbnail" || variant == "both" {
                if let bytes, FileManager.default.fileExists(atPath: url.path) == false {
                    try bytes.write(to: url, options: .atomic)
                }
                // ⚠ Detached at `.utility`, as `adoptClip` does — deliberately
                // NOT awaited, because the app does not await it either.
                Task.detached(priority: .utility) {
                    _ = try? await ClipThumbnail.jpeg(fromClipAt: url,
                                                      atNs: 1_500_000_000)
                }
            }
            _ = clip
            try await Task.sleep(for: .seconds(5))
        }
        try await Task.sleep(for: .seconds(3))

        let stats = device.ringStats
        device.stopRetaining()
        device.goCold()
        try? FileManager.default.removeItem(at: dir)

        let meanFps = stats.meanInterArrivalNs > 0
            ? 1_000_000_000.0 / Double(stats.meanInterArrivalNs) : 0
        print("""

        ── #101 variant: \(variant) ────────────────────────────
        realised rate             \(String(format: "%.1f", meanFps)) fps
        ⛔ maxInterArrival           \(String(format: "%.2f", Double(stats.maxInterArrivalNs) / 1e6)) ms
        drop: encoder busy        \(stats.framesDroppedEncoderBusy)
        framesAppended            \(stats.framesAppended)
        """)
        #expect(stats.framesAppended > 0)
    }

    /// ⛔ **#102's evidence, dumped rather than reasoned about.** Every format the
    /// hardware enumerates, beside the list `enumerateCapability()` actually
    /// keeps, beside what a rate cap then selects. Mark, 25 August: *"you can't
    /// select 120fps? that doesn't make ANY sense — the native video apps let
    /// you use 120 fps. Something smells off here."* Quite. So: measure it.
    @MainActor
    @Test("#102 — every format the hardware offers, beside the ones we keep")
    func everyFormatBesideTheOnesWeKeep() async throws {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera,
                          .builtInTelephotoCamera],
            mediaType: .video, position: .back)
        guard discovery.devices.isEmpty == false else {
            print("SKIP — no physical camera"); return
        }

        print("\n── every format AVFoundation reports ────────────────────")
        var rawCount = 0
        for device in discovery.devices {
            var rows: [String] = []
            for format in device.formats {
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let rates = format.videoSupportedFrameRateRanges
                    .map { $0.maxFrameRate }.sorted()
                guard let top = rates.last else { continue }
                rawCount += 1
                rows.append("\(d.width)x\(d.height) @ \(Int(top))")
            }
            // Collapsed for readability only — the COUNT is what matters.
            let unique = Array(Set(rows)).sorted()
            print("  \(device.localizedName): \(device.formats.count) formats, "
                  + "\(unique.count) distinct geometry@rate")
            for r in unique.sorted() { print("      \(r)") }
        }

        let capability = try AVFoundationCaptureDevice().enumerateCapability()
        print("""

        ── what enumerateCapability() KEEPS ────────────────────
        raw formats walked        \(rawCount)
        claimed modes             \(capability.claimed.count)
        """)
        for m in capability.claimed.sorted(by: { ($0.fps, $0.height) > ($1.fps, $1.height) }) {
            print("      \(m.width)x\(m.height) @ \(Int(m.fps))  \(m.lens)")
        }

        // What a rate cap actually selects. ⛔ **Through the SHARED comparator**,
        // which is the whole point of #102 — this line held a second copy of the
        // ranking and, after the fix landed, was still reporting `ultraWide` for
        // a 240 fps cap while the application chose `wide`. An instrument with
        // its own copy of the rule measures the rule it holds, not the one that
        // ships.
        for cap in [240.0, 120.0, 60.0] {
            let picked = capability.claimed.filter { $0.fps <= cap }
                .max(by: VideoMode.isWorseForCapture)
            print("  cap \(Int(cap)) fps → "
                  + (picked.map { "\($0.width)x\($0.height) @ \(Int($0.fps)) \($0.lens)" }
                     ?? "NOTHING"))
        }
        // ⛔ #102's exit criterion, both halves, on the hardware that showed it.
        #expect(capability.claimed.contains { $0.width == 1920 && $0.height == 1080
                                              && $0.fps == 120 && $0.lens == .wide },
                "1920x1080 @ 120 wide is offered by this camera and must survive enumeration")
        let atMost120 = capability.claimed.filter { $0.fps <= 120 }
            .max(by: VideoMode.isWorseForCapture)
        #expect(atMost120?.height == 1080, "a 120 cap must not fall through to 4K")
        #expect(atMost120?.fps == 120)
        #expect(atMost120?.lens == .wide, "REQ-OPT-5 — the rate cap must not change lens")

        // ⚠ Deterministic, not merely correct once: the defect was hash order.
        let again = try AVFoundationCaptureDevice().enumerateCapability()
        #expect(again.bestMode?.lens == capability.bestMode?.lens)
        #expect(again.claimed.filter { $0.fps <= 120 }
            .max(by: VideoMode.isWorseForCapture)?.lens == atMost120?.lens)
        #expect(capability.claimed.isEmpty == false)
    }

    /// The bucket counts, labelled. ⚠ A histogram rather than a mean, for the
    /// reason `RingStatsOverlay` exists at all: 150 frames at 6.67 ms with one
    /// 40 ms stall averages to a healthy-looking 145 fps.
    static func histogram(_ stats: RingStats) -> String {
        let labels = ["  <2ms", "  <5ms", " <10ms", " <20ms",
                      " <50ms", "<100ms", "<500ms", " >=500"]
        return zip(labels, stats.gapBuckets)
            .filter { $0.1 > 0 }
            .map { "\($0.0)  \($0.1)" }
            .joined(separator: "\n        ")
    }

    /// ⛔ Offsets from the FIRST frame. A reconfiguration stall clusters near
    /// zero; a sustained problem does not.
    static func whenTheGapsHappened(_ stats: RingStats) -> String {
        guard stats.largestGaps.isEmpty == false else { return "  (none over 10 ms)" }
        return stats.largestGaps
            .sorted { $0.deltaNs > $1.deltaNs }
            .map { gap in
                String(format: "  at %6.2f s   %8.2f ms",
                       Double(gap.sinceFirstNs) / 1e9, Double(gap.deltaNs) / 1e6)
            }
            .joined(separator: "\n        ")
    }

    // MARK: E1.2 / E1.3 — a clip, and what describes it

    @Test("E1.2 / E1.3 — a real clip plays, and carries a real sidecar")
    func clipAndSidecarOnHardware() async throws {
        guard let capability = Self.liveCapability(), let mode = capability.bestMode else {
            print("SKIP — no physical camera"); return
        }
        let device = AVFoundationCaptureDevice()
        try await device.warmUp(mode: mode)
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
        // `RecordingSession.persist` exists to close for the shipping
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

    // MARK: The whole loop, hosted — what the manual run kept doing by hand

    /// ⛔ **Test 1 of the hardware list, automated.**
    ///
    /// Connect to a real PinPointStudio, arm, inject a swing, assert a clip with
    /// real bytes reached the bundle. Six manual runs on 27 August found five
    /// separate faults that this would have caught in one: `stream_open` refused
    /// on a re-arm, `t0` read in the host's clock and handed to the ring, the
    /// clip keyed on the wrong instant, the wall clock two hours out, and a
    /// relation extrapolated across two boot origins landing 47 s in the future.
    ///
    /// ⚠ **Injected audio is not a compromise** — `CONF` §2a's *injected* method
    /// exists for exactly this. What cannot be injected is the camera, which is
    /// why this suite has to run on a phone at all.
    ///
    /// ⚠ Skips without `HOST`/`PSK`, so `make test-device` alone still proves the
    /// hostless camera halves above.
    @Test("The hosted loop — a real link, an injected swing, and a clip with bytes")
    func aHostedSwingProducesAClip() async throws {
        guard let capability = Self.liveCapability(), capability.bestMode != nil else {
            print("SKIP — no physical camera"); return
        }
        // ⛔ **No credentials needed, and that is the point.** This phone already
        // holds a pairing, so the honest way to reach PinPointStudio is the one a
        // golfer takes: browse `_ppcp._tcp`, resolve the advertisement's `rid`
        // against every held pairing (3.4b), and dial. Requiring a PSK on the
        // command line would be testing a path this app does not ship.
        //
        // ⚠ 3.6a — finding nothing is **not an error**. It means Studio is not
        // running, or this network does not carry discovery between its clients,
        // and neither is a failure of the thing under test.
        let outcome = await ReconnectCoordinator().attempt()
        guard case .connected(let host) = outcome else {
            print("SKIP — no host reached: \(outcome). Is PinPointStudio running "
                  + "on a network that carries multicast?")
            return
        }
        print("DEVICE-RUN reached \(host.hostDisplayName ?? host.instanceName) "
              + "— \(host.security.summary)")

        let model = await AppModel()
        await MainActor.run { model.refreshCapability() }
        await model.connect(transport: host.transport, sessionId: host.sessionId,
                            hostDisplayName: host.hostDisplayName)
        let link = try #require(await model.link, "no link was composed")

        // Studio opens the Session at `declare`; allow that and the sync burst.
        try await Task.sleep(for: .seconds(12))
        let session = try #require(await link.hostSession, "session_open never arrived")
        print("DEVICE-RUN session=\(session.sessionId) ref=\(session.timebaseRefId)")

        await model.arm()
        try await Task.sleep(for: .seconds(3))
        let armed = await model.captureStatus.state
        let why = await model.capabilityError ?? "—"
        #expect(armed == .armed, "did not reach armed: \(why)")

        // ⛔ One swing. PinPointStudio's pipeline is unavailable for 15–40 s after
        // each, so a burst measures their backlog rather than our capture.
        await model.observe(SyntheticAudio.oneSwing(timebaseId: PpcpTimebases.captureId,
                                                    startNs: MachClock.hostTimeNs))
        // 8.2i's deadline is `issue_hold` plus a heartbeat, then the clip is cut.
        try await Task.sleep(for: .seconds(8))

        let shots = await model.session.shots
        let candidates = await model.candidateCount
        print("DEVICE-RUN candidates=\(candidates) shots=\(shots.count)")
        for shot in shots {
            print("DEVICE-RUN shot \(shot.ordinal) at \(shot.impact) — \(shot.syncState.displayText)")
        }
        if let diagnostic = await model.recordingError {
            print("DEVICE-RUN recordingError: \(diagnostic)")
        }
        #expect(shots.isEmpty == false, "no Shot was minted")

        // ⛔ **The assertion every manual run failed.** A bundle with no payload
        // is #98's shape, and all five of today's faults ended here.
        await model.disarm()
        try await Task.sleep(for: .seconds(2))

        let bundles = await model.libraryRows()
        let newest = try #require(bundles.first, "no bundle was written")
        print("DEVICE-RUN bundle \(newest.sessionId) — \(newest.byteCount / 1_000_000) MB")
        #expect(newest.byteCount > 1_000_000,
                "bundle is \(newest.byteCount) bytes — the Capture was announced absent")

        await model.disconnect()
    }

    // MARK: The rest of the hardware list, automated

    /// Reaches PinPointStudio the way a golfer does, or skips saying why.
    static func reachStudio() async -> (AppModel, ReconnectedHost)? {
        let outcome = await ReconnectCoordinator().attempt()
        guard case .connected(let host) = outcome else {
            print("SKIP — no host reached: \(outcome)")
            return nil
        }
        let model = await AppModel()
        await MainActor.run { model.refreshCapability() }
        await model.connect(transport: host.transport, sessionId: host.sessionId,
                            hostDisplayName: host.hostDisplayName)
        return (model, host)
    }

    /// **Test 2 — preview.** Our half of it: the third channel, the Stream, and
    /// frames actually leaving.
    ///
    /// ⛔ **And the part 5.11i makes non-negotiable**: preview must never cost a
    /// captured frame. The ring's counters are read with preview running and
    /// again with it stopped, because "it looked fine" is not a measurement and
    /// a tap on the 6.7 ms frame path is exactly where a regression would hide.
    @Test("Preview opens a third channel and does not cost the ring a frame")
    func previewCostsTheRingNothing() async throws {
        guard let capability = Self.liveCapability(), capability.bestMode != nil else {
            print("SKIP — no physical camera"); return
        }
        guard let (model, _) = await Self.reachStudio() else { return }
        try await Task.sleep(for: .seconds(12))

        await model.arm()
        try await Task.sleep(for: .seconds(6))
        let withPreview = await model.ringStats
        let hasPreview = await model.recording?.previewStream != nil
        print("DEVICE-RUN preview stream declared: \(hasPreview)")
        print("DEVICE-RUN with preview: frames \(withPreview.framesAppended) "
              + "maxInterArrival \(withPreview.maxInterArrivalNs / 1_000_000) ms")

        // ⚠ 5.11a/I5 — the Stream must name a profile the declaration carries,
        // and 5.11m makes that profile's `intrinsics: none`.
        #expect(hasPreview, """
                no preview Stream was derived — either no camera Source declares \
                the preview profile, or the guard that requires it is refusing
                """)

        await model.disarm()
        try await Task.sleep(for: .seconds(2))
        await model.arm()
        try await Task.sleep(for: .seconds(6))
        let second = await model.ringStats
        print("DEVICE-RUN second arm: frames \(second.framesAppended) "
              + "maxInterArrival \(second.maxInterArrivalNs / 1_000_000) ms")

        // ⛔ **The re-arm is the assertion.** A Stream's identity is fixed for its
        // lifetime and the engine refuses an id it already holds, so a link peer
        // that outlives the recording session used to make the second arm fail
        // with `invalid argument` and report "nothing is being recorded".
        let error = await model.recordingError
        #expect(error == nil, "the second arm failed: \(error ?? "—")")

        await model.disarm()
        await model.disconnect()
    }

    /// **Test 6 — the residual.** REQ-SYNC-4: how far this device's own acoustic
    /// fiducial sat from the instant the host decided the shot happened.
    ///
    /// ⚠ **Needs the host to arbitrate over our Candidate**, which needs its
    /// corroboration rule to pass — so run PinPointStudio under its probe with
    /// `--corroborate`, or with no detector available at all. With neither, the
    /// host excludes and issues nothing, no Shot is arbitrated over our
    /// nomination, and there is correctly nothing to subtract.
    @Test("The impact residual is computed when the host arbitrates our Candidate")
    func theResidualIsComputed() async throws {
        guard let capability = Self.liveCapability(), capability.bestMode != nil else {
            print("SKIP — no physical camera"); return
        }
        guard let (model, _) = await Self.reachStudio() else { return }
        try await Task.sleep(for: .seconds(12))

        await model.arm()
        try await Task.sleep(for: .seconds(3))
        await model.observe(SyntheticAudio.oneSwing(timebaseId: PpcpTimebases.captureId,
                                                    startNs: MachClock.hostTimeNs))
        try await Task.sleep(for: .seconds(10))

        let residual = await model.hostLink.clock?.lastImpactResidualMilliseconds
        let clock = await model.hostLink.clock
        // ⚠ **The exchange count separates the two explanations** for a drift of
        // −184515 ppm: an estimator that never converged, or one fed samples
        // whose `t4` includes queueing delay. 6.3c's burst is 16; if it finished
        // and the estimate is still this wide, the samples are bad.
        print("DEVICE-RUN agreement=\(clock?.agreementText ?? "—") "
              + "drift=\(clock?.driftText ?? "—") "
              + "exchanges=\(clock?.exchangesCompleted ?? 0)"
              + "/\(clock?.exchangesExpected ?? 0)")
        print("DEVICE-RUN residual=\(residual.map { "\($0) ms" } ?? "not yet")")

        // ⚠ **Reported, not asserted.** Whether a residual exists depends on the
        // host arbitrating, which depends on its corroboration rule — a person's
        // configuration, not our correctness. What IS asserted is that a
        // residual, if one exists, is a plausible number rather than the whole
        // offset between two unrelated clocks, which is what 8.2i1's "never
        // substitute a zero" exists to prevent.
        if let residual {
            #expect(abs(residual) < 1_000, """
                    a residual of \(residual) ms is not a clock disagreement — it \
                    is the two clocks being compared through no relation at all
                    """)
        }

        await model.disarm()
        await model.disconnect()
    }

    /// **Test 8 — the honesty check.** `mvp-online.md` §4.2: the bundle must carry
    /// the same records that went over the wire, or "online only" has quietly
    /// become "online or nothing", which is a different product.
    @Test("The bundle holds what crossed — shots, and a clip with bytes")
    func theBundleHoldsWhatCrossed() async throws {
        guard let capability = Self.liveCapability(), capability.bestMode != nil else {
            print("SKIP — no physical camera"); return
        }
        guard let (model, _) = await Self.reachStudio() else { return }
        try await Task.sleep(for: .seconds(12))

        await model.arm()
        try await Task.sleep(for: .seconds(3))
        await model.observe(SyntheticAudio.oneSwing(timebaseId: PpcpTimebases.captureId,
                                                    startNs: MachClock.hostTimeNs))
        try await Task.sleep(for: .seconds(8))
        let shots = await model.session.shots.count
        await model.disarm()
        try await Task.sleep(for: .seconds(2))

        let bundles = await model.libraryRows()
        let newest = try #require(bundles.first, "no bundle was written")
        print("DEVICE-RUN bundle \(newest.sessionId) — \(newest.byteCount / 1_000_000) MB, "
              + "\(shots) shot(s) in the session")

        // ⛔ A bundle with no payload is #98's shape, and every fault found on
        // 27 August ended here.
        #expect(newest.byteCount > 1_000_000, """
                the bundle is \(newest.byteCount) bytes — the Capture was \
                announced `absent`, so nothing was filmed
                """)
        await model.disconnect()
    }
}