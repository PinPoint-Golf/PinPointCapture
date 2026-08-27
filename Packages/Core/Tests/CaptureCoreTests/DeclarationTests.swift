//  DeclarationTests.swift
//  The device's `Peer` declaration, against `libppcp`'s own validators.
//
//  ⚠ **These are the device half of CT-I4, CT-I19, CT-I22, CT-I28, CT-I31 and
//  CT-S7 assertions 1–3.** They run on the host in milliseconds because the
//  declaration is built in Core out of neutral inputs — the platform's
//  contribution is a `DeviceCapability` and a JSON block, and both are values.
//
//  ⛔ **What they cannot do, and `CONF` §2c says why.** "An implementation tested
//  only against itself will pass every one of them by accident — most dangerously
//  I31, where an unmeasured offset declared as `0` is correct relative to another
//  implementation that also declared `0`." CT-S7 assertion 4 — the one that
//  catches a hardcoded zero, by converting against a synthetic peer that declares
//  a *non-zero* measured offset — needs `ppcp-sim` (L13) and is not here. These
//  tests assert the shape; that assertion asserts the value.

import Foundation
import Testing
import CPPCP
@testable import CaptureCore

@Suite("Peer declaration — CORE §5.2–5.8")
struct DeclarationTests {

    // MARK: Fixtures

    /// ⚠ **The same 1080p240 on the wide and the ultra-wide, deliberately.**
    /// `CORE` 5.6d names exactly this case: "a device offering the same profile
    /// on both a wide and an ultra-wide lens makes that ambiguity real", and it
    /// is real on every current iPhone. A fixture with one lens would pass 5.6d
    /// without exercising it.
    static func capability(measured: MeasuredCapability? = nil) -> DeviceCapability {
        DeviceCapability(
            modelIdentifier: "iPhone17,3",
            modelName: "iPhone 16",
            claimed: [wide1080p240, ultraWide1080p240, wide4K60],
            measured: measured)
    }

    static let wide1080p240 = VideoMode(
        width: 1920, height: 1080, fps: 240, lens: .wide,
        pixelFormat: "420v", exposureRangeNs: 125_000...1_000_000_000, isoRange: 34...3072)
    static let ultraWide1080p240 = VideoMode(
        width: 1920, height: 1080, fps: 240, lens: .ultraWide,
        pixelFormat: "420v", exposureRangeNs: 125_000...1_000_000_000, isoRange: 34...3072)
    static let wide4K60 = VideoMode(
        width: 3840, height: 2160, fps: 60, lens: .wide,
        pixelFormat: "420v", exposureRangeNs: 125_000...1_000_000_000, isoRange: 34...3072)

    /// The shipping stance: nothing measured, everything `assumed` (A12).
    static let unmeasuredTiming = PpcpDeviceTimingProfile(
        frameStartToExposureOffsetNs: 0,
        offsetProvenance: .assumed,
        geometry: [PpcpGeometryEntry(readout: .assumedFractionOfFrameInterval(1.0),
                                     direction: .topToBottom)])

    static let timebases = [
        PpcpTimebaseDeclaration(id: "tb:hosttime", kind: .monotonic, epochStable: true,
                                resolutionNs: 42, origin: "CMClockGetHostTimeClock"),
        PpcpTimebaseDeclaration(id: "tb:continuous", kind: .continuous, epochStable: true,
                                resolutionNs: 42, origin: "mach_continuous_time"),
        PpcpTimebaseDeclaration(id: "tb:wall", kind: .wall, epochStable: false,
                                resolutionNs: 1_000, origin: "Foundation.Date")
    ]

    static func input(capability: DeviceCapability? = nil,
                      timing: PpcpDeviceTimingProfile? = nil,
                      viewpoint: PpcpViewpoint? = nil) -> PpcpDeclarationInput {
        PpcpDeclarationInput(
            peerId: "peer:test-device",
            profiles: PpcpProfileSet.device,
            timebases: timebases,
            captureTimebaseId: "tb:hosttime",
            capability: capability ?? Self.capability(),
            timing: timing ?? unmeasuredTiming,
            clipCodec: "hevc",
            viewpoint: viewpoint)
    }

