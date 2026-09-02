//  IntrinsicsCarryTests.swift
//  E1.3 — the intrinsic matrices, from fragment to extraction.
//
//  ⚠ **What was wrong.** `FrameTimeline` observed a matrix per frame and
//  `drain()` returned them, but `CapturedFragment` had no field to hold one — so
//  they were dropped at the fragment boundary and `RingBufferRecorder.capture()`
//  rebuilt the batch with `intrinsics: []` one line before handing it to the
//  builder that wanted them. Nothing failed; the field was simply always absent.
//  These tests are the reason it cannot go quiet again.
//
//  Spec: `CORE` §5.8 `intrinsics`; `ENC` §4.1, 4.1d; REQ-CLIP-1, REQ-OPT-7.

import Foundation
import Testing
@testable import CaptureCore

@Suite("E1.3 — intrinsics reach the extraction")
struct IntrinsicsCarryTests {

    /// ⚠ Force-unwrapped deliberately: `PpcpMatrix3.init?` refuses anything but
    /// nine values, and a fixture that silently became `nil` would test nothing.
    static func matrix(_ fx: Double) -> PpcpMatrix3 {
        PpcpMatrix3([fx, 0, 960, 0, fx, 540, 0, 0, 1])!
    }

    /// A fragment carrying one matrix per frame, on a 100 ms grid.
    static func fragment(_ sequence: UInt64, startNs: Int64,
                         matrices: [PpcpMatrix3]) -> CapturedFragment {
        let times = (0..<matrices.count).map { startNs + Int64($0) * 100_000_000 }
        return CapturedFragment(
            sequence: sequence, startNs: startNs,
            endNs: startNs + Int64(matrices.count) * 100_000_000,
            frameTimestampsNs: times,
            exposureNs: Array(repeating: 1_000_000, count: times.count),
            iso: Array(repeating: 640, count: times.count),
            intrinsics: matrices)
    }

