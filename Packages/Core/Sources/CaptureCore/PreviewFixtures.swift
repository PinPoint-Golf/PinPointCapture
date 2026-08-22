//  PreviewFixtures.swift
//  Fixed sample state for SwiftUI previews and for the reviewer walkthrough.
//
//  Values are taken from the design handoff so a preview matches the mockup
//  exactly. ⚠ This is preview scaffolding, not seed data: nothing here is ever
//  persisted, sent to a host, or shown outside a preview or the review mode
//  required by REQ-STANDALONE-6.

import Foundation

public enum PreviewFixtures {
    /// A fixed clock so previews and snapshots do not drift. 21 August 2026.
    public static let sessionStart = Date(timeIntervalSince1970: 1_787_336_400) // 18:20 UTC
    /// A fixed instant on the fixture's day, so previews and snapshots do not
    /// drift. Public because screen previews build their own sample shots and
    /// gap windows from it.
    public static func at(_ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 21
        c.hour = hour; c.minute = minute; c.second = second
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c) ?? sessionStart
    }

    // MARK: - Capability (A1, A7, C1 rail)

    public static let modes: [VideoMode] = [
        VideoMode(width: 1920, height: 1080, fps: 240, lens: .wide, deliversIntrinsics: true),
        VideoMode(width: 1920, height: 1080, fps: 120, lens: .wide, deliversIntrinsics: true),
        VideoMode(width: 1920, height: 1080, fps: 120, lens: .ultraWide, deliversIntrinsics: true),
        VideoMode(width: 3840, height: 2160, fps: 60, lens: .wide, deliversIntrinsics: true)
    ]

    public static let capability = DeviceCapability(
        modelIdentifier: "iPhone17,3",
        modelName: "iPhone 16",
        claimed: modes,
        measured: MeasuredCapability(
            mode: VideoMode(width: 1920, height: 1080, fps: 150, lens: .wide,
                            deliversIntrinsics: true),
            achievedFPS: 149.6,
            droppedFrames: 0,
            thermalAtEnd: .nominal,
            measuredAt: at(18, 19, 0),
            // ⚠ `cold_sample`, not `sustained` (`CORE` 5.8b). The onboarding
            // self-test of I28 runs for seconds from cold, and a fixture that
            // said `sustained` would put the one claim 5.8b singles out —
            // "a consumer MUST NOT treat a cold sample as a sustained figure" —
            // onto every preview screen in the app.
            method: .coldSample,
            durationSeconds: 8,
            exposureSeconds: 1.0 / 1600.0,
            iso: 2200
        )
    )

    public static let storage = StorageHeadroom(estimatedSessions: 40,
                                                freeBytes: 40 * 1_000_000_000)

    // MARK: - Framing (A6)

    public static let framingMarginalLight = FramingStatus(
        inFrameAtAddress: true,
        inFrameAtTop: true,
        isSteady: true,
        light: LightAssessment(verdict: .marginal, exposureSeconds: 1.0 / 1600.0,
                               iso: 2200, fps: 150),
        viewpoint: Viewpoint(angle: .downTheLine, handedness: .rightHanded)
    )

    // MARK: - Host link (B2, B3 — all four states)

    public static let hostName = "Bay 3 — Mac Studio"
    public static let hostVersion = "PinPoint Studio 0.9.4 · protocol PPCP 1.0"

    /// B2, mid-burst: "14 of 20 exchanges · offset −3.184 ms · drift 18 ppm".
    public static let pairing = HostLink(
        state: .pairing, hostName: hostName, hostVersion: hostVersion,
        clock: ClockAgreement(offsetMilliseconds: -3.184, offsetSigmaMilliseconds: 0.21,
                              driftPPM: 18, exchangesCompleted: 14, exchangesExpected: 20)
    )

    public static let connected = HostLink(
        state: .connected, hostName: hostName, hostVersion: hostVersion,
        clock: ClockAgreement(offsetMilliseconds: -3.184, offsetSigmaMilliseconds: 0.21,
                              driftPPM: 18, lastImpactResidualMilliseconds: 0.4),
        lastSeen: at(19, 36, 2)
    )

    public static let weak = HostLink(
        state: .weak, hostName: hostName, hostVersion: hostVersion,
        clock: ClockAgreement(offsetMilliseconds: -3.20, offsetSigmaMilliseconds: 1.9,
                              driftPPM: 18, lastImpactResidualMilliseconds: 1.9),
        throughputMbitPerSecond: 4.1,
        lastSeen: at(19, 36, 2)
    )

    /// ⚠ In this state the UI's first telemetry row is `Capture — still armed`,
    /// above the error. That ordering is the priority rule made visible and must
    /// not be rearranged to put the failure first.
    public static let lost = HostLink(
        state: .lost, hostName: hostName, hostVersion: hostVersion,
        lastSeen: at(14, 38, 12)
    )

    public static let resyncing = HostLink(
        state: .resyncing, hostName: hostName, hostVersion: hostVersion,
        clock: ClockAgreement(offsetMilliseconds: -3.191, offsetSigmaMilliseconds: 0.24,
                              driftPPM: 18),
        lastSeen: at(14, 44, 3),
        gap: GapWindow(start: at(14, 38, 12), end: at(14, 44, 3), shotsInGap: 6)
    )

    // MARK: - Session (C1, C3)

    public static let shots: [Shot] = [
        Shot(ordinal: 41, impact: at(19, 36, 2), duration: 3.0, club: "7 iron",
             syncState: .inStudio, detectionConfidence: 0.97),
        Shot(ordinal: 40, impact: at(19, 35, 14), duration: 3.0, club: "7 iron",
             syncState: .inStudio, detectionConfidence: 0.96),
        Shot(ordinal: 39, impact: at(19, 34, 41), duration: 3.0, club: "7 iron",
             syncState: .sending(progress: 0.61), detectionConfidence: 0.94),
        Shot(ordinal: 38, impact: at(19, 33, 58), duration: 3.0, club: nil,
             syncState: .onDevice, detectionConfidence: nil, hasImpact: false),
        Shot(ordinal: 37, impact: at(19, 31, 20), duration: 3.0, club: "9 iron",
             syncState: .onDevice, detectionConfidence: 0.95),
        Shot(ordinal: 36, impact: at(19, 30, 47), duration: 3.0, club: "9 iron",
             syncState: .onDevice, detectionConfidence: 0.93)
    ]

    /// Shots 1–35, which the C3 list scrolls to rather than showing.
    ///
    /// The design's headline numbers are "41 shots · 18:20 to 19:36 · 12 still to
    /// send", so the fixture has to actually contain 41 shots and 12 outstanding
    /// ones — otherwise C1's *Session · n* button and C3's subtitle both quote a
    /// number the screen cannot justify.
    ///
    /// ⚠ 1–27 are `inStudio` and 28–35 are not, which together with the six named
    /// shots gives exactly 29 confirmed and 12 outstanding. Note the ordering is
    /// the design's own and is illustrative: an ordered, oldest-first queue
    /// (REQ-SESS-6) would not leave shots 40 and 41 confirmed while 36–39 are
    /// still waiting. Reproduced as drawn rather than corrected, because these
    /// screens are what a reviewer compares against the PNG.
    static let earlierShots: [Shot] = (1...35).map { ordinal in
        Shot(
            ordinal: ordinal,
            impact: at(18, 20 + (ordinal * 2), 0),
            duration: 3.0,
            club: ordinal > 20 ? "9 iron" : "pitching wedge",
            syncState: ordinal <= 27 ? .inStudio : .onDevice,
            detectionConfidence: 0.95
        )
    }

    public static let session = Session(
        name: "Wednesday range",
        start: at(18, 20, 0),
        end: at(19, 36, 0),
        shots: earlierShots + shots.reversed()
    )

    public static let transferQueue = TransferQueue(
        pendingShotIDs: session.shots.filter {
            if case .inStudio = $0.syncState { false } else { true }
        }.map(\.id),
        isPaused: false,
        bytesRemaining: 218_000_000,
        currentShotOrdinal: 30,
        totalShots: 41
    )

    // MARK: - Capture (C1)

    public static let armed = CaptureStatus(
        state: .armed, isReviewing: false, thermal: .nominal,
        bufferSeconds: 10.0, achievedFPS: 149.6
    )

    // MARK: - Permissions (A4)

    public static let permissionsBeforeNetwork = Permissions(
        camera: .allowed, microphone: .allowed,
        localNetwork: .notRequested, motion: .allowed
    )
}
