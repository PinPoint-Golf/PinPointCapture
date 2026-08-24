//  TimelineIndexTests.swift
//  E1.5 — the merged timeline, and the window over it.
//
//  ⚠ **The primary result of E1.5 is not in this file.** It is that
//  `CapturePathTests` and every other existing suite pass **unmodified** after
//  `FragmentRing.extract` was reimplemented over `TimelineSnapshot`. Those tests
//  are the specification of the behaviour being preserved; what is below is the
//  new behaviour they cannot see.
//
//  Spec: `CORE` §5.1, §5.11, §5.14, §8.4; `CONF` CT-I10, CT-I11.

import Foundation
import Testing
@testable import CaptureCore

@Suite("E1.5 — the merged timeline")
struct TimelineIndexTests {

    static let video = "src:cam"
    static let audio = "src:mic"
    static let imu = "src:imu"

    static func entry(_ source: String, _ sequence: UInt64,
                      _ startNs: Int64, _ endNs: Int64,
                      kind: String = PpcpStreamKind.video,
                      presence: TimelineEntry.Presence = .data) -> TimelineEntry {
        TimelineEntry(sourceId: source, kind: kind, sequence: sequence,
                      startNs: startNs, endNs: endNs, byteCount: 1_000,
                      presence: presence)
    }

    // MARK: Merge

    /// PPS `timeline_index_test.cpp` intent — `LatestSequenceNeverDecreases`.
    /// Its merger thread assigns a `global_sequence`; there is no merger thread
    /// here, so the total order comes from the data and must be just as
    /// monotonic.
    @Test("Sources at different rates merge into one ascending timeline")
    func sourcesMergeAscending() {
        var index = TimelineIndex()
        // Inserted deliberately out of order and interleaved.
        index.insert(Self.entry(Self.imu, 2, 200, 300, kind: PpcpStreamKind.metadata))
        index.insert(Self.entry(Self.video, 0, 0, 500))
        index.insert(Self.entry(Self.audio, 7, 100, 400, kind: PpcpStreamKind.audio))
        index.insert(Self.entry(Self.imu, 1, 100, 200, kind: PpcpStreamKind.metadata))

        let starts = index.entries.map(\.startNs)
        #expect(starts == starts.sorted(), "merged order is ascending in time")
        #expect(index.entries.count == 4)
        #expect(index.coveredNs == 0..<500)
    }

