//  WiredPresence.swift
//  The record this device serves on the wired presence port, and nothing else.
//
//  ⚠ **This is an `RV` §3 advertisement delivered over a cable instead of over
//  multicast** — the same TXT semantics, read by the same `pvAcceptsMajor()` and
//  the same `decideDial()` on the host. `RV` §2's *direct* path is defined as
//  "out of band — a tunnel, a cached endpoint, a socket handed in by an embedding
//  application", and this is the out-of-band part of it.
//
//  ⛔ **Why the device publishes an identity at all.** usbmux is host→device
//  only, so on a cable the device listens and the host dials — and
//  `Network.framework`'s listener can accept exactly the one PSK identity it
//  registered (`RV` 3.5d, and the finding recorded at the top of
//  `PpcpListener`). A host that drew a fresh `rn2` per 5.3a would offer an
//  identity this device never heard of and get alert 115. So the resolution moves
//  to the client: the device publishes what it registered, and the host
//  recomputes `tag = HMAC-SHA256(K_id, "ppcp1 psk-id" || rn2)` over every pairing
//  it holds and refuses to dial unless one matches. That is 5.3b, run early, by
//  the peer whose TLS stack can actually do it. The security property is
//  unchanged: only a peer holding `K_id` can *produce* a resolvable identity, and
//  only a peer holding `K_id` can *verify* one. An identity is public data — it
//  crosses the wire in cleartext in every `ClientHello`.
//
//  ⛔ **THERE IS NO `rid` HERE AND THERE MUST NEVER BE ONE.** The host's
//  `identityResolver()` already recomputes the tag with the `K_id` of every
//  pairing it holds and hands back **both** `K_tls` and the pairing — the whole
//  result a dial needs. A `rid` would be a second resolution path computing the
//  same answer from a different nonce, and a second place to get expiry (7.3e),
//  exhaustion (7.3a) and invalidation (7.3b) wrong. It would also *cost* a
//  capability: `resolveRid()` is documented "ONLY PERSISTED PAIRINGS (7.4a)", so
//  an `rid`-based record could not carry a **scanned but not yet connected** code
//  — and carrying one is exactly what makes a phone's first pairing over the
//  cable work with no new host machinery (design §6.5). The simplification was
//  also the enabler. Do not reintroduce `rid` for tidiness.
//
//  ⛔ **What this discloses, recorded rather than waved away.** The record names
//  every pairing this device holds, so a reader learns how many there are — which
//  `RV` 3.4d1 keeps unobservable on the radio by advertising one pairing at a
//  time. **The loopback bind is what makes that reader non-existent rather than
//  merely unlikely** (see `WiredPresenceListener`): the reader is either a process
//  on this device, which has strictly better attacks available to it, or a process
//  at the far end of a physical cable. On an all-interfaces bind this trade would
//  not hold and the design would be wrong.
//
//  ⚠ `RV` 7.7a forbids PPCP messages before the handshake and this record carries
//  none; 7.7b forbids disclosing Sources, profiles, calibration or stored
//  sessions and none of those appear. A port is not a secret.
//
//  Contract: `PinPointStudio/docs/implementation/wired_transport_impl_plan.md`
//  **C3**, fixed 29 August 2026 — field names, types and order are agreed with the
//  host reader and are not negotiable from this side.
//  Design: `PinPointStudio/docs/design/wired_transport_design.md` §5.2–§5.5.

import Foundation
import CPPCP

/// The CBOR record served on the wired presence port.
///
/// ⚠ **A value, and the encoder that goes with it, deliberately in `CaptureCore`
/// rather than beside the listener.** The bytes are the contract with
/// PinPointStudio; they are worth asserting byte for byte in a suite that needs
/// no simulator and no socket.
public struct WiredPresence: Sendable, Equatable {

    /// One `PpcpListener` this device is running, and the identity it registered.
    ///
    /// ⛔ **One entry per held pairing, NOT per host.** `PpcpCredentials` carries
    /// one `tlsKey` and one `nextPskIdentity()`, and an `NWListener` registers
    /// exactly one (key, identity) pair — so a device holding three pairings runs
    /// three listeners on three ephemeral ports (C5).
    public struct Peer: Sendable, Equatable {
        /// The **actual** bound port of that pairing's listener. Because the
        /// record carries it, no port-derivation scheme is needed anywhere: the
        /// listener binds `0` and reports what it got.
        public let port: UInt16

