//  Annotation.swift
//  `CORE` §5.18 — a **user artefact**, not an observation, and the distinction is
//  the point of the type existing.
//
//  ⛔ **I37 / 5.18c — there is no path from anything here to a Shot, a Candidate,
//  a calibration or any computed quantity.** Not a weak one, not a convenience
//  one. Nothing in this file takes an Annotation and a Shot, or an Annotation and
//  a `TimebaseRelation`, or returns an instant derived from one; `kind:
//  nav_anchor` in particular is **never** persisted or interpreted as phase data.
//  `CONF` §3 makes CT-I37 an assertion "by API surface, not behaviour", so that
//  absence is what the test checks and this paragraph is what it is for.
//
//  ⚠ **Everything else in PPCP that carries payload is a Capture realising a
//  Shot, a Candidate or an interval of a Stream — all produced by a Source, which
//  has a clock, a calibration and an owning peer. A person has none of those.**
//
//  Spec: `CORE` §5.18; `MSG` §9.0. Plan D8.

import Foundation
import CPPCP

/// One Annotation, with its `body` owned alongside.
///
/// ⚠ `ppcp_annotation.body` is a **borrowed** pointer, so the bytes are bound
/// inside `withValue` and are never valid outside it — the same shape as
/// `PpcpCandidate.classifier`, and for the same reason.
public struct PpcpAnnotation: @unchecked Sendable, Hashable {

    /// 5.18b — a **user** artefact, or one a peer derived for scrubbing.
    ///
    /// ⛔ `deviceAdvisory` is not a weaker kind of measurement. 5.18c forbids an
    /// annotation of **any** provenance contributing to a computed quantity, so
    /// the impact fiducial that produces a `nav_anchor` reaches a Shot through
    /// `Candidate.at` and reaches this type only as a scrub target.
    public enum Provenance: Sendable, Hashable {
        case user, deviceAdvisory

        var c: ppcp_annotation_provenance {
            switch self {
            case .user: PPCP_ANNOT_USER
            case .deviceAdvisory: PPCP_ANNOT_DEVICE_ADVISORY
            }
        }
    }

    /// 5.18j — the registry marks each value view-specific or not, and presence of
    /// `stream_id` **follows from it**.
    ///
    /// ⚠ It replaced a presence rule that could not be checked: "present for any
    /// annotation whose `body` is interpreted in image coordinates" was a rule
    /// about a *judgement*, and `body` is opaque, so no peer and no test could
    /// determine whether a given annotation was view-specific.
    public enum Kind: Sendable, Hashable {
        /// View-specific: a set of image coordinates, meaningful on the image they
        /// were drawn on and nowhere else.
        case line, plane
        /// Not view-specific.
        case text
        /// ⛔ Not view-specific, and **never phase data** (5.18c).
        case navAnchor
        /// A vendor kind. 5.18j's conservative default applies: it is treated as
        /// view-specific if and only if `stream_id` is present.
        case other(String)

        public var wire: String {
            switch self {
            case .line: "line"
            case .plane: "plane"
            case .text: "text"
            case .navAnchor: "nav_anchor"
            case .other(let value): value
            }
        }

        /// The library's own answer, so this application cannot hold a second
        /// registry that drifts from it.
        public var isViewSpecific: Bool {
            wire.withCString { pointer in
                ppcp_annotation_kind_view(pointer, strlen(pointer)) == PPCP_KIND_VIEW_SPECIFIC
            }
        }
    }

    public let id: String
    public let sessionId: String
    public let shotId: String
    public let streamId: String?
    public let timebaseId: String
    public let atNs: Int64
    public let authorPeerId: String
    public let provenance: Provenance
    public let kind: Kind
    public let format: String
    public let revision: UInt64
    public let isDeleted: Bool
    public let body: Data

    private let stored: ppcp_annotation