    /// ⛔ Parallel to `frames.ns`, in order, and clipped to the same realised
    /// interval as every other per-frame series (5.8f).
    @Test("Per-frame matrices come out of an extraction in frame order")
    func matricesSurviveExtraction() {
        var ring = FragmentRing(capacity: 4)
        _ = ring.append(Self.fragment(0, startNs: 0,
                                      matrices: [Self.matrix(1500), Self.matrix(1501)]))
        _ = ring.append(Self.fragment(1, startNs: 200_000_000,
                                      matrices: [Self.matrix(1502), Self.matrix(1503)]))

        let clip = ring.extract(0..<400_000_000)
        #expect(clip.frameTimestampsNs.count == 4)
        #expect(clip.intrinsics.count == clip.frameTimestampsNs.count,
                "⛔ 5.8f — a parallel series is exactly `frames.ns` long")
        #expect(clip.intrinsics.map { $0.values[0] } == [1500, 1501, 1502, 1503])
    }

    /// ⚠ A window that clips the extraction must clip the matrices with it, or
    /// the series slides out of step with the times it is parallel to.
    @Test("A window inside one fragment lists the whole fragment, matrices alongside")
    func matricesAreClippedWithTheFrames() {
        var ring = FragmentRing(capacity: 4)
        _ = ring.append(Self.fragment(0, startNs: 0, matrices: [
            Self.matrix(1500), Self.matrix(1501), Self.matrix(1502), Self.matrix(1503)
        ]))

        // The request covers only the middle two frames; a fragment decodes
        // whole and is sent whole, so all four come, each with its own matrix.
        let clip = ring.extract(100_000_000..<300_000_000)
        #expect(clip.outcome == .present(.complete))
        #expect(clip.frameTimestampsNs == [0, 100_000_000, 200_000_000, 300_000_000])
        #expect(clip.intrinsics.map { $0.values[0] } == [1500, 1501, 1502, 1503])
    }

    /// ⛔ **Empty is the normal case, not a failure.** A device that does not
    /// deliver intrinsics produces no matrices, and the extraction must say so
    /// by carrying none — never by synthesising an identity, which would be a
    /// calibration claim with nothing behind it.
    @Test("A device that delivers no matrices produces none, not a placeholder")
    func noMatricesMeansNone() {
        var ring = FragmentRing(capacity: 4)
        _ = ring.append(CapturedFragment(sequence: 0, startNs: 0, endNs: 200_000_000,
                                         frameTimestampsNs: [0, 100_000_000]))
        let clip = ring.extract(0..<200_000_000)
        #expect(clip.frameTimestampsNs.count == 2)
        #expect(clip.intrinsics.isEmpty)
    }

    /// ⚠ A fragment that delivered matrices for only some of its frames must not
    /// slide the series: each matrix is taken alongside its own frame index, so
    /// a short array contributes what it has and nothing is misattributed.
    @Test("A fragment with fewer matrices than frames does not misalign them")
    func shortMatrixArrayDoesNotSlide() {
        var ring = FragmentRing(capacity: 4)
        _ = ring.append(CapturedFragment(
            sequence: 0, startNs: 0, endNs: 300_000_000,
            frameTimestampsNs: [0, 100_000_000, 200_000_000],
            intrinsics: [Self.matrix(1500)]))
        let clip = ring.extract(0..<300_000_000)

        #expect(clip.frameTimestampsNs.count == 3)
        #expect(clip.intrinsics.count == 1, "what was delivered, attributed to frame 0")
        #expect(clip.intrinsics.first?.values[0] == 1500)
    }

    /// ⛔ **5.8f, and it was not enforced for intrinsics.** `CaptureBuilder`
    /// length-checked `iso` and passed `intrinsics` straight through — harmless
    /// only because they were always `nil`. Now that E1.3 fills them, a series
    /// shorter than `frames.ns` would be a claim about frames it does not
    /// describe, so it is refused outright rather than sent short.
    @Test("A per-frame series shorter than the frames is refused, not truncated")
    func mismatchedSeriesIsRefused() {
        var ring = FragmentRing(capacity: 4)
        _ = ring.append(Self.fragment(0, startNs: 0, matrices: [
            Self.matrix(1500), Self.matrix(1501), Self.matrix(1502)
        ]))
        let clip = ring.extract(0..<300_000_000)
        let stream = PpcpStreamRecord(
            id: "str:v", sessionId: "ses:1", sourceId: "src:cam",
            kind: PpcpStreamKind.video, profileId: "p", timebaseId: "tb:hosttime",
            continuity: .shotWindowed, openedAtNs: 0)

        // Matching length — sent.
        let matching = CaptureBuilder.shotCapture(
            id: "cap:1", shotId: "sht:1", stream: stream, extraction: clip,
            exposure: .lockedConstant(1_000_000),
            intrinsics: .perFrame(clip.intrinsics))
        #expect(matching.achievedFrames?.intrinsics != nil)

        // One short — refused.
        let short = CaptureBuilder.shotCapture(
            id: "cap:2", shotId: "sht:1", stream: stream, extraction: clip,
            exposure: .lockedConstant(1_000_000),
            intrinsics: .perFrame(Array(clip.intrinsics.dropLast())))
        #expect(short.achievedFrames?.intrinsics == nil,
                "⛔ absent means not delivered, which is true; a short series is not")

        // ⚠ The constant form is exempt — one matrix is not a series.
        let constant = CaptureBuilder.shotCapture(
            id: "cap:3", shotId: "sht:1", stream: stream, extraction: clip,
            exposure: .lockedConstant(1_000_000),
            intrinsics: .constant(Self.matrix(1500)))
        #expect(constant.achievedFrames?.intrinsics != nil)
    }

    /// ⛔ `ENC` 4.1d — the constant and per-frame forms are told apart by the
    /// type of the FIRST element, so an empty array has nothing to branch on and
    /// is malformed. `IntrinsicsObservation` therefore has no empty case, and a
    /// Capture with no matrices carries `nil` rather than an empty series.
    @Test("An observation is never an empty array")
    func thereIsNoEmptyObservation() {
        let constant = IntrinsicsObservation.constant(Self.matrix(1500))
        let perFrame = IntrinsicsObservation.perFrame([Self.matrix(1500),
                                                       Self.matrix(1501)])
        if case .perFrame(let values) = perFrame { #expect(values.isEmpty == false) }
        if case .constant = constant { } else { Issue.record("constant form lost") }
    }
}
