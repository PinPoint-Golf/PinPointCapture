//  DiscoveryAdvertisement.swift
//  `PPCP-RV` §3 — what this device puts on the multicast network, and nothing
//  else.
//
//  ⛔ **3.3a is a closed list and this type is the closed list.** Five keys:
//  `txtvers`, `pv`, `role`, `rn`, `rid`. 3.3b forbids `Peer.id`, a device or user
//  name, a serial number, a session identifier, a count of stored sessions or any
//  capability detail — and the reason it has to be forbidden explicitly is that
//  every platform advertising API defaults the service name to the device name,
//  which on a phone is frequently a person's name. Publishing that on a driving
//  range's network is a privacy failure no amount of transport encryption
//  repairs, and it happens **by default** unless the name is set.
//
//  ⛔ **The instance name is `PPCP-` + the first four bytes of `rid`** (3.2a),
//  computed by `libppcp` from `rn`, and nothing that persists across pairings goes
//  anywhere near it (3.2b).
//
//  ⚠ **`rn` rotates on every registration and at least every 15 minutes** (3.4a).
//  A stable identifier would be trackable across every venue the device visits;
//  the construction is the same idea as a resolvable private address, and the
//  rotation is the half that makes two observations uncorrelatable. The library
//  states the interval as `PPCP_RV_RN_MAX_AGE_NS` and this reads it rather than
//  writing 900 down again.
//
//  ⚠ **Discovery failure is never an error state** (3.6a). Multicast is
//  rate-limited or dropped by many consumer access points, blocked by client
//  isolation on guest networks, and does not cross VLANs — "it will not work at a
//  range". This type therefore has no failure to report; the pairing code is the
//  path (3.6b).
//
//  Spec: `RV` §3, §7.6a. Plan D7.

import Foundation
import CPPCP

/// The role a peer states it intends to take (3.3a). ⚠ Not a capability claim:
/// capability is declared inside the authenticated channel, where it belongs
/// (3.3b).
public enum DiscoveryRole: String, Sendable, Hashable {
    case host, capture, observer
}

/// One registration of `_ppcp._tcp`.
///
/// ⛔ Built from a pairing's `K_id`, so only a peer that holds the pairing can
/// resolve it (3.4b) and a stranger learns that a PPCP peer exists and nothing
/// about which one (7.6c).
public struct DiscoveryAdvertisement: Sendable, Hashable {

    /// 3.1a — and 3.1b forbids any other service type for PPCP rendezvous.
    public static let serviceType = "_ppcp._tcp"

    /// 3.4a — regenerated on every registration and at least this often
    /// thereafter. ⚠ Asked of the library rather than restated.
    public static var maximumNonceAgeNs: Int64 { PPCP_RV_RN_MAX_AGE_NS }

    /// 3.2a — `PPCP-9B1D2DF9`.
    public let instanceName: String
    /// The eight CSPRNG bytes, published in the clear as sixteen hex characters.
    public let rn: Data
    /// `HMAC-SHA256(K_id, "ppcp1 rid" || rn)[0..7]`.
    public let rid: Data
    public let role: DiscoveryRole
    /// The wire versions this peer speaks. ⚠ A browser filters on MAJOR **before**
    /// connecting, which is why it is in the record at all.
    public let protocolVersions: String
    /// When `rn` was minted, in the timebase the caller ticks with — so
    /// `needsRotation(asOf:)` is answered against a clock that measures rather
    /// than a wall clock (I15).
    public let mintedAtNs: Int64

    /// - Parameters:
    ///   - identityKey: `K_id` from `RV` §5.1. ⛔ Never `K_tls`: 5.1a/5.1b give
    ///     each key exactly one use, and it is what lets `rid` be published in the
    ///     clear on a range's multicast network without revealing anything about
    ///     the handshake key.
    ///   - rn: eight bytes the **caller** obtained from a CSPRNG. ⛔ A parameter
    ///     rather than something generated here, for the reason `rv.h` gives: a
    ///     library that called `rand()` would be the single point at which the
    ///     whole model fails silently.
    public init(identityKey: Data, rn: Data, role: DiscoveryRole = .capture,
                protocolVersions: String = PpcpLibrary.wireVersion,
                mintedAtNs: Int64) throws {
        guard identityKey.count == Int(PPCP_RV_KEY_BYTES) else {
            throw TransportError.invalidKeyLength(identityKey.count)
        }
        guard rn.count == Int(PPCP_RV_RN_BYTES) else {
            throw TransportError.invalidIdentityLength(rn.count)
        }
        var ridBytes = [UInt8](repeating: 0, count: Int(PPCP_RV_RID_BYTES))
        try check(identityKey.withUnsafeBytes { key in
            rn.withUnsafeBytes { nonce in
                ppcp_rv_rid(key.bindMemory(to: UInt8.self).baseAddress,
                            nonce.bindMemory(to: UInt8.self).baseAddress,
                            &ridBytes)
            }
        })
        var name = [CChar](repeating: 0, count: Int(PPCP_RV_INSTANCE_NAME_MAX))
        try check(ppcp_rv_instance_name(&ridBytes, &name))

        self.instanceName = String(cString: name)
        self.rn = rn
        self.rid = Data(ridBytes)
        self.role = role
        self.protocolVersions = protocolVersions
        self.mintedAtNs = mintedAtNs
    }

