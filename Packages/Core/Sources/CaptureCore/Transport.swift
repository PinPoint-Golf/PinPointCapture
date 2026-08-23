//  Transport.swift
//  The port surface for PPCP transport: an ordered, reliable, bidirectional byte
//  channel, and the peer link that carries two of them (three with preview).
//
//  ⛔ NOTHING FROM Network.framework MAY APPEAR IN THIS FILE (REQ-PORT-3).
//  `NWConnection`, `NWEndpoint`, `NWProtocolTLS.Options`, `sec_protocol_options_t`
//  and their equivalents stay behind `Sources/Platform/Network/PpcpTransport.swift`.
//  `LayerPurityTests` fails the build if that erodes.
//
//  ⚠ These protocols are the transport half of the port surface (REQ-PORT-2), and
//  they are deliberately four calls wide. The peer engine that will sit on top of
//  them — `ppcp_peer`, fed and drained per channel — needs bytes in, bytes out,
//  backpressure and a close reason, and nothing else. Adding a method here is a
//  decision, and an `NWConnection` convenience is not one of them.
//
//  Spec: `CORE` §3 (T1–T5), `ENC` §2 (channel numbering), `RV` §5.4k (the
//  negotiated mode is surfaced), `RV` §7.5d (no application data before the
//  handshake completes).

import Foundation

// MARK: - Channels

/// The channel numbers of `ENC` 2a.
///
/// ⚠ `CORE` T2/T5 is the reason this is an enum and not an `Int`: two channels
/// with **independent flow control** is a protocol requirement derived from a
/// product one — a 25 MB capture in flight must not head-of-line block the next
/// shot's event (`CORE` §3.1). A transport that multiplexes these onto one
/// flow-controlled stream does not satisfy T2 however cleverly it does it.
public enum PpcpChannel: UInt8, Sendable, CaseIterable, Hashable {
    /// Control. Messages, events, everything that must arrive now.
    case control = 0
    /// Bulk. Capture payload, permitted to lag.
    case bulk = 1
    /// Preview. Optional, live-only, and the first thing to drop.
    case preview = 2

    // ⛔ 255 is reserved by `ENC` 2a and must never be allocated here.

    /// The two channels every peer link must have (`CORE` T2).
    public static let required: [PpcpChannel] = [.control, .bulk]
}

// MARK: - Failure

/// Why a channel is no longer carrying bytes.
///
/// ⚠ A close reason is part of the contract rather than a diagnostic nicety: the
/// device must be able to tell "the host went away" from "we refused the peer"
/// without reading a log, because those are different sentences on B3 and only
/// one of them is the user's problem.
public enum ChannelCloseReason: Sendable, Equatable, Hashable {
    /// This end closed it deliberately, having finished.
    case normal
    /// The counterpart closed it cleanly.
    case peerClosed
    /// Torn down locally — session end, backgrounding, revocation.
    case cancelled
    /// The transport failed. The string is for a diagnostic export and therefore
    /// ⛔ carries no key material and no payload (`RV` 7.2b).
    case failed(String)
    /// The counterpart did something the protocol forbids — `ENC` 2c channel
    /// mismatch, or bytes before the handshake completed (`RV` 7.5d).
    case protocolViolation(String)
}

