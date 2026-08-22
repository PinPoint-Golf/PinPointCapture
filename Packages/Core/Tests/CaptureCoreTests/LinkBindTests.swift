//  LinkBindTests.swift
//  `ENC` §2.1 and `MSG` §3.0, exercised against the real `libppcp` codec.
//
//  ⚠ These are the *codec* assertions. That a listener actually assembles a link
//  from them — concurrent dials, a late third channel, a bad first frame — is a
//  transport fact and lives in `Tests/TransportLoopbackTests.swift`, which needs
//  a simulator. Splitting them this way keeps the encoding testable on the host
//  in milliseconds, which is where a codec bug is cheapest to find.

import Foundation
import Testing
@testable import CaptureCore

@Suite("link_bind — ENC §2.1")
struct LinkBindTests {

    private static func linkId(_ seed: UInt8 = 0) throws -> PpcpLinkId {
        try PpcpLinkId(bytes: Data((0..<16).map { UInt8($0) &+ seed }))
    }

    @Test("A link_id is 16 bytes, and nothing else is one")
    func linkIdIsSixteenBytes() throws {
        #expect(PpcpLinkId.byteCount == 16)
        #expect(throws: TransportError.self) { try PpcpLinkId(bytes: Data(count: 15)) }
        #expect(throws: TransportError.self) { try PpcpLinkId(bytes: Data(count: 17)) }
        #expect(throws: TransportError.self) { try PpcpLinkId(bytes: Data()) }
        _ = try PpcpLinkId(bytes: Data(count: 16))
    }

    /// ⛔ 2.1f — a `link_id` never reaches a log. Asserted the same way the
    /// rendezvous secrets are, because the failure is identical: someone prints
    /// it while debugging and it ships.
    @Test("A link_id never prints itself")
    func linkIdDoesNotPrintItself() throws {
        let id = try Self.linkId(0x40)
        #expect("\(id)".contains("40") == false)
        #expect(String(describing: id) == "PpcpLinkId(16 bytes)")
    }

    @Test("A link_bind round-trips on every channel", arguments: PpcpChannel.allCases)
    func roundTrip(channel: PpcpChannel) throws {
        let id = try Self.linkId(0x11)
        let frame = try PpcpLinkBind.frame(linkId: id, channel: channel)

        let binding = try #require(try PpcpLinkBind.decode(frame))
        #expect(binding.linkId == id)
        #expect(binding.channel == channel)
        #expect(binding.consumed == frame.count)
    }

    /// `ENC` §3 — an 8-byte header, then the payload, with the channel in the
    /// header. ⚠ Asserted on the *bytes* rather than on the round trip: a codec
    /// that encoded and decoded its own private format would pass the round trip
    /// and meet no other implementation, which is the whole reason E1 exists.
    @Test("The frame is ENC §3 on the wire: 8-byte header, big-endian length, channel byte")
    func framingIsOnTheWire() throws {
        let frame = try PpcpLinkBind.frame(linkId: Self.linkId(), channel: .bulk)
        #expect(frame.count > 8)

        let length = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(Int(length) == frame.count - 8)
        #expect(frame[4] == PpcpChannel.bulk.rawValue)
        #expect(frame[5] == 0, "ENC 3b — flags MUST be 0 in ppcp/1.0")
        #expect(frame[6] == 0 && frame[7] == 0, "ENC 3b — reserved MUST be 0")
    }

    /// ⚠ `ENC` 4e deterministic order over the *encoded* keys, which is not
    /// alphabetical: "type" (0x64…) sorts before "msg_id" (0x66…), and both
    /// before the two seven-character keys, of which "channel" precedes
    /// "link_id". The library refuses any other order, so this asserts that the
    /// order this file writes them in is the one it is allowed to.
    @Test("The payload carries the four ENC 4e-ordered keys and the type is link_bind")
    func payloadShape() throws {
        let frame = try PpcpLinkBind.frame(linkId: Self.linkId(), channel: .control)
        let payload = frame.dropFirst(8)
        let text = String(decoding: payload, as: UTF8.self)

        for key in ["type", "msg_id", "channel", "link_id"] {
            #expect(text.contains(key), "payload is missing \(key)")
        }
        #expect(text.contains("link_bind"))
        // 3.0c — no `session_id`: link_bind precedes the session on channel 0
        // and is unrelated to it on a bulk channel.
        #expect(text.contains("session_id") == false)

        let order = ["type", "msg_id", "channel", "link_id"].map { text.range(of: $0)!.lowerBound }
        #expect(order == order.sorted(), "keys are not in ENC 4e deterministic order")
    }

