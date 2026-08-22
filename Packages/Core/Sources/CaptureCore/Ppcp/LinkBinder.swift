//  LinkBinder.swift
//  `ENC` §2.1, listener half — and F-D3-3 closed.
//
//  ⚠ **What the finding was.** `ppcp_link_binder_offer` used to take a
//  `stream_channel` parameter, and a stream-per-connection transport — a TCP
//  accept, an `NWConnection` — has no such value to give: a freshly accepted
//  stream carries no channel number of its own, and 2.1b forbids inferring one
//  from arrival order or from the transport address. So the listener kept its own
//  link table and used the library only to decode the frame. `libppcp` L9 changed
//  the signature to take the channel **from the frame header** and report it, and
//  this type is the listener half moving onto it.
//
//  ⛔ **The three refusals of 2.1c are now the library's, in one place.** The
//  first frame is not `link_bind`; its `channel` disagrees with the frame header's;
//  the `link_id` names a link that already holds that channel. Each is
//  `PPCP_ERR_MALFORMED` and each means the listener closes the stream — and 3.0c
//  says there is nothing to answer with, because `link_bind` "requires no
//  response".
//
//  ⚠ **The timeout is deliberately NOT in here.** 2.1c makes it "the listener's
//  own", so the library supplies the predicate (`is_ready`) and the discard, and
//  the embedding owns the clock.
//
//  Spec: `ENC` §2.1a–f; `MSG` §3.0. Plan D6 (F-D3-3).

import Foundation
import CPPCP

/// The listener's link table, held by `libppcp`.
///
/// ⚠ Deliberately **not** part of `ppcp_peer`: a listener meets streams before it
/// knows which peer they belong to, which is the whole problem 2.1 exists to
/// solve. The dialler half is `DevicePeer.setLinkId` and `.openChannel`.
public final class PpcpLinkBinder: @unchecked Sendable {

    /// What one offered stream turned out to be.
    public struct Bound: Sendable, Hashable {
        /// The library's link index — how the embedding routes that stream's later
        /// bytes to the peer it associates with the link.
        public let link: Int
        /// ⚠ **From the frame header** (2.1b), reported by the library after it
        /// checked the body against it. Not a value the listener supplied.
        public let channel: PpcpChannel
        /// Bytes of the stream this frame occupied. Anything after it is
        /// application data the caller must not lose — TCP is free to coalesce
        /// `link_bind` with the `hello` behind it.
        public let consumed: Int
        public let linkId: PpcpLinkId
    }

    private var binder = ppcp_link_binder()

    public init() {
        ppcp_link_binder_init(&binder)
    }

    /// Offers the **first frame** of a newly accepted stream.
    ///
    /// - Returns: `nil` where `bytes` does not yet hold a whole frame — read more
    ///   and offer again.
    /// - Throws: `TransportError.bindRefused` for 2.1c's refusals, and
    ///   `PpcpLibraryError` for `PPCP_ERR_LIMIT` when every link slot is in use.
    public func offer(_ bytes: Data) throws -> Bound? {
        var consumed = 0
        var link = 0
        var channel: UInt8 = 0
        let result: ppcp_result = bytes.withUnsafeBytes { raw in
            ppcp_link_binder_offer(&binder,
                                   raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                                   &consumed, &link, &channel)
        }
        if result == PPCP_ERR_TRUNCATED { return nil }
        if result == PPCP_ERR_MALFORMED {
            // ⚠ The library does not distinguish 2.1c's three refusals in its
            // return code, and this type does not invent a distinction it cannot
            // observe. Every one of them ends the same way — the stream is closed
            // — and reporting a guess would mislead an implementer at the far end
            // more than a single honest code does.
            throw TransportError.bindRefused(.notLinkBind)
        }
        try check(result)
        guard let boundChannel = PpcpChannel(rawValue: channel) else {
            // `ENC` 2a reserves 255 and this application allocates 0, 1 and 2.
            throw TransportError.bindRefused(.channelMismatch)
        }
        guard let raw = ppcp_link_binder_id(&binder, link) else {
            throw PpcpLibraryError(PPCP_ERR_INVALID)
        }
        let linkId = try PpcpLinkId(bytes: Data(bytes: raw, count: PpcpLinkId.byteCount))
        return Bound(link: link, channel: boundChannel, consumed: consumed, linkId: linkId)
    }

    /// 2.1c — a link that has not bound **channel 0** is not usable yet. The
    /// timeout that acts on this is the embedding's.
    public func isReady(link: Int) -> Bool {
        ppcp_link_binder_is_ready(&binder, link)
    }

    public func hasChannel(_ channel: PpcpChannel, link: Int) -> Bool {
        ppcp_link_binder_has_channel(&binder, link, channel.rawValue)
    }

    /// 2.1c — "…is discarded with every stream it holds".
    public func discard(link: Int) throws {
        try check(ppcp_link_binder_discard(&binder, link))
    }

    public var linkCount: Int { ppcp_link_binder_count(&binder) }
}