    /// 3.3a — **exactly** these keys.
    ///
    /// ⚠ Hexadecimal is lowercase here and the instance name is uppercase, which
    /// is 3.2a and 3.3's own spellings rather than an inconsistency: the name is
    /// read by a human off a screen and the record is read by a machine.
    public var txtRecord: [String: String] {
        [
            "txtvers": "1",
            "pv": protocolVersions,
            "role": role.rawValue,
            "rn": rn.map { String(format: "%02x", $0) }.joined(),
            "rid": rid.map { String(format: "%02x", $0) }.joined()
        ]
    }

    /// 3.3c — the whole record under 200 bytes so it fits a single response.
    public var txtRecordBytes: Int {
        // DNS-SD encodes each entry as one length octet plus `key=value`.
        txtRecord.reduce(0) { $0 + 1 + $1.key.utf8.count + 1 + $1.value.utf8.count }
    }

    /// 3.4a — `rn` is regenerated at least every 15 minutes.
    public func needsRotation(asOfNs nowNs: Int64) -> Bool {
        nowNs - mintedAtNs >= Self.maximumNonceAgeNs
    }
}

// MARK: - Resolving what was discovered

/// 3.4b/3.4c — a browsing peer resolves a discovered `rid` against the `K_id` of
/// each pairing it holds, and **does not connect** to one it cannot resolve.
///
/// ⚠ Here even though this device advertises rather than browses, for the reason
/// `RV` §2 gives: the direction is a deployment fact, not a role. 3.5c makes a
/// host advertising and a device browsing conformant, and it is the shape a
/// "reconnect to a discovered host" interaction needs.
public enum DiscoveryResolver {

    /// - Returns: the index of the pairing whose `K_id` produces this `rid`, or
    ///   `nil` when none does — which 3.4c makes a refusal to connect and not a
    ///   prompt.
    public static func resolve(rid: Data, rn: Data, against identityKeys: [Data]) -> Int? {
        guard rid.count == Int(PPCP_RV_RID_BYTES),
              rn.count == Int(PPCP_RV_RN_BYTES),
              identityKeys.isEmpty == false,
              identityKeys.allSatisfy({ $0.count == Int(PPCP_RV_KEY_BYTES) })
        else { return nil }

        // ⚠ The keys are held as one contiguous buffer for the whole call, because
        // `ppcp_rv_pairing.k_id` is a **borrowed** pointer the resolver reads
        // inside its constant-time loop.
        var flattened = [UInt8]()
        for key in identityKeys { flattened.append(contentsOf: key) }
        var index = 0
        let width = Int(PPCP_RV_KEY_BYTES)

        return flattened.withUnsafeBufferPointer { keys -> Int? in
            let pairings = (0..<identityKeys.count).map { slot in
                ppcp_rv_pairing(k_id: keys.baseAddress! + slot * width, user: nil)
            }
            return pairings.withUnsafeBufferPointer { table in
                rn.withUnsafeBytes { nonce in
                    rid.withUnsafeBytes { identifier in
                        let result = ppcp_rv_resolve_rid(
                            table.baseAddress, table.count,
                            nonce.bindMemory(to: UInt8.self).baseAddress,
                            identifier.bindMemory(to: UInt8.self).baseAddress,
                            &index)
                        return result == PPCP_OK ? index : nil
                    }
                }
            }
        }
    }

    /// Parses the two hexadecimal fields of a TXT record. ⚠ `nil` for anything
    /// that is not exactly the width 3.3a states — a record that half-parses is a
    /// record from something that is not a PPCP peer.
    public static func hexField(_ text: String?, bytes: Int) -> Data? {
        guard let text, text.count == bytes * 2 else { return nil }
        var out = Data(capacity: bytes)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}
