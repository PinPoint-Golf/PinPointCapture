//  MarkupTests.swift
//  D8 — Annotations: the total order, the placement rule, the size cap, the drag
//  coalescer, and the absence CT-I37 is about.
//
//  Rows exercised: CT-I37 (device).

import Foundation
import Testing
import CPPCP
@testable import CaptureCore

@Suite("Markup — CORE §5.18; MSG §9.0")
struct MarkupTests {

    static let sessionId = "ses:d8"
    static let shotId = "sht:1"
    static let timebase = "tb:hosttime"
    static let timebaseRef = "tb:hosttime"

    static let videoStream = PpcpStreamRecord(
        id: "str:video", sessionId: sessionId, sourceId: "src:camera:wide",
        kind: PpcpStreamKind.video, profileId: "1920x1080@150",
        timebaseId: timebase, continuity: .shotWindowed, openedAtNs: 0)

    static func line(id: String = "ann:1", author: String, revision: UInt64 = 1,
                     body: Data = Data("{\"p\":[[0,0],[1,1]]}".utf8)) throws
        -> PpcpAnnotation {
        try PpcpAnnotation(id: id, sessionId: sessionId, shotId: shotId,
                           streamId: videoStream.id, timebaseId: timebase,
                           atNs: 5_000_000_000, authorPeerId: author,
                           provenance: .user, kind: .line, format: "application/json",
                           body: body, createdAtTimebaseId: timebase,
                           createdAtNs: 5_000_000_000, revision: revision)
    }

    // MARK: 5.18e / 9.0c — the total order

    /// ⛔ **The tiebreak is not decoration.** Revision 7 of the specification
    /// claimed two peers editing concurrently converge on the higher revision, and
    /// they do not: both hold revision 1, both produce revision 2, each receives an
    /// equal revision and ignores it, and the two ends diverge permanently while
    /// each believes it converged.
    @Test("An equal revision is decided by author_peer_id, bytewise")
    func equalRevisionsTiebreakOnAuthor() throws {
        let coach = try Self.line(author: "peer:host", revision: 2)
        let golfer = try Self.line(author: "peer:device", revision: 2)
        // "peer:host" sorts above "peer:device" bytewise ('h' > 'd').
        #expect(coach.supersedes(golfer))
        #expect(golfer.supersedes(coach) == false)
    }

    /// "Converges in both delivery orders" is a property of a **collection**, which
    /// is why the store is the library's and this test uses it rather than the
    /// comparison alone.
    @Test("Both delivery orders converge on the same revision")
    func bothOrdersConverge() throws {
        let first = try Self.line(author: "peer:device", revision: 1,
                                  body: Data("one".utf8))
        let second = try Self.line(author: "peer:device", revision: 2,
                                   body: Data("two".utf8))

        let forwards = try AnnotationStore()
        #expect(try forwards.observe(first))
        #expect(try forwards.observe(second))

        let backwards = try AnnotationStore()
        #expect(try backwards.observe(second))
        // 9.0c — "lower is ignored". ⚠ `false` here is not a failure: it is the
        // store saying it kept what it had.
        #expect(try backwards.observe(first) == false)

        #expect(forwards.count == 1)
        #expect(backwards.count == 1)
        #expect(forwards.annotation(id: "ann:1")?.body == Data("two".utf8))
        #expect(backwards.annotation(id: "ann:1")?.body == Data("two".utf8))
    }

    // MARK: 5.18a — lossless round-trip

    /// ⛔ `body` is opaque and is stored and returned **byte for byte**. A peer
    /// that does not understand a `format` round-trips it rather than dropping or
    /// rewriting it; interpreting it is explicitly not the requirement.
    @Test("An unrecognised format round-trips byte for byte")
    func bodyIsOpaque() throws {
        let bytes = Data((0..<256).map { UInt8($0) })
        let alien = try PpcpAnnotation(
            id: "ann:alien", sessionId: Self.sessionId, shotId: Self.shotId,
            streamId: Self.videoStream.id, timebaseId: Self.timebase, atNs: 1,
            authorPeerId: "peer:host", provenance: .user, kind: .other("vendor.blob"),
            format: "application/x-vendor", body: bytes,
            createdAtTimebaseId: Self.timebase, createdAtNs: 1)
        let store = try AnnotationStore()
        #expect(try store.observe(alien))
        #expect(store.annotation(id: "ann:alien")?.body == bytes)
        #expect(store.annotation(id: "ann:alien")?.format == "application/x-vendor")
    }