    static func declaration(_ overrides: PpcpDeclarationInput? = nil) throws -> PpcpDeclaration {
        try PpcpDeclaration(overrides ?? input())
    }

    // MARK: The declaration as a whole

    /// The gate for D2: `ppcp_peer_desc_validate`, `ppcp_source_validate` and
    /// `ppcp_capture_profile_validate` all pass on the real declaration. ⚠ Every
    /// one of them runs inside `PpcpDeclaration.init`, so *constructing* it is
    /// the assertion — this test exists to say so out loud, and to fail with the
    /// library's own result code when it stops being true.
    @Test("Every Source and every profile validates through libppcp")
    func declarationValidates() throws {
        let declaration = try Self.declaration()
        #expect(declaration.sources.isEmpty == false)
        #expect(declaration.allProfiles.isEmpty == false)
        let encoded = try declaration.encoded()
        #expect(encoded.isEmpty == false)
    }

    /// `CORE` 5.6d — "a physically distinct lens is a distinct Source. A peer MUST
    /// NOT present two lenses as one Source, and `optics` names which one."
    @Test("Each physical lens is its own Source, named by optics")
    func lensesAreSeparateSources() throws {
        let cameras = try Self.declaration().sources.filter { $0.kind == "camera" }

        #expect(cameras.count == 2)
        #expect(Set(cameras.map(\.optics)) == ["wide", "ultra_wide"])
        // ⚠ Bound out of the macro. `#expect` rewrites a function call into
        // `$0.allSatisfy($1)`, and with a key path as `$1` it cannot prove the
        // `rethrows` is not thrown. A closure literal is fine; a key path is not.
        let everyLensIsPhysical = cameras.allSatisfy(\.physical)
        #expect(everyLensIsPhysical, "REQ-OPT-5 — never a virtual multi-lens device")
        // The ambiguity 5.6d exists for: identical profiles, told apart only by
        // which Source carries them.
        let wide = try #require(cameras.first { $0.optics == "wide" })
        let ultra = try #require(cameras.first { $0.optics == "ultra_wide" })
        #expect(wide.profileIds.contains("1920x1080@240"))
        #expect(ultra.profileIds.contains("1920x1080@240"))
        #expect(wide.id != ultra.id)
    }

