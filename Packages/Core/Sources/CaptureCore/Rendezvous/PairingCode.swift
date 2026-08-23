//  PairingCode.swift
//  `PPCP-RV` §4 — a scanned `ppcp:` code, decoded by `libppcp` and nothing else.
//
//  ⛔ **Not one byte of CBOR is parsed here.** `ppcp_rv_uri_decode` does the
//  base64url, the deterministic-CBOR decode, the `v`-first check of 4.2a, the
//  unknown-key skip of 4.2c and the 64-byte cap on `dn`. A second decoder in
//  Swift would be the single-implementation trap `CONF` §2c names, in the one
//  part of the specification 4.1 says "cannot be changed after release".
//
//  ⛔ **7.2b, and it shapes the type rather than being remembered.** A pairing
//  secret, a derived key or a decoded payload must not appear in a log, a crash
//  report, an analytics event or a diagnostic export. So `psk` and `sid` are
//  `private`, `description` says nothing, there is no `Codable`, and the only way
//  out of the secret is `RendezvousKeys` — which redacts itself for the same
//  reason.
//
//  ⚠ **Three failures a user can act on, and they are not the same failure**
//  (4.2b, 4.4a/a1, 4.4b): a code from a newer application, a code past its
//  expiry, and a code that is not a code. Draft 1 of this application had one
//  "could not pair", which is what 4.2b exists to forbid.
//
//  Spec: `RV` §4, §5.1, §6, §7.2, §7.4f. Plan D7.

import Foundation
import CPPCP

// MARK: - What a scan produced

/// `RV` §6 — network credentials carried in the code.
///
/// ⛔ 6c: this is a network credential in every respect, so 4.4c and 7.2 apply to
/// it exactly as they do to `psk`. It is never logged and never exported.
public struct PairingNetwork: Sendable, Hashable, CustomStringConvertible {
    /// The network name. ⚠ Shown to the user, because 6a requires consent for the
    /// *specific* network — a prompt that does not name it is not consent.
    public let ssid: String
    /// Absent means an open network (`RV` §6 table).
    public let passphrase: String?
    public let isHidden: Bool

    public init(ssid: String, passphrase: String?, isHidden: Bool) {
        self.ssid = ssid
        self.passphrase = passphrase
        self.isHidden = isHidden
    }

    /// ⛔ Names the network and never the passphrase (7.2b).
    public var description: String { "PairingNetwork(\(ssid), passphrase redacted)" }
}

/// `RV` 4.4a / 4.4a1 — the three outcomes, and there is no fourth.
public enum PairingCodeExpiry: Sendable, Hashable {
    case ok
    /// 4.4a — refuse, and report it **as expired** rather than as a failure to
    /// connect.
    case expired
    /// 4.4a1 — the clock is not trustworthy, so the pairing is attempted anyway
    /// and reported as *possibly* expired. The publisher holds the authoritative
    /// clock and enforces `exp` itself (7.3e).
    case possiblyExpired
}

/// Why the device thinks its own wall clock can or cannot be believed.
///
/// ⚠ 4.4a1 names the two positive reasons to distrust it — never synchronised
/// since boot, or reading earlier than the software's own build date — and
/// requires a *positive* reason. ⛔ Absence of evidence is `trusted`, because the
/// alternative locks a user out of a valid code at a range with no network to
/// correct the clock from.
public enum WallClockTrust: Sendable, Hashable {
    case trusted, untrusted

    var c: ppcp_rv_clock_trust {
        switch self {
        case .trusted: PPCP_RV_CLOCK_TRUSTED
        case .untrusted: PPCP_RV_CLOCK_UNTRUSTED
        }
    }
}

public enum PairingCodeError: Error, Sendable, Equatable {
    /// 4.2b — **not** a generic failure. The user is told the code requires a
    /// newer version of the application, which is the one thing they can act on.
    case requiresNewerApplication
    /// 4.4b — could not decode. No connection is attempted.
    case invalidCode
    /// 4.1a/4.1b — the scheme is not `ppcp:`. ⚠ Reported apart from
    /// `invalidCode` because an `https:` code is 4.1c's exact failure and the
    /// user has scanned something that is not a PPCP pairing code at all.
    case notAPairingCode
}

