//  LinkBind.swift
//  `ENC` §2.1 / `MSG` §3.0 — how a listener learns which streams belong to one
//  peer and which of them is channel 0.
//
//  ⚠ **Erratum E1, and it withdrew what D1 shipped.** S1's listener assembled a
//  link from *arrival order*: the connector dialled its channels one at a time
//  and the listener took them in the order they landed. That is correct only for
//  a dialler that behaves exactly as that listener assumes, which `ENC` §2.1's
//  commentary names as the definition of an interoperability failure — and
//  PinPointStudio's listener had independently chosen a *different* implicit
//  rule (grouping by the pairing its PSK identity resolved to). Both worked
//  against themselves. Neither would have met the other.
//
//  Arrival order also fails three things this application actually needs:
//  concurrent dials (2.1d permits them, and they halve the time to first frame),
//  a `preview` channel opened *after* the session is established (2.1d names it
//  the expected case), and the `direct` path of D9's conformance harness where
//  there is no TLS identity to group by at all.
//
//  So the dialler mints a `link_id` and says which channel each stream carries.
//  One frame of roughly forty bytes, once per stream.
//
//  ⛔ Every byte of the encoding below is `libppcp`'s (`ppcp_frame_*`,
//  `ppcp_envelope_*`, `ppcp_cbor_*`). This file assembles no CBOR of its own and
//  must never start to: `ENC` 4e deterministic ordering, the §8 limits and the
//  reserved-key rule of 5a are the library's to enforce, and a second encoder in
//  Swift is precisely the "two implementations that each pass alone" failure
//  `CONF` §2c describes.
//
//  Spec: `ENC` §2.1 (2.1a–f), §3 framing, §5 envelope; `MSG` §3.0.

import Foundation
import CPPCP

// MARK: - The link identifier

/// `ENC` 2.1a — 16 bytes from a CSPRNG, minted by the **dialler**, fresh per link.
///
/// ⛔ 2.1f: `link_id` is a transport-binding token and nothing else. It is not
/// `Peer.id`, it is **never persisted**, it is never reused across links, and it
/// carries no identity a stranger could correlate. That is why this type has no
/// `Codable`, no string form, and no initialiser from anything but raw bytes —
/// there is deliberately no way to write one to a file or read one back.
///
/// ⚠ The bytes come from the platform layer (`SecRandomCopyBytes`), not from
/// here: Core owns no entropy source, and `RV` §5 already established that the
/// randomness a security property rests on is the platform's to supply.
public struct PpcpLinkId: Sendable, Hashable {

    /// `ENC` 2.1a fixes the width; it is not a parameter.
    public static let byteCount = 16

    public let bytes: Data

    /// - Throws: `TransportError.invalidLinkIdLength` for anything but 16 bytes.
    ///   Length only — there is no structure in a `link_id` to validate, and
    ///   2.1f says a reader must not look for any.
    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw TransportError.invalidLinkIdLength(bytes.count)
        }
        self.bytes = bytes
    }
}

extension PpcpLinkId: CustomStringConvertible {
    /// ⛔ Says nothing. 2.1f — no correlatable identity leaves this type, and a
    /// `link_id` in a log is a `link_id` in a bug report.
    public var description: String { "PpcpLinkId(16 bytes)" }
}

// MARK: - Failures particular to binding

public extension TransportError {
    /// `ENC` 2.1c — the three refusals, kept apart because they are three
    /// different bugs at the far end and a listener that reports "closed" for all
    /// of them tells an implementer nothing.
    enum BindRefusal: String, Sendable, Equatable {
        /// The first frame on the stream was not `link_bind` (2.1a).
        case notLinkBind
        /// `link_bind.channel` disagreed with the frame header (2.1c, and 2c).
        case channelMismatch
        /// The named link already holds that channel (2.1c).
        case channelAlreadyBound
        /// Channel 0 was not bound within the listener's own timeout (2.1c).
        case timedOut
    }
}

// MARK: - The message

/// `MSG` §3.0 — `link_bind { link_id, channel }`, encoded as a whole `ENC` §3
/// frame because that is the only form it is ever in.
public enum PpcpLinkBind {

    /// `ENC` §5: `msg_id` is per sender, per connection, from 1. Each stream is
    /// its own connection, and `link_bind` is its first message.
    static let msgId: UInt64 = 1

    static let type = "link_bind"

    /// A generous ceiling for one frame carrying two small fields. Not a limit in
    /// its own right — `ppcp_frame_check_length` holds the real one (`ENC` §8) —
    /// just the stack buffer this encode is written into, since ⛔ nothing in
    /// `libppcp` allocates.
    static let encodedCapacity = 256

