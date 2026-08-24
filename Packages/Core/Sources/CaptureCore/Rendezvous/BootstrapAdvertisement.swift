//  BootstrapAdvertisement.swift
//  `PPCP-RV` §3.7 — the advertisement a bootstrap window puts on the network,
//  and the receiver-side rule that tells it apart from a reconnection instance.
//
//  ⛔ **A BOOTSTRAP INSTANCE IS NOT A MODE OF `DiscoveryAdvertisement`** (3.7f).
//  It is a service instance of its own, advertised *alongside* — not instead of —
//  whatever the peer advertises for reconnection (3.7e), and the endpoint its SRV
//  record names MUST NOT be the peer's PPCP listener. The two records share the
//  service type and nothing else, so they are two types here rather than one type
//  with a flag: a flag is what produces a record carrying both sets of keys, and
//  3.3g makes exactly that combination malformed.
//
//  ⛔ **The TXT record carries `bs` and NO `rn` and NO `rid`** (3.3f, 3.3g). It
//  names no pairing because it holds none. `DiscoveryAdvertisement.txtRecord` is
//  the closed list for the reconnection form; `txtRecord` here is the closed list
//  for this one, and neither is reachable from the other.
//
//  ⛔ **`dl` is NEVER defaulted from a device, user or host name** (3.3f, 3.3g).
//  Every platform advertising API wants to do this and that is the point of the
//  clause — see 3.2b, which exists because the default behaviour publishes a
//  person's name on a venue's network. `BootstrapLabel` can only be built from a
//  string the operator typed for this window, and the parameter has no default so
//  that a call site cannot omit the decision.
//
//  ⚠ **`dl` is a privacy trade and the specification states it as one** (3.3g).
//  It is admitted because 11.3d1 makes it load-bearing: an initiator must let its
//  user select ONE window **before** the attempt begins, and the digits do not
//  exist yet, so `dl` is the only thing there is to select on. It lives only
//  while the window lives (3.7d), is typed for the venue rather than inherited
//  from the device, and is never any part of what the pairing is keyed on.
//
//  Spec: `RV` 3.2c, 3.3f, 3.3g, 3.7c, 3.7d, 4.4d. Plan D10. Unlocks RT-22.

import Foundation

// MARK: - RV 3.3f / 3.3g / 4.4d — the optional operator label

/// `dl` — the operator-set bootstrap label. **Untrusted display text.**
///
/// ⛔ 3.3g binds this to the rules of [4.4d] in full: escaped for display,
/// truncated, and **never** an identifier, a trust signal or a storage key. It is
/// shown before anything has been authenticated, so it is whatever somebody
/// typed — including, if they chose, the digits of another window.
///
/// ⛔ **There is no initialiser that takes a device name, a user name or a host
/// name, and there must not be one.** The single entry point is labelled
/// `operatorEntered:` so that a call site wiring in `UIDevice.current.name` has
/// to write the lie down before it compiles.
public struct BootstrapLabel: Sendable, Hashable {

    /// 3.3f — "tstr, at most 32 bytes".
    public static let maximumBytes = 32

    /// The stored text: already truncated, already escaped, ready to display.
    public let text: String