    /// `CORE` 5.6a / I19 — "every Source declares `timebase_id`, and every
    /// CaptureProfile it offers declares `timing`, `geometry` and `intrinsics`,
    /// regardless of which peer owns the Source."
    ///
    /// ⚠ **I19 is about `intrinsics` being DECLARED, not about its value.** This
    /// asserted `== .perFrame` on every camera profile, which was true only
    /// while every camera profile was a capture profile. 5.11m makes a preview
    /// profile declare `intrinsics: none` — a positive declaration, because
    /// decimation and downscaling change the intrinsic matrix and 5.11g forbids
    /// anyone consuming a preview for measurement anyway. ⛔ `nil` here would be
    /// *absent*, which is the thing I19 actually refuses.
    @Test("I19 — every camera profile declares timing, geometry and intrinsics")
    func everyCameraProfileIsFullyDeclared() throws {
        let declaration = try Self.declaration()
        for source in declaration.sources where source.kind == "camera" {
            for profile in source.profiles {
                #expect(profile.geometry != nil, "\(profile.id) has no geometry")
                #expect(profile.rateMillihertz != nil)
                // I19 — declared, never absent.
                let intrinsics = try #require(profile.intrinsics,
                                              "\(profile.id) declares no intrinsics")
                if profile.id == PpcpDeclaration.previewProfileId {
                    // 5.11m.
                    #expect(intrinsics == .none,
                            "a preview profile declares intrinsics: none")
                } else {
                    #expect(intrinsics == .perFrame, "\(profile.id) intrinsics")
                }
            }
        }
    }

    /// `CORE` §5.11.2 — the profile a `preview` Stream names, and the things
    /// about it that are deliberately unlike a capture profile.
    @Test("5.11 — one preview profile per lens, derived and never a capture mode")
    func everyLensDeclaresAPreviewProfile() throws {
        let declaration = try Self.declaration()
        let cameras = declaration.sources.filter { $0.kind == "camera" }
        #expect(cameras.isEmpty == false)

        for camera in cameras {
            #expect(camera.profileIds.contains(PpcpDeclaration.previewProfileId),
                    "no preview profile on \(camera.id) — 5.11a/I5 make a Stream's profile id something the declaration must carry")
            let preview = try #require(
                camera.profiles.first { $0.id == PpcpDeclaration.previewProfileId })

            // 5.11m — `none` is the declaration; geometry is the sensor's and
            // decimation does not change it, so it stays declared honestly.
            //
            // ⛔ **Spelled out, because `.none` on an `Optional` is `nil`.**
            // `profile.intrinsics` is `Intrinsics?`, so `== .none` would assert
            // that this profile declares no intrinsics AT ALL — which is
            // *absent*, the one thing I19 refuses on a camera Source, and the
            // exact opposite of what 5.11m asks for. The two readings differ by
            // nothing visible at the call site.
            #expect(preview.intrinsics == PpcpDeclaration.Intrinsics.none)
            #expect(preview.geometry != nil,
                    "readout is the sensor's and survives downscaling")

            // ⚠ A rate that is a *request* (5.11k), and low enough that the tap
            // is nowhere near the 6.7 ms frame path.
            #expect(preview.rateMillihertz == 10_000)
        }
    }

    // MARK: CT-I4

    /// **CT-I4** — "two Sources declared on one clock share one `timebase_id`.
    /// Assert no `TimebaseRelation` with `from == to` is emitted, and that
    /// identity is never asserted by relation."
    ///
    /// ⚠ `CORE` §5.3 states the platform fact this rests on: "On iOS, camera and
    /// microphone Sources both reference `tb:hosttime` and no relation exists
    /// because none is needed." The negative half is the load-bearing one — an
    /// implementation that declared an identity relation would look more
    /// thorough and would be wrong.
    @Test("CT-I4 — one clock, one id, and no relation asserting it")
    func sharedTimebaseIsAnIdNotARelation() throws {
        let declaration = try Self.declaration()

        #expect(declaration.sources.count >= 3, "camera(s), microphone and IMU")
        #expect(Set(declaration.sources.map(\.timebaseId)) == ["tb:hosttime"])
        #expect(declaration.sources.contains { $0.kind == "microphone" })
        #expect(declaration.sources.contains { $0.kind == "imu" })
        #expect(declaration.declaredRelationCount == 0,
                "identity is a shared id, never a relation (I4)")
    }

    // MARK: CT-I22

    /// **CT-I22** — "`frame_start_to_exposure_offset_ns` present with
    /// `nominal_frame_start` and absent otherwise … an explicit zero is accepted
    /// and a defaulted zero is not producible."
    @Test("CT-I22 — the offset is present exactly where the convention requires it")
    func offsetPresentIffNominalFrameStart() throws {
        let declaration = try Self.declaration()

        for profile in declaration.allProfiles {
            if profile.convention == .nominalFrameStart {
                #expect(profile.offsetNs != nil, "\(profile.id) is missing its offset")
                #expect(profile.offsetProvenance != nil, "\(profile.id) offset has no provenance")
            } else {
                #expect(profile.offsetNs == nil,
                        "\(profile.id) declares an offset with convention \(profile.convention)")
                #expect(profile.offsetProvenance == nil)
            }
        }

        // Every camera profile is `nominal_frame_start` — 5.7: "what every
        // AVFoundation source declares".
        let cameras = declaration.sources.filter { $0.kind == "camera" }.flatMap(\.profiles)
        #expect(cameras.allSatisfy { $0.convention == .nominalFrameStart })
        // And the explicit zero, which 5.7b requires rather than permits.
        #expect(cameras.allSatisfy { $0.offsetNs == 0 })

        // The microphone is `mid` and therefore carries no offset at all — which
        // is the "absent otherwise" half, on a Source that really is otherwise.
        let mic = try #require(declaration.sources.first { $0.kind == "microphone" })
        #expect(mic.profiles.allSatisfy { $0.convention == .mid && $0.offsetNs == nil })
    }

    /// The other half of CT-I22, and the one that cannot be written as a value
    /// assertion: **a defaulted zero is not producible**, because the library has
    /// two constructors and only the `nominal_frame_start` one takes an offset.
    @Test("CT-I22 — nominal_frame_start cannot be built without an offset")
    func defaultedZeroIsUnconstructible() throws {
        // `ppcp_timing_make` refuses `nominal_frame_start` outright: there is no
        // argument on it to carry the offset, so the shape cannot be reached.
        var timing = ppcp_timing()
        #expect(ppcp_timing_make(&timing, PPCP_CONV_NOMINAL_FRAME_START) != PPCP_OK)

        // And the constructor that does take it takes the provenance in the same
        // call, so an offset without one is equally unconstructible (I31).
        #expect(ppcp_timing_make_nominal_frame_start(&timing, 0, PPCP_PROV_ASSUMED) == PPCP_OK)
        #expect(timing.has_offset)
        #expect(timing.offset_provenance == PPCP_PROV_ASSUMED)
    }

    // MARK: CT-I31 and CT-S7

    /// **CT-I31 / CT-S7 assertion 1** — "every
    /// `frame_start_to_exposure_offset_ns` and every `rolling_shutter.readout_ns`
    /// the implementation emits carries a provenance, and one that has not been
    /// measured for that device model is `assumed`."
    ///
    /// ⛔ **This is the shipping stance and the test that holds it.** No model has
    /// been through an LED timecode rig (REQ-TEST-1/2), so plan A12 makes every
    /// constant `assumed` with no exception. The day one is measured this test
    /// starts failing, and that is correct — the entry that changed will name
    /// itself.
    @Test("CT-I31 — nothing is declared `measured`, because nothing has been measured")
    func noProvenanceIsMeasured() throws {
        let declaration = try Self.declaration()

        for profile in declaration.allProfiles {
            if let provenance = profile.offsetProvenance {
                #expect(provenance == .assumed, "\(profile.id) offset is \(provenance)")
            }
            if case .rollingShutter(_, let provenance, _, _) = profile.geometry {
                #expect(provenance == .assumed, "\(profile.id) readout is \(provenance)")
            }
        }
        #expect(Self.unmeasuredTiming.isFullyUnmeasured)
    }

    /// **CT-S7 assertion 2** — "test by supplying a device-profile entry with no
    /// rig measurement and asserting the emitted provenance is not `measured`."
    ///
    /// ⚠ The data file's third readout form — a *rule* rather than a number — is
    /// what makes this structural instead of a promise: an entry expressed as a
    /// fraction of the frame interval has no way to say `measured`.
    @Test("CT-S7 (2) — an unmeasured device-profile entry cannot emit `measured`")
    func aTableEntryCannotClaimMeasured() throws {
        let rule = PpcpReadout.assumedFractionOfFrameInterval(1.0)
        #expect(rule.provenance == .assumed)

        let declaration = try Self.declaration()
        let readouts = declaration.allProfiles.compactMap { profile -> PpcpProvenance? in
            guard case .rollingShutter(_, let provenance, _, _) = profile.geometry else { return nil }
            return provenance
        }
        #expect(readouts.isEmpty == false)
        #expect(readouts.allSatisfy { $0 != .measured })
    }

    /// The rule form applied: readout is derived from the profile's own rate, so
    /// 240 fps and 60 fps get different — and individually honest-as-placeholders
    /// — values rather than one number copied across every mode. `CORE` 5.7:
    /// "per **profile**, not per source: readout time differs per mode."
    @Test("Readout is per profile, from the profile's own rate")
    func readoutIsPerProfile() throws {
        let declaration = try Self.declaration()
        let wide = try #require(declaration.sources.first { $0.optics == "wide" })

        let at240 = try #require(wide.profiles.first { $0.id == "1920x1080@240" })
        let at60 = try #require(wide.profiles.first { $0.id == "3840x2160@60" })

        guard case .rollingShutter(let fast, _, let direction, let fastRows) = at240.geometry,
              case .rollingShutter(let slow, _, _, let slowRows) = at60.geometry else {
            Issue.record("expected rolling shutter geometry on both profiles")
            return
        }
        // 1.0 × the frame interval: 1/240 s and 1/60 s.
        #expect(fast == 4_166_667)
        #expect(slow == 16_666_667)
        #expect(direction == .topToBottom)
        // `CORE` 6.2b — R is the rows in the *delivered image*, i.e. the format's
        // height, and the data file does not carry a second copy of it.
        #expect(fastRows == 1080)
        #expect(slowRows == 2160)
    }

    // MARK: CT-I28

    /// **CT-I28** — "a profile with no self-test carries no `measured`. Assert the
    /// implementation never synthesises one from claimed values or a
    /// device-profile table, and that a short onboarding sample is emitted as
    /// `method: cold_sample`."
    @Test("CT-I28 — no self-test, no `measured` block, on any profile")
    func absentMeasuredMeansNotMeasured() throws {
        let declaration = try Self.declaration()
        #expect(declaration.allProfiles.allSatisfy { $0.measuredMethod == nil })
    }

    /// The positive half, and the two refusals beside it. ⚠ Assertions 2 and 3
    /// are the ones that matter: a self-test of 1080p240 must not decorate
    /// 4K60 (5.8c — "1080p240 and 1080p120 are separate self-tests with separate
    /// results"), and it must not decorate the *other lens's* identical profile,
    /// which is 5.6d's ambiguity showing up where it would do real damage.
    @Test("CT-I28 — a self-test lands on its own profile, as its own method")
    func measuredLandsOnlyOnTheProfileItMeasured() throws {
        let selfTest = MeasuredCapability(
            mode: Self.wide1080p240, achievedFPS: 238.4, droppedFrames: 3,
            thermalAtEnd: .serious, measuredAt: Date(),
            method: .coldSample, durationSeconds: 12, observedHostTimeNs: 1_234_567_890)

        let declaration = try Self.declaration(
            Self.input(capability: Self.capability(measured: selfTest)))

        // ⛔ **ONE, not one per lens — and this assertion used to say two.**
        // `CORE` 5.6d makes a physically distinct lens a distinct Source, so a
        // self-test run on the wide lens is evidence about the wide lens and
        // about nothing else. The two lenses offer an identically *named*
        // profile — `1920x1080@240` on both — which is exactly the ambiguity
        // 5.6d exists for, and decorating the ultra-wide's copy with the wide's
        // measurement would be I28's defect committed through 5.6d's door. The
        // prose beside the old assertion said so; the assertion did not.
        let measured = declaration.allProfiles.filter { $0.measuredMethod != nil }
        #expect(measured.count == 1, "a self-test measures the lens it ran on")
        #expect(measured.allSatisfy { $0.id == "1920x1080@240" })
        // 5.8b — an onboarding sample is `cold_sample` and a consumer MUST NOT
        // read it as sustained.
        #expect(measured.allSatisfy { $0.measuredMethod == .coldSample })

        // The other lens's identically named profile carries nothing.
        let ultraWide = try #require(declaration.sources.first { $0.optics == "ultra_wide" })
        #expect(ultraWide.profiles.allSatisfy { $0.measuredMethod == nil })

        // 5.8c — the 4K60 profile was never measured and says so by silence.
        let untested = try #require(declaration.allProfiles.first { $0.id == "3840x2160@60" })
        #expect(untested.measuredMethod == nil)
    }

    /// I28 again, from the other side: a self-test with no `observed_at` in the
    /// capture timebase produces **no** `measured` block rather than one with an
    /// invented instant. An `Instant` has no meaning without a `tb` (I1), and the
    /// wall clock is not a substitute (5.3b).
    @Test("CT-I28 — a self-test with no host-time instant declares nothing")
    func measuredWithoutAnInstantIsNotDeclared() throws {
        let selfTest = MeasuredCapability(
            mode: Self.wide1080p240, achievedFPS: 238.4, droppedFrames: 3,
            thermalAtEnd: .serious, measuredAt: Date(),
            method: .sustained, durationSeconds: 900, observedHostTimeNs: nil)

        let declaration = try Self.declaration(
            Self.input(capability: Self.capability(measured: selfTest)))
        #expect(declaration.allProfiles.allSatisfy { $0.measuredMethod == nil })
    }

    // MARK: 5.6e viewpoint

    /// `CORE` 5.6e — `confidence` "if and only if `method: classified`".
    /// ⛔ Held by there being two constructors, so a `declared` viewpoint has
    /// nowhere to put a number and cannot be asked to invent one.
    @Test("5.6e — a classified viewpoint carries a confidence and a declared one cannot")
    func viewpointCarriesConfidenceOnlyWhenClassified() throws {
        _ = try Self.declaration(Self.input(viewpoint: .declared(label: "dtl")))
        _ = try Self.declaration(Self.input(
            viewpoint: .classified(label: "dtl", confidence: 0.82)))

        // Absent unless something actually classified it — which nothing does
        // yet, so the shipping declaration has no viewpoint at all.
        _ = try Self.declaration()
    }

    // MARK: Refusals

    /// The declaration refuses to be built rather than inventing geometry. ⚠ The
    /// alternative — falling back to `global` — would be a false claim about a
    /// rolling sensor, and I31's subject is precisely that such a claim "silently
    /// biases every cross-source comparison the host makes, in a way that moves
    /// with exposure and therefore looks like clock drift".
    @Test("A model with no geometry data refuses to declare rather than guessing")
    func missingGeometryIsRefused() throws {
        let empty = PpcpDeviceTimingProfile(frameStartToExposureOffsetNs: 0,
                                            offsetProvenance: .assumed,
                                            geometry: [])
        #expect(throws: PpcpDeclarationError.self) {
            try Self.declaration(Self.input(timing: empty))
        }
    }

    /// `CORE` 5.6d again, negatively: a peer with no physical lens has nothing to
    /// declare and says so, rather than declaring a Source with no profiles.
    @Test("A device with no camera refuses to declare")
    func noCameraIsRefused() throws {
        let bare = DeviceCapability(modelIdentifier: "unknown", modelName: "unknown",
                                    claimed: [], measured: nil)
        #expect(throws: PpcpDeclarationError.noCameraSource) {
            try Self.declaration(Self.input(capability: bare))
        }
    }

    // MARK: Profile set

    /// Plan §2 and `CONF` §1d — this application declares seven profiles and
    /// **not** `arbitrate`, which I20 makes host-only.
    @Test("The declared profile set is CORE §2.2.3 and excludes arbitrate")
    func profileSetIsTheMobileCaptureOne() {
        #expect(PpcpProfileSet.device.contains("core"))
        #expect(PpcpProfileSet.device.contains("arbitrate") == false)
        #expect(Set(PpcpProfileSet.device)
            == ["core", "capture", "detect", "mint", "live", "offline", "markup"])
    }
}