// MARK: - The code

/// One scanned pairing code.
public struct PpcpPairingCode: Sendable, CustomStringConvertible {

    /// 4.2a — the payload version. This application implements `1`.
    public let version: UInt64
    /// 4.3c — walked **in order**, stopping at the first that completes the
    /// handshake. ⛔ The order is the publisher's preference and is never sorted.
    public let endpoints: [PeerEndpoint]
    /// 4.4d — untrusted display text, escaped and truncated. ⛔ Never an
    /// identifier, a trust signal or a storage key.
    public let displayName: String?
    /// 4.3e — the canonical lowercase UUID text form of `sid`, which is
    /// `Session.id` in `CORE` §5.10. ⛔ Produced by the library, because two
    /// implementations choosing different textual forms would duplicate every
    /// Capture in a re-imported session (8.5c).
    public let sessionId: String
    /// 7.3a — the maximum successful pairings this code may complete.
    public let maxUses: UInt64
    /// 7.3c — seconds since the Unix epoch, absent where the publisher set none.
    public let expiresAtUnixSeconds: UInt64?
    /// §6 — present only where the publisher provides its own network.
    public let network: PairingNetwork?
    /// 7.4f — **false** for a code whose `mu` exceeded 1: a pairing from a
    /// multi-use code is session-scoped, because every peer that scanned that
    /// code holds identical key material. ⛔ The predicate is the library's.
    public let mayPersistPairing: Bool

    /// ⛔ `private`, and there is no accessor. 7.2b.
    private let psk: Data
    private let sid: Data

    /// `RV` §5.1 — `PRK`, `K_tls`, `K_id`, through `libppcp`'s HKDF.
    public func keys() throws -> RendezvousKeys {
        try RendezvousKeys(psk: psk, sid: sid)
    }

    /// ⛔ Says nothing (7.2b).
    public var description: String { "PpcpPairingCode(redacted)" }

    // MARK: Decoding

    /// The `ppcp:` URI a QR code carries.
    ///
    /// ⚠ Whitespace is trimmed and nothing else is repaired: a scanner returns
    /// exactly what the code encodes, and a decoder that "fixed" a payload would
    /// be accepting codes no other implementation accepts.
    public init(uri: String) throws {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        // 4.1b — the scheme does not change between payload versions, so this is
        // the one check that is safe to make before the library sees it.
        guard trimmed.lowercased().hasPrefix("ppcp:") else {
            throw PairingCodeError.notAPairingCode
        }

        var payload = ppcp_rv_payload()
        var scratch = [UInt8](repeating: 0, count: Int(PPCP_RV_MAX_PAYLOAD))
        let bytes = Array(trimmed.utf8)

        // ⚠ Everything is copied out **inside** this scope: `rv.h` says the strings
        // in `out` point into `scratch`, so a field read after it goes away is a
        // read of freed memory that usually still looks right.
        let decoded: Result<PpcpPairingCode, PairingCodeError> =
            bytes.withUnsafeBufferPointer { uriBytes in
                scratch.withUnsafeMutableBufferPointer { scratchBytes in
                    let result = ppcp_rv_uri_decode(
                        UnsafeRawPointer(uriBytes.baseAddress!)
                            .assumingMemoryBound(to: CChar.self),
                        uriBytes.count,
                        scratchBytes.baseAddress, scratchBytes.count, &payload)
                    if result == PPCP_ERR_VERSION_NEWER {
                        // 4.2d — nothing else in the payload may be acted on, so
                        // nothing else is read out of it.
                        return .failure(.requiresNewerApplication)
                    }
                    guard result == PPCP_OK else { return .failure(.invalidCode) }
                    return .success(PpcpPairingCode(payload))
                }
            }
        self = try decoded.get()
    }