    /// The frame a dialler sends **first on every stream it opens** (2.1a).
    ///
    /// ⛔ **Encoded by `ppcp_msg_encode`, header, envelope and body together.**
    /// This used to write the two body keys by hand through `ppcp_envelope_before`
    /// — correct, but a second encoder for a message the library already knows,
    /// which is what ground rule 1 exists to stop. `ENC` 4e deterministic
    /// ordering, the reserved-key rule of 5a and the §8 limits are now enforced
    /// in exactly one place for `link_bind` as for the other forty-four messages.
    public static func frame(linkId: PpcpLinkId, channel: PpcpChannel) throws -> Data {
        try withMessage { message in
            // ⚠ `1`: `ENC` §5 numbers `msg_id` per sender per connection from 1,
            // and each stream is its own connection with `link_bind` as its first
            // message. There is no peer sequence to draw from — 2.1a puts this
            // frame *before* the engine exists on that stream.
            try check(ppcp_msg_init(message, PPCP_MT_LINK_BIND, msgId))
            // ⛔ 3.0c — no `session_id`. `link_bind` precedes the session's
            // existence on channel 0 and is unrelated to it on a bulk channel.
            withUnsafeMutablePointer(to: &message.pointee.body) { body in
                body.withMemoryRebound(to: ppcp_body_link_bind.self, capacity: 1) { bind in
                    bind.pointee.channel = channel.rawValue
                    withUnsafeMutablePointer(to: &bind.pointee.link_id) { tuple in
                        tuple.withMemoryRebound(to: UInt8.self,
                                                capacity: Int(PPCP_LINK_ID_BYTES)) { out in
                            for (index, byte) in linkId.bytes.enumerated() { out[index] = byte }
                        }
                    }
                }
            }

            var out = [UInt8](repeating: 0, count: encodedCapacity)
            var written = 0
            try check(ppcp_msg_encode(&out, encodedCapacity, channel.rawValue,
                                      message, &written))
            return Data(out[0..<written])
        }
    }

