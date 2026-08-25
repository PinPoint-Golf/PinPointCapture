//  ModeSelectionTests.swift
//  #102 — which capture mode gets picked, and whether the answer is the same
//  twice.
//
//  ⛔ **Three defects, one subject.** A phone offering 1080p at 30, 60, 120 and
//  240 declared only 240, because enumeration keyed its collapse on geometry and
//  discarded every slower rate. The framing check's *Use 120 fps* button
//  therefore selected 3840×2160 @ 60 on the ultra-wide camera — a different rate,
//  resolution and lens than it promised. Underneath that sat two more: two
//  ranking rules that disagreed about the lens, and a `profile_id` that named a
//  profile the declaration never carried.
//
//  ⚠ **The enumeration itself is not testable here** — it walks a real
//  `AVCaptureDevice` and lives in the platform layer. What is testable, and what
//  these assert, is everything downstream of it: the ranking, the ids, and the
//  size of what gets declared. The device half is `DeviceSessionTests`.
//
//  Spec: `CORE` 5.6d, 5.7, 5.11a, I5; REQ-RES-1, REQ-OPT-5, REQ-FPS-1.

import Foundation
import Testing
@testable import CaptureCore

@Suite("Mode selection — one ranking, one id, one declaration — #102")
struct ModeSelectionTests {

    static func mode(_ w: Int, _ h: Int, _ fps: Double, _ lens: Lens) -> VideoMode {
        VideoMode(width: w, height: h, fps: fps, lens: lens, pixelFormat: "420v",
                  exposureRangeNs: 125_000...1_000_000_000, isoRange: 34...3072)
    }

    /// What an iPhone 16 actually reports, per lens, measured on the device on
    /// 25 August 2026 — twenty distinct geometry×rate pairs.
    ///
    /// ⚠ **The whole list, including the tiny legacy modes.** They are 60% of it
    /// and they are what makes the declaration-size assertion below meaningful;
    /// a fixture trimmed to the plausible ones would assert nothing about the
    /// case that actually ships.
    static let perLens: [(Int, Int, Double)] = [
        (192, 144, 60), (352, 288, 60), (480, 360, 60), (640, 480, 60),
        (960, 540, 60), (1024, 768, 60), (1280, 720, 30), (1280, 720, 60),
        (1280, 720, 240), (1440, 1080, 60), (1920, 1080, 30), (1920, 1080, 60),
        (1920, 1080, 120), (1920, 1080, 240), (1920, 1440, 60),
        (2592, 1944, 30), (3264, 2448, 30), (3840, 2160, 30), (3840, 2160, 60),
        (4032, 3024, 30)
    ]

    static var iPhone16: DeviceCapability {
        var modes: [VideoMode] = []
        for lens in [Lens.wide, .ultraWide] {
            for (w, h, fps) in perLens { modes.append(mode(w, h, fps, lens)) }
        }
        return DeviceCapability(modelIdentifier: "iPhone17,3", modelName: "iPhone 16",
                                claimed: modes)
    }

    // MARK: The ranking