    private init(_ payload: ppcp_rv_payload) {
        version = payload.v
        var value = payload

        endpoints = withUnsafeBytes(of: &value.ep) { raw -> [PeerEndpoint] in
            let base = raw.bindMemory(to: ppcp_rv_endpoint.self)
            return (0..<payload.ep_count).compactMap { index in
                let entry = base[index]
                guard let host = entry.h else { return nil }
                return PeerEndpoint(
                    host: String(decoding: UnsafeRawBufferPointer(start: host,
                                                                 count: entry.h_len),
                                 as: UTF8.self),
                    port: entry.p)
            }
        }

        displayName = payload.has_dn && payload.dn != nil
            ? Self.displayText(payload.dn!, payload.dn_len)
            : nil

        var sessionText = [CChar](repeating: 0, count: Int(PPCP_RV_SESSION_ID_CHARS))
        _ = withUnsafeBytes(of: &value.sid) { sidBytes in
            ppcp_rv_sid_to_session_id(
                sidBytes.bindMemory(to: UInt8.self).baseAddress, &sessionText)
        }
        sessionId = String(cString: sessionText)

        // 7.3a — the default is 1, and it is the *specification's* default rather
        // than one chosen here.
        maxUses = payload.has_mu ? payload.mu : 1
        expiresAtUnixSeconds = payload.has_exp ? payload.exp : nil
        mayPersistPairing = ppcp_rv_may_persist(&value)

        if payload.has_wifi, let ssid = payload.wifi.s {
            network = PairingNetwork(
                ssid: String(decoding: UnsafeRawBufferPointer(start: ssid,
                                                             count: payload.wifi.s_len),
                             as: UTF8.self),
                passphrase: payload.wifi.has_k && payload.wifi.k != nil
                    ? String(decoding: UnsafeRawBufferPointer(start: payload.wifi.k!,
                                                              count: payload.wifi.k_len),
                             as: UTF8.self)
                    : nil,
                isHidden: payload.wifi.has_h ? payload.wifi.h : false)
        } else {
            network = nil
        }

        psk = withUnsafeBytes(of: &value.psk) { Data($0.prefix(payload.psk_len)) }
        sid = withUnsafeBytes(of: &value.sid) { Data($0) }
    }

    /// `RV` 4.4d — untrusted display text.
    ///
    /// ⛔ **Escaped and truncated here, once**, because it is shown *before*
    /// anything has been authenticated: it is whatever was printed on the code.
    /// Control characters and the bidirectional overrides are removed — a name
    /// carrying `U+202E` renders a host called `moc.kcatta` as something else
    /// entirely, and this string sits next to a "connect?" button.
    static func displayText(_ pointer: UnsafePointer<CChar>, _ length: Int) -> String {
        let raw = String(decoding: UnsafeRawBufferPointer(start: pointer,
                                                          count: min(length, 64)),
                         as: UTF8.self)
        let cleaned = raw.unicodeScalars.filter { scalar in
            // C0/C1 controls, and the Unicode bidi overrides of TR9.
            scalar.properties.generalCategory != .control
                && scalar.properties.generalCategory != .format
        }
        return String(String.UnicodeScalarView(cleaned))
    }

    // MARK: Expiry

    /// 4.4a / 4.4a1 — the decision, with this peer's own opinion of its clock.
    ///
    /// ⛔ The **policy** is the library's `ppcp_rv_check_expiry`; what this
    /// application supplies is the two inputs. A device that decided expiry itself
    /// would be the second implementation of a clause whose whole point is that
    /// two peers disagree about time.
    public func expiry(nowUnixSeconds: UInt64,
                       trust: WallClockTrust) -> PairingCodeExpiry {
        var payload = ppcp_rv_payload()
        ppcp_rv_payload_init(&payload)
        payload.v = version
        if let expiresAtUnixSeconds {
            payload.has_exp = true
            payload.exp = expiresAtUnixSeconds
        }
        var outcome = PPCP_RV_EXPIRY_OK
        guard ppcp_rv_check_expiry(&payload, nowUnixSeconds, trust.c, &outcome) == PPCP_OK
        else { return .ok }
        switch outcome {
        case PPCP_RV_EXPIRY_EXPIRED: return .expired
        case PPCP_RV_EXPIRY_POSSIBLY_EXPIRED: return .possiblyExpired
        default: return .ok
        }
    }
}
