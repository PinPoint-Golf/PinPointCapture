//  PpcpDiagnostics.swift
//
//  ⚠ **A DIAGNOSTIC RECORD, NOT A LOG AND NOT TELEMETRY.**  It exists because a
//  phone on a desk cannot be watched: the link was dropping every 30-100 s on a
//  cable and the only account of why lived on a screen nobody could stare at
//  (1 Sep 2026).  PinPointStudio could see "the far end went away" and never
//  which end went first.
//
//  ⛔ **NOTHING SENSITIVE.**  Channel numbers, error text and timestamps only —
//  no key material, no payload, no peer identity beyond the channel it was on
//  (`RV` 7.2b, and `CORE` 13d makes telemetry off-limits: this file never leaves
//  the device except when a developer copies it off deliberately).
//
//  Retrieve with:
//    xcrun devicectl device copy from --device <udid> \
//      --domain-type appDataContainer --domain-identifier org.pinpointstudio.capture \
//      --source Documents/ppcp-diag.log --destination /tmp/

import Foundation

public enum PpcpDiagnostics {

    /// Bounded so a long session cannot fill the container: the newest entries
    /// are the ones being asked about, and an unbounded diagnostic file is a bug
    /// of its own.
    private static let maxBytes = 256 * 1024

    private static let queue = DispatchQueue(label: "org.pinpointstudio.capture.diag")

    /// ⚠ A function, not a stored global: Swift 6 strict concurrency forbids
    /// mutable global state, and this is cheap enough to recompute on the
    /// diagnostic queue where it is used.
    private static func fileURL() -> URL? {
        guard let dir = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("ppcp-diag.log")
    }

    /// ⚠ Off the caller's thread and never throwing: a diagnostic that can break
    /// the thing it observes is worse than no diagnostic.
    public static func note(_ line: String) {
        let stamped = Self.stamp() + " " + line + "\n"
        queue.async {
            guard let url = Self.fileURL(),
                  let data = stamped.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
            Self.trimIfNeeded(url)
        }
    }

    public static func channelFailed(_ channel: PpcpChannel, _ error: any Error) {
        note("channel \(name(channel)) FAILED — \(String(describing: error))")
    }

    public static func channelEnded(_ channel: PpcpChannel) {
        note("channel \(name(channel)) end-of-stream (clean)")
    }

    public static func channelOpened(_ channel: PpcpChannel) {
        note("channel \(name(channel)) open")
    }

    public static func linkClosing(_ reason: String) {
        note("link closing — \(reason)")
    }

    public static func session(_ what: String) {
        note("session — \(what)")
    }

    private static func name(_ c: PpcpChannel) -> String {
        switch c {
        case .control: return "0/control"
        case .bulk:    return "1/bulk"
        case .preview: return "2/preview"
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    /// Keeps the tail, drops the head — the run that just failed is the one worth
    /// having.
    private static func trimIfNeeded(_ url: URL) {
        guard let size = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int,
              size > maxBytes,
              let data = try? Data(contentsOf: url) else { return }
        let keep = data.suffix(maxBytes / 2)
        try? keep.write(to: url)
    }
}