    /// ⛔ **The defect this replaced was a coin flip.** `bestMode` ranked on
    /// `(fps, height, -captureRank)` and `AppModel.remeasure(atMost:)` ranked the
    /// same list on `(fps, height)`, so between the wide and the ultra-wide
    /// offering the identical mode the winner was whichever the dictionary
    /// yielded last. Measured on one phone: the format dump computed `ultraWide`,
    /// a later run of the same code chose `wide`.
    @Test("No two modes a device can report compare equal")
    func theRankingIsTotal() {
        let modes = Self.iPhone16.claimed
        for a in modes {
            for b in modes where a.id != b.id {
                let ab = VideoMode.isWorseForCapture(a, b)
                let ba = VideoMode.isWorseForCapture(b, a)
                #expect(ab != ba,
                        "\(a.id) and \(b.id) compare equal — the winner is hash order")
            }
        }
    }

    /// REQ-OPT-5 / `Lens.captureRank` — "lens choice is calibration-affecting and
    /// forbidden to change within a session, so picking it by accident is
    /// expensive".
    @Test("The wide lens wins a tie, whichever order the modes arrive in")
    func theLensTieIsDecided() {
        let wide = Self.mode(1920, 1080, 240, .wide)
        let ultra = Self.mode(1920, 1080, 240, .ultraWide)
        #expect([wide, ultra].max(by: VideoMode.isWorseForCapture)?.lens == .wide)
        #expect([ultra, wide].max(by: VideoMode.isWorseForCapture)?.lens == .wide)
    }

    /// ⚠ `width` is in the ranking because these two tie on rate, height and
    /// lens, and would otherwise be one more order-dependent answer.
    @Test("Equal height and rate is broken by width, not by luck")
    func theWidthTieIsDecided() {
        let narrow = Self.mode(1440, 1080, 60, .wide)
        let wide = Self.mode(1920, 1080, 60, .wide)
        #expect([narrow, wide].max(by: VideoMode.isWorseForCapture) == wide)
        #expect([wide, narrow].max(by: VideoMode.isWorseForCapture) == wide)
    }

    /// ⛔ **The button, as arithmetic.** `remeasure(atMost:)` filters on the cap
    /// and takes the best of what is left. With every rate kept, at most 120 fps
    /// is 1080p120 on the wide lens — not 4K60, and not the ultra-wide.
    @Test("A 120 fps cap selects 1080p120 on the wide lens")
    func theRateCapSelectsTheRate() throws {
        let capped = Self.iPhone16.claimed.filter { $0.fps <= 120 }
        let picked = try #require(capped.max(by: VideoMode.isWorseForCapture))
        #expect(picked.fps == 120)
        #expect(picked.height == 1080)
        #expect(picked.lens == .wide)
        // ⚠ And the uncapped answer is unchanged — REQ-RES-1's rate-first target.
        #expect(Self.iPhone16.bestMode?.fps == 240)
        #expect(Self.iPhone16.bestMode?.lens == .wide)
    }

    // MARK: The ids

    /// ⛔ **`CORE` 5.11a / I5 — a Stream names what the peer declared, and for
    /// every bundle this app has written it did not.** Read out of a real bundle
    /// on 25 August: the `declare` frame carried `1920x1080@240`, the
    /// `stream_open` carried `1920x1080@240.0-wide`.
    ///
    /// ⚠ Asserted against the declaration the library actually built, not against
    /// a second copy of the format string — which is the only version of this
    /// test that can catch the two drifting apart again.
    @Test("Every mode's profileId and sourceId name something the declaration carries")
    func theIdsNameDeclaredThings() throws {
        let capability = Self.iPhone16
        let declaration = try PpcpDeclaration(PpcpDeclarationInput(
            peerId: "peer:test-device",
            profiles: PpcpProfileSet.device,
            timebases: DeclarationTests.timebases,
            captureTimebaseId: "tb:hosttime",
            capability: capability,
            timing: DeclarationTests.unmeasuredTiming,
            clipCodec: "hevc"))

        for mode in capability.claimed {
            let source = try #require(
                declaration.sources.first { $0.id == mode.sourceId },
                "no Source declared for \(mode.id) — expected \(mode.sourceId)")
            #expect(source.profileIds.contains(mode.profileId),
                    "\(mode.sourceId) declares no profile \(mode.profileId)")
        }
    }

    /// 5.6d — one Source per physical lens, and the optics spelling is the
    /// protocol's. ⚠ `Lens.opticsName` is the single source of that string;
    /// `PpcpDeclaration` used to hold a second copy of the switch.
    @Test("Each lens becomes its own Source, spelled the same way twice")
    func eachLensIsItsOwnSource() throws {
        let declaration = try PpcpDeclaration(PpcpDeclarationInput(
            peerId: "peer:test-device",
            profiles: PpcpProfileSet.device,
            timebases: DeclarationTests.timebases,
            captureTimebaseId: "tb:hosttime",
            capability: Self.iPhone16,
            timing: DeclarationTests.unmeasuredTiming,
            clipCodec: "hevc"))
        let cameras = Set(declaration.sources.filter { $0.kind == "camera" }.map(\.id))
        #expect(cameras == ["src:camera:wide", "src:camera:ultra_wide"])
    }

    // MARK: What it costs to declare

    /// ⛔ **Keeping every rate roughly doubles the declaration, and #98 is why
    /// that has to be asserted rather than assumed.** `libppcp` encodes an
    /// originated message into a 64 KiB per-channel queue and refuses anything
    /// larger; the `declare` frame measured **13,416 bytes** on a real phone with
    /// 28 profiles. Forty should land near 19 KB.
    ///
    /// ⚠ The bound is deliberately far below the queue rather than just under it.
    /// A test that passed at 63 KiB would be a test that let the next person
    /// discover #98 again on a phone.
    @Test("A full two-lens declaration stays well inside what libppcp will send")
    func theDeclarationStillFits() throws {
        let capability = Self.iPhone16
        let declaration = try PpcpDeclaration(PpcpDeclarationInput(
            peerId: "peer:test-device",
            profiles: PpcpProfileSet.device,
            timebases: DeclarationTests.timebases,
            captureTimebaseId: "tb:hosttime",
            capability: capability,
            timing: DeclarationTests.unmeasuredTiming,
            clipCodec: "hevc"))

        let bytes = try declaration.encoded().count
        #expect(capability.claimed.count == 40)
        #expect(bytes < 32 * 1024,
                "declaration is \(bytes) bytes for \(capability.claimed.count) modes")
    }
}
