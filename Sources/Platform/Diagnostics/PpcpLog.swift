//
//  PpcpLog.swift
//  PinPointCapture — PPCP lifecycle logging that leaves the device.
//

import Foundation
import OSLog
import CaptureCore

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
    private static let transfer = Logger(subsystem: subsystem, category: "ppcp.transfer")

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
        // ⛔ **THE THIRD SINK, AND THE ONLY ONE THAT CAN BE READ WITHOUT
        // BREAKING WHAT IT IS MEASURING.**
        //
        // The other two are both unreachable in practice on a cabled phone:
        // `idevicesyslog` reads the legacy syslog relay and carries no os_log at
        // all, and `devicectl … --console` bridges stdout while holding a
        // CoreDevice tunnel that re-enumerates the device — the kernel logs
        // `setConfigurationGated`, every usbmux tunnel dies, and the link under
        // measurement is killed by the act of watching it (1 Sept 2026: zero
        // re-enumerations in the one run that did not use it).
        //
        // So every category also goes to the file PpcpDiagnostics already keeps
        // — bounded, off-thread, non-throwing — which comes off with a plain
        // `devicectl device copy from` and touches nothing.  That file existed
        // for the channel lifecycle and carried none of this; a transfer that
        // stalled could not be seen at all.
        //
        // ⚠ Same secrets rule as the other two: no key material, no PRK, no PSK
        // identity, no payload (RV 7.2b, CORE 13d). Session and pairing ids are
        // permitted, and nothing here composes anything else.
        PpcpDiagnostics.note(line)
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

    /// ⛔ **THE PAYLOAD TRANSFER, WHICH HAD NO VOICE AT ALL.**
    ///
    /// A Capture is announced on control and its bytes follow on bulk. When the
    /// bytes did not follow, every surface said the same nothing: the host saw
    /// `transfer: pending` and waited, the phone's own row said `sending`, and
    /// the drain loop swallowed whatever it threw behind a `try?` and slept for
    /// 20 ms before trying again, for ever.
    ///
    /// Measured 1 Sept against PinPointStudio: five Captures announced against
    /// real Shots, `bulk 0/0` on the link, and not one line on either side
    /// saying why. This is that line.
    public static func transferEvent(_ event: String, detail: String = "") {
        emit("transfer \(event) \(detail)", to: transfer)
    }

    /// `PPCP-MSG` §12 — the torch: what was commanded, what the hardware then
    /// did, and every change nobody commanded.  Added 2 Sept 2026 when a torch
    /// the host had lit went out on arm and no line at either end said which
    /// of arm's five steps put it out.
    public static func actuator(_ event: String, detail: String = "") {
        emit("actuator \(event) \(detail)", to: link)
    }
}