    /// `ENC` §3 is length-prefixed, so "not yet a whole frame" is a distinct
    /// answer from "a bad frame". A listener reads more on the first and closes
    /// the stream on the second; conflating them is how a slow network becomes a
    /// refused peer.
    @Test("A partial frame asks for more bytes rather than failing")
    func partialFrameIsNotAFailure() throws {
        let frame = try PpcpLinkBind.frame(linkId: Self.linkId(), channel: .control)
        for cut in [0, 1, 4, 7, 8, frame.count - 1] {
            #expect(try PpcpLinkBind.decode(frame.prefix(cut)) == nil,
                    "\(cut) of \(frame.count) bytes should not decode yet")
        }
        #expect(try PpcpLinkBind.decode(frame) != nil)
    }

    /// 2.1c, refusal one: "a listener closes a stream whose first frame is not
    /// `link_bind`".
    @Test("A first frame that is not link_bind is refused")
    func nonLinkBindFirstFrameIsRefused() throws {
        // A well-formed ENC §3 frame whose payload is not a link_bind envelope.
        var frame = Data([0, 0, 0, 3, 0, 0, 0, 0])
        frame.append(contentsOf: [0xA1, 0x61, 0x61])   // { "a": <missing> }
        #expect(throws: TransportError.self) { try PpcpLinkBind.decode(frame) }

        // An empty payload on a legal header is the same refusal, not a crash.
        #expect(throws: TransportError.self) {
            try PpcpLinkBind.decode(Data([0, 0, 0, 0, 0, 0, 0, 0]))
        }
    }

    /// 2.1c, refusal two: "…whose `channel` disagrees with its header". ⚠ Built
    /// by encoding for one channel and rewriting the header byte, so the payload
    /// is a genuine `link_bind` and only the disagreement is under test.
    @Test("A link_bind whose channel disagrees with its header is refused")
    func channelMismatchIsRefused() throws {
        var frame = try PpcpLinkBind.frame(linkId: Self.linkId(), channel: .control)
        frame[4] = PpcpChannel.bulk.rawValue

        #expect(throws: TransportError.bindRefused(.channelMismatch)) {
            try PpcpLinkBind.decode(frame)
        }
    }

    /// `ENC` 2a reserves 255. ⚠ The refusal comes from `libppcp`'s own header
    /// parse (`ppcp_channel_validate`), *before* any of this file's bind logic
    /// runs — which is the stronger place for it: a reserved channel is a
    /// stream-level `ENC` §2 violation and not merely a failed bind, and it is
    /// refused identically for every frame on every channel rather than only for
    /// the first one.
    @Test("The reserved channel 255 is refused by the frame parse itself")
    func reservedChannelIsRefused() throws {
        var frame = try PpcpLinkBind.frame(linkId: Self.linkId(), channel: .control)
        frame[4] = 255

        #expect(throws: PpcpLibraryError.self) { try PpcpLinkBind.decode(frame) }
    }

    /// `ENC` 8a — a `payload_len` beyond the channel's limit means the stream has
    /// desynchronised, and there is no resynchronising from it. ⛔ It stays a
    /// *fatal* library result rather than being folded into a bind refusal: the
    /// difference is whether the peer may be retried, and a listener that reports
    /// "not a link_bind" for a desynchronised stream invites exactly that retry.
    @Test("An oversized payload_len is fatal, not a bind refusal")
    func oversizedFrameIsFatal() throws {
        // 2 MiB on the control channel, whose ENC §8 limit is 1 MiB.
        var frame = Data([0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        frame.append(Data(count: 64))
        #expect(throws: PpcpLibraryError.self) { try PpcpLinkBind.decode(frame) }
    }

    /// I13 — an unknown key at any depth is skipped, never fatal, so a later
    /// MINOR may add one to `link_bind`. ⚠ Asserted by decoding a frame this
    /// build cannot have produced: the extra key is spliced in as CBOR.
    @Test("An unknown key in link_bind is skipped, not refused")
    func unknownKeyIsSkipped() throws {
        let id = try Self.linkId(0x22)
        let original = try PpcpLinkBind.frame(linkId: id, channel: .bulk)
        var payload = Array(original.dropFirst(8))

        // The head is a definite-length map of 4 pairs (0xA4). Make it 5 and
        // append { "zz": 1 } — "zz" sorts last, so 4e order is preserved.
        #expect(payload[0] == 0xA4)
        payload[0] = 0xA5
        payload.append(contentsOf: [0x62, 0x7A, 0x7A, 0x01])

        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(contentsOf: [PpcpChannel.bulk.rawValue, 0, 0, 0])
        frame.append(contentsOf: payload)

        let binding = try #require(try PpcpLinkBind.decode(frame))
        #expect(binding.linkId == id)
        #expect(binding.channel == .bulk)
    }

    /// The residue problem E1 creates: TCP is free to hand a listener
    /// `link_bind` and the `hello` behind it in one read.
    @Test("Bytes behind link_bind survive the bind")
    func bytesBehindTheBindAreNotLost() async throws {
        let underlying = LoopbackChannel(channel: .control)
        let trailing = Data("hello-would-go-here".utf8)

        let bind = try PpcpLinkBind.frame(linkId: Self.linkId(), channel: .control)
        let arrived = bind + trailing

        let binding = try #require(try PpcpLinkBind.decode(arrived))
        let held = arrived.dropFirst(binding.consumed)
        #expect(Data(held) == trailing)

        let prefixed = PrefixedByteChannel(underlying, holding: Data(held))
        #expect(prefixed.channel == .control)
        // The held prefix comes out first...
        #expect(try await prefixed.receive() == trailing)

        // ...and then the channel behind it, in order.
        try await underlying.send(Data("second".utf8))
        #expect(try await prefixed.receive() == Data("second".utf8))
    }
}

/// The smallest thing that satisfies `ByteChannel`: what is sent comes back.
/// ⚠ Deliberately not shared with `TransportContractTests`' equivalent — a test
/// double that grows features to serve two suites stops being a double.
private actor LoopbackChannel: ByteChannel {
    nonisolated let channel: PpcpChannel
    private var queue: [Data] = []

    init(channel: PpcpChannel) { self.channel = channel }

    func send(_ bytes: Data) async throws { queue.append(bytes) }
    func receive() async throws -> Data? { queue.isEmpty ? nil : queue.removeFirst() }
    func close(_ reason: ChannelCloseReason) async {}
}