    /// ⚠ Two sources can genuinely produce a unit at the same instant — camera
    /// and microphone share a timebase here (CT-I4). The merge must be
    /// deterministic anyway, or two runs over the same data disagree.
    @Test("Equal timestamps order deterministically, whatever the insert order")
    func equalTimestampsAreDeterministic() {
        let a = Self.entry(Self.audio, 1, 100, 200, kind: PpcpStreamKind.audio)
        let b = Self.entry(Self.video, 1, 100, 200)
        let c = Self.entry(Self.video, 2, 100, 200)

        let forward = TimelineIndex([a, b, c]).entries
        let backward = TimelineIndex([c, b, a]).entries
        var oneByOne = TimelineIndex()
        oneByOne.insert(b); oneByOne.insert(c); oneByOne.insert(a)

        #expect(forward == backward)
        #expect(forward == oneByOne.entries)
        // ⚠ "src:cam" sorts before "src:mic", so the video lane leads. The
        // ordering rule is (startNs, sourceId, sequence) and the point is that it
        // is total and data-derived — not that any particular source wins.
        #expect(forward.map(\.sourceId) == [Self.video, Self.video, Self.audio],
                "source id breaks the tie, then sequence")
        #expect(forward.map(\.sequence) == [1, 2, 1])
    }

    // MARK: Snapshot boundaries

    /// ⛔ `CORE` §5.1 — intervals are half-open at **both** ends. An entry that
    /// ends exactly where the window starts never reached into it, and one that
    /// starts exactly where the window ends is past it. Getting this wrong by
    /// one nanosecond puts a fragment in a clip that contains none of its frames.
    @Test("Snapshot boundaries are half-open at both ends")
    func snapshotBoundariesAreHalfOpen() {
        let index = TimelineIndex([
            Self.entry(Self.video, 0, 0, 100),      // ends exactly at the window start
            Self.entry(Self.video, 1, 100, 200),    // inside
            Self.entry(Self.video, 2, 200, 300)     // starts exactly at the window end
        ])
        let snapshot = index.snapshot(100..<200)
        #expect(snapshot.entries.map(\.sequence) == [1])
    }

    /// The Lane (`swing_window.h`) — one source's entries, in order, without the
    /// others.
    @Test("A lane returns only its own source, ascending")
    func laneIsPerSourceAndOrdered() {
        let index = TimelineIndex([
            Self.entry(Self.video, 0, 0, 100),
            Self.entry(Self.audio, 0, 10, 90, kind: PpcpStreamKind.audio),
            Self.entry(Self.video, 1, 100, 200),
            Self.entry(Self.imu, 0, 50, 150, kind: PpcpStreamKind.metadata)
        ])
        let snapshot = index.snapshot(0..<200)

        #expect(snapshot.sourceIds == [Self.audio, Self.video, Self.imu].sorted())
        let lane = snapshot.entries(ofSource: Self.video)
        #expect(lane.count == 2)
        #expect(lane.allSatisfy { $0.sourceId == Self.video })
        #expect(lane.map(\.startNs) == [0, 100])
    }

    /// ⛔ I10 / 8.4b — an empty index answers `absent`, and never a `present`
    /// over nothing.
    @Test("An empty index realises nothing and invents nothing")
    func emptyIndexRealisesNothing() {
        let snapshot = TimelineIndex().snapshot(0..<1_000)
        #expect(snapshot.isEmpty)
        #expect(snapshot.sourceIds.isEmpty)
        #expect(snapshot.realisedNs(ofSource: Self.video) == nil)
        #expect(snapshot.holes(ofSource: Self.video).isEmpty)
    }

    // MARK: Hole provenance — the thing the old inference could not do

    /// ⛔ **The reason E1.5 exists.** Two discontinuities of identical shape:
    /// one caused by a platform interruption, one by a fragment whose bytes
    /// failed to write. `FragmentRing`'s inference calls both an interruption,
    /// because a ring evicts only from the front so a mid-window hole "means
    /// recording stopped". That is good reasoning and it is still a guess — and
    /// E1.1 made the write-failure case separately countable, so the guess is no
    /// longer the best available answer.
    @Test("Identical holes report different causes when a record explains one")
    func holeProvenanceDistinguishesItsCauses() {
        let explained = TimelineIndex([
            Self.entry(Self.video, 0, 0, 100),
            Self.entry(Self.video, 2, 200, 300),
            // 7.3d — the platform took the capture away over exactly that span.
            Self.entry(Self.video, 0, 100, 200, kind: PpcpStreamKind.event,
                       presence: .interruption(kind: .call, recovered: true))
        ]).snapshot(0..<300)

        // The same shape, with nothing accounting for the missing span.
        let unexplained = TimelineIndex([
            Self.entry(Self.video, 0, 0, 100),
            Self.entry(Self.video, 2, 200, 300)
        ]).snapshot(0..<300)

        let explainedHoles = explained.holes(ofSource: Self.video)
        let unexplainedHoles = unexplained.holes(ofSource: Self.video)

        #expect(explainedHoles.count == 1)
        #expect(unexplainedHoles.count == 1)
        #expect(explainedHoles.first?.intervalNs == unexplainedHoles.first?.intervalNs,
                "identical intervals — only the explanation differs")
        #expect(explainedHoles.first?.cause == .interruption(kind: .call, recovered: true))
        #expect(unexplainedHoles.first?.cause == .unexplained,
                "⛔ honest, rather than filed as an interruption nobody recorded")
    }

    /// 5.11c3 — deliberate non-retention is an `absent` span with a reason,
    /// never a gap and never an interruption.
    @Test("A recorded absence explains a hole with its own reason")
    func absentRecordExplainsAHole() {
        let snapshot = TimelineIndex([
            Self.entry(Self.audio, 0, 0, 100, kind: PpcpStreamKind.audio),
            Self.entry(Self.audio, 2, 200, 300, kind: PpcpStreamKind.audio),
            Self.entry(Self.audio, 1, 100, 200, kind: PpcpStreamKind.audio,
                       presence: .absent(reason: PpcpAbsentReason.notRetained))
        ]).snapshot(0..<300)

        let holes = snapshot.holes(ofSource: Self.audio)
        #expect(holes.count == 1)
        #expect(holes.first?.cause == .absent(reason: PpcpAbsentReason.notRetained))
    }

    /// ⚠ An interruption outranks an absence where both cover the span: 7.3d is
    /// the more specific claim, and it is the one a maintainer needs.
    @Test("An interruption outranks an absence over the same span")
    func interruptionOutranksAbsence() {
        let snapshot = TimelineIndex([
            Self.entry(Self.video, 0, 0, 100),
            Self.entry(Self.video, 3, 200, 300),
            Self.entry(Self.video, 1, 100, 200, kind: PpcpStreamKind.event,
                       presence: .absent(reason: PpcpAbsentReason.notRetained)),
            Self.entry(Self.video, 2, 100, 200, kind: PpcpStreamKind.event,
                       presence: .interruption(kind: .background, recovered: false))
        ]).snapshot(0..<300)

        #expect(snapshot.holes(ofSource: Self.video).first?.cause
                == .interruption(kind: .background, recovered: false))
    }

    /// ⚠ Holes are clipped to what the source realised inside the request, so a
    /// window asking for more than the source ever covered does not report the
    /// uncovered ends as holes — those are `partial`, which is a different
    /// statement (I11).
    @Test("Holes are clipped to the realised interval, not to the request")
    func holesAreClippedToWhatWasRealised() {
        let snapshot = TimelineIndex([
            Self.entry(Self.video, 0, 1_000, 1_100),
            Self.entry(Self.video, 1, 1_200, 1_300)
        ]).snapshot(0..<5_000)

        #expect(snapshot.realisedNs(ofSource: Self.video) == 1_000..<1_300)
        let holes = snapshot.holes(ofSource: Self.video)
        #expect(holes.count == 1, "one hole in the middle, and no holes at the ends")
        #expect(holes.first?.intervalNs == 1_100..<1_200)
    }

    // MARK: The window

    /// A backing that serves some entries and not others, so the window's
    /// "skipped and reported" contract can be checked.
    struct StubSource: RetainedPayloadSource {
        var available: Set<UInt64>
        var prefix: Data?
        func payload(for entry: TimelineEntry) throws -> Data? {
            available.contains(entry.sequence)
                ? Data(repeating: UInt8(entry.sequence & 0xFF), count: 4)
                : nil
        }
        func initialisationPrefix(ofSource sourceId: String) -> Data? { prefix }
    }

    /// ⛔ The header goes first and is not optional: measured on this platform,
    /// fragments without it do not decode at all.
    @Test("A concatenated clip is the header followed by its entries, in order")
    func concatenationPutsTheHeaderFirst() throws {
        let snapshot = TimelineIndex([
            Self.entry(Self.video, 1, 0, 100),
            Self.entry(Self.video, 2, 100, 200)
        ]).snapshot(0..<200)
        let window = RetainedWindow(
            snapshot: snapshot,
            source: StubSource(available: [1, 2], prefix: Data([0xFF, 0xFF])))

        let assembled = try #require(try window.concatenatedPayload(ofSource: Self.video))
        #expect(assembled.bytes == Data([0xFF, 0xFF]) + Data(repeating: 1, count: 4)
                                                     + Data(repeating: 2, count: 4))
        #expect(assembled.missing.isEmpty)
    }

    /// ⛔ An entry the backing can no longer serve is **reported**, not silently
    /// dropped. A clip short of a fragment is a different thing from a whole
    /// one, and only the caller can decide what to say about it.
    @Test("An entry the backing cannot serve is skipped and named")
    func missingEntriesAreReportedNotSwallowed() throws {
        let snapshot = TimelineIndex([
            Self.entry(Self.video, 1, 0, 100),
            Self.entry(Self.video, 2, 100, 200),
            Self.entry(Self.video, 3, 200, 300)
        ]).snapshot(0..<300)
        let window = RetainedWindow(snapshot: snapshot,
                                    source: StubSource(available: [1, 3], prefix: nil))

        let assembled = try #require(try window.concatenatedPayload(ofSource: Self.video))
        #expect(assembled.missing.map(\.sequence) == [2])
        #expect(assembled.bytes.count == 8, "two of three entries' bytes")
    }

    /// A source that carried nothing here is `nil` — 8.4b's `absent`, a result
    /// rather than an empty clip that claims to be one.
    @Test("A window over a source with no data yields nothing, not empty bytes")
    func noDataYieldsNothing() throws {
        let snapshot = TimelineIndex([Self.entry(Self.video, 1, 0, 100)]).snapshot(0..<100)
        let window = RetainedWindow(snapshot: snapshot,
                                    source: StubSource(available: [], prefix: Data([0xFF])))
        #expect(try window.concatenatedPayload(ofSource: Self.audio) == nil,
                "a source that contributed nothing")
        #expect(try window.concatenatedPayload(ofSource: Self.video) == nil,
                "and a source whose every entry the backing lost")
    }
}