    public func withValue<T>(_ body: (UnsafeMutablePointer<ppcp_annotation>) throws -> T)
        rethrows -> T {
        var value = stored
        return try self.body.withUnsafeBytes { raw in
            value.body = raw.bindMemory(to: UInt8.self).baseAddress
            value.body_len = raw.count
            return try body(&value)
        }
    }

    public enum AnnotationError: Error, Sendable, Equatable {
        /// 5.18f — `body` MUST NOT exceed 8 KiB. "A finger-drawn plane is a few
        /// hundred bytes and a text note less; anything approaching the cap is a
        /// different feature."
        case bodyTooLarge(Int)
        /// 5.18j — a view-specific `kind` carries `stream_id`; a non-view-specific
        /// one does not. ⛔ Checked by `ppcp_annotation_validate_placement`, not
        /// here: the placement rule needs the Stream, and asserting it without one
        /// would assert nothing.
        case placementRefused
    }

    /// - Parameters:
    ///   - atNs: 5.18g — where `streamId` is present this is in **that Stream's**
    ///     timebase and names a frame it contains; where it is absent it is in
    ///     `Session.timebase_ref`. The caller passes `timebaseId` to match, and
    ///     `validate(in:timebaseRef:)` checks the pair against a real Stream.
    ///   - revision: 5.18e — increments on edit, and a higher one for the same
    ///     `id` supersedes.
    public init(id: String, sessionId: String, shotId: String,
                streamId: String? = nil,
                timebaseId: String, atNs: Int64,
                authorPeerId: String,
                provenance: Provenance,
                kind: Kind,
                format: String,
                body: Data,
                createdAtTimebaseId: String,
                createdAtNs: Int64,
                revision: UInt64 = 1,
                isDeleted: Bool = false) throws {
        guard body.count <= Int(PPCP_ANNOTATION_BODY_MAX) else {
            throw AnnotationError.bodyTooLarge(body.count)
        }
        var annotation = ppcp_annotation()
        var at = ppcp_instant()
        var createdAt = ppcp_instant()
        try check(ppcp_instant_make_z(&at, timebaseId, atNs))
        try check(ppcp_instant_make_z(&createdAt, createdAtTimebaseId, createdAtNs))
        try body.withUnsafeBytes { raw in
            try check(ppcp_annotation_make(&annotation, id, sessionId, shotId, &at,
                                           authorPeerId, provenance.c, kind.wire, format,
                                           raw.bindMemory(to: UInt8.self).baseAddress,
                                           raw.count, &createdAt, revision))
            if let streamId {
                try check(ppcp_annotation_set_stream_id(&annotation, streamId))
            }
            if isDeleted { try check(ppcp_annotation_set_deleted(&annotation, true)) }
            try check(ppcp_annotation_validate(&annotation))
        }
        // ⛔ The `body` pointer above dies with the borrow; it is cleared rather
        // than carried out dangling, and `withValue` re-binds from `self.body`.
        annotation.body = nil
        annotation.body_len = 0
        stored = annotation

        self.id = id
        self.sessionId = sessionId
        self.shotId = shotId
        self.streamId = streamId
        self.timebaseId = timebaseId
        self.atNs = atNs
        self.authorPeerId = authorPeerId
        self.provenance = provenance
        self.kind = kind
        self.format = format
        self.revision = revision
        self.isDeleted = isDeleted
        self.body = body
    }

    init(_ annotation: ppcp_annotation) {
        var value = annotation
        id = ppcpString(value.id)
        sessionId = ppcpString(value.session_id)
        shotId = ppcpString(value.shot_id)
        streamId = value.has_stream_id ? ppcpString(value.stream_id) : nil
        timebaseId = ppcpString(value.at.tb)
        atNs = value.at.ns
        authorPeerId = ppcpString(value.author_peer_id)
        provenance = value.provenance == PPCP_ANNOT_USER ? .user : .deviceAdvisory
        let kindText = ppcpString(value.kind)
        kind = switch kindText {
        case "line": .line
        case "plane": .plane
        case "text": .text
        case "nav_anchor": .navAnchor
        default: .other(kindText)
        }
        format = ppcpString(value.format)
        revision = value.revision
        isDeleted = value.has_deleted && value.deleted
        body = value.body.map { Data(bytes: $0, count: value.body_len) } ?? Data()
        value.body = nil
        value.body_len = 0
        stored = value
    }

