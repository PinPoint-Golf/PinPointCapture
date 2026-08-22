//  DeviceProfiles.swift
//  Per-model facts that no API reports, keyed by model identifier.
//
//  ⚠ REQ-PORT-10 / plan A13: device profiles ship as DATA keyed by device model,
//  never as code. Android's device population makes a code-based approach
//  untenable and iOS benefits equally. This file is the loader;
//  `DeviceProfiles.json` is the data and `DeviceProfiles.md` is its field guide,
//  and the data is what gets edited when a new model goes through the rig.
//
//  ⛔ The PPCP block's *shape* lives in `CaptureCore` (`PpcpDeviceTimingProfile`)
//  and not here. REQ-PORT-11: that vocabulary is the protocol's, an Android port
//  reads the same fields out of a file of its own, and a type defined beside the
//  iOS loader would have to be rewritten rather than ported.

import Foundation
import CaptureCore

public struct DeviceProfile: Sendable, Codable {
    /// "iPhone 16" — no public API reports this, so it is data.
    public var marketingName: String

    /// A13 — the PPCP timing and geometry this model declares.
    ///
    /// ⛔ Every value in it is `assumed` and will stay so until an LED timecode
    /// rig exists (A12, REQ-TEST-1/2). `nil` only for a model entry written
    /// before the block existed; `DeviceProfiles.ppcp(for:)` falls back to
    /// `_default` rather than letting a declaration be built without geometry.
    public var ppcp: PpcpDeviceTimingProfile?
}

public enum DeviceProfiles {

    /// The entry used for a model identifier the data file does not list.
    ///
    /// ⚠ In the *data*, not here. An unprofiled device must still be able to
    /// declare — capability is enumerated, not looked up — and the rule its
    /// timing is assumed by is the same rule every listed model uses, so writing
    /// a second copy of it in Swift would be exactly the code-shaped device
    /// knowledge REQ-PORT-10 forbids.
    public static let defaultKey = "_default"

    /// Look up the profile for a model identifier such as "iPhone17,3".
    ///
    /// An unknown model is not an error: capability is *measured*, not looked up,
    /// so an unprofiled device still works. It displays its raw identifier and
    /// takes its PPCP timing from `_default`.
    public static func profile(for identifier: String) -> DeviceProfile {
        if let known = table[identifier] { return known }
        return DeviceProfile(marketingName: identifier, ppcp: table[defaultKey]?.ppcp)
    }

    /// The PPCP timing block to declare for a model. Never `nil` while the data
    /// file carries a `_default`; a `nil` here means the file failed to load and
    /// the declaration will refuse to be built (I31 — no invented geometry).
    public static func ppcp(for identifier: String) -> PpcpDeviceTimingProfile? {
        profile(for: identifier).ppcp ?? table[defaultKey]?.ppcp
    }

    /// The current device's model identifier, e.g. "iPhone17,3".
    public static var currentIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            // Non-failable on purpose: `machine` is a fixed-size ASCII field the
            // kernel always fills. A failable initialiser here would force a
            // meaningless nil branch, and an unprofiled identifier is already a
            // supported outcome — capability is measured, not looked up.
            // swiftlint:disable:next optional_data_string_conversion
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static let table: [String: DeviceProfile] = load()

    private static func load() -> [String: DeviceProfile] {
        guard let url = Bundle.main.url(forResource: "DeviceProfiles", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: DeviceProfile].self, from: data)
        else {
            return [:]
        }
        return decoded
    }
}