@Suite("E1.5 — the Session's merged timeline")
struct SessionTimelineTests {

    // ⚠ Fixtures are local rather than borrowed from `CapturePathTests`, so that
    // file stays **provably unmodified** — it is the specification E1.5's
    // refactor is measured against, and a helper added to it would weaken the
    // claim that nothing there changed.

    static let peerId = "peer:e15"
    static let sessionId = "ses:e15"
    static let timebase = "tb:hosttime"
    static let sourceId = "src:cam"

    final class Sink: @unchecked Sendable {
        private(set) var bytes = Data()
        func append(_ data: Data) { bytes.append(data) }
    }

    static func declaration() throws -> PpcpDeclaration {
        try PpcpDeclaration(PpcpDeclarationInput(
            peerId: peerId,
            profiles: PpcpProfileSet.device,
            timebases: [PpcpTimebaseDeclaration(id: timebase, kind: .monotonic,
                                                epochStable: true, resolutionNs: 42,
                                                origin: "CMClockGetHostTimeClock")],
            captureTimebaseId: timebase,
            capability: DeviceCapability(
                modelIdentifier: "iPhone17,3", modelName: "iPhone 16",
                claimed: [VideoMode(width: 1920, height: 1080, fps: 150, lens: .wide,
                                    pixelFormat: "420v")],
                measured: nil),
            timing: PpcpDeviceTimingProfile(
                frameStartToExposureOffsetNs: 0, offsetProvenance: .assumed,
                geometry: [PpcpGeometryEntry(readout: .assumedFractionOfFrameInterval(1.0),
                                             direction: .topToBottom)]),
            clipCodec: "hevc",
            declaresMicrophone: true,
            declaresIMU: true))
    }

