//  RetainedWindow.swift
//  E1.5 — a frozen, bounded view of a time range over a pluggable backing.
//
//  ⚠ **Adapted from PinPointStudio's `SwingWindow` / `SwingPayloadSource`
//  (`src/Buffer/swing_window.h`, `swing_payload_source.h`).** What transfers is
//  the *shape*: one concrete window type, fed by whichever backing has the
//  bytes. PPC treated "extract a clip" (E1.2) and "read a bundle back" (E4.1) as
//  unrelated problems; they are one problem with two backings, and that is worth
//  settling before either is built rather than after both are.
//
//  ⛔ **The boundary goes ONE LEVEL UP from where PPS has it, and this is the
//  whole adaptation.** `SwingPayloadSource::payloadOf` returns a
//  `SourceRing::ReadHandle` — a pointer into a RAM ring of raw frames — so even
//  its disk source has to manufacture a ring handle it does not have, purely to
//  satisfy the signature. PPC's payloads are *encoded fragments* and *byte
//  ranges in a bundle*; neither is a ring slot, and neither should have to
//  pretend to be one. So the protocol below hands back `Data`, which both
//  backings can produce honestly, one entry at a time.
//
//  ⚠ `CompositePayloadSource` (`composite_payload_source.h`) is read and NOT
//  built. Its rule shapes this file — routing is by source, and a source belongs
//  to exactly one backing, because one id cannot split its sequence space across
//  two without the sequences colliding — but nothing needs ring-and-disk at once
//  until E4.1.
//
//  Spec: `CORE` §5.14, §8.4; requirements REQ-BUF-1, REQ-PORT-9.

import Foundation

// MARK: - The backing

/// Where a window's bytes come from.
///
/// ⛔ **One source belongs wholly to one backing.** Splitting a source's
/// sequence space across two backings collides the sequences, which is the
/// constraint PPS's composite documents in as many words. A window that needs
/// two backings routes *by source*, never by interval.
public protocol RetainedPayloadSource: Sendable {

    /// The bytes for one entry, or `nil` when the backing no longer holds them.
    ///
    /// ⚠ `nil` is a **result**, not a failure — an entry whose bytes have been
    /// evicted since the snapshot was taken is exactly 8.4b's `absent`, and it
    /// must not throw. Throwing is for a backing that is broken: a file that
    /// exists and will not read.
    func payload(for entry: TimelineEntry) throws -> Data?

    /// A header that must precede this source's payloads for them to decode, if
    /// it has one.
    ///
    /// ⛔ **Not an optimisation.** On this platform a fragment is an
    /// `mpeg4AppleHLS` separable segment: measured on 24 August 2026, the
    /// initialisation segment plus fragments opens as one video track and the
    /// same fragments *without* it do not open at all. A backing that has such a
    /// header must say so here, or every clip it serves is unplayable.
    func initialisationPrefix(ofSource sourceId: String) -> Data?
}

public extension RetainedPayloadSource {
    func initialisationPrefix(ofSource sourceId: String) -> Data? { nil }
}

// MARK: - The window

/// A frozen view of one interval, and the bytes behind it.
///
/// ⚠ **Frozen** means the snapshot is fixed at construction; the backing may
/// still be evicting underneath. That is why `payload(for:)` can answer `nil`
/// for an entry the snapshot lists — and why answering `nil` rather than
/// inventing bytes is the only honest behaviour (I10).
public struct RetainedWindow: Sendable {

    public let snapshot: TimelineSnapshot
    private let source: any RetainedPayloadSource

    public init(snapshot: TimelineSnapshot, source: any RetainedPayloadSource) {
        self.snapshot = snapshot
        self.source = source
    }

    public var requestedNs: Range<Int64> { snapshot.requestedNs }
    public var sourceIds: [String] { snapshot.sourceIds }

    public func entries(ofSource sourceId: String) -> [TimelineEntry] {
        snapshot.entries(ofSource: sourceId)
    }

    public func payload(for entry: TimelineEntry) throws -> Data? {
        try source.payload(for: entry)
    }

    /// The clip: this source's data entries in time order, behind whatever
    /// header the backing says they need.
    ///
    /// ⛔ Returns `nil` when the source carried no data in this window — 8.4b's
    /// `absent`, a result rather than an error. ⚠ An entry the backing can no
    /// longer serve is **skipped and reported**, never silently dropped: a clip
    /// short of a fragment is a different thing from a clip that is whole, and
    /// the caller is the only one who can decide what to say about it.
    public func concatenatedPayload(ofSource sourceId: String)
        throws -> (bytes: Data, missing: [TimelineEntry])? {
        let data = snapshot.dataEntries(ofSource: sourceId)
        guard data.isEmpty == false else { return nil }

        var bytes = source.initialisationPrefix(ofSource: sourceId) ?? Data()
        var missing: [TimelineEntry] = []
        for entry in data {
            guard let payload = try source.payload(for: entry) else {
                missing.append(entry)
                continue
            }
            bytes.append(payload)
        }
        guard missing.count < data.count else { return nil }
        return (bytes, missing)
    }
}