    /// - Parameter operatorEntered: what the operator typed **for this window**.
    ///   `nil` where it is empty once trimmed — 3.3g's "either set by the operator
    ///   for this window or absent" has no third state, and an empty `dl` on the
    ///   wire is a key carrying nothing.
    public init?(operatorEntered raw: String) {
        let escaped = Self.escapedForDisplay(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard escaped.isEmpty == false else { return nil }
        text = Self.truncated(escaped, toBytes: Self.maximumBytes)
    }

    /// 4.4d — "escaped for display". The removals are the ones that matter for a
    /// string a stranger controls and a person reads off a screen: C0/C1 controls,
    /// which can erase the line around them, and the Unicode bidirectional
    /// overrides, which reorder what follows and are the classic way to make one
    /// label render as another.
    static func escapedForDisplay(_ raw: String) -> String {
        String(String.UnicodeScalarView(raw.unicodeScalars.filter { scalar in
            if scalar.properties.generalCategory == .control { return false }
            if scalar.properties.generalCategory == .format { return false }
            switch scalar.value {
            // LRE RLE PDF LRO RLO, LRI RLI FSI PDI — bidi overrides and isolates.
            case 0x202A...0x202E, 0x2066...0x2069: return false
            default: return true
            }
        }))
    }

    /// 3.3f's 32 bytes, counted in UTF-8 and cut on a scalar boundary. ⚠ Counting
    /// characters instead would put a record of unbounded size on the wire, which
    /// 3.3c bounds for the whole record.
    static func truncated(_ text: String, toBytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var out = String.UnicodeScalarView()
        var used = 0
        for scalar in text.unicodeScalars {
            let width = String(scalar).utf8.count
            if used + width > limit { break }
            out.append(scalar)
            used += width
        }
        return String(out)
    }
}

// MARK: - RV 3.2c / 3.3f — the instance and its record

/// One open bootstrap window's service instance.
///
/// ⛔ **`bn` is drawn fresh for every window and is used for the instance name
/// and for nothing else** (3.7c). It is not a key, not an identifier of this
/// peer, and is never persisted — `BootstrapWindow` drops the whole value on
/// close, which is what makes 3.7d's "the instance exists only while the window
/// is open" a property of the type rather than of a call order.
public struct BootstrapAdvertisement: Sendable, Hashable {

    /// 3.1a — the same service type. A bootstrap instance is told apart by `bs`
    /// in the TXT record (3.3f), never by a second service type, which 3.1b
    /// forbids outright.
    public static let serviceType = DiscoveryAdvertisement.serviceType

    /// 3.7c — four bytes from a CSPRNG.
    public static let windowIdBytes = 4

    /// 3.7b — "the peer's own policy and MUST NOT exceed 180 seconds".
    public static let maximumTimeoutNs: Int64 = 180 * 1_000_000_000

    /// The four CSPRNG bytes of 3.7c.
    public let bn: Data
    /// 3.2c — `PPCP-` + the eight uppercase hexadecimal characters of `bn`.
    public let instanceName: String
    public let role: DiscoveryRole
    /// 3.3f — the same version range as the reconnection form, and filtered by a
    /// browser before connecting for the same reason.
    public let protocolVersions: String
    /// 3.3f — `dl`, optional and operator-set. `nil` is the ordinary case.
    public let label: BootstrapLabel?

    /// - Parameters:
    ///   - bn: four bytes the **caller** obtained from a CSPRNG, on the same
    ///     discipline `DiscoveryAdvertisement` applies to `rn` and for the reason
    ///     `rv.h` gives — a library that called `rand()` would be the single point
    ///     at which the whole model fails silently.
    ///   - label: ⛔ **no default value, deliberately.** 3.3f forbids defaulting
    ///     `dl` from a device or user name, and the way that mistake is actually
    ///     made is by a parameter nobody had to think about.
    public init(bn: Data,
                role: DiscoveryRole = .capture,
                protocolVersions: String = PpcpLibrary.wireVersionRange,
                label: BootstrapLabel?) throws {
        guard bn.count == Self.windowIdBytes else {
            throw TransportError.invalidIdentityLength(bn.count)
        }
        self.bn = bn
        // 3.2c — uppercase, and deliberately indistinguishable in FORM from a
        // reconnection instance name (3.2a). 3.2b binds it identically: `bn`
        // persists across nothing.
        //
        // ⚠ Computed here rather than through `ppcp_rv_instance_name`, which
        // takes an 8-byte `rid` and reads four of it — handing it a 4-byte `bn`
        // would read past the buffer. `libppcp`'s bootstrap API does not exist
        // yet; when it does, this is the line that goes.
        self.instanceName = "PPCP-" + bn.map { String(format: "%02X", $0) }.joined()
        self.role = role
        self.protocolVersions = protocolVersions
        self.label = label
    }

    /// 3.3f — **exactly** these keys, plus `dl` when the operator set one.
    ///
    /// ⛔ No `rn` and no `rid` (3.3g). The absence is the whole point: a bootstrap
    /// instance names no pairing because it holds none, and a receiver seeing both
    /// `bs` and `rid` treats the instance as malformed.
    public var txtRecord: [String: String] {
        var record = [
            "txtvers": "1",
            "pv": protocolVersions,
            "role": role.rawValue,
            "bs": "1"
        ]
        if let label { record["dl"] = label.text }
        return record
    }