    static func recorder() throws -> CaptureSessionRecorder {
        let sink = Sink()
        let writer = try SessionBundleWriter(peer: try DevicePeer(peerId: peerId)) {
            sink.append($0)
        }
        return try CaptureSessionRecorder(
            writer: writer, declaration: try declaration(),
            session: PpcpSessionRecord(id: sessionId, timebaseRef: timebase))
    }

    static var videoStream: PpcpStreamRecord {
        PpcpStreamRecord(id: "str:video", sessionId: sessionId, sourceId: sourceId,
                         kind: PpcpStreamKind.video, profileId: "prof:1",
                         timebaseId: timebase, continuity: .shotWindowed,
                         openedAtNs: 0)
    }

    /// ⛔ **The question E1.5 exists to make askable**, end to end through the
    /// recorder: a hole in the *video* explained by an interruption recorded
    /// against the Session. Before this, `CaptureSessionRecorder` held
    /// `coverage` as a dictionary of independent per-Stream accounts and an
    /// interruption was written to the bundle and forgotten — so the video's
    /// hole could only ever be inferred, and a disk write failure would have
    /// been filed as a phone call.
    @Test("An interruption explains a hole in another source's coverage")
    func interruptionExplainsAVideoHole() throws {
        let recorder = try Self.recorder()
        let stream = Self.videoStream
        try recorder.open(stream: stream)

        // 7.3d — the platform took the capture away between the two fragments.
        try recorder.record(InterruptionRecord(
            kind: .call,
            timebaseId: stream.timebaseId,
            intervalNs: 1_000..<2_000,
            recovered: true,
            streamIds: [stream.id]))

        // The ring's live coverage: two fragments with that span missing.
        var ring = FragmentRing(capacity: 8)
        _ = ring.append(CapturedFragment(sequence: 0, startNs: 0, endNs: 1_000,
                                         frameTimestampsNs: [0, 500]))
        _ = ring.append(CapturedFragment(sequence: 1, startNs: 2_000, endNs: 3_000,
                                         frameTimestampsNs: [2_000, 2_500]))

        let snapshot = recorder.timeline(
            over: 0..<3_000,
            mergingLive: ring.timelineEntries(sourceId: stream.sourceId))

        let holes = snapshot.holes(ofSource: stream.sourceId)
        #expect(holes.count == 1)
        #expect(holes.first?.intervalNs == 1_000..<2_000)
        #expect(holes.first?.cause == .interruption(kind: .call, recovered: true),
                "⛔ the cause is READ from the record, not inferred from the shape")
    }

    /// ⛔ **The defect this API shape exists to prevent.** Live coverage is
    /// passed per query, never accumulated — so a fragment that has rolled out
    /// of the ring stops being claimed the instant it is gone. An index that
    /// kept every fragment ever written would assert coverage for evicted bytes,
    /// which is precisely what I10 forbids.
    @Test("Coverage that has rolled out of the ring is no longer claimed")
    func evictedCoverageIsNotClaimed() throws {
        let recorder = try Self.recorder()
        let stream = Self.videoStream
        try recorder.open(stream: stream)

        var ring = FragmentRing(capacity: 2)
        for index in 0..<2 {
            _ = ring.append(CapturedFragment(sequence: UInt64(index),
                                             startNs: Int64(index) * 1_000,
                                             endNs: Int64(index + 1) * 1_000,
                                             frameTimestampsNs: [Int64(index) * 1_000]))
        }
        let early = recorder.timeline(over: 0..<1_000,
                                      mergingLive: ring.timelineEntries(sourceId: stream.sourceId))
        #expect(early.realisedNs(ofSource: stream.sourceId) != nil, "held at first")

        // Two more fragments; capacity 2, so the first two are gone.
        for index in 2..<4 {
            _ = ring.append(CapturedFragment(sequence: UInt64(index),
                                             startNs: Int64(index) * 1_000,
                                             endNs: Int64(index + 1) * 1_000,
                                             frameTimestampsNs: [Int64(index) * 1_000]))
        }
        let later = recorder.timeline(over: 0..<1_000,
                                      mergingLive: ring.timelineEntries(sourceId: stream.sourceId))
        #expect(later.realisedNs(ofSource: stream.sourceId) == nil,
                "and absent once evicted — not still claimed from an accumulated index")
    }
}