        /// `RV` 5.3a — exactly 17 octets, `0x01 ‖ rn2(8) ‖ tag(8)`, **as
        /// registered**.
        ///
        /// ⛔ **Binary, and it need not be valid UTF-8** (`RV` 5.3f). It MUST NOT
        /// be transcoded, validated as text or truncated, here or anywhere
        /// downstream of here. With the `RV` §10.2 `rn2` the value is
        /// `010f1e2d3c4b5a6978b355ada60b4b5aa8`, which is not valid UTF-8 — that
        /// is the point, not an accident.
        public let pskIdentity: Data

        public init(port: UInt16, pskIdentity: Data) throws {
            guard port != 0 else { throw Failure.invalidPort }
            // ⛔ Length only. No UTF-8 validation and no transcoding (5.3f).
            guard pskIdentity.count == PpcpKeyLengths.pskIdentity else {
                throw Failure.invalidIdentityLength(pskIdentity.count)
            }
            self.port = port
            self.pskIdentity = pskIdentity
        }
    }

    public enum Failure: Error, Sendable, Equatable {
        /// A record with no listener in it is a device that cannot be dialled.
        /// The host refuses it (C3), so it is not emitted either.
        case noPeers
        /// C3 — the host refuses more than 16 entries.
        case tooManyPeers(Int)
        case invalidPort
        /// `RV` 5.3a — 17 octets and nothing else.
        case invalidIdentityLength(Int)
        /// ⚠ Refused rather than truncated. `dl` is display text, and a device
        /// name long enough to threaten the 4096-byte cap is not a device name.
        case labelTooLong(Int)
        /// C3 — the host caps the read at 4096 bytes and a breach is a refusal,
        /// so a record that would breach it is never written.
        case recordTooLarge(Int)
    }

    /// `RV` 3.3a — the host filters on MAJOR before it dials.
    /// ⛔ **Not the wire version.** `pv` is the *rendezvous* payload version, the
    /// same one a pairing code and a TXT record carry.
    public static let pv = "1.0"
    /// `CORE` 5.1 — what this peer is. The host has no use for a cable to
    /// another host.
    public static let role = "capture"
    /// C3 — the host refuses a record with more than this many entries.
    public static let maxPeers = 16
    /// C3 — the host reads to EOF with this cap and refuses a breach.
    public static let maxRecordBytes = 4096
    /// Refused above this. Well under the cap, and far above any real label.
    public static let maxLabelBytes = 128

    /// `RV` 4.4d — display text, and **UNTRUSTED**.
    ///
    /// ⛔ It is *this* device's label, but the reader must sanitise it before it
    /// is displayed and must never use it as a key or an identifier. That
    /// obligation is the host's and this side does not rely on it having been
    /// met: nothing here keys on `dl` either.
    ///
    /// ⚠ **Omitted entirely when absent — never `null`** (C3). A CBOR `null` in
    /// a field the reader treats as optional is a third state nobody wrote a
    /// rule for.
    public let displayLabel: String?

    public let peers: [Peer]

    public init(displayLabel: String?, peers: [Peer]) throws {
        guard peers.isEmpty == false else { throw Failure.noPeers }
        guard peers.count <= WiredPresence.maxPeers else {
            throw Failure.tooManyPeers(peers.count)
        }
        if let displayLabel {
            let bytes = displayLabel.utf8.count
            guard bytes <= WiredPresence.maxLabelBytes else {
                throw Failure.labelTooLong(bytes)
            }
        }
        // ⚠ An empty label is an absent one. `dl: ""` would be a third state for
        // a reader that already has two, and C3 gives it no meaning.
        self.displayLabel = displayLabel.flatMap { $0.isEmpty ? nil : $0 }
        self.peers = peers
    }