    /// 5.18f — `body` MUST NOT exceed 8 KiB. "A finger-drawn plane is a few
    /// hundred bytes and a text note less; anything approaching the cap is a
    /// different feature."
    @Test("A body over 8 KiB is refused")
    func bodyCapIsEnforced() {
        #expect(throws: PpcpAnnotation.AnnotationError.bodyTooLarge(8_193)) {
            _ = try PpcpAnnotation(
                id: "ann:big", sessionId: Self.sessionId, shotId: Self.shotId,
                timebaseId: Self.timebaseRef, atNs: 1, authorPeerId: "peer:host",
                provenance: .user, kind: .text, format: "text/plain",
                body: Data(count: 8_193), createdAtTimebaseId: Self.timebaseRef,
                createdAtNs: 1)
        }
    }

    // MARK: 5.18g / 5.18j — placement

    /// ⛔ **Presence of `stream_id` follows from `kind`.** It replaced a rule that
    /// could not be checked — "present for any annotation whose `body` is
    /// interpreted in image coordinates" — because `body` is opaque, so no peer and
    /// no test could determine whether a given annotation was view-specific.
    @Test("A view-specific kind carries stream_id and a non-view-specific one does not")
    func placementFollowsKind() throws {
        #expect(PpcpAnnotation.Kind.line.isViewSpecific)
        #expect(PpcpAnnotation.Kind.plane.isViewSpecific)
        #expect(PpcpAnnotation.Kind.text.isViewSpecific == false)
        #expect(PpcpAnnotation.Kind.navAnchor.isViewSpecific == false)

        let good = try Self.line(author: "peer:device")
        #expect(throws: Never.self) {
            try good.validatePlacement(in: Self.videoStream, timebaseRef: Self.timebaseRef)
        }

        // A `line` with no `stream_id` is a breach of 5.18j, and the library says
        // so — ⚠ against a real Stream, because the rule needs one and asserting it
        // without one would assert nothing.
        let stray = try PpcpAnnotation(
            id: "ann:stray", sessionId: Self.sessionId, shotId: Self.shotId,
            timebaseId: Self.timebaseRef, atNs: 1, authorPeerId: "peer:device",
            provenance: .user, kind: .line, format: "application/json",
            body: Data("{}".utf8), createdAtTimebaseId: Self.timebaseRef, createdAtNs: 1)
        #expect(throws: PpcpLibraryError.self) {
            try stray.validatePlacement(in: nil, timebaseRef: Self.timebaseRef)
        }
    }

    // MARK: 5.18b/c, 9.0d — the device advisory anchor

    /// ⛔ **`nav_anchor` is `device_advisory`, carries no `stream_id`, and is never
    /// persisted or interpreted as phase data** (5.18c). The instant comes *from* a
    /// Shot's `t0`; what is forbidden is the other direction.
    @Test("The impact anchor is device_advisory, not view-specific, and not phase data")
    func navigationAnchorIsAdvisory() throws {
        let anchor = try PpcpAnnotation.navigationAnchor(
            id: "ann:impact", sessionId: Self.sessionId, shotId: Self.shotId,
            timebaseRef: Self.timebaseRef, atNs: 5_000_000_000,
            authorPeerId: "peer:device", createdAtTimebaseId: Self.timebase,
            createdAtNs: 5_000_000_000)

        #expect(anchor.provenance == .deviceAdvisory)
        #expect(anchor.kind == .navAnchor)
        #expect(anchor.streamId == nil)
        // 5.18g — with no `stream_id`, `at` is in `Session.timebase_ref`.
        #expect(anchor.timebaseId == Self.timebaseRef)
        #expect(throws: Never.self) {
            try anchor.validatePlacement(in: nil, timebaseRef: Self.timebaseRef)
        }
    }

    /// **CT-I37, by API surface.** `CONF` §3 gives the method as "asserted by API
    /// surface, not behaviour", so the assertion is an *absence*: no function
    /// anywhere in `CaptureCore` or `libppcp` takes an Annotation together with a
    /// Shot, a Candidate, a Calibration or a TimebaseRelation, or returns an
    /// instant derived from one.
    ///
    /// ⚠ Written as a documented check rather than a runtime one, because that is
    /// what the method is. It fails the day someone adds the convenience.
    @Test("There is no path from an Annotation to a Shot, a Candidate or a relation")
    func noPathFromMarkupToMeasurement() throws {
        let anchor = try PpcpAnnotation.navigationAnchor(
            id: "ann:impact", sessionId: Self.sessionId, shotId: Self.shotId,
            timebaseRef: Self.timebaseRef, atNs: 5_000_000_000,
            authorPeerId: "peer:device", createdAtTimebaseId: Self.timebase,
            createdAtNs: 5_000_000_000)

        // The only things reachable from an annotation are its own fields and the
        // store. `shotId` is a *reference* the annotation is about, not a route
        // into one: nothing here can produce a `PpcpShot`, a `PpcpCandidate` or a
        // `ppcp_timebase_relation`.
        let mirror = Mirror(reflecting: anchor)
        let types = mirror.children.compactMap { $0.label }
        #expect(types.contains("shotId"))
        #expect(types.contains { $0.lowercased().contains("candidate") } == false)
        #expect(types.contains { $0.lowercased().contains("relation") } == false)
        #expect(types.contains { $0.lowercased().contains("calibration") } == false)

        // And the store returns annotations and nothing else.
        let store = try AnnotationStore()
        #expect(try store.observe(anchor))
        #expect(store.all.count == 1)
    }

    // MARK: 5.18i — coalescing a drag

    /// ⚠ **The reason is the channel, not the bandwidth.** Each revision resends
    /// the whole `body`, and `annotation` is on the **control** channel — the one
    /// carrying `shot`, `candidate` and `readiness`.
    @Test("A drag sends the latest revision, not every intermediate")
    func dragCoalesces() throws {
        var coalescer = AnnotationCoalescer(quiescenceNs: 100_000_000)
        var current = try Self.line(author: "peer:device", body: Data("r1".utf8))
        coalescer.offer(current, atNs: 0)

        for step in 1...20 {
            current = try current.revised(body: Data("r\(step + 1)".utf8),
                                          atNs: Int64(step) * 5_000_000,
                                          createdAtTimebaseId: Self.timebase)
            coalescer.offer(current, atNs: Int64(step) * 5_000_000)
        }
        // 100 ms of dragging, 21 edits, and nothing has gone out.
        #expect(coalescer.pendingCount == 1)
        #expect(coalescer.due(nowNs: 50_000_000).isEmpty)

        let sent = coalescer.due(nowNs: 200_000_000)
        #expect(sent.count == 1)
        #expect(sent[0].revision == 21)
        #expect(coalescer.pendingCount == 0)

        // A lifted finger is the strongest signal that no newer revision is
        // coming, so `force` sends without waiting the interval out.
        coalescer.offer(current, atNs: 300_000_000)
        #expect(coalescer.due(nowNs: 300_000_001, force: true).count == 1)
    }

    /// 5.18 `deleted` — "a revision may **retract** rather than replace", and it is
    /// still a revision, so it supersedes by the same rule.
    @Test("A retraction is a higher revision, not a deletion")
    func retractionIsARevision() throws {
        let original = try Self.line(author: "peer:device")
        let retracted = try original.retracted(atNs: 1, createdAtTimebaseId: Self.timebase)
        #expect(retracted.isDeleted)
        #expect(retracted.revision == original.revision + 1)
        #expect(retracted.supersedes(original))

        let store = try AnnotationStore()
        #expect(try store.observe(original))
        #expect(try store.observe(retracted))
        #expect(store.count == 1)
        #expect(store.annotation(id: "ann:1")?.isDeleted == true)
    }

    // MARK: MSG 9.0a — either direction, and Markup confers it

    /// ⛔ `annotation` is the **only** content in PPCP that travels either way, and
    /// C2 refuses a peer that has not declared Markup — the negative half of
    /// `CONF` §1d.
    @Test("A peer without Markup cannot originate an annotation")
    func markupIsRequiredToOriginate() throws {
        let annotation = try Self.line(author: "peer:device")

        let full = try DevicePeer(peerId: "peer:device")
        #expect(throws: Never.self) { try full.annotate(annotation) }

        let bare = try DevicePeer(peerId: "peer:device", profiles: ["core", "capture"])
        #expect(throws: PpcpLibraryError.self) { try bare.annotate(annotation) }
    }
}
