//
//  PpcpLog.swift
//  PinPointCapture — PPCP lifecycle logging that leaves the device.
//

import Foundation
import OSLog

/// ⛔ **THIS EXISTS BECAUSE THE DEVICE HAD NO VOICE, AND IT COST TWO DAYS.**
///
/// During the Linux port (30 Aug 2026) two wired faults could not be diagnosed at
/// all — a link that authenticated and then never sent `link_bind`, and a link
/// accepted and dead inside the same second, seen 653 times — and the reason was
/// recorded plainly: *"we could not see PPC's side: it emits no PPCP events to
/// the device syslog, so `idevicesyslog` on a cabled phone shows only UIKit
/// noise."*
///
/// The app's existing diagnostics are `print()`, which goes to **stdout**. That is
/// visible in Xcode and nowhere else — not in `idevicesyslog`, not in Console, and
/// not on a phone plugged into a Linux box. `Logger` goes to the unified log,
/// which all three can read.
///
/// ⚠ **What may be logged, and this is `RV` 7.2b and not a style preference.**
/// No key, no `PRK`, no PSK identity, no decoded payload — none of them may reach
/// a log or a diagnostic export. Session and pairing ids MAY: the host already
/// prints them, they are how two logs are read side by side, and they are useless
/// without the key material that never appears here.
///
/// Read it with:
/// ```
/// idevicesyslog -u <udid> | grep ppcp        # cabled, any platform
/// log stream --predicate 'subsystem == "org.pinpointstudio.capture"'   # macOS
/// ```
public enum PpcpLog {

    private static let link = Logger(subsystem: subsystem, category: "ppcp.link")
    private static let wired = Logger(subsystem: subsystem, category: "ppcp.wired")
    private static let rendezvous = Logger(subsystem: subsystem, category: "ppcp.rv")

    private static let subsystem = "org.pinpointstudio.capture"

    // ⚠ `\(… , privacy: .public)` on every interpolation. Without it the unified
    // log redacts dynamic strings to `<private>` for a release build, which would
    // leave exactly the silence this type exists to end.

    /// ⛔ **BOTH SINKS, BECAUSE THE TOOL YOU HAPPEN TO HAVE MUST NOT DECIDE
    /// WHETHER THE DEVICE HAS A VOICE.** They are read by different tools and
    /// neither is a superset:
    ///
    /// * `Logger` → the unified log → `idevicesyslog` (which is what a **Linux**
    ///   box has, since `libimobiledevice` is already the usbmux prerequisite)
    ///   and Console.app.
    /// * `print()` → stdout → `devicectl … --console`, which bridges stdout only
    ///   and shows **nothing** from `Logger`. That is the tool available on a Mac
    ///   with no `libimobiledevice` installed — as this build machine is.
    ///
    /// ⚠ Discovered while trying to verify this very type: the unified log could
    /// not be read from the build Mac at all, and a device-side diagnostic nobody
    /// can read is the problem it was written to solve.
    private static func emit(_ line: String, to logger: Logger) {
        logger.notice("\(line, privacy: .public)")
        print("[ppcp] \(line)")
    }

    /// A channel was dialled, authenticated, and bound — or failed on the way.
    public static func channel(_ event: String, channel: String, detail: String = "") {
        emit("channel \(channel) \(event) \(detail)", to: link)
    }

    /// The link's own lifecycle: opening, open, closing, gone, and WHY.
    public static func linkPhase(_ phase: String, detail: String = "") {
        emit("link \(phase) \(detail)", to: link)
    }

    /// The wired presence listener: up, down, and what it is publishing.
    public static func wiredPresence(_ event: String, detail: String = "") {
        emit("presence \(event) \(detail)", to: wired)
    }

    /// Reconnection sweeps and their outcomes — the other half of "it did
    /// nothing", which was indistinguishable from "it tried and failed".
    public static func reconnect(_ event: String, detail: String = "") {
        emit("reconnect \(event) \(detail)", to: rendezvous)
    }
}