public enum TransportError: Error, Sendable, Equatable {
    /// TLS did not complete. ⛔ There is no plaintext fallback from here, ever,
    /// including on user instruction (`RV` 5.2f).
    case handshakeFailed(String)
    /// Bytes were offered or requested before the handshake completed
    /// (`RV` 1.3c, 7.5d). `hello` is the first byte of application data.
    case applicationDataBeforeHandshake
    case channelClosed(ChannelCloseReason)
    /// `K_tls` is not 32 bytes (`RV` §5.1).
    case invalidKeyLength(Int)
    /// The PSK identity is not 17 octets (`RV` 5.3a).
    case invalidIdentityLength(Int)
    case endpointUnreachable(String)
    case listenerFailed(String)
    /// A peer link needs every channel it asked for; a link with only channel 0
    /// is not a PPCP transport (`CORE` T2).
    case incompleteLink(missing: PpcpChannel)
    /// `ENC` 2.1a — a `link_id` is 16 bytes and nothing else.
    case invalidLinkIdLength(Int)
    /// `ENC` 2.1c — a stream refused at the bind. The four reasons are apart
    /// because they are four different bugs at the far end.
    case bindRefused(BindRefusal)
    /// This link carries no such channel and cannot open one — the listening
    /// side of `ENC` 2.1d, where only the dialler may open a stream.
    case channelUnavailable(PpcpChannel)
    /// The platform CSPRNG refused to produce a `link_id` (`ENC` 2.1a).
    /// ⛔ There is no weaker source to fall back to, and the value carried is a
    /// platform status code, never any part of the entropy.
    case failedToMintLinkId(Int)
}

// MARK: - The channel

/// One ordered, reliable, bidirectional byte stream with its own flow control.
///
/// `CORE` T1: PPCP does not retransmit, reorder or checksum — the transport does,
/// or the protocol is broken. `CORE` T3: message boundaries come from `ENC` §3
/// framing, not from here, so `receive()` is free to return any non-empty slice.
public protocol ByteChannel: Sendable {

    /// Which channel this stream carries. `ENC` 2c: the channel number in every
    /// frame header must match this, and a mismatch is `error` / `malformed`.
    var channel: PpcpChannel { get }

    /// Hand bytes to the transport.
    ///
    /// ⚠ **This is the backpressure.** It does not return until the transport has
    /// taken the bytes, so a bulk sender that outruns the link is throttled by
    /// awaiting rather than by an unbounded queue in front of it. That matters on
    /// a device: the alternative is a growing buffer during a range session, and
    /// the eviction predicate (`CORE` 5.14g) is not a memory manager.
    func send(_ bytes: Data) async throws

    /// Take the next bytes to arrive. `nil` is a clean end of stream.
    ///
    /// ⛔ Throws `.applicationDataBeforeHandshake` if called before the handshake
    /// completes (`RV` 1.3c, 7.5d).
    func receive() async throws -> Data?

    /// Close this channel alone. The rest of the link stays up — that is what
    /// "independent" in T2 means.
    func close(_ reason: ChannelCloseReason) async
}

public extension ByteChannel {

    /// Read exactly `count` bytes, or throw if the stream ends first.
    ///
    /// ⚠ Here rather than in each implementation because `ENC` §3 framing reads
    /// fixed-size headers and every transport would otherwise write this loop
    /// slightly differently. A platform implementation supplies bytes; it does
    /// not supply reassembly policy.
    func receive(exactly count: Int) async throws -> Data {
        precondition(count >= 0)
        var accumulated = Data()
        accumulated.reserveCapacity(count)
        while accumulated.count < count {
            guard let next = try await receive() else {
                throw TransportError.channelClosed(.peerClosed)
            }
            accumulated.append(next)
        }
        // A transport may hand back more than was asked for; `ENC` framing is
        // length-prefixed, so over-read is the caller's to buffer. Refuse rather
        // than silently drop it — dropped bytes desynchronise a frame stream and
        // the symptom appears frames later.
        guard accumulated.count == count else {
            throw TransportError.channelClosed(
                .protocolViolation("over-read: wanted \(count), got \(accumulated.count)"))
        }
        return accumulated
    }
}

// MARK: - The link

/// What was actually negotiated, so the application can say it out loud.
///
/// **`RV` 5.4k MUST**: a peer makes the achieved TLS version and key-exchange mode
/// available to its application layer and records both in its diagnostic export.
/// This type is that value, and it is safe to export — it is neither a key nor a
/// payload (`RV` 7.2b).
///
/// ⚠ Forward secrecy is now a **per-connection outcome**, not a property of the
/// protocol (`RV` §5.4.3, Route D). A device on a plain-PSK leg carries candidate
/// audio with no forward secrecy, and `RV` §5.4 is explicit that this is an
/// accepted consequence rather than an oversight. The app can only be honest
/// about that if the transport tells it, which is why this is not optional.
public struct NegotiatedSecurity: Sendable, Equatable, Hashable {

