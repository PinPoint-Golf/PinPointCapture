//  BootstrapOfferDecoder.swift
//  `PPCP-RV` 11.3c — filling the seam D10 left empty, with `libppcp`'s decoder
//  and with nothing written here.
//
//  ⛔ **NOT ONE BYTE OF CBOR IS PARSED IN THIS REPOSITORY.** `ppcp_bs_frame_read`
//  does the deterministic-CBOR decode, `v` first (11.4d), `v` in 1…255 (11.4h1),
//  the field types and lengths, and — the one that matters — **`malformed` on a
//  map key it does not recognise** (11.4c1, erratum E46). Bootstrap frames are
//  the **one closed vocabulary** in the protocol set: 3.3a has a TXT receiver
//  ignore unrecognised keys, 4.2c has a pairing-code decoder do the same at every
//  nesting level, and §11 is the exception. Two implementations could have
//  differed there without either being wrong and §10.4 could never have shown it,
//  which is exactly why the judgement is not made twice.
//
//  ⛔ **AND THE VALIDATOR IS NOT TOUCHED** (trap 1, CA6). `ppcp_channel_validate()`
//  returns `PPCP_ERR_MALFORMED` for channel 255 and **must go on doing so** —
//  that rejection *is* 11.4a's fail-closed property, the thing that stops a
//  bootstrap frame being half-understood on a PPCP link. This is a **separate
//  read path** that does not consult the PPCP channel rule at all, because a
//  bootstrap connection is not a PPCP link (1.3c1).
//
//  **Why the header is rebuilt here.** `BootstrapFirstFrame` hands over the
//  *payload*, having already read and checked the 8-byte envelope; `libppcp`'s
//  reader wants the whole frame. So the envelope is reconstituted from values
//  that are entirely determined — the payload's own length, and channel 255 with
//  zero flags — rather than carried through the seam. ⚠ Nothing is *decided*
//  here: if the two ever disagreed about what a frame is, the engine's answer is
//  the one that counts, and `BootstrapAcceptorTests` asserts they agree on the
//  same bytes.
//
//  Spec: `RV` 11.3c, 11.4a, 11.4b, 11.4c, 11.4c1, 11.4d, 11.4h1; `ENC` §3.
//  Plan D11, filling D10's seam.

import Foundation
import CPPCP

/// The real recogniser: `libppcp`'s frame reader, asked whether this payload is a
/// well-formed `bs_offer`.
///
/// ⚠ It replaces `BootstrapDecoderUnavailable`, whose refusal of everything was
/// 11.3c's correct behaviour for a peer with **no acceptor**. A peer that now has
/// one owes a real answer.
public struct LibppcpOfferRecogniser: BootstrapOfferRecognising {

    public init() {}

    /// - Returns: `true` only where the payload decodes as `bs_offer` — `v` then
    ///   `ct`, nothing else, no unrecognised key. Everything else is `false`, and
    ///   11.3c's answer to that is to close **without reply**.
    public func isWellFormedOffer(payload: Data) -> Bool {
        guard !payload.isEmpty,
              payload.count <= Int(BootstrapFirstFrame.maximumPayloadBytes) else { return false }

        // `ENC` §3's envelope, reconstituted: payload_len uint32 BE, channel 255
        // (11.4a), flags 0, reserved 0.
        let n = UInt32(payload.count)
        var frame = Data([UInt8(truncatingIfNeeded: n >> 24),
                          UInt8(truncatingIfNeeded: n >> 16),
                          UInt8(truncatingIfNeeded: n >> 8),
                          UInt8(truncatingIfNeeded: n),
                          BootstrapFirstFrame.reservedChannel, 0, 0, 0])
        frame.append(payload)

        var decoded = ppcp_bs_frame()
        var consumed = 0
        let rc = frame.withUnsafeBytes { buf in
            ppcp_bs_frame_read(buf.bindMemory(to: UInt8.self).baseAddress,
                               buf.count, &decoded, &consumed)
        }
        // ⚠ `consumed == frame.count` matters: trailing bytes inside a frame the
        // envelope said was this long are not a `bs_offer` with something after
        // it, they are a frame this peer does not understand (11.4c).
        return rc == PPCP_OK && decoded.ty == PPCP_BS_OFFER && consumed == frame.count
    }
}

/// `RV` 11.3c / 11.3d — the one frame an acceptor sends **before** an exchange
/// engine exists.
///
/// ⛔ **This is the other half of 11.3c and it is a distinction, not a
/// courtesy.** Where the first frame is *not* a well-formed `bs_offer` the
/// connection closes **without reply** — something that has not demonstrated it
/// speaks this protocol gets nothing to learn from. Where it **is** a well-formed
/// offer and no window is open, or one attempt is already running (11.3d), the
/// acceptor replies `bs_abort` / `window_closed` and closes: that is far more
/// likely a peer racing a window that has just shut than an attacker, and it is
/// owed a diagnostic its user can act on. D10 closed silently in both cases for
/// want of an encoder; L19 exists now.
///
/// ⛔ CA6 — a **separate write path**. It calls `ppcp_bs_frame_write`, which sets
/// channel 255 itself, and it never goes near `ppcp_channel_validate()`, whose
/// rejection of 255 *is* 11.4a's fail-closed property (trap 1).
///
/// ⛔ 11.4g — `bs_abort` carries `rc` and nothing else. No message, no diagnostic
/// string, no peer name, and there is no parameter here for one.
public enum BootstrapAbortFrame {
    public static func bytes(_ rc: BootstrapAbortReason) -> Data {
        var f = ppcp_bs_frame()
        f.ty = PPCP_BS_ABORT
        f.rc = rc.c
        var out = [UInt8](repeating: 0, count: 128)
        var n = 0
        guard ppcp_bs_frame_write(&f, &out, out.count, &n) == PPCP_OK else { return Data() }
        return Data(out.prefix(n))
    }
}
