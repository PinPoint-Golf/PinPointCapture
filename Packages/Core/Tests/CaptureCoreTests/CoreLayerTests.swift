//  CoreLayerTests.swift
//  Tests for the platform-neutral Core layer.
//
//  These pin the formatting and state rules that carry the design. Each test
//  names the claim it pins — a test that only asserts the code does what it does
//  proves nothing.

import Foundation
import Testing
@testable import CaptureCore

@Suite("Capability")
struct CapabilityTests {

    @Test("The A1 sentence is built from enumerated formats, not a spec sheet")
    func summaryUsesEnumeratedFormats() {
        let capability = DeviceCapability(
            modelIdentifier: "iPhone17,3",
            modelName: "iPhone 16",
            claimed: [
                VideoMode(width: 1920, height: 1080, fps: 240, lens: .wide),
                VideoMode(width: 1920, height: 1080, fps: 120, lens: .ultraWide)
            ]
        )
        let sentence = capability.summarySentence
        #expect(sentence.contains("iPhone 16"))
        #expect(sentence.contains("1080p"))
        #expect(sentence.contains("240 fps"))
        #expect(sentence.contains("wide"))
    }

    @Test("A device with no usable format says so rather than claiming nothing")
    func emptyCapabilityIsHonest() {
        let capability = DeviceCapability(modelIdentifier: "x", modelName: "Unknown",
                                          claimed: [])
        #expect(capability.summarySentence.contains("no usable capture format"))
        #expect(capability.clearsGate() == false)
    }

    /// ⛔ REQ-CAP-5. The floor is host policy. A device declaring 60 fps is not
    /// malformed — it is honest, and the host is what refuses it.
    @Test("The ingest floor is host policy, so a stricter host rejects more")
    func ingestFloorIsPolicyNotProtocol() {
        let sixtyOnly = DeviceCapability(
            modelIdentifier: "old", modelName: "Old phone",
            claimed: [VideoMode(width: 1920, height: 1080, fps: 60, lens: .wide)]
        )
        #expect(sixtyOnly.clearsGate(.pinPointStudioCurrent) == false)
        // A host that accepts 60 fps takes the same device without any change to
        // the device's declaration.
        let lenient = HostIngestPolicy(minimumHeight: 1080, minimumFPS: 60)
        #expect(sixtyOnly.clearsGate(lenient) == true)
    }

    @Test("A 4K-only device fails a 1080p floor on height, not on rate")
    func heightIsPartOfTheGate() {
        let lowRes = DeviceCapability(
            modelIdentifier: "x", modelName: "x",
            claimed: [VideoMode(width: 1280, height: 720, fps: 240, lens: .wide)]
        )
        #expect(lowRes.clearsGate() == false)
    }

    /// ⚠ Regression. An iPhone 16 enumerates 4032×3024 at 30 fps — a stills
    /// format that beats 1080p240 on height. Ranking by resolution put it on A1's
    /// capability card, next to a verdict that had been computed from a different
    /// mode entirely.
    @Test("A stills format never wins the capability card over a high-speed one")
    func stillsFormatDoesNotWin() {
        let capability = DeviceCapability(
            modelIdentifier: "iPhone17,3", modelName: "iPhone 16",
            claimed: [
                VideoMode(width: 4032, height: 3024, fps: 30, lens: .wide),
                VideoMode(width: 1920, height: 1080, fps: 240, lens: .wide),
                VideoMode(width: 3840, height: 2160, fps: 60, lens: .wide)
            ]
        )
        let best = try? #require(capability.bestMode)
        #expect(best?.fps == 240)
        #expect(best?.height == 1080)
        #expect(capability.summarySentence.contains("1080p"))
        #expect(capability.summarySentence.contains("4032") == false)
    }

    /// The card must not describe one mode and judge another.
    @Test("The verdict and the described mode agree")
    func verdictDescribesTheSameMode() {
        let stillsOnly = DeviceCapability(
            modelIdentifier: "x", modelName: "x",
            claimed: [VideoMode(width: 4032, height: 3024, fps: 30, lens: .wide)]
        )
        #expect(stillsOnly.clearsGate() == false)
        #expect(stillsOnly.verdictSentence().contains("Below what a host will accept"))
    }