    public enum Version: Sendable, Equatable, Hashable {
        case tls12
        case tls13
        /// ⛔ **No handshake at all** — `RV` §2's `direct` path, where the
        /// transport is a tunnel or a socket handed in by an embedding. It is a
        /// case rather than `other(0)` because a link with no TLS must not read
        /// as a link whose version could not be determined: `RV` 5.2i's "the
        /// platform did not expose it" and "there was nothing to expose" are
        /// different facts, and only one of them is safe.
        case plaintext
        case other(UInt16)

        public init(code: UInt16) {
            switch code {
            case 0: self = .plaintext
            case 0x0303: self = .tls12
            case 0x0304: self = .tls13
            default: self = .other(code)
            }
        }

        public var displayName: String {
            switch self {
            case .tls12: "TLS 1.2"
            case .tls13: "TLS 1.3"
            case .plaintext: "no TLS"
            case .other(let code): String(format: "TLS 0x%04X", code)
            }
        }
    }

    /// The key-exchange mode, as far as it can be known.
    public enum KeyExchange: Sendable, Equatable, Hashable {
        /// Plain PSK. No ephemeral exchange, therefore no forward secrecy — the
        /// `0x00A8` outcome `RV` 5.4b1 measured on an iPhone 16.
        case psk
        /// PSK with an ephemeral Diffie-Hellman exchange: TLS 1.3 `psk_dhe_ke`, or
        /// a TLS 1.2 `ECDHE_PSK` suite. Property 2 of `RV` 5.2h is obtained.
        case pskEphemeral
        /// ⚠ The platform did not expose it. `RV` 5.2i says exactly this case is
        /// expected and that conformance is then demonstrated by observed
        /// handshake rather than by an API assertion.
        case unknown
        /// ⛔ There was no key exchange, because there was no handshake. Only
        /// `RV` §2's `direct` path reaches this, and `forwardSecrecy` is
        /// **`false`** rather than `nil`: nothing is unknown here.
        case plaintext
    }

    public let version: Version
    /// The IANA ciphersuite code point, as negotiated.
    public let cipherSuite: UInt16
    public let cipherSuiteName: String
    public let keyExchange: KeyExchange

    /// `nil` where the platform did not expose enough to answer honestly.
    /// ⛔ Never default this to `true`; an unknown mode is not a secure one.
    public var forwardSecrecy: Bool? {
        switch keyExchange {
        case .psk: false
        case .pskEphemeral: true
        case .plaintext: false
        case .unknown: nil
        }
    }

    public init(version: Version, cipherSuite: UInt16) {
        self.version = version
        self.cipherSuite = cipherSuite
        let known = Self.registry[cipherSuite]
        self.cipherSuiteName = known?.name ?? String(format: "0x%04X", cipherSuite)
        self.keyExchange = known?.exchange ?? .unknown
    }

    public init(versionCode: UInt16, cipherSuite: UInt16) {
        self.init(version: Version(code: versionCode), cipherSuite: cipherSuite)
    }

    /// `RV` §2's `direct` path: no rendezvous, no handshake, no negotiated mode.
    ///
    /// ⛔ **Not reachable from a shipping build.** It exists for D9's conformance
    /// harness, which runs this device's peer over plaintext loopback sockets so
    /// `ppcp-conform` and `ppcp-sim` can drive it — 9a makes a peer handed an
    /// established socket fully PPCP-conformant with no rendezvous
    /// implementation, and a simulator that spoke TLS would be testing OpenSSL
    /// rather than PPCP. The application's own rendezvous path has no plaintext
    /// branch by construction (5.2f).
    public static let directPathPlaintext =
        NegotiatedSecurity(version: .plaintext, cipherSuite: 0)