    /// 5.18g / 5.18j — the placement rule, checked against a **real Stream**.
    ///
    /// ⚠ It checks *where* the annotation is anchored. It does not read `body`,
    /// cannot read `body`, and produces nothing an analysis could consume (I37).
    public func validatePlacement(in stream: PpcpStreamRecord?,
                                  timebaseRef: String) throws {
        var reference = ppcp_id()
        try check(ppcp_id_set_z(&reference, timebaseRef))
        try withValue { annotation in
            guard let stream else {
                try check(ppcp_annotation_validate_placement(annotation, &reference, nil))
                return
            }
            var value = ppcp_stream()
            var openedAt = ppcp_instant()
            try check(ppcp_instant_make_z(&openedAt, stream.timebaseId, stream.openedAtNs))
            try check(ppcp_stream_make(&value, stream.id, stream.sessionId, stream.sourceId,
                                       stream.kind, stream.profileId, stream.timebaseId,
                                       stream.continuity == .continuous
                                           ? PPCP_CONTINUOUS : PPCP_SHOT_WINDOWED,
                                       &openedAt))
            try check(ppcp_annotation_validate_placement(annotation, &reference, &value))
        }
    }

    /// A new revision of the same annotation. ⚠ `revision` increments here so a
    /// caller cannot send two edits with one number, which is what makes 5.18e's
    /// total order usable.
    public func revised(body newBody: Data, atNs createdAtNs: Int64,
                        createdAtTimebaseId: String) throws -> PpcpAnnotation {
        try PpcpAnnotation(id: id, sessionId: sessionId, shotId: shotId,
                           streamId: streamId, timebaseId: timebaseId, atNs: atNs,
                           authorPeerId: authorPeerId, provenance: provenance,
                           kind: kind, format: format, body: newBody,
                           createdAtTimebaseId: createdAtTimebaseId,
                           createdAtNs: createdAtNs, revision: revision + 1,
                           isDeleted: false)
    }

    /// 5.18 `deleted` — "a revision may **retract** rather than replace".
    public func retracted(atNs createdAtNs: Int64,
                          createdAtTimebaseId: String) throws -> PpcpAnnotation {
        try PpcpAnnotation(id: id, sessionId: sessionId, shotId: shotId,
                           streamId: streamId, timebaseId: timebaseId, atNs: atNs,
                           authorPeerId: authorPeerId, provenance: provenance,
                           kind: kind, format: format, body: body,
                           createdAtTimebaseId: createdAtTimebaseId,
                           createdAtNs: createdAtNs, revision: revision + 1,
                           isDeleted: true)
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.revision == b.revision && a.authorPeerId == b.authorPeerId
            && a.body == b.body && a.isDeleted == b.isDeleted
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(revision)
    }

    /// 5.18e / 9.0c — the total order, from `libppcp`.
    ///
    /// ⛔ **`id`, then `revision`, then `author_peer_id` bytewise**, and the
    /// tiebreak is not decoration: revision 7 claimed two peers editing
    /// concurrently converge on the higher revision, and they do not — both hold
    /// revision 1, both produce revision 2, each receives an equal revision and
    /// ignores it, and the two ends diverge permanently while each believes it
    /// converged.
    public func supersedes(_ other: PpcpAnnotation) -> Bool {
        withValue { mine in
            other.withValue { theirs in
                ppcp_annotation_supersedes(mine, theirs) > 0
            }
        }
    }
}
