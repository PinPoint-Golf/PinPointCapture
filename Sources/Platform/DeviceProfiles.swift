//  DeviceProfiles.swift
//  Per-model facts that no API reports, keyed by model identifier.
//
//  ⚠ REQ-PORT-10: device profiles ship as DATA keyed by device model, never as
//  code. Android's device population makes a code-based approach untenable and
//  iOS benefits equally. This file is the loader; `DeviceProfiles.json` is the
//  data, and the data is what gets edited when a new model is calibrated.
//
//  Today the profile carries only the marketing name, because rolling-shutter
//  readout time and exposure convention require the LED timecode rig
//  (REQ-TEST-1/2) and no model has been through it yet. The shape is here so
//  those fields are added to the data rather than to the code.

import Foundation

public struct DeviceProfile: Sendable, Codable {
    /// "iPhone 16" — no public API reports this, so it is data.
    public var marketingName: String

    /// REQ-EXP-3. Sensor readout time in microseconds, per capture mode.
    /// `nil` until the model has been measured on the LED timecode rig.
    /// ⛔ Never guessed, never interpolated from another model.
    public var readoutMicroseconds: Int?
}

public enum DeviceProfiles {
    /// Look up the profile for a model identifier such as "iPhone17,3".
    ///
    /// An unknown model is not an error: capability is *measured*, not looked up,
    /// so an unprofiled device still works. It simply displays its raw identifier
    /// and declares its readout time unknown.
    public static func profile(for identifier: String) -> DeviceProfile {
        if let known = table[identifier] { return known }
        return DeviceProfile(marketingName: identifier, readoutMicroseconds: nil)
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
