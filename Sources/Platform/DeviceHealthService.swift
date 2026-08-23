//  DeviceHealthService.swift
//  Thermal, storage and battery, as `CORE` 7.4b asks for them.
//
//  ⚠ REQ-PORT-3. `ProcessInfo.thermalState`, `UIDevice.batteryLevel` and the
//  volume resource keys appear here; what leaves is `DeviceHealth`, which is
//  three numbers and an ordinal.
//
//  ⛔ `CORE` §5.8: `ThermalLevel` is "an ordinal protocol vocabulary, **not a
//  platform passthrough**". The mapping from iOS's four states onto the
//  protocol's four is the specification's own table and lives in
//  `ThermalState.ppcpLevel`; this file's job is only to read the platform and
//  hand over a `ThermalState`.

import Foundation
import UIKit
import CaptureCore

public enum DeviceHealthService {

    /// The current reading.
    ///
    /// ⚠ Cheap enough for the heartbeat (`CORE` 7.4a, default one second) and
    /// deliberately not cached: 7.4b exists so a host "reports degradation rather
    /// than silently accepting worse data", and a cached thermal state is exactly
    /// a host being told the device is fine while it throttles.
    public static func current() -> DeviceHealth {
        DeviceHealth(thermal: thermalState,
                     storageFreeBytes: freeBytes,
                     batteryPercent: batteryPercent,
                     isCharging: isCharging)
    }

    public static var thermalState: ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    /// ⚠ `volumeAvailableCapacityForImportantUsage`, not `volumeAvailableCapacity`
    /// — the latter counts space the system will not actually give up, and a
    /// device that refuses to arm on storage (5.14g1, REQ-OFF-2) must refuse on
    /// the number it can really write into.
    public static var freeBytes: UInt64 {
        let value = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
        return UInt64(max(0, value))
    }

    /// ⛔ `nil` rather than a number when the platform will not say. Battery
    /// monitoring is opt-in on iOS and reports `-1` when it is off or on a
    /// simulator; passing that on as a percentage — or substituting 100 — is the
    /// "absence never means zero" rule of `CORE` 5.1 broken in the most
    /// consequential direction, since a host uses this to decide whether a device
    /// will survive a session.
    public static var batteryPercent: Int? {
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        if wasMonitoring == false { device.isBatteryMonitoringEnabled = true }
        defer { if wasMonitoring == false { device.isBatteryMonitoringEnabled = false } }

        let level = device.batteryLevel
        guard level >= 0 else { return nil }
        return Int((level * 100).rounded())
    }

    /// `MSG` 5.4 — optional beside `battery_pct`, and ⛔ `nil` for the same
    /// reason: `.unknown` is what a simulator reports, and a host reading `false`
    /// would conclude the device is running down when nobody has looked.
    ///
    /// ⚠ `.full` counts as charging. It means the cable is in, which is the
    /// question a host is asking — "will this device survive the session" — and
    /// not the narrower one about current flow.
    public static var isCharging: Bool? {
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        if wasMonitoring == false { device.isBatteryMonitoringEnabled = true }
        defer { if wasMonitoring == false { device.isBatteryMonitoringEnabled = false } }

        switch device.batteryState {
        case .charging, .full: return true
        case .unplugged: return false
        case .unknown: return nil
        @unknown default: return nil
        }
    }
}