    /// The record, as the bytes that go on the socket.
    ///
    /// ⛔ **Key order is `dl`, `pv`, `role`, `peers`, and that is `ENC` 4e's
    /// deterministic order rather than a house style.** 4e sorts bytewise over the
    /// **encoded** key, so `62 64 6c` (`dl`) < `62 70 76` (`pv`) < `64 …` (`role`)
    /// < `65 …` (`peers`). ⚠ The default `ppcp_cbor_writer` *enforces* that and
    /// sets its sticky error on a key out of order, which is the right trade: a
    /// duplicate key becomes impossible to emit rather than merely forbidden
    /// (`ENC` 4d), and no call site has to remember a discipline.
    ///
    /// ⚠ **C3 originally fixed the order as `pv, role, dl, peers`, and that
    /// record was not emittable.** With a label present it is out of 4e order, so
    /// the writer refused it and the only way to produce it was
    /// `PPCP_CBOR_ORDER_LITERAL` — whose own header says it exists for two
    /// reasons and no others. C3 was amended instead. ⛔ **Note how nearly this
    /// survived:** with `dl` absent, `pv, role, peers` is *already* deterministic,
    /// so a record with no label encodes identically under either rule and a
    /// fixture that only covered the unlabelled case would have proved nothing.
    /// Both cases are asserted against literal bytes for that reason.
    ///
    /// ⚠ Ordering is not something the far end depends on — C3 requires the
    /// reader to *"accept keys in any order and ignore unknown ones"* — but it is
    /// written down at both ends so a byte-for-byte fixture is possible.
    ///
    /// ⚠ Written through `libppcp`'s encoder, key ordering included — a
    /// hand-rolled map here would be the second encoder `CONF` §2c warns about.
    public func encoded() throws -> Data {
        var buffer = [UInt8](repeating: 0, count: WiredPresence.maxRecordBytes)
        var length = 0
        let label: [UInt8]? = displayLabel.map { Array($0.utf8) }

        try buffer.withUnsafeMutableBufferPointer { out in
            var writer = ppcp_cbor_writer()
            // ⛔ The DEFAULT writer, which is `PPCP_CBOR_ORDER_DETERMINISTIC`.
            // Nothing on this path asks for the literal-order escape hatch, and
            // nothing should: if a key ever has to be written out of 4e order
            // again, the schema is wrong, not the writer.
            ppcp_cbor_writer_init(&writer, out.baseAddress, out.count)
            // A definite-length map. ⛔ Three keys, or four with `dl` — an absent
            // label changes the head, it does not become a `null`.
            _ = ppcp_cbor_write_map(&writer, label == nil ? 3 : 4)

            // ⚠ `dl` FIRST — `ENC` 4e, see the note above. Writing it where a
            // reader would naturally expect it, after `role`, is what the writer
            // refuses.
            if let label {
                _ = ppcp_cbor_write_text_z(&writer, "dl")
                // ⚠ `write_text` with an explicit length, not `write_text_z`: a
                // Swift `String` may contain a NUL, and `strlen` would silently
                // publish a shorter label than the device carries.
                _ = label.withUnsafeBufferPointer { bytes in
                    ppcp_cbor_write_text(&writer,
                                         UnsafeRawPointer(bytes.baseAddress!)
                                             .assumingMemoryBound(to: CChar.self),
                                         bytes.count)
                }
            }

            _ = ppcp_cbor_write_text_z(&writer, "pv")
            _ = ppcp_cbor_write_text_z(&writer, WiredPresence.pv)

            _ = ppcp_cbor_write_text_z(&writer, "role")
            _ = ppcp_cbor_write_text_z(&writer, WiredPresence.role)

            _ = ppcp_cbor_write_text_z(&writer, "peers")
            _ = ppcp_cbor_write_array(&writer, peers.count)
            for peer in peers {
                _ = ppcp_cbor_write_map(&writer, 2)
                // ⚠ `port` before `psk_identity` is BOTH C3's order and `ENC`
                // 4e's, so the inner maps need no dispensation.
                _ = ppcp_cbor_write_text_z(&writer, "port")
                _ = ppcp_cbor_write_uint(&writer, UInt64(peer.port))
                _ = ppcp_cbor_write_text_z(&writer, "psk_identity")
                _ = peer.pskIdentity.withUnsafeBytes { raw in
                    ppcp_cbor_write_bytes(&writer,
                                          raw.bindMemory(to: UInt8.self).baseAddress,
                                          raw.count)
                }
            }

            // ⚠ One check for the whole record: every write returns the writer's
            // sticky error, and the first failure wins.
            try check(ppcp_cbor_writer_finish(&writer, &length))
        }

        guard length <= WiredPresence.maxRecordBytes else {
            throw Failure.recordTooLarge(length)
        }
        return Data(buffer[0..<length])
    }
}