    /// The one line the About box and the diagnostic export carry (`RV` 5.4k).
    public var summary: String {
        let secrecy = switch forwardSecrecy {
        case .some(true): "forward secrecy"
        case .some(false): "no forward secrecy"
        case .none: "forward secrecy unknown"
        }
        return "\(version.displayName), \(cipherSuiteName) — \(secrecy)"
    }

    /// ⚠ The registry is here, in the neutral layer, and not in the platform
    /// layer, because the code point is the protocol's and the name is the same
    /// name on every platform. The platform hands over a number.
    ///
    /// Only PSK suites are listed with a key exchange. Anything else negotiated on
    /// a PPCP link would already be a bug — neither end presents a certificate
    /// (`RV` 5.2e) — so it lands in `.unknown` and is reported as the raw code.
    private static let registry: [UInt16: (name: String, exchange: KeyExchange)] = [
        // TLS 1.2, RFC 5487 — the interoperable floor (`RV` 5.2d), and what iOS
        // actually negotiates (`RV` 5.4b1).
        0x00A8: ("TLS_PSK_WITH_AES_128_GCM_SHA256", .psk),
        0x00A9: ("TLS_PSK_WITH_AES_256_GCM_SHA384", .psk),
        0x00AE: ("TLS_PSK_WITH_AES_128_CBC_SHA256", .psk),
        0x00AF: ("TLS_PSK_WITH_AES_256_CBC_SHA384", .psk),
        // TLS 1.2, RFC 5489 and RFC 8442 — preferred where available (`RV` 5.2d).
        // ⚠ Requesting either of these on iOS is silently ignored (`RV` 5.4b1).
        0xC037: ("TLS_ECDHE_PSK_WITH_AES_128_CBC_SHA256", .pskEphemeral),
        0xC038: ("TLS_ECDHE_PSK_WITH_AES_256_CBC_SHA384", .pskEphemeral),
        0xD001: ("TLS_ECDHE_PSK_WITH_AES_128_GCM_SHA256", .pskEphemeral),
        0xD002: ("TLS_ECDHE_PSK_WITH_AES_256_GCM_SHA384", .pskEphemeral),
        0xD003: ("TLS_ECDHE_PSK_WITH_AES_128_CCM_SHA256", .pskEphemeral),
        // TLS 1.3. ⚠ The suite does not name the key exchange at 1.3 — `psk_ke`
        // and `psk_dhe_ke` share these code points — and no platform interface
        // reports which was used, so the mode stays `.unknown` (`RV` 5.2i).
        0x1301: ("TLS_AES_128_GCM_SHA256", .unknown),
        0x1302: ("TLS_AES_256_GCM_SHA384", .unknown),
        0x1303: ("TLS_CHACHA20_POLY1305_SHA256", .unknown),
        // ⛔ Not a ciphersuite. `RV` §2's `direct` path, named so its summary
        // reads "no TLS, none — no forward secrecy" rather than a hexadecimal
        // zero that looks like a failed lookup.
        0x0000: ("none", .plaintext)
    ]
}

/// One peer link: two ordered byte streams, three where preview is offered.
///
/// ⚠ A `PeerTransport` only exists **after** every one of its channels has
/// completed the handshake of `RV` §5. There is no half-authenticated link to
/// hold, which is how `RV` 1.3c ("`hello` is the first byte of application data
/// on an established, authenticated connection") becomes a shape rather than a
/// rule to remember.
public protocol PeerTransport: Sendable {
    /// Channel 0.
    var control: any ByteChannel { get }
    /// Channel 1.
    var bulk: any ByteChannel { get }
    /// Channel 2, where the link carries preview. `nil` is normal.
    var preview: (any ByteChannel)? { get }
    /// `RV` 5.4k. What this link actually negotiated.
    var security: NegotiatedSecurity { get }
    /// Close every channel.
    func close(_ reason: ChannelCloseReason) async
}