    /// ⚠ Regression. An iPhone 16 offers 1080p240 on BOTH the wide and the
    /// ultra-wide lens, so an arbitrary tie-break selected ultra-wide and A7 read
    /// "Lens — Ultra-wide · locked". Ultra-wide is the cramped-studio fallback
    /// (REQ-OPT-6), carries heavy distortion, and lens choice is
    /// calibration-affecting and forbidden to change mid-session.
    @Test("Wide wins a tie against ultra-wide at the same resolution and rate")
    func wideWinsTheLensTieBreak() {
        let capability = DeviceCapability(
            modelIdentifier: "iPhone17,3", modelName: "iPhone 16",
            claimed: [
                VideoMode(width: 1920, height: 1080, fps: 240, lens: .ultraWide),
                VideoMode(width: 1920, height: 1080, fps: 240, lens: .wide)
            ]
        )
        #expect(capability.bestMode?.lens == .wide)

        // ...and the order they enumerate in must not change the answer.
        let reversed = DeviceCapability(
            modelIdentifier: "iPhone17,3", modelName: "iPhone 16",
            claimed: capability.claimed.reversed()
        )
        #expect(reversed.bestMode?.lens == .wide)
    }

    /// A tie-break must never override a genuinely better mode.
    @Test("Lens preference does not outrank frame rate")
    func lensNeverBeatsFrameRate() {
        let capability = DeviceCapability(
            modelIdentifier: "x", modelName: "x",
            claimed: [
                VideoMode(width: 1920, height: 1080, fps: 120, lens: .wide),
                VideoMode(width: 1920, height: 1080, fps: 240, lens: .ultraWide)
            ]
        )
        #expect(capability.bestMode?.fps == 240)
        #expect(capability.bestMode?.lens == .ultraWide)
    }

    @Test("Measured rate is reported to one decimal, as the design shows it")
    func measuredSummaryFormatting() {
        let measured = MeasuredCapability(
            mode: VideoMode(width: 1920, height: 1080, fps: 150, lens: .wide),
            achievedFPS: 149.6, droppedFrames: 0,
            thermalAtEnd: .nominal, measuredAt: Date(),
            method: .coldSample, durationSeconds: 8
        )
        #expect(measured.displaySummary == "149.6 fps · 0 drops")
    }

    @Test("Thermal state orders from nominal to critical so comparisons work")
    func thermalOrdering() {
        #expect(ThermalState.nominal < ThermalState.fair)
        #expect(ThermalState.fair < ThermalState.serious)
        #expect(ThermalState.serious < ThermalState.critical)
    }
}

@Suite("Host link")
struct HostLinkTests {

    /// The design writes this with U+2212 MINUS SIGN, not a hyphen. It is a
    /// measured value in a monospaced column, and a hyphen sits at the wrong
    /// height and the wrong width.
    @Test("Clock offset uses a real minus sign and three decimal places")
    func offsetFormatting() {
        let clock = ClockAgreement(offsetMilliseconds: -3.184,
                                   offsetSigmaMilliseconds: 0.21, driftPPM: 18)
        #expect(clock.offsetText == "\u{2212}3.184 ms ± 0.21")
        #expect(clock.offsetText.contains("-") == false)
    }

    /// ⛔ **What B3 actually shows.** Found live against real PinPointStudio
    /// (26 August 2026): a real, converged relation between two peers' own
    /// since-boot clocks can carry an offset of minus several million
    /// milliseconds — correct, and meaningless to a golfer. `agreementText`
    /// is the uncertainty alone, which is the number that answers a real
    /// question regardless of how large the underlying offset is.
    @Test("Clock agreement shows the uncertainty, not the offset")
    func agreementFormattingIgnoresTheOffsetMagnitude() {
        let huge = ClockAgreement(offsetMilliseconds: -7_569_907.589,
                                  offsetSigmaMilliseconds: 17.26, driftPPM: 18)
        #expect(huge.agreementText == "± 17.26 ms")
        let settled = ClockAgreement(offsetMilliseconds: -3.184,
                                     offsetSigmaMilliseconds: 0.21, driftPPM: 18)
        #expect(settled.agreementText == "± 0.21 ms")
    }

    /// ⚠ REQ-SYNC-3: the estimate is filtered, never stepped. The word "filtered"
    /// in the UI is the visible half of that promise.
    @Test("Drift is reported as filtered")
    func driftSaysFiltered() {
        let clock = ClockAgreement(offsetMilliseconds: 0, offsetSigmaMilliseconds: 0,
                                   driftPPM: 18)
        #expect(clock.driftText == "18 ppm, filtered")
    }

    /// ⛔ The three sentences the handoff marks "reproduce verbatim".
    @Test("The four B3 state sentences are the design's own words")
    func stateCopyIsVerbatim() {
        #expect(HostLinkState.lost.explanation.hasPrefix("Capture never stops for this."))
        #expect(HostLinkState.weak.explanation
            .hasPrefix("Shots are still being correlated the moment you hit them."))
        #expect(HostLinkState.resyncing.explanation
            .hasPrefix("Twenty fresh exchanges before anything is sent"))
        #expect(HostLinkState.connected.explanation
            == "Every shot is reaching Studio as you hit it.")
    }

    @Test("Every link state has a title and an action, including the ones with no host")
    func everyStateIsRenderable() {
        for state in HostLinkState.allCases {
            #expect(state.title.isEmpty == false)
            #expect(state.actionTitle.isEmpty == false)
            #expect(state.explanation.isEmpty == false)
        }
    }
}

