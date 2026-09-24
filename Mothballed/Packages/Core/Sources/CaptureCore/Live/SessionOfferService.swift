//  SessionOfferService.swift
//  What the device does with its stored sessions the moment a host appears.
//
//  ⛔ **The user's decision of 22 August 2026, and it removed a UI rather than
//  adding one.** Sessions are never imported from a file: a *connected* capture
//  device offers what it holds and the host chooses from a list. PinPointStudio's
//  menu item and native file dialog were deleted for it, and this application has
//  never had one — there is no document picker anywhere in these flows and no
//  code path that would benefit from one.
//
//  ⚠ **`already_held` is recorded per host, not per session.** 8.5c makes
//  re-import a no-op, but "this host already has it" is a fact about a *pair*:
//  a second studio has not seen it, and a device that stopped offering after the
//  first `already_held` would strand every session on the first host it met.
//
//  Spec: `MSG` §9.1, §9.2; `CORE` §8.5c, §9. Plan D6 (offer stored sessions).

import Foundation

/// Offers stored bundles to a connected host and replays the accepted ones.
public final class SessionOfferService: @unchecked Sendable {

    /// What a host said about one offer. ⛔ Held per (host, session): see above.
    public enum Disposition: String, Sendable, Hashable {
        case offered, accepted, alreadyHeld, refused, replayed
    }

    private let peer: DevicePeer
    private let store: SessionStore
    /// The bytes of one stored bundle, read in runs. ⚠ A provider rather than
    /// `Data`: a session is about a gigabyte, and `CaptureCore` opens no file
    /// (ground rule 8).
    private let read: @Sendable (SessionBundle) throws -> Data

    /// `hostPeerId` → `sessionId` → what happened.
    private var dispositions: [String: [String: Disposition]] = [:]
    private var replay: BundleReplay?
    private var replaying: SessionBundle?
    /// The bytes of the replay in flight, and how far through them the peer has
    /// taken us.
    ///
    /// ⛔ **Both are instance state because `pumpReplay` returns mid-bundle.**
    /// They used to be locals, so a pump that stopped on a full outbound queue
    /// threw its position away and the next call re-fed the bundle from byte
    /// zero — into a `BundleReplay` that had already consumed part of it, over a
    /// file it re-read in full every time. `bundle.h`'s own call sequence is a
    /// loop over the file advancing by `consumed`; this is that loop, spread
    /// across calls because the drain happens between them.
    private var replayBytes: Data?
    private var replayOffset = 0

    public init(peer: DevicePeer, store: SessionStore,
                read: @escaping @Sendable (SessionBundle) throws -> Data) {
        self.peer = peer
        self.store = store
        self.read = read
    }

    /// Every stored Session this host has not already dispositioned.
    ///
    /// ⚠ Offered on connect **and** when a hostless session ends while connected:
    /// the second case is the one a golfer actually meets, having recorded on the
    /// mat and then walked into the bay.
    @discardableResult
    public func offerAll(toHost hostPeerId: String) throws -> [SessionBundle] {
        var offered: [SessionBundle] = []
        for bundle in try store.bundles() {
            if let held = dispositions[hostPeerId]?[bundle.sessionId],
               held == .alreadyHeld || held == .replayed || held == .offered {
                continue
            }
            // ⛔ `completeness: unknown` is not expressible here and that is right:
            // I10 makes it the owner's assertion, and a device that has the bundle
            // on disk knows whether it closed it. `partial` is the honest default
            // for one this app has not finished.
            try peer.offer(PpcpSessionOffer(sessionId: bundle.sessionId,
                                            mintingPeerId: bundle.mintingPeerId,
                                            completeness: .partial,
                                            bytesEstimate: try? bundleBytes(bundle)))
            dispositions[hostPeerId, default: [:]][bundle.sessionId] = .offered
            offered.append(bundle)
        }
        return offered
    }

    /// The host answered. ⛔ Only `accept` starts a replay; the other two verdicts
    /// are recorded and nothing moves.
    public func received(_ accept: PpcpSessionAccept, fromHost hostPeerId: String) throws {
        switch accept.verdict {
        case .alreadyHeld:
            dispositions[hostPeerId, default: [:]][accept.sessionId] = .alreadyHeld
        case .refuse:
            dispositions[hostPeerId, default: [:]][accept.sessionId] = .refused
        case .accept:
            dispositions[hostPeerId, default: [:]][accept.sessionId] = .accepted
            guard let bundle = try store.bundles()
                .first(where: { $0.sessionId == accept.sessionId }) else { return }
            // 9.1a — `have_digests` is honoured by the library, which skips the
            // payload for a Capture the importer already holds. ⚠ The
            // `capture_announce` and the manifest entry are still sent: the
            // importer needs the Capture record, and it is the payload that is
            // redundant, not the fact.
            replay = try BundleReplay(peer: peer, haveDigests: accept.haveDigests)
            replaying = bundle
            // Read once per replay, not once per pump.
            replayBytes = try read(bundle)
            replayOffset = 0
        }
    }

    /// Pushes the accepted bundle's frames onto the link.
    ///
    /// ⚠ **Drain between calls.** `ppcp_bundle_replay_feed` stops when the peer's
    /// outbound queue is full and reports what it consumed; a caller that does not
    /// drain makes no progress, deliberately, because the alternative is an engine
    /// that buffers a whole session.
    ///
    /// - Returns: `true` once the whole bundle has been replayed.
    @discardableResult
    public func pumpReplay(hostPeerId: String) throws -> Bool {
        guard let replay, let bundle = replaying, let bytes = replayBytes else { return true }
        while replayOffset < bytes.count {
            let consumed = try replay.feed(bytes.subdata(in: replayOffset..<bytes.count))
            // Queue full. ⛔ Keep the offset — drain and call again.
            guard consumed > 0 else { return false }
            replayOffset += consumed
        }
        dispositions[hostPeerId, default: [:]][bundle.sessionId] = .replayed
        forgetReplay()
        return true
    }

    /// The link died with a replay in flight.
    ///
    /// ⛔ **Without this the service pumps at a dead peer for ever.** A replay is
    /// not resumable across links — `BundleReplay` holds the host's
    /// `have_digests` from a `session_accept` that belonged to the link that just
    /// went — so the honest move is to drop it and let `offerAll` offer the
    /// Session again on the next one. ⚠ The disposition stays `.accepted`, which
    /// is deliberately **not** in `offerAll`'s skip set, so the re-offer happens.
    public func linkLost() {
        forgetReplay()
    }

    private func forgetReplay() {
        replay = nil
        replaying = nil
        replayBytes = nil
        replayOffset = 0
    }

    public func disposition(ofSession sessionId: String,
                            forHost hostPeerId: String) -> Disposition? {
        dispositions[hostPeerId]?[sessionId]
    }

    /// ⚠ `nil` rather than zero where the size is not known — `MSG` 9.1 makes
    /// `bytes_estimate` optional, and 5.1's "absence never means zero" is why it
    /// is not filled in with a guess.
    private func bundleBytes(_ bundle: SessionBundle) throws -> UInt64 {
        UInt64(try read(bundle).count)
    }
}
