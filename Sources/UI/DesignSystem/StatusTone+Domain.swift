//  StatusTone+Domain.swift
//  The single mapping from a domain state to the tone it carries.
//
//  ⚠ This file exists because two screens independently grew their own version of
//  this mapping and they disagreed: one rendered `pairing` as progress-blue, the
//  other as neutral-grey. The same state must not be two colours in two places,
//  so the mapping lives here, once, where `StatusTone` is defined.
//
//  Which tone a state carries is a *design* decision, not a domain fact, which is
//  why this sits in the design system rather than on the Core types themselves.

import Foundation
import CaptureCore

public extension StatusTone {

    /// ⚠ The one colour rule, applied to the host link.
    ///
    /// `lost` is the only red here, and it colours the **host** — never capture.
    /// Capture continuing is the product's core promise, so nothing about capture
    /// state ever reaches `.error`.
    init(_ state: HostLinkState) {
        self = switch state {
        case .none: .neutral
        // In flight, so progress — the same tone as a shot being sent. The
        // twenty-exchange burst is work happening, not an idle state.
        case .pairing: .progress
        case .connected: .accent
        case .weak: .warning
        case .lost: .error
        case .resyncing: .progress
        }
    }

    /// ⚠ `inStudio` is accent because the **host confirmed** it, never because it
    /// was merely uploaded (REQ-SESS-4).
    ///
    /// A shot still sitting on the device is a normal state — the expected one,
    /// for UC-1 — and not a failure, so `onDevice` is neutral.
    ///
    /// ⚠ `delivered` (`CORE` 5.14 `present`) is **progress, not accent**. The
    /// receiver has the bytes and has not committed them; showing it in the same
    /// colour as a confirmed shot is exactly how an unconfirmed one gets treated
    /// as safe (REQ-SESS-4, I38). `failed` is the one sync state that *is*
    /// `.error`, because it is the only one that will not resolve on its own.
    init(_ syncState: ShotSyncState) {
        self = switch syncState {
        case .onDevice: .neutral
        case .sending, .delivered: .progress
        case .inStudio: .accent
        case .failed: .error
        }
    }

    /// ⚠ Thermal state never reaches `.error` either. Even `critical` is
    /// warning-orange, because the device is still capturing; if it stops
    /// capturing, that is a capture-state change and is reported as one.
    ///
    /// ⚠ `fair` is deliberately neutral, not warning. iOS reports `fair` routinely
    /// under ordinary use, so tinting it orange would spend the warning colour on
    /// a non-event and teach the user to ignore it — which is exactly what must
    /// not happen when `serious` arrives mid-session.
    init(_ thermal: ThermalState) {
        self = thermal >= .serious ? .warning : .neutral
    }
}