@Suite("Session and shots")
struct SessionTests {

    /// ⚠ "In Studio" means confirmed by the host, never merely uploaded, so a
    /// shot in flight is still counted as outstanding.
    @Test("Only host-confirmed shots stop counting as still to send")
    func onlyConfirmedShotsAreDone() {
        let session = Session(name: "t", start: Date(), shots: [
            Shot(ordinal: 1, impact: Date(), duration: 3, syncState: .inStudio),
            Shot(ordinal: 2, impact: Date(), duration: 3, syncState: .sending(progress: 0.99)),
            Shot(ordinal: 3, impact: Date(), duration: 3, syncState: .onDevice)
        ])
        #expect(session.shotsStillToSend == 2)
    }

    /// Three words, not an icon — a golfer glancing from the mat reads a state.
    @Test("Sync state renders as a short phrase, with progress rounded to a percent")
    func syncStateText() {
        #expect(ShotSyncState.onDevice.displayText == "On device")
        #expect(ShotSyncState.inStudio.displayText == "In Studio")
        #expect(ShotSyncState.sending(progress: 0.61).displayText == "Sending 61%")
    }

    @Test("A practice swing is labelled by its lack of impact, not by a club")
    func practiceSwingLabelling() {
        let practice = Shot(ordinal: 38, impact: Date(), duration: 3,
                            club: nil, hasImpact: false)
        #expect(practice.displayTitle == "38 · practice swing")
        #expect(practice.displayDetail.hasSuffix("no impact"))
    }

    @Test("Transfer progress reads as shot-of-total with megabytes remaining")
    func transferQueueText() {
        let queue = TransferQueue(pendingShotIDs: [UUID()], bytesRemaining: 218_000_000,
                                  currentShotOrdinal: 30, totalShots: 41)
        #expect(queue.displayDetail == "shot 30 of 41 · 218 MB left")
    }

    /// ⚠ Pause is user-level. Backpressure is automatic and separate — a paused
    /// queue is not a stalled one.
    /// ⛔ **`In Studio` is the receiver's word and nothing else.** 5.14h makes
    /// `capture_committed` the host's statement that it holds the bytes, and
    /// 8.4b forbids an owner setting `confirmed` on its own authority — so a
    /// send completing is `delivered`, not `inStudio`, and the two states exist
    /// precisely to keep "sent" and "kept" apart.
    ///
    /// ⚠ **And progress is computed from the receiver's `acked_index`**, because
    /// the library reports `in_flight` with a hardcoded zero fraction: what a
    /// screen shows is how far the far end says it has got, not how much this
    /// end has handed to a socket.
    @Test("Progress comes from the receiver's acked index, and In Studio from its commit")
    func progressAndConfirmationComeFromTheReceiver() {
        let chunk = Int64(PayloadTransferQueue.chunkBytes)

        // Nothing acked yet: in flight, and honestly at zero.
        #expect(progress(ShotSyncState.sending(bytes: UInt64(chunk * 10), ackedIndex: nil, chunkBytes: PayloadTransferQueue.chunkBytes)) == 0)

        // Index 4 acked means five chunks are known received (8.3d — the index
        // is inclusive, and resumption restarts *after* it).
        let half = progress(ShotSyncState.sending(bytes: UInt64(chunk * 10), ackedIndex: 4, chunkBytes: PayloadTransferQueue.chunkBytes))
        #expect(abs(half - 0.5) < 0.0001)

        // ⚠ Never over one, whatever the far end says: a receiver acking past
        // the announced length is its bug and must not become our progress bar
        // reading 140%.
        #expect(progress(ShotSyncState.sending(bytes: UInt64(chunk), ackedIndex: 99, chunkBytes: PayloadTransferQueue.chunkBytes)) == 1)

        // The states a receiver can put a Capture in, and which of them mean
        // this device may stop holding the bytes (5.14g).
        #expect(ShotSyncState.delivered.isConfirmedByReceiver == false,
                "sent is not kept")
        #expect(ShotSyncState.inStudio.isConfirmedByReceiver)
        #expect(ShotSyncState.inStudio.displayText == "In Studio")
    }

    @Test("A paused queue is not active even with work outstanding")
    func pauseIsUserLevel() {
        var queue = TransferQueue(pendingShotIDs: [UUID()], totalShots: 1)
        #expect(queue.isActive == true)
        queue.isPaused = true
        #expect(queue.isActive == false)
    }
}