public extension PeerTransport {
    /// The channel a frame header names (`ENC` 2c), if the link already carries
    /// it. `nil` for a channel that has not been bound — which for `preview` is
    /// the ordinary case, not an error.
    func boundChannel(_ number: PpcpChannel) -> (any ByteChannel)? {
        switch number {
        case .control: control
        case .bulk: bulk
        case .preview: preview
        }
    }
}

/// `ENC` 2.1d — "a bulk channel MAY be opened at any later point in the
/// session; a `preview` channel after the session is established is the expected
/// case."
///
/// ⚠ This is the half of E1 that arrival order could not have supported at all.
/// A third stream arriving mid-session is indistinguishable from a *new peer's*
/// first stream unless it names the link it belongs to, which is precisely what
/// `link_bind` carries. Two protocols rather than one because the two sides do
/// genuinely different things: the dialler *opens* a stream (2.1a mints nothing
/// new — the same `link_id`), and the listener *waits* for one to be bound to
/// the link it already holds.
public protocol DiallingPeerLink: PeerTransport {
    /// Dial a further stream into this link, sending `link_bind` with the link's
    /// existing `link_id` (2.1d). Returns the already-bound channel if the link
    /// carries it.
    func openChannel(_ channel: PpcpChannel) async throws -> any ByteChannel
}

public protocol ListeningPeerLink: PeerTransport {
    /// Suspend until the counterpart binds `channel` into this link, or the
    /// link closes. Returns the already-bound channel if it carries it.
    func channelBound(_ channel: PpcpChannel) async throws -> any ByteChannel
}

// MARK: - Bytes held in front of a channel

/// A `ByteChannel` that yields a held prefix before delegating to the real one.
///
/// ⚠ It exists for one reason and it is a TCP fact rather than a protocol one:
/// `link_bind` is a ~40-byte frame and the `hello` behind it is written by the
/// dialler moments later, so a single `receive()` on the listener routinely
/// returns **both**. The bind decoder reports how many bytes its frame occupied
/// (`ENC` §3 is length-prefixed, so this is exact); whatever followed is
/// application data that has already left the socket and would otherwise be
/// silently dropped. Dropped bytes desynchronise a frame stream and the symptom
/// appears frames later, which is the worst class of bug to debug.
///
/// Here in Core rather than in the platform layer because it is reassembly
/// policy over the neutral `ByteChannel` contract, and every transport that ever
/// carries `link_bind` needs exactly this.
/// ⚠ An `actor` rather than a lock, so that Core needs no synchronisation
/// primitive of its own: every member of `ByteChannel` except `channel` is
/// already `async`, and `channel` is a pass-through with nothing to guard.
public actor PrefixedByteChannel: ByteChannel {

    private let underlying: any ByteChannel
    private var residue: Data?

    public nonisolated var channel: PpcpChannel { underlying.channel }

    public init(_ underlying: any ByteChannel, holding prefix: Data) {
        self.underlying = underlying
        self.residue = prefix.isEmpty ? nil : prefix
    }

    public func send(_ bytes: Data) async throws { try await underlying.send(bytes) }

    public func receive() async throws -> Data? {
        if let held = residue {
            residue = nil
            return held
        }
        return try await underlying.receive()
    }

    public func close(_ reason: ChannelCloseReason) async {
        residue = nil
        await underlying.close(reason)
    }
}

// MARK: - Credentials

/// What rendezvous hands the transport, and nothing more.
///
/// ⛔ `RV` 7.2b: a pairing secret, a derived key or a decoded payload must not
/// appear in a log, a crash report, an analytics event or a diagnostic export.
/// That is why this type has no `Codable`, no `CustomDebugStringConvertible` that
/// prints bytes, and a `description` that says nothing.
public protocol PpcpCredentials: Sendable, CustomStringConvertible {
    /// `K_tls` — 32 bytes from `HKDF-Expand(PRK, "ppcp1 tls-psk", 32)` (`RV` 5.1).
    /// ⛔ Used for TLS and for nothing else (`RV` 5.1a).
    var tlsKey: Data { get }

