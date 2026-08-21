//
//  CaptureScreenStyle.swift
//  PinPointCapture — C1 / C2 / C3
//
//  Small formatting and tone decisions shared by the three capture screens.
//
//  ⚠ This is NOT a design-system component and must not become one. It holds no
//  views: it is the handful of mappings that C1, C2 and C3 would otherwise
//  duplicate — how a sync state picks its ``StatusTone``, how a host name is
//  shortened for a chip, how a measured number is written out.
//

import SwiftUI
import CaptureCore

enum CaptureScreenStyle {

    // MARK: Sync state

    /// The tone a per-shot sync state carries.
    ///
    /// ⚠ `inStudio` is accent because the *host confirmed* it, never because it
    /// was merely uploaded (REQ-SESS-4). Nothing here is ever `.error`: a shot
    /// still sitting on the device is a normal state, not a failure.
    static func tone(for syncState: ShotSyncState) -> StatusTone {
        StatusTone(syncState)
    }

    /// The lower-case phrase used in C1's one-line last-shot summary,
    /// "12 s ago · sent, confirmed". The `inStudio` wording is verbatim from the
    /// handoff; the other two match its register.
    static func lastShotPhrase(for syncState: ShotSyncState) -> String {
        switch syncState {
        case .onDevice: "held on this device"
        case .sending(let progress): "sending \(Int((progress * 100).rounded()))%"
        case .inStudio: "sent, confirmed"
        }
    }

    // MARK: Host

    /// `"Bay 3 — Mac Studio"` -> `"Bay 3"`.
    ///
    /// C1's chip and C3's transfer banner both want the bay, not the machine:
    /// the long form is a *name* and belongs on B2/B3 where there is room for it.
    static func shortHostName(_ hostName: String?) -> String? {
        guard let hostName else { return nil }
        let bay = hostName.split(separator: "\u{2014}", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespaces) ?? hostName
        return bay.isEmpty ? hostName : bay
    }

    /// The tone of the C1 host chip.
    ///
    /// ⚠ Red here is about the *host*, never about capture: capture keeps its
    /// accent pill whatever this says.
    static func tone(for hostState: HostLinkState) -> StatusTone {
        StatusTone(hostState)
    }

    /// SF Symbol for the host chip. From the handoff's symbol list only.
    static func symbol(for hostState: HostLinkState) -> String {
        switch hostState {
        case .none, .lost: "wifi.slash"
        case .pairing, .connected, .weak, .resyncing: "wifi"
        }
    }

    // MARK: Measured numbers
    //
    // Everything below is set in SF Mono by its call site: these are numbers the
    // user could not have guessed.

    /// `149.6`
    static func fpsText(_ fps: Double) -> String { String(format: "%.1f", fps) }

    /// `10.0 s`
    static func bufferText(_ seconds: Double) -> String { String(format: "%.1f s", seconds) }

    /// `0.4 ms`, or `—` when there is no host to be in agreement with.
    static func residualText(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "\u{2014}" }
        return String(format: "%.1f ms", milliseconds)
    }

    /// A residual is a verdict as well as a number: accent while it is inside a
    /// fraction of a frame, warning once it is not. Never error — a poor
    /// residual does not stop capture.
    static func residualTone(_ milliseconds: Double?) -> StatusTone {
        guard let milliseconds else { return .neutral }
        return abs(milliseconds) <= 1.0 ? .accent : .warning
    }

    /// Thermal state never reads as an error on a capture screen (§9.2).
    static func tone(for thermal: ThermalState) -> StatusTone {
        StatusTone(thermal)
    }

    /// `12 s ago`
    static func elapsedText(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "\(Int(seconds.rounded())) s ago" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded(.down))) min ago" }
        return "\(Int((seconds / 3600).rounded(.down))) h ago"
    }

    /// A signed time on the C2 timeline, always four decimals and always
    /// relative to impact: `0.0000 s`, `− 0.0067 s`, `+1.2 s`.
    ///
    /// ⚠ REQ-REPLAY-2: replay is addressed in *time*, zeroed on impact, never in
    /// frame index. There is deliberately no frame-number formatter here.
    static func impactRelativeText(_ seconds: TimeInterval, decimals: Int = 4) -> String {
        let magnitude = String(format: "%.\(decimals)f", abs(seconds))
        if seconds > 0 { return "+\(magnitude) s" }
        if seconds < 0 { return "\u{2212} \(magnitude) s" }
        return "\(magnitude) s"
    }
}