@Suite("Framing and light")
struct FramingTests {

    @Test("The light row shows shutter, ISO and rate in the design's own form")
    func lightMeasurementText() {
        let light = LightAssessment(verdict: .marginal, exposureSeconds: 1.0 / 1600.0,
                                    iso: 2200, fps: 150)
        #expect(light.measurementText == "1/1600 s · ISO 2200 · 150 fps")
    }

    /// ⚠ Warnings never block arming. They state the consequence and offer the
    /// trade — so a marginal verdict must always carry a consequence to state.
    @Test("A degraded verdict always explains the consequence")
    func degradedVerdictsExplainThemselves() {
        let marginal = LightAssessment(verdict: .marginal, exposureSeconds: 1.0 / 1600.0,
                                       iso: 2200, fps: 150)
        #expect(marginal.consequenceText != nil)
        let good = LightAssessment(verdict: .good, exposureSeconds: 1.0 / 500.0,
                                   iso: 200, fps: 150)
        #expect(good.consequenceText == nil)
    }

    @Test("The framing check passes only when every check and the light pass")
    func framingRequiresEverything() {
        var status = PreviewFixtures.framingMarginalLight
        #expect(status.allChecksPass == false)   // light is marginal
        status.light = LightAssessment(verdict: .good, exposureSeconds: 1.0 / 500.0,
                                       iso: 200, fps: 150)
        #expect(status.allChecksPass == true)
        status.isSteady = .fail
        #expect(status.allChecksPass == false)
        // ⚠ And a check nobody ran is not a pass either — the distinction a
        // `Bool` could not express, and the reason A6 could show an unearned tick.
        status.isSteady = .notChecked
        #expect(status.allChecksPass == false)
    }

    @Test("The device reports its own viewpoint rather than asking")
    func viewpointSelfClassification() {
        let viewpoint = Viewpoint(angle: .downTheLine, handedness: .rightHanded)
        #expect(viewpoint.displayText == "DTL · Right-handed")
    }
}

@Suite("Permissions")
struct PermissionsTests {

    /// ⚠ REQ-DISC-6 / §11. Refusing local network costs a golfer a network, not a
    /// session. Capture needs camera and microphone and nothing else.
    @Test("Capture survives a refused local network")
    func localNetworkIsNotRequiredForCapture() {
        let permissions = Permissions(camera: .allowed, microphone: .allowed,
                                      localNetwork: .denied, motion: .denied)
        #expect(permissions.canCapture == true)
    }

    @Test("Capture requires camera and microphone")
    func captureNeedsCameraAndMic() {
        #expect(Permissions(camera: .allowed, microphone: .denied).canCapture == false)
        #expect(Permissions(camera: .denied, microphone: .allowed).canCapture == false)
    }

    /// iOS exposes no API to read local-network permission back, so `.unknown`
    /// must be expressible rather than collapsed into allowed or denied.
    @Test("Local network permission can be genuinely unknown")
    func localNetworkStateIsInferable() {
        #expect(PermissionState.unknown.displayText.isEmpty == false)
    }
}

@Suite("Preview fixtures")
struct FixtureTests {

    /// The fixtures are what a reviewer walks through, so they must match the
    /// design's numbers exactly or the walkthrough proves nothing.
    @Test("Fixtures carry the handoff's exact telemetry")
    func fixturesMatchTheDesign() {
        #expect(PreviewFixtures.connected.clock?.offsetText == "\u{2212}3.184 ms ± 0.21")
        #expect(PreviewFixtures.capability.measured?.displaySummary == "149.6 fps · 0 drops")
        #expect(PreviewFixtures.session.name == "Wednesday range")
        // The design's headline: "41 shots · 18:20 to 19:36 · 12 still to send".
        // C1's *Session · n* button quotes this count, so it has to be real.
        #expect(PreviewFixtures.session.shots.count == 41)
        #expect(PreviewFixtures.session.shotsStillToSend == 12)
        #expect(PreviewFixtures.transferQueue.displayDetail == "shot 30 of 41 · 218 MB left")
        #expect(PreviewFixtures.storage.displayText == "about 40 sessions")
    }

    @Test("The pairing fixture is mid-burst, so B2 shows real progress")
    func pairingIsMidBurst() {
        let clock = PreviewFixtures.pairing.clock
        #expect(clock?.exchangesCompleted == 14)
        #expect(clock?.exchangesExpected == 20)
    }
}



/// Reads the fraction back out, so the assertions above read as arithmetic.
func progress(_ state: ShotSyncState) -> Double {
    if case .sending(let fraction) = state { fraction } else { -1 }
}