    /// 3.3c — the whole record under 200 bytes so it fits a single response.
    public var txtRecordBytes: Int {
        txtRecord.reduce(0) { $0 + 1 + $1.key.utf8.count + 1 + $1.value.utf8.count }
    }
}

// MARK: - RV 3.3g — what a receiver does with a discovered instance

/// What a discovered `_ppcp._tcp` instance turned out to be.
///
/// ⛔ **The malformed case is normative, not defensive** (3.3g): "a receiver that
/// sees both `bs` and `rid` on one instance treats the instance as malformed and
/// ignores it". That is half of RT-22, and it is asserted here — over a
/// dictionary, on the host, in milliseconds — rather than against a live
/// responder, because it is a statement about the record and not about the
/// network.
public enum DiscoveredInstance: Sendable, Equatable {

    /// Carries `bs`, no `rn`, no `rid` (3.3f, 3.3g).
    case bootstrap(BootstrapInstance)
    /// Carries `rn` and `rid` and no `bs` — §3.4's form, resolved elsewhere.
    case reconnection
    /// Ignored. ⚠ Never surfaced to a user and never dialled.
    case ignored(Ignored)

    public enum Ignored: Sendable, Equatable {
        /// 3.3g — both `bs` and `rid`. The one the specification names.
        case bootstrapCarriesRid
        /// 3.3g — a bootstrap instance carries no `rn` either. ⚠ **Stricter than
        /// the sentence 3.3g spells out**, which names only `bs` + `rid`. A
        /// producer emitting `bs` with `rn` breaches 3.3g whichever key a reader
        /// checks, so ignoring it is fail-closed and costs nothing; it is called
        /// out here so nobody reads it back as the specification's own rule.
        case bootstrapCarriesRn
        /// 3.3f fixes `bs` at `1`.
        case malformedBootstrapFlag
        /// 3.3d — "a reader that cannot parse a range ignores that advertisement
        /// rather than guessing".
        case unparseableVersionRange
        /// Not this protocol's record at all, or missing what 3.3a requires.
        case notPpcp
    }

    /// A bootstrap instance as read off the wire. ⚠ `label` is untrusted display
    /// text and is re-escaped on the way in — the far end is not obliged to have
    /// done it, and 4.4d binds the *reader*.
    public struct BootstrapInstance: Sendable, Equatable {
        public let role: DiscoveryRole
        public let protocolVersions: String
        public let label: BootstrapLabel?
    }

    /// Classify one discovered TXT record.
    ///
    /// ⚠ Pure, and over a plain dictionary, so it is the same function whichever
    /// platform's browser produced the record — and so RT-22 is a unit test.
    public static func classify(txt: [String: String]) -> DiscoveredInstance {
        let bs = txt["bs"]
        let hasRid = txt["rid"] != nil
        let hasRn = txt["rn"] != nil

        guard let bs else {
            // No `bs`: §3.4's reconnection form, which needs both halves.
            return (hasRid && hasRn) ? .reconnection : .ignored(.notPpcp)
        }
        // ⛔ 3.3g, checked BEFORE anything else about the record is believed.
        guard hasRid == false else { return .ignored(.bootstrapCarriesRid) }
        guard hasRn == false else { return .ignored(.bootstrapCarriesRn) }
        guard bs == "1" else { return .ignored(.malformedBootstrapFlag) }
        guard txt["txtvers"] == "1",
              let role = DiscoveryRole(rawValue: txt["role"] ?? "")
        else { return .ignored(.notPpcp) }
        guard let versions = txt["pv"],
              PpcpVersionRange.parse(versions) != nil
        else { return .ignored(.unparseableVersionRange) }

        // 4.4d — escaped and truncated by the reader. An over-long `dl` is not a
        // reason to ignore the instance; it is a reason not to display all of it.
        let label = txt["dl"].flatMap { BootstrapLabel(operatorEntered: $0) }
        return .bootstrap(BootstrapInstance(role: role,
                                            protocolVersions: versions,
                                            label: label))
    }
}
