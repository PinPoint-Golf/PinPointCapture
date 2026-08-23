//  UIIntegrationTests.swift
//  The two producers the UI integration pass added, and the honesty rules they
//  exist to hold.
//
//  Both replace a fixture the screens had been rendering as though it were
//  measured. The assertions that matter here are the *refusals*: a verdict that
//  cannot be produced from absent inputs, and a check that never ran not counting
//  as a check that passed.

import Foundation
import Testing
@testable import CaptureCore

@Suite("Light assessment — REQ-LIGHT-1 from a real self-test")
struct LightAssessmentTests {

    private func measured(exposure: Double?, iso: Double?, fps: Double = 150,
                          method: MeasuredCapability.Method = .coldSample) -> MeasuredCapability {
        MeasuredCapability(
            mode: VideoMode(width: 1920, height: 1080, fps: fps, lens: .wide),
            achievedFPS: fps, droppedFrames: 0, thermalAtEnd: .nominal,
            measuredAt: Date(timeIntervalSince1970: 1_787_336_400),
            method: method, durationSeconds: 3,
            exposureSeconds: exposure, iso: iso)
    }

    @Test("No exposure or ISO produces no verdict, rather than a guess")
    func absentInputsProduceNothing() {
        #expect(LightAssessment.from(measured(exposure: nil, iso: 800)) == nil)
        #expect(LightAssessment.from(measured(exposure: 1.0 / 1600, iso: nil)) == nil)
        #expect(LightAssessment.from(measured(exposure: nil, iso: nil)) == nil)
    }

    @Test("A zero or absurd exposure produces no verdict")
    func degenerateInputsProduceNothing() {
        #expect(LightAssessment.from(measured(exposure: 0, iso: 800)) == nil)
        #expect(LightAssessment.from(measured(exposure: 1.0 / 1600, iso: 800, fps: 0)) == nil)
    }

    @Test("Bright light at a high shutter speed reads good")
    func brightReadsGood() throws {
        let light = try #require(LightAssessment.from(measured(exposure: 1.0 / 2000, iso: 400)))
        #expect(light.verdict == .good)
        #expect(light.consequenceText == nil)
    }

    @Test("A high ISO reads marginal and states the trade")
    func highISOReadsMarginal() throws {
        let light = try #require(LightAssessment.from(measured(exposure: 1.0 / 2000, iso: 2200)))
        #expect(light.verdict == .marginal)
        #expect(light.consequenceText?.contains("120 fps") == true)
    }

    @Test("Exposure pinned at the frame-rate ceiling reads insufficient")
    func pinnedExposureReadsInsufficient() throws {
        // 150 fps allows 1/150 s at most; using essentially all of it means the
        // sensor had no light to spare.
        let light = try #require(LightAssessment.from(measured(exposure: 1.0 / 152, iso: 800)))
        #expect(light.verdict == .insufficient)
    }

    @Test("A cold sample says so, and a sustained one says that instead")
    func provenanceIsCarried() throws {
        let cold = try #require(LightAssessment.from(measured(exposure: 1.0 / 2000, iso: 400)))
        #expect(cold.provenance == .coldSample)
        #expect(cold.provenanceText.contains("cold"))

        let hot = try #require(LightAssessment.from(
            measured(exposure: 1.0 / 2000, iso: 400, method: .sustained)))
        #expect(hot.provenance == .sustained)
        #expect(hot.provenanceText.contains("sustained"))
    }

    @Test("The measurement text is the numbers the user could not have guessed")
    func measurementTextIsMono() throws {
        let light = try #require(LightAssessment.from(measured(exposure: 1.0 / 1600, iso: 2200)))
        #expect(light.measurementText.contains("1/1600"))
        #expect(light.measurementText.contains("ISO 2200"))
        #expect(light.measurementText.contains("150 fps"))
    }
}

@Suite("Framing status — a check that never ran is not a pass")
struct FramingStatusTests {

    @Test("An unchecked row does not count towards allChecksPass")
    func uncheckedIsNotPass() {
        let good = LightAssessment(verdict: .good, exposureSeconds: 1.0 / 2000,
                                   iso: 400, fps: 150)
        // Everything the build can actually establish is fine, and the three pose
        // rows have no producer. That must not read as "all checks pass".
        let status = FramingStatus(light: good)
        #expect(status.allChecksPass == false)
        #expect(status.hasAnyRealCheck)
    }

    @Test("A default status claims nothing at all")
    func defaultClaimsNothing() {
        let status = FramingStatus()
        #expect(status.allChecksPass == false)
        #expect(status.hasAnyRealCheck == false)
        #expect(status.light == nil)
        #expect(status.viewpoint == nil)
    }

    @Test("All three checked and good light is the only way to pass")
    func allPassRequiresEverything() {
        let good = LightAssessment(verdict: .good, exposureSeconds: 1.0 / 2000,
                                   iso: 400, fps: 150)
        var status = FramingStatus(inFrameAtAddress: .pass, inFrameAtTop: .pass,
                                   isSteady: .pass, light: good)
        #expect(status.allChecksPass)

        status.isSteady = .fail
        #expect(status.allChecksPass == false)
        status.isSteady = .notChecked
        #expect(status.allChecksPass == false)
    }
}

@Suite("Wall-clock anchor — REQ-OFF-8, labels not measurements")
struct WallClockAnchorTests {

    private let wall = Date(timeIntervalSince1970: 1_787_336_400)  // 18:20:00 UTC

    @Test("A monotonic instant is labelled by its offset from the anchor")
    func labelsByMonotonicOffset() {
        let anchor = WallClockAnchor(hostTimeNs: 1_000_000_000, wallClock: wall)
        // Three seconds later on the monotonic clock.
        let labelled = anchor.label(4_000_000_000)
        #expect(abs(labelled.timeIntervalSince(wall) - 3) < 0.000_001)
    }

    @Test("An instant before the anchor labels backwards, not to zero")
    func labelsBackwards() {
        let anchor = WallClockAnchor(hostTimeNs: 5_000_000_000, wallClock: wall)
        let labelled = anchor.label(2_000_000_000)
        #expect(abs(labelled.timeIntervalSince(wall) + 3) < 0.000_001)
    }

    @Test("Elapsed time is computed in the monotonic domain")
    func elapsedIsMonotonic() {
        let anchor = WallClockAnchor(hostTimeNs: 1_000_000_000, wallClock: wall)
        #expect(abs(anchor.elapsedSeconds(to: 3_500_000_000) - 2.5) < 0.000_001)
    }

    @Test("The same protocol id always produces the same Shot id")
    func shotIDIsStable() {
        let id = "shot:1e2d3c4b-5a69-78b3-55ad-a60b4b5aa8f0"
        #expect(Shot.stableID(for: id) == Shot.stableID(for: id))
        #expect(Shot.stableID(for: id).uuidString.lowercased()
                == "1e2d3c4b-5a69-78b3-55ad-a60b4b5aa8f0")
    }

    @Test("An id whose tail is not a UUID still hashes stably and distinctly")
    func nonUUIDIDsAreStable() {
        #expect(Shot.stableID(for: "shot:not-a-uuid") == Shot.stableID(for: "shot:not-a-uuid"))
        #expect(Shot.stableID(for: "shot:one") != Shot.stableID(for: "shot:two"))
    }
}