    /// A PSK identity for the next connection.
    ///
    /// `RV` 5.3a: 17 octets, `0x01 || rn2 || tag`, with `rn2` fresh per connection
    /// from a CSPRNG. ⚠ **Fresh per connection** is the whole point — a stable
    /// identity in the clear in the `ClientHello` is a tracking beacon, which is
    /// what `RV` §5.3's commentary describes finding in Draft 1.
    ///
    /// ⛔ The result is **binary and need not be valid UTF-8** (`RV` 5.3f). A peer
    /// MUST NOT transcode, validate as text, or truncate it.
    func nextPskIdentity() throws -> Data
}

public extension PpcpCredentials {
    var description: String { "PpcpCredentials(redacted)" }  // `RV` 7.2b
}

/// Byte lengths the rendezvous layer fixes.
public enum PpcpKeyLengths {
    /// `RV` §5.1 — `K_tls` is 32 bytes.
    public static let tlsKey = 32
    /// `RV` 5.3a — `0x01 || rn2(8) || tag(8)`.
    public static let pskIdentity = 17
}

/// One pairing, one identity — the shape a listener holds while a code is
/// outstanding, and the shape the loopback tests use.
///
/// ⚠ This is **not** the resolver of `RV` 5.3b. Resolving a rotating identity
/// against a set of held pairings needs `HMAC-SHA256(K_id, "ppcp1 psk-id" || rn2)`
/// per pairing, which is `libppcp`'s L12 API and arrives with D7. What can be
/// said now: the platform's server side offers no hook to see the offered
/// identity, so the resolver cannot live inside the TLS handshake on this
/// platform — see the finding recorded in `Sources/Platform/Network/PpcpTransport.swift`.
public struct FixedPskCredentials: PpcpCredentials {
    public let tlsKey: Data
    public let identity: Data

    public init(tlsKey: Data, identity: Data) throws {
        guard tlsKey.count == PpcpKeyLengths.tlsKey else {
            throw TransportError.invalidKeyLength(tlsKey.count)
        }
        // ⛔ Length only. No UTF-8 validation, no transcoding (`RV` 5.3f).
        guard identity.count == PpcpKeyLengths.pskIdentity else {
            throw TransportError.invalidIdentityLength(identity.count)
        }
        self.tlsKey = tlsKey
        self.identity = identity
    }

    public func nextPskIdentity() throws -> Data { identity }
}

// MARK: - Dialling

/// Where to dial. ⚠ A string and a port, not a resolved address: `RV` 4.3 puts a
/// list of endpoints in the pairing code and D7 walks them in order, so the
/// transport takes them as written.
public struct PeerEndpoint: Sendable, Equatable, Hashable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// The dialling half. **The scanner dials** (`RV` 2d), and the dialler is the TLS
/// client (`RV` 5.2g).
public protocol PeerTransportConnector: Sendable {
    /// Dial every requested channel and return only when all of them have
    /// completed the handshake **and sent `link_bind`**.
    ///
    /// ⚠ Channels are dialled **concurrently**, and E1 is what made that
    /// possible. S1 dialled them one at a time because a listener could only
    /// assemble a link from arrival order; `ENC` 2.1a replaced that with a
    /// `link_id` in the first frame of every stream, and 2.1d says in as many
    /// words that bulk channels may be opened "before, after, or concurrently
    /// with channel 0". Concurrency halves the time from scan to first frame,
    /// which is time the user spends holding a phone up at a tripod.
    func connect(to endpoint: PeerEndpoint,
                 credentials: any PpcpCredentials,
                 channels: [PpcpChannel]) async throws -> any PeerTransport
}

/// The listening half. Needed for the discovery path, where the **advertiser**
/// listens and the browser dials (`RV` §2, 3.5b) — the opposite direction to the
/// pairing-code path, which is the inconsistency `RV` §2 exists to make explicit.
public protocol PeerTransportListener: Sendable {
    /// Bind and return the port actually bound (0 asks for an ephemeral one).
    func start() async throws -> UInt16
    /// Await one complete peer link.
    func accept() async throws -> any PeerTransport
    func stop() async
}
