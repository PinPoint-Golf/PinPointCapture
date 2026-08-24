//  BootstrapFirstFrame.swift
//  `PPCP-RV` 11.3c — an acceptor closes the connection **without reply** if the
//  first frame is not a well-formed `bs_offer`.
//
//  ⛔ **THIS FILE DOES NOT DECODE `bs_offer`, AND MUST NOT START.** It reads the
//  8-byte envelope of `PPCP-ENC` §3 far enough to say whether what arrived could
//  be a bootstrap frame at all, and hands the payload to a
//  `BootstrapOfferRecognising` — which is `libppcp`'s decoder (plan L19) when
//  there is one. A CBOR reader written here would be a second implementation of
//  11.4b/11.4c/11.4c1/11.4d in a repository that must not own one, and the
//  closed-vocabulary rule of 11.4c1 is exactly the sort of thing two
//  implementations disagree about silently.
//
//  ⛔ **THE PPCP FRAME PARSER CANNOT READ THIS HEADER, AND THAT IS THE POINT.**
//  11.4a sets the channel byte to 255, which `ENC` 2a reserves;
//  `ppcp_channel_validate()` returns `PPCP_ERR_MALFORMED` for it and **must go on
//  doing so**, because that rejection *is* 11.4a's fail-closed property — it is
//  what stops a bootstrap frame being half-understood on a PPCP link. So this is
//  a **separate read path that does not consult the PPCP channel rule**, the
//  mirror of the separate write path CA6 requires. ⚠ Relaxing the validator to
//  let a bootstrap frame through is trap 1: every test still passes and the
//  safety argument is gone.
//
//  ⚠ **Refusing is the default, and while D11 is unwritten it is the only
//  outcome.** `BootstrapDecoderUnavailable` recognises nothing, so an acceptor
//  built on it closes every connection without reply. That is 11.3c's correct
//  behaviour for a peer with no acceptor, not a stub that fails open.
//
//  Spec: `RV` 11.3c, 11.4a, 11.4c; `ENC` §3, 2a, 3a. Plan D10, seam for L19/D11.

import Foundation

/// Whether a payload is a well-formed `bs_offer` (11.4b, 11.4c, 11.4c1, 11.4d).
///
/// ⛔ **The seam.** The judgement is `libppcp`'s: `bs_offer` is `v` uint then
/// `ct` bstr(32) as a deterministically encoded CBOR map, with `v` first (11.4d),
/// with an unrecognised key `malformed` (11.4c1), and with `v` in 1..255
/// (11.4h1). None of that is decided in this repository.
public protocol BootstrapOfferRecognising: Sendable {
    func isWellFormedOffer(payload: Data) -> Bool
}

/// The recogniser for a peer that has no acceptor yet.
///
/// ⚠ Recognises nothing, so 11.3c's refusal is what every connection gets. ⛔ Do
/// not "temporarily" make this return `true`: a peer that accepted a first frame
/// it had not understood is a peer that has guessed which protocol it received,
/// which is precisely what 3.7f separates the endpoints to avoid.
public struct BootstrapDecoderUnavailable: BootstrapOfferRecognising {
    public init() {}
    public func isWellFormedOffer(payload: Data) -> Bool { false }
}

/// The envelope of `ENC` §3, read only as far as 11.3c needs it.
public enum BootstrapFirstFrame {

    /// `ENC` 2a / 11.4a — the reserved channel a bootstrap frame carries.
    public static let reservedChannel: UInt8 = 255
    /// `ENC` §3 — `payload_len` uint32 BE, `channel`, `flags`, `reserved` uint16.
    public static let headerBytes = 8

    /// ⛔ **`ENC` 3a — read `payload_len` before allocating, and reject a frame
    /// that exceeds the limit without allocating for it.** The PPCP limits do not
    /// apply here: `ppcp_channel_frame_limit()` cannot be asked about channel 255
    /// without going through the validator that refuses it, and a megabyte would
    /// be an absurd bound anyway. `bs_offer` is a `v` and a 32-byte `ct` — tens of
    /// bytes. A kilobyte leaves room for a later version to grow and still refuses
    /// an unauthenticated stranger the chance to make this peer allocate.
    public static let maximumPayloadBytes: UInt32 = 1024

    public enum Classification: Sendable, Equatable {
        /// Fewer bytes than a whole frame. ⚠ Wait for more — bounded by the
        /// window's own deadline (3.7b) and by `maximumPayloadBytes`, never
        /// unbounded.
        case incomplete
        /// 11.3c — close **without reply**.
        case refuse(Refusal)
        /// A complete channel-255 frame. ⛔ **NOT yet a `bs_offer`**: only the
        /// envelope is understood, and `BootstrapOfferRecognising` decides the
        /// rest.
        case envelope(payload: Data)
    }

    public enum Refusal: Sendable, Equatable {
        /// The first frame is not on the reserved channel, so it is not a
        /// bootstrap frame — most likely a PPCP peer that dialled the wrong
        /// endpoint. 3.7f separates the ports so neither side has to guess.
        case notBootstrapChannel(UInt8)
        /// A frame with no payload cannot be a `bs_offer`; 11.4b gives it two
        /// fields.
        case emptyPayload
        /// `ENC` 3a — refused on the length alone, before allocating.
        case payloadTooLarge(UInt32)
    }

    /// Classify what has arrived so far on a bootstrap connection.
    ///
    /// ⚠ Pure and over `Data`, so 11.3c is a unit test rather than a socket test.
    public static func classify(_ bytes: Data) -> Classification {
        guard bytes.count >= headerBytes else { return .incomplete }

        let head = [UInt8](bytes.prefix(headerBytes))
        let payloadLen = (UInt32(head[0]) << 24) | (UInt32(head[1]) << 16)
                       | (UInt32(head[2]) << 8)  |  UInt32(head[3])
        let channel = head[4]
        // ⚠ `flags` and `reserved` are NOT checked. `ENC` 3b: "a receiver ignores
        // unknown bits rather than failing, so a later minor version may use
        // them". Refusing on them would be this peer inventing a rule.

        guard channel == reservedChannel else {
            return .refuse(.notBootstrapChannel(channel))
        }
        guard payloadLen > 0 else { return .refuse(.emptyPayload) }
        guard payloadLen <= maximumPayloadBytes else {
            return .refuse(.payloadTooLarge(payloadLen))
        }
        guard bytes.count >= headerBytes + Int(payloadLen) else { return .incomplete }

        let start = bytes.index(bytes.startIndex, offsetBy: headerBytes)
        let end = bytes.index(start, offsetBy: Int(payloadLen))
        return .envelope(payload: Data(bytes[start..<end]))
    }

    /// The whole of 11.3c's first-frame test: the envelope, then the decoder.
    ///
    /// - Returns: `true` only where the frame is complete **and** the recogniser
    ///   says it is a well-formed `bs_offer`. Everything else is a refusal or a
    ///   wait, and neither of those replies.
    public static func isWellFormedOffer(
        _ bytes: Data,
        using recogniser: some BootstrapOfferRecognising
    ) -> Bool {
        guard case .envelope(let payload) = classify(bytes) else { return false }
        return recogniser.isWellFormedOffer(payload: payload)
    }
}
