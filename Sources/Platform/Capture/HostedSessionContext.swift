//  HostedSessionContext.swift
//  The live half of a `RecordingSession`, when PinPointStudio opened the Session.
//
//  ⛔ **Everything in here belongs to the LINK peer, which lives behind
//  `PeerLinkPump.perform` and may not be touched outside it.** `DevicePeer` is
//  `@unchecked Sendable` over a C engine with no internal locking; `perform` is
//  the only door. This type is therefore a bag of references plus the one
//  `open` that builds them, and every use of them goes back through the pump.
//
//  ⚠ **Why this is not "an optional live peer" on `RecordingSession`.** Handing
//  in a second peer looks like adding a sink. It is not: it moves the Mint
//  engine, the Session's reference timebase and the isolation domain that
//  `observe`/`pump` run in. An optional that changes three of those quietly is
//  the kind of parameter a test passes `nil` and proves nothing about.
//
//  Spec: `CORE` §5.10e, §5.13c, §8.2; `MSG` §4.1, §5.1.

import Foundation
import CaptureCore

/// Why a Stream this device owns could not be opened on the link.
public enum HostedSessionError: Error, CustomStringConvertible {
    case streamRefused(id: String, kind: String, profileId: String, underlying: any Error)

    public var description: String {
        switch self {
        case .streamRefused(let id, let kind, let profileId, let underlying):
            "stream_open refused for \(id) (kind: \(kind), profile: \(profileId)) — \(underlying)"
        }
    }
}

/// The pieces a hosted `RecordingSession` needs from the live link.
///
/// ⚠ **`Sendable` and deliberately not `@MainActor`.** Every member is already
/// `Sendable` — `PeerLinkPump` is an actor, the rest are `@unchecked Sendable`
/// over the C engine — and the isolation that matters here is not an actor
/// annotation on this bag of references but the rule that each of them is only
/// ever *used* inside `pump.perform`. Marking it `@MainActor` would have said
/// something true of where it is stored and false of where it is touched, and
/// would stop `open` below building it where it must be built.
public struct HostedSessionContext: Sendable {

    /// The only door to the link peer.
    public let pump: PeerLinkPump
    /// The host's `session_open`, as it arrived (I16 — read, never invented).
    public let parameters: PpcpSessionParameters
    /// Bulk payload, backpressure-aware.
    public let queue: PayloadTransferQueue
    /// The wire half of the fan-out; the bundle is the other half.
    public let live: LiveDetectionSink
    /// ⛔ Built on the **link** peer — see this file's header.
    public let mint: DeviceMint
    public let hostPeerId: String

    public init(pump: PeerLinkPump, parameters: PpcpSessionParameters,
                queue: PayloadTransferQueue, live: LiveDetectionSink,
                mint: DeviceMint, hostPeerId: String) {
        self.pump = pump
        self.parameters = parameters
        self.queue = queue
        self.live = live
        self.mint = mint
        self.hostPeerId = hostPeerId
    }

    /// Builds the live half inside one `perform`.
    ///
    /// ⚠ **Streams are not opened here.** They are opened by `openStreams` once
    /// the `RecordingSession` has derived them, so the wire and the bundle carry
    /// one set of records — one `profile_id`, one `opened_at`. Deriving them
    /// twice is how a Stream ends up naming a profile that does not exist
    /// (5.11a, I5), which is what #102 was.
    public static func open(pump: PeerLinkPump,
                            parameters: PpcpSessionParameters,
                            hostPeerId: String,
                            promotion: @escaping PromotionPolicy)
        async throws -> HostedSessionContext {
        try await pump.perform { peer in
            let queue = PayloadTransferQueue(peer: peer)
            return HostedSessionContext(
                pump: pump,
                parameters: parameters,
                queue: queue,
                live: LiveDetectionSink(peer: peer, queue: queue),
                mint: try DeviceMint(peer: peer, promotion: promotion),
                hostPeerId: hostPeerId)
        }
    }

    /// Opens the `preview` Stream on the link and returns its producer.
    ///
    /// ⛔ **On the link and nowhere else.** `SessionBundleWriter` refuses a
    /// preview Capture (5.11j — live-only, never retained, never written), so
    /// this Stream has no counterpart in the bundle by construction rather than
    /// by a filter someone has to remember.
    ///
    /// ⚠ Returns the producer rather than storing it: this is a `struct` held in
    /// a `let`, so a `mutating` setter here would write to a copy and the caller
    /// would hold a producer nothing ever used.
    public func openPreview(_ stream: PpcpStreamRecord) async throws -> PreviewProducer {
        try await pump.perform { [stream] peer in
            try peer.openStream(stream)
            return try PreviewProducer(peer: peer, stream: stream)
        }
    }

    /// Opens the recording session's own Stream records on the link.
    ///
    /// ⛔ **A `preview` Stream is deliberately excluded.** `SessionBundleWriter`
    /// refuses a preview Capture (5.11j), so preview is opened on the link alone
    /// and by whoever owns it — not from here, which is the path that also feeds
    /// the bundle.
    public func openStreams(_ streams: [PpcpStreamRecord]) async throws {
        try await pump.perform { peer in
            for stream in streams where stream.kind != PpcpStreamKind.preview {
                do {
                    try peer.openStream(stream)
                } catch {
                    // ⛔ **Name the Stream.** `libppcp: invalid argument
                    // (openStream)` on a device tells nobody which of four it
                    // was, and `arm` shipped dead for weeks once before because
                    // a guard refused silently. 5.1a's duplicate-id refusal and
                    // a malformed record are the same message otherwise.
                    throw HostedSessionError.streamRefused(
                        id: stream.id, kind: stream.kind,
                        profileId: stream.profileId, underlying: error)
                }
            }
        }
    }
}