    /// ⚠ **`ppcp_msg` is about 48 KB and it goes on the heap.** A C union imports
    /// into Swift with COMPUTED members, so touching `msg.body.link_bind` by
    /// value is a get-modify-set of the whole union — a 48 KB stack temporary per
    /// field. `body` itself is a stored property, so one pointer to it, rebound,
    /// is in-place and nothing large is ever copied.
    private static func withMessage<T>(_ body: (UnsafeMutablePointer<ppcp_msg>) throws -> T)
        rethrows -> T {
        let bytes = MemoryLayout<ppcp_msg>.stride
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: bytes, alignment: MemoryLayout<ppcp_msg>.alignment)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        defer { raw.deallocate() }
        return try body(raw.assumingMemoryBound(to: ppcp_msg.self))
    }

    /// What a listener learned from one stream's first frame.
    public struct Binding: Sendable, Equatable {
        public let linkId: PpcpLinkId
        /// ⚠ **From the frame header** (2.1b). `link_bind.channel` is checked
        /// against it and is not an independent source of truth: 2c already
        /// requires every frame on the stream to carry the same header channel,
        /// so the header is the value the rest of the session is checked against.
        public let channel: PpcpChannel
        /// Bytes of the stream this frame occupied. Anything after it is
        /// application data the caller must not lose — TCP is free to coalesce
        /// `link_bind` with the `hello` behind it.
        public let consumed: Int
    }

    /// Decode a candidate first frame.
    ///
    /// - Returns: `nil` where `bytes` does not yet hold a whole frame — the
    ///   caller reads more. `ENC` 3c makes truncation the reader's decision, and
    ///   on a live transport an incomplete *final* frame is fatal; here it simply
    ///   means the stream has not finished speaking.
    /// - Throws: `TransportError.bindRefused` for each of 2.1c's refusals.
    public static func decode(_ bytes: Data) throws -> Binding? {
        var header = ppcp_frame_header()
        var payload: UnsafePointer<UInt8>?
        var consumed = 0

        let read: ppcp_result = bytes.withUnsafeBytes { raw in
            ppcp_frame_read(raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                            &header, &payload, &consumed)
        }
        if read == PPCP_ERR_TRUNCATED { return nil }
        try check(read)

        guard let headerChannel = PpcpChannel(rawValue: header.channel) else {
            // ⛔ `ENC` 2a reserves 255 and this application allocates 0, 1 and 2.
            // A stream announcing anything else is refused rather than tracked.
            throw TransportError.bindRefused(.channelMismatch)
        }

        // ⚠ The payload pointer is into `bytes`, whose buffer is only valid for
        // the duration of `withUnsafeBytes`. Decode inside a second borrow of the
        // same `Data` rather than carrying the pointer out — the decoder returns
        // pointers into the caller's buffer too (`cbor.h`), so every read of it
        // has to happen while the buffer is alive.
        let payloadRange = (consumed - Int(header.payload_len))..<consumed
        let decoded: (PpcpLinkId, UInt8) = try bytes.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            return try decodePayload(base?.advanced(by: payloadRange.lowerBound),
                                     Int(header.payload_len),
                                     channel: header.channel)
        }

        // 2.1c — `channel` disagreeing with its header closes the stream.
        guard decoded.1 == header.channel else {
            throw TransportError.bindRefused(.channelMismatch)
        }
        return Binding(linkId: decoded.0, channel: headerChannel, consumed: consumed)
    }

    /// ⚠ **Every library failure inside the payload becomes `notLinkBind`, and
    /// that is a deliberate narrowing.** `ENC` 2.1c gives a listener exactly
    /// three reasons to close a stream at the bind, and "the payload was
    /// malformed CBOR" is not a fourth — it is the first one: whatever that
    /// stream opened with, it was not a `link_bind`. Reporting `malformed` here
    /// instead would invite a caller to answer `error` / `malformed` on a stream
    /// that has no session to answer on, which 3.0c rules out by saying
    /// `link_bind` "requires no response".
    ///
    /// The *frame header* is not narrowed this way and is checked by the library
    /// before this is reached: an oversized `payload_len` is `ENC` 8a fatal and a
    /// reserved channel is 2a malformed, and both are stream-level facts that
    /// deserve their own diagnostic.
    ///
    /// ⛔ **Decoded by `ppcp_msg_decode`.** The hand-written CBOR walk this
    /// replaced re-implemented key iteration, the unknown-key skip of I13 and the
    /// §8 limit checks — three rules the library already holds and which a second
    /// implementation can only drift from. A `NULL` arena is right here:
    /// `message.h` says only `declare` and `payload_begin` need one, and neither
    /// can be a stream's first frame.
    private static func decodePayload(_ payload: UnsafePointer<UInt8>?, _ length: Int,
                                      channel: UInt8) throws -> (PpcpLinkId, UInt8) {
        guard let payload else { throw TransportError.bindRefused(.notLinkBind) }
        let limits = ppcp_cbor_limits_for_channel(channel)

        return try withMessage { message in
            guard ppcp_msg_decode(payload, length, limits, nil, message) == PPCP_OK,
                  message.pointee.type == PPCP_MT_LINK_BIND else {
                throw TransportError.bindRefused(.notLinkBind)
            }
            return withUnsafeMutablePointer(to: &message.pointee.body) { body in
                body.withMemoryRebound(to: ppcp_body_link_bind.self, capacity: 1) { bind in
                    let bytes = withUnsafeBytes(of: &bind.pointee.link_id) { Data($0) }
                    // The width is `PPCP_LINK_ID_BYTES` by the struct's own
                    // declaration, so this initialiser cannot refuse.
                    return ((try? PpcpLinkId(bytes: bytes)) ?? Self.zeroLinkId,
                            bind.pointee.channel)
                }
            }
        }
    }

    private static let zeroLinkId = try! PpcpLinkId(bytes: Data(count: PpcpLinkId.byteCount))

    /// Read a stream's **first frame** and decode it as `link_bind` (2.1a).
    ///
    /// Returns the binding and whatever bytes arrived behind it — hand those to
    /// `PrefixedByteChannel` or they are lost.
    ///
    /// ⚠ There is no read cap here and there does not need to be one: the frame
    /// header is parsed the moment eight bytes exist, `ppcp_frame_read` refuses a
    /// `payload_len` beyond the channel's `ENC` §8 limit *before* the body is
    /// read, and a peer that dribbles bytes forever is caught by the listener's
    /// bind timeout (2.1c) rather than by a limit invented here. Adding a second
    /// cap would be a limit the protocol does not have.
    public static func awaitBinding(on channel: any ByteChannel) async throws
        -> (binding: Binding, residue: Data) {
        var buffer = Data()
        while true {
            if let binding = try decode(buffer) {
                return (binding, buffer.dropFirst(binding.consumed))
            }
            guard let next = try await channel.receive() else {
                // The stream ended before it said what it was. 2.1c's outcome
                // either way is that the stream is discarded.
                throw TransportError.bindRefused(.notLinkBind)
            }
            buffer.append(next)
        }
    }
}
