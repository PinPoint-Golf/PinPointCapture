# PinPointCapture — requirements traceability matrix

**Every PRD requirement, its delivery status, the epic and capability level that owns it, and the evidence.**

| | |
|---|---|
| Status | Draft — generated against the tree on 23 August 2026 |
| Rows | 173 requirements (172 in the PRD, plus REQ-CAP-6 added by this pass) |
| Links | [PRD](../design/capture-companion-requirements.md) · [Delivery scope](delivery-scope.md) · [Conformance claim](../conformance/ppcp-conformance.md) |
| Rule | A row's status is a claim about **this repository**. Where the obligation is `libppcp`'s or PinPointStudio's, the row says so rather than claiming credit. |

## Status vocabulary

| Mark | Meaning | Board consequence |
|---|---|---|
| ✅ | **Delivered** — built, tested, and reached by the running app, or held by construction | Closed |
| ◐ | **Built, not composed** — exists and is tested; nothing in the app calls it | An issue, but a cheap one |
| ▨ | **Fixture** — the app shows it, but from fixture data rather than measurement | An issue that looks done and is not |
| ○ | **Not built** | An issue |
| ⛔ | **Blocked** — written, unprovable without hardware or a rig | An issue with a `Blocked on` value |
| ⊘ | **Not this repository** — `libppcp` or PinPointStudio owns it | Tracked as an external dependency |
| ⏳ | **Deferred** — PRD v2 or v3 | On the shelf (§8 of the scope) |

## Rollup

Counted from the table below, by **primary** status.

| Status | Count | Share |
|---|---|---|
| ✅ Delivered | 85 | 49% |
| ○ Not built | 37 | 21% |
| ◐ Built, not composed | 19 | 11% |
| ▨ Fixture | 13 | 8% |
| ⏳ Deferred to v2/v3 | 10 | 6% |
| ⊘ Not this repository | 8 | 5% |
| ⛔ Blocked, primary | 1 | 1% |

A further **27 rows carry ⛔ as a secondary mark** — satisfied in code, unprovable without a phone or a rig. Nine of them close in one device session; the rest wait on the measurement workstream (§6 of the scope).

**Three things this table says that the headline number does not.**

1. **49% delivered is real, and it is the unglamorous half.** Timebases, declaration, the bundle, purity, rendezvous, TLS — the parts that are expensive to retrofit and invisible when they work.
2. **The ◐ column is not a backlog, it is a composition list.** Nineteen requirements are satisfied by tested code that nothing calls. They will close far faster than their count suggests.
3. **The ▨ column is the one to watch.** Thirteen requirements the app currently *appears* to satisfy and does not — every one of them behind a screen that looks finished. REQ-LIGHT-1 is the sharpest example: the PRD calls achievable exposure "the binding constraint on how useful the video is", and A6 currently displays an invented number for it.

---

## §2.3 — Advisory pose (v2)

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-POSE-1 | M | Pose tagged `provenance: device-advisory` | ⏳ | E17 | No pose of any kind exists. Binds the moment E8.2 introduces Vision |
| REQ-POSE-2 | M | Device pose never ingested by a producer | ⏳ | E17 | — |
| REQ-POSE-3 | M | Host pose silently supersedes | ⏳ | E17 | — |
| REQ-POSE-4 | S | Visibly different estimator from the host's | ⏳ | E17 | Apple Vision is the intended estimator, and is also E8.2's |

## §2.4 — Navigation anchors

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-NAV-1 | M | Coarse scrub targets for replay navigation | ○ | E5.2 | C2's timeline draws both anchors at fixed positions; neither is derived |
| REQ-NAV-2 | M | Named distinctly, never persisted as P1–P8 | ✅ | — | By construction: no phase concept exists anywhere in Core |
| REQ-NAV-3 | M | Impact anchor from the acoustic detector, not pose | ✅ | E2 | `Detect/DetectAndMint.swift`, `Detect/Shot.swift`; CT-I23 |

## §4 — Standalone operation

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-STANDALONE-1 | M | Every capability degrades to a stated standalone behaviour | ○ | E13.3 | Never audited as a whole. Individual paths hold; the sweep does not exist |
| REQ-STANDALONE-2 | M | Wire format and on-disk format are one schema | ✅ | — | `ENC` §7 bundle **is** the wire format; CT-I12, CT-I34, `SessionBundleTests` |
| REQ-STANDALONE-3 | M | Clips are self-describing | ⛔ | E1.3 | The sidecar schema is complete and tested; no clip has ever carried bytes |
| REQ-STANDALONE-4 | M | Device mints its own shot identity offline | ✅ | E2 | `Detect/DeviceMint.swift`; CT-I23, CT-S4 (1) |
| REQ-STANDALONE-5 | M | Session first-class independent of host presence | ✅ | — | `HostlessRecordingSession`; CT-S4 (1) passes end to end |
| REQ-STANDALONE-6 | M | Ship a review mode for App Store review | ○ | E13.2 | `DebugScreenGallery` is `#if DEBUG` and is not this |

## §5.1 — Timebase contract

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-TIME-1 | M | Every sample declares its timebase by identity | ✅ | — | `Ppcp/Declaration.swift`; CT-I4, CT-I19 |
| REQ-TIME-2 | M | Pairwise timebase relations declared, three-valued | ✅ | — | CT-I4 — and the **negative** half is asserted: zero relations on iOS, because none is needed |
| REQ-TIME-3 | M | Host may refuse a device on declared uncertainty | ⊘ ◐ | E3.1 | Host policy. The device's obligation is to accept the refusal — `ingest_policy` `out_reason` is wired, uncomposed |
| REQ-TIME-4 | M | `mach_continuous_time` semantics; discontinuity as an explicit observation | ✅ ◐ | E3.1 | `Platform/PpcpTimebases.swift` carries the observation type with magnitude and cause. Emission needs a live link |
| REQ-TIME-5 | M | Time never inferred from frame index | ✅ | — | CT-I2 passes; `FrameTimeline` carries per-frame stamps |

## §5.2 — Exposure convention

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-EXP-1 | M | Canonical instant is mid-exposure | ✅ | — | `libppcp` conversion; CT-S1 (6) passes |
| REQ-EXP-2 | M | Declare native convention **and** per-frame exposure duration | ✅ | — | CT-I22, CT-I31. **The third field the 22 Aug review asked for is closed**: `ppcp_timing_make_nominal_frame_start` takes offset, sigma and provenance as required parameters |
| REQ-EXP-2a | M | Declaration is symmetric — hosts declare too | ⊘ | — | Host obligation. This peer's own declaration is complete; IOP-2 meets a foreign one |
| REQ-EXP-3 | M | Rolling-shutter readout time and direction declared | ▨ ⛔ | E-M1 | Declared for every profile, and every one carries provenance `assumed`. No model has been through a rig |

## §5.3 — Clock synchronisation

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-SYNC-1 | M | Two-way exchange, min-RTT filtered, offset **and** rate | ◐ | E3.2 | `libppcp`'s engine, driven by `PeerLinkPump`. Never run against a live host from the app |
| REQ-SYNC-1a | M | One exchange per timebase; relations declared, never composed | ◐ | E3.2 | CT-I21, CT-I18 pass on this peer's own half |
| REQ-SYNC-2 | M | Burst 10–20 on connect, network change, thermal event | ◐ | E3.2 | Composition only |
| REQ-SYNC-3 | M | Filtered, never stepped | ◐ | E3.2 | Library-held |
| REQ-SYNC-4 | M | Per-shot residual against the acoustic fiducial, reported and logged | ○ | E3.5 | Nothing computes it. **Also gates REQ-MIC-4** — the residual series is what the ToF estimator consumes |

## §5.4 — Streams

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-STREAM-1 | M | Typed streams: video, event, metadata, IMU, relayed-sensor | ✅ | — | `Capture/StreamCoverage.swift` — `PpcpStreamKind`, spellings owned by the library |
| REQ-STREAM-2 | M | Nothing in the protocol assumes iOS or a phone | ✅ | — | `LayerPurityTests` fails the build on a platform import |
| REQ-STREAM-3 | S | Sensor ownership negotiated at session start | ⏳ | E21 | Needs a sensor to own |

## §5.5 — Capability declaration

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-CAP-1 | M | **Claimed** capability on the wire | ✅ | — | `AVFoundationCaptureDevice.enumerateCapability`, real on A1/A7 |
| REQ-CAP-2 | M | **Measured** capability, per capture profile, re-measured after OS updates | ▨ ⛔ | E-M4 | `runSelfTest` runs three seconds and the code says outright this demonstrates the path rather than measuring. CT-I28 asserts the refusals correctly |
| REQ-CAP-3 | M | **Achieved** — realised intervals, drops, thermal, per shot | ◐ ⛔ | E1.3 | `Ppcp/Achieved.swift` complete and tested; no shot has produced one |
| REQ-CAP-4 | M | Optical quality, not only frame rate | ○ ⛔ | E-M1, E8.1 | **No device has a measured noise or contrast figure.** The A1 verdict is a frame-rate check wearing a fuller claim's wording — now stated in REQ-CAP-6 |
| REQ-CAP-5 | M | Frame-rate thresholds are host policy, not protocol | ✅ | — | `HostIngestPolicy` is a value the app applies, not a protocol constraint. I14 |
| REQ-CAP-6 | M | The standalone verdict names whose ingest policy it is, and is advisory | ✅ | — | **New in this pass.** `DeviceCapability.verdictSentence(_:)` takes the policy and names it |

## §5.6 — Versioning

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-VER-1 | M | Capability and version negotiation from the first message | ◐ | E3.1 | `ppcp_peer_config` carries `versions` and `min_version`; uncomposed in the app |
| REQ-VER-2 | M | Unknown fields ignored, never fatal, both ends | ⊘ | — | The codec is `libppcp`'s. Exercised by IOP-1/IOP-2 |
| REQ-VER-3 | M | Written support-window policy and unknown-dialect behaviour | ○ | E14.4 | **Waits on OPEN-5.** Nothing written, nothing implemented |

## §5.7 — Transport independence

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-TRANS-1 | M | Library takes an established byte stream, agnostic to origin | ✅ | — | `Core/Transport.swift` — `ByteChannel`, `PeerTransport`; no `Network.framework` type crosses |
| REQ-TRANS-2 | M | Discovery and transport are a pluggable locator interface | ✅ | — | `PeerTransportConnector` / `PeerTransportListener`; two implementations exist (TLS, direct) |
| REQ-TRANS-3 | M | Transport-specific copyleft deps stay outside the MIT library | ✅ | E15.2 | Holds today. Binds again when USB arrives — the LGPL half is PinPoint's |

## §6.1 — Discovery

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-DISC-1 | M | The device advertises; the host browses | ✅ ⛔ | E16.1 | `Rendezvous/PpcpAdvertiser.swift`; RT-6/7/8/9 pass. Unproven against a real AP |
| REQ-DISC-2 | M | QR is the **primary** pairing path | ✅ | — | B1 opens with the camera live; `RendezvousCoordinator` walks §4 in order. RT-3 passes |
| REQ-DISC-3 | M | Assume multicast fails | ✅ | E16.1 | Direct-IP from QR is the primary path by construction |
| REQ-DISC-4 | S | QR carries SSID/passphrase → `NEHotspotConfiguration` | ✅ ⛔ | E16.3 | `Rendezvous/NetworkJoin.swift` with consent and 6b's second branch. Needs the App ID capability |
| REQ-DISC-5 | S | USB transport for co-located use | ○ | E15.1 | B1's row is drawn and its closure is empty |
| REQ-DISC-6 | M | Detect and explain Local Network denial | ✅ | — | B6 routed from `noEndpointReachable(blocked:)` — inferred from the symptom, never from a permission query |

## §6.2 — Pairing and authentication

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-AUTH-1 | M | PSK from the QR feeds TLS-PSK | ✅ | — | RT-1, RT-14 pass byte-for-byte. **Measured on iOS 27: TLS 1.2 PSK only, no forward secrecy** — a platform limit, recorded |
| REQ-AUTH-2 | M | Discovery, pairing and auth in a single user action | ✅ | — | One scan completes all three |

## §6.3 — Shot identity

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-SHOT-1 | M | Any participant may nominate; the host arbitrates | ◐ | E3.4 | Arbitration is the library's; the device's nomination half passes (CT-I8) |
| REQ-SHOT-2 | M | Device accepts "send me the clip at t₀=X" | ◐ ⛔ | E1.2, E3.4 | The message path exists; `extractClip` has no bytes to return |
| REQ-SHOT-3 | M | Device mints its own identity when hostless | ✅ | — | CT-I23, CT-S4 (1), CT-S4 (6) all pass |
| REQ-SHOT-4 | M | Candidates carry source timestamp and confidence | ✅ | — | CT-I6, CT-I26 pass |
| REQ-SHOT-5 | M | Candidates carry a nomination basis | ✅ | — | CT-I6 |
| REQ-SHOT-6 | M | Every nominator modelled as a capture source with clock and calibration | ⊘ | D-REV-1, E9.3 | **Open.** The launch monitor this project integrates with is a filesystem-watched CSV with no clock. Needs narrowing to *live* nominators, with file-imported records going through `ShotLink` |

## §6.4 — Acoustic detection

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-MIC-1 | M | `.measurement` mode, AGC/EQ/NS off, small IO buffer | ▨ ⛔ | E2.1 | Written; **the microphone has never run** |
| REQ-MIC-2 | M | Onset refined to sample index, not buffer granularity | ▨ ⛔ | E2.1 | Same |
| REQ-MIC-3 | M | Correct for acoustic time of flight | ✅ ⛔ | E2.3, E-M5 | `MicrophoneGeometry` + the mic-to-ball setting reach every Candidate's `tof_correction`. **Nothing has measured a distance, so a shipping session declares none rather than an assumed one.** CT-I29 passes |
| REQ-MIC-4 | M | ToF must not require user measurement | ○ | E2.3 | The estimator does not exist. Needs REQ-SYNC-4's residual series |
| REQ-MIC-5 | M | Discriminate transients | ▨ | E2.2 | A shape-based taxonomy exists (rise/decay/peak) and has never met field audio |
| REQ-MIC-6 | S | Report confidence and classification per candidate | ✅ | — | `AcousticOnsetDetector` emits both; CT-I6 |

## §7.1 — Optical configuration

All seven are implemented in `AVFoundationCaptureDevice.warmUp`. None has been verified on hardware — that verification is **E1.1**.

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-OPT-1 | M | Video stabilisation off | ✅ ⛔ | E1.1 | `preferredVideoStabilizationMode = .off` |
| REQ-OPT-2 | M | Autofocus locked | ✅ ⛔ | E1.1 | `focusMode = .locked` |
| REQ-OPT-3 | M | Auto-exposure locked | ✅ ⛔ | E1.1 | `exposureMode = .locked` |
| REQ-OPT-4 | M | Auto white balance locked | ✅ ⛔ | E1.1 | `whiteBalanceMode = .locked` |
| REQ-OPT-5 | M | A **physical** device, never a virtual multi-lens one | ✅ | — | `.builtInWideAngleCamera` / `.builtInUltraWideCamera` only |
| REQ-OPT-6 | M | Lens selection is calibration-affecting; wide preferred on a tie | ✅ | — | `bestMode`'s third sort term. **Amended in this pass** to state the tie-break |
| REQ-OPT-7 | M | Per-frame intrinsic matrix delivery | ✅ | — | `isCameraIntrinsicMatrixDeliveryEnabled = true`; `FrameTimeline` does the column- to row-major transpose |

## §7.2 — Frame rate

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-FPS-1 | M | Enumerate formats; rank frame-rate-first | ✅ | — | `bestMode` — fps, then height, then lens. **Amended in this pass** to state the ranking |
| REQ-FPS-2 | M | Verify achieved rate from realised timestamp deltas | ✅ ⛔ | E1.1 | `measureSustainedRate` does exactly this; only ever over three seconds |
| REQ-FPS-3 | M | Report achieved intervals per shot | ◐ ⛔ | E1.3 | `AchievedFrames` complete; no shot has produced one |

## §7.3 — Resolution *(renamed from REQ-RES to REQ-RESOL — see D-ID-1)*

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-RESOL-1 | M | Target 1080p at the highest sustainable frame rate | ✅ | — | `bestMode`'s frame-rate-first ranking is this requirement in code |
| REQ-RESOL-2 | S | Do not foreclose 4K | ✅ | — | Capability declaration already carries whatever the device enumerates |

## §7.4 — Light

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-LIGHT-1 | M | Measure achievable exposure before committing to a profile | ▨ | E8.1 | A6's numbers are fixture. **This is the binding constraint on how useful the video is** and it is currently invented |
| REQ-LIGHT-2 | S | Light warning at arm time | ▨ | E8.1 | The row is drawn, in the right colour, with the right consequence text, from a fixture |

## §7.5 — Clip container

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-CLIP-1 | M | MP4/HEVC plus a sidecar carrying twelve named things | ◐ ⛔ | E1.3 | The schema carries all twelve and is tested. No clip exists |
| REQ-CLIP-2 | M | Identical schema on wire and on disk | ✅ | — | CT-I12, CT-I34 |
| REQ-CLIP-3 | M | Timing must not live only in the wire protocol | ✅ | — | The bundle carries it; CT-S4 (1) reads it back |

## §7.6 — Buffering

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-BUF-1 | M | Rolling buffer of hardware-encoded fragments, ~0.5 s, ~20 retained | ◐ | E1.1 | `RingBufferRecorder` implements exactly this and **is not connected** |
| REQ-BUF-2 | M | Fragment length fixed by two independent requirements | ✅ | — | `fragmentSeconds` with the rationale in the file, marked not-a-tuning-knob |
| REQ-BUF-3 | M | Operating bitrate by measurement, not perceptual judgement | ○ ⛔ | E1.4, E-M2 | No sweep has run |
| REQ-BUF-4 | S | Tolerate platforms without clean per-frame access | ✅ | — | Encode-to-fragments is the design; REQ-PORT-9's counterpart |

## §7.7 — Encoder configuration

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-ENC-1 | M | Set `ExpectedFrameRate` explicitly | ○ | E1.1 | **Not set.** Apple DTS's finding is that this silently caps at 80–90 of 120 fps |
| REQ-ENC-2 | M | `RealTime = true` | ○ | E1.1 | Not set |
| REQ-ENC-3 | M | `AllowFrameReordering = false` | ○ | E1.1 | Not set |
| REQ-ENC-4 | M | Sustained encode rate under thermal load after ~40 min | ○ ⛔ | E-M4 | Never measured |

## §8 — Session model

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-SESS-1 | M | Session first-class: start, calibration, roster, context, end | ◐ | E4.3 | `Core/Session.swift` carries all five; a hostless session has no roster by construction |
| REQ-SESS-2 | M | At most one host; hostless is a different regime, not a special case | ✅ | — | `ppcp_session_make_hostless`; CT-S4 (1) |
| REQ-SESS-3 | M | Device library an independent store with per-shot sync state | ◐ ▨ | E4.2 | `SessionStore` writes bundles; **the UI shows a fixture session and nothing reads them back** |
| REQ-SESS-4 | M | Nothing unconfirmed is evicted | ✅ | — | `TransferQueue` — eviction goes through `ppcp_transfer_is_evictable` and nowhere else. CT-I38 |
| REQ-SESS-5 | M | Decouple event from payload | ◐ | E3.4 | `TransferQueue` implements the split; uncomposed |
| REQ-SESS-6 | M | Bulk transfer queued, resumable, backpressure-aware | ◐ | E3.4 | Same |

## §9.1 — State machine

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-STATE-1 | M | Capture start/stop host-controlled | ◐ ▨ | E3.3 | The local override works; **no host has ever armed this device** |
| REQ-STATE-2 | M | Warm exists so arming costs no settling penalty | ✅ ▨ | E11.3 | `warmUp` is real. `estimated_ready_ms` is an assumed 1 200 that has not been through a rig |
| REQ-STATE-3 | M | Keepalive lapse drops warm → cold | ○ | E3.3 | Not implemented |
| REQ-STATE-4 | M | Armed + reviewing is the normal state | ▨ | E5.3 | C2 says "still armed" and nothing tests that it stays true under load |
| REQ-STATE-5 | M | Recover from interruptions with auto re-arm and explicit gap | ▨ | E11.1 | `InterruptionMonitor` **records** the gap with a `recovered` flag. Nothing re-arms or reports it |
| REQ-STATE-6 | M | cold/warm/armed stays device-internal; readiness crosses the wire | ✅ | — | `ReadinessMeasurement` — a measurement, never a state name. Ported cleanly, and the PRD review singles it out |

## §9.2 — Priority rule

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-RES-1 | M | Replay never disarms or tears down capture | ○ | E11.2 | The rule is honoured in the *design* everywhere and enforced nowhere, because replay does not exist |
| REQ-RES-2 | M | Replay yields decode, smoothness and resolution before the ring drops a frame | ○ | E11.2 | Same |
| REQ-RES-3 | M | Thermal state a first-class protocol field | ✅ ◐ | E11.3 | `ThermalTimeline`, `DeviceCapability`; reported, never acted on |
| REQ-RES-4 | M | A **measured** battery target | ○ ⛔ | E-M4 | Never measured |
| REQ-RES-5 | S | Address the charging trade-off explicitly | ○ ⛔ | E-M4 | Never measured |

## §10.1 — v1 application functionality

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-SETUP-1 | M | Verify golfer in frame at address **and** at top, light, stability | ▨ | E8.2 | All four rows are fixture |
| REQ-SETUP-2 | S | Device classifies its own viewpoint | ▨ | E8.3 | A6 displays `DTL · RIGHT-HANDED` from a fixture |
| REQ-SETUP-3 | M | Framing validation may use body-pose detection | ○ | E8.2 | No `Vision` import exists anywhere in the tree |
| REQ-REPLAY-1 | M | Frame-accurate stepping both directions at capture rate | ○ | E5.2 | `onStepFrame` is an empty closure |
| REQ-REPLAY-2 | M | Timeline addressed in time, never frame index | ✅ ▨ | E5.1 | The design and the placeholder captions honour it; there is no timeline to address |
| REQ-REPLAY-3 | M | Impact fiducial on the timeline and as a scrub target | ▨ | E5.2 | Drawn at a fixed 52% |
| REQ-REPLAY-4 | M | Two-shot comparison synchronised on impact | ○ | E7.1, E7.2 | **Not designed.** The handoff names it and stops |
| REQ-MARK-1 | M | Markup a user artefact, anchored to shot id + frame timestamp | ✅ ◐ | E6.2 | `Markup/Annotation.swift`; CT-I37 passes |
| REQ-MARK-2 | M | Device markup appears in PinPoint; the link is bidirectional | ◐ | E6.3 | The payload direction exists in `DevicePeerLive`; nothing authors an annotation |
| REQ-MARK-3 | S | Finger-drawn plane and alignment lines | ○ | E6.1 | No drawing surface |
| REQ-META-1 | M | Attitude and gravity captured continuously | ◐ | E1.3 | `MotionMetadataSource` is written and feeds nothing |
| REQ-META-2 | S | Time, location, and weather for outdoor sessions | ○ | E4.3 | No location or weather capture of any kind |

## §11 — Security and privacy

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-PRIV-1 | M | No unpaired host receives video | ✅ | — | Held **by construction**: `PpcpTransport` has no plaintext branch and `PpcpByteChannel.open` refuses a ready connection with no TLS metadata |
| REQ-PRIV-2 | M | Audio retention explicit, user-visible, configurable, honestly labelled | ✅ ○ | E-R2 | A4 surfaces it with a *Change* control. **The privacy label itself does not exist yet** |
| REQ-PRIV-3 | M | No telemetry | ✅ | — | By absence — verified across the tree |
| REQ-PRIV-4 | M | Audio windows attach to **candidates**, including rejected ones | ✅ | — | `CandidateAudioRetention` |
| REQ-PRIV-5 | M | Audio a separate stream with a shorter window | ✅ | — | Separate `Stream`, `shot_windowed`, own window |
| REQ-PRIV-6 | M | Retention bounded, in candidates, with an explicit cap | ✅ | — | `maximumRetainedCandidates = 150`, enforced by eviction, evicted windows re-announced `absent`. **The PRD was amended in this pass to match the code** |
| REQ-PRIV-7 | S | Raw PCM at v1 | ✅ | — | Retained as PCM so an improved classifier can be re-run |

## §12 — Observability

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-OBS-1 | M | Exportable diagnostic bundle, first-class | ○ | E10.1 | **No type of that name exists.** This is the project's only channel into the field |
| REQ-OBS-2 | M | User-initiated, attachable to an issue | ○ | E10.1 | `onExportDiagnostics` is empty |
| REQ-OBS-3 | S | The same bundle serves as the validation record | ○ | E10.1 | — |
| REQ-OBS-4 | S | Device diagnostic mode, default off | ○ | E10.3 | **Waits on D-REV-2** — the PRD does not yet say when it turns itself off |

## §13 — Testing and validation

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-TEST-1 | M | LED timecode rig | ○ ⛔ | E-M1 | **The PRD says build this before the protocol.** It is now the other way round |
| REQ-TEST-2 | M | Per-frame ground truth and rolling-shutter readout from it | ○ ⛔ | E-M1 | Consequence of the above: every profile's provenance is `assumed` |
| REQ-TEST-3 | M | Recorded-session fixture format replaying deterministically | ✅ | — | **The bundle is the fixture format** (REQ-OFF-1's collapse). Bundles checked into `docs/conformance/bundles/` |
| REQ-TEST-4 | M | Injectable clock | ✅ | — | `libppcp` §5.1; used throughout `make conform` |
| REQ-TEST-5 | M | Software device simulator | ✅ | — | `ppcp-sim`, driven by `make conform` and `make conform-iop` |
| REQ-TEST-6 | M | Bitrate sweep | ○ ⛔ | E-M2 | Gates REQ-BUF-3 |
| REQ-TEST-7 | M | Resolution comparison 1080p150 vs 4K120 | ○ ⛔ | E-M3 | Gates OPEN-3's resolution half |

## §14 — Licensing and distribution

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-LIC-1 | M | Protocol specification published openly | ⊘ | — | `libppcp`'s obligation; the spec exists in that repo |
| REQ-LIC-2 | M | `libppcp` MIT-licensed | ⊘ ✅ | — | It is |
| REQ-LIC-3 | M | One implementation of the wire format, used by both ends | ✅ | — | **The central architectural claim of this repository, and it holds**: twelve `import CPPCP` sites, no hand-written wire format |
| REQ-LIC-4 | M | The app's licence is an independent decision | ○ | OPEN-4, E-R2 | `LICENSE` is present; the distribution decision is not made |
| REQ-LIC-5 | M | Copyleft deps stay out of the MIT library | ✅ | — | Holds; binds again at E15.2 |
| REQ-LIC-6 | M | Trademark clearance before first submission | ○ | E-R1 | Register searches recorded in the PRD; no qualified opinion |

## §15 — Host-side integration

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-HOST-1 | M | The device lands behind PinPoint's camera abstraction | ⊘ | — | PinPointStudio's obligation |
| REQ-HOST-2 | M | One ingest path for live and store-and-forward | ⊘ ✅ | E9.2 | This side satisfies its half: the bundle **is** a recorded stream. IOP-3/IOP-10 exercise it |

## §16 — Offline capture and export

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-OFF-1 | M | An exported session is a recorded PPCP stream replayed from a file | ✅ | — | The single best-delivered idea in the build. `ENC` §7; CT-I12, CT-I34 |
| REQ-OFF-2 | M | Warn on low space; **refuse to arm** below a floor | ○ | E9.4 | `StorageHeadroom` is computed and displayed; nothing refuses |
| REQ-OFF-3 | M | Export metadata and sensor streams **before** video | ○ | E9.2 | Ordering not implemented |
| REQ-OFF-4 | M | Device estimates device↔sensor clock mapping live | ⏳ | E21 | No sensors yet |
| REQ-OFF-5 | M | Bundle carries the estimate **and** the raw arrival evidence | ⏳ | E21 | — |
| REQ-OFF-6 | M | Every offline sample in the declared timebase with stated uncertainty | ✅ | — | Holds for the streams that exist today |
| REQ-OFF-7 | M | The device's estimate is a prior, not authoritative | ⏳ | E21 | — |
| REQ-OFF-7a | M | A session's canonical timebase is immutable once set | ✅ | — | Held by the bundle schema |
| REQ-OFF-8 | M | **Wall clock labels; monotonic measures** | ○ | E9.2 | **Nothing in the tree distinguishes them.** No wall-clock field, no observed discontinuity between the two. A real gap in a delivered-looking area |
| REQ-OFF-9 | M | Chunked, resumable, content-addressed export | ○ | E9.2 | Content addressing exists in the transfer digest; the export path does not |
| REQ-OFF-10 | M | Idempotent re-import | ✅ | — | CT-I34 passes |
| REQ-OFF-11 | M | Completeness explicit, never inferred | ✅ | — | `SessionStore` asserts `partial` on a user disarm — a claim nobody can back is refused |
| REQ-OFF-12 | M | Do not auto-merge on reconciliation | ◐ ▨ | E9.3 | B5 is drawn correctly and passed an **empty** candidate array. `SessionMatch` exists and is untested against real data |
| REQ-OFF-13 | M | Sensor dropout recorded as an explicit gap | ✅ | E21 | CT-I11 passes for the streams that exist; binds again with sensors |
| REQ-OFF-14 | M | Any subset of streams is a valid bundle | ✅ | — | CT-I12 passes for video-only, IMU-only and empty |
| REQ-OFF-15 | M | Measure BLE + 120 fps capture + encode sustained | ⏳ ⛔ | E21 | — |
| REQ-OFF-16 | S | Two offline devices aligned by cross-correlating the impact transient | ⏳ | E22 | — |

## §17 — Platform portability

The best-served section in the document. Layering is not merely intended — it is mechanically enforced, and that enforcement was tested rather than assumed.

| Req | | Requirement | Status | Epic · level | Evidence / note |
|---|---|---|---|---|---|
| REQ-PORT-1 | M | Four layers with explicit boundaries | ✅ | — | `Packages/Core` · `Sources/Platform` · `Sources/UI` · `libppcp`. Both layer READMEs state the contract |
| REQ-PORT-2 | M | The port surface enumerated as a **documented artefact** | ▨ | E14.3 | The Core README has a three-row table headed "The port surface so far". That is a start, not the artefact the requirement asks for |
| REQ-PORT-3 | M | No platform type crosses an internal API boundary | ✅ | — | `LayerPurityTests` **fails the build** on a forbidden import and walks the tree recursively |
| REQ-PORT-4 | M | Abstract base and factory from the start | ✅ | — | `CaptureDevice` protocol + `CaptureDeviceFactory` |
| REQ-PORT-5 | M | UI native per platform | ✅ | — | SwiftUI throughout |
| REQ-PORT-6 | M | Shared layers bind cleanly to both platforms without a runtime | ✅ ⚠ | E25 | Satisfied by `libppcp` (C). **Core is Swift**, deliberately and temporarily — the README states the substitution is the plan and has started |
| REQ-PORT-7 | MN | Do not use Qt | ✅ | — | By absence |
| REQ-PORT-8 | M | Do not assume camera and mic share a timebase | ✅ | — | CT-I4 asserts the iOS case **and** the negative half. The README warns a port must re-derive, not copy |
| REQ-PORT-9 | M | Survive a platform without clean per-frame access | ✅ | — | Encode-to-fragments is the design |
| REQ-PORT-10 | M | Device profiles ship as **data**, keyed by model | ✅ ▨ | E-M1 | `DeviceProfiles.json` is data. Every value in it is `assumed` |
| REQ-PORT-11 | M | Capability in protocol vocabulary, never platform vocabulary | ✅ | — | Enforced by the purity test; the S2 finding (a `Date` where three protocol fields belonged) is the requirement earning its keep |
| REQ-PORT-12 | M | On-disk schema carries no platform concepts | ✅ | — | CT-I12, CT-I34; the bundle is library-written |
| REQ-PORT-13 | S | Permissions in the platform layer; Core consumes neutral readiness | ✅ | — | `PermissionsService` → `Core.Permissions` |
| REQ-PORT-14 | S | Do not pre-generalise beyond the port surface | ✅ | — | Stated as a non-goal in the Core README and honoured |

---

## Reverse index — epic to requirements

For the board: what each capability level closes.

| Level | Closes |
|---|---|
| **E1.1** | REQ-BUF-1 · REQ-ENC-1/2/3 · REQ-OPT-1..4 (hardware verification) · REQ-FPS-2 |
| **E1.2** | REQ-STANDALONE-3 · REQ-SHOT-2 |
| **E1.3** | REQ-CLIP-1 · REQ-CAP-3 · REQ-FPS-3 · REQ-META-1 |
| **E1.4** | REQ-BUF-3 |
| **E2.1** | REQ-MIC-1 · REQ-MIC-2 |
| **E2.2** | REQ-MIC-5 |
| **E2.3** | REQ-MIC-3 · REQ-MIC-4 |
| **E3.1** | REQ-VER-1 · REQ-TIME-3 · REQ-TIME-4 (emission) |
| **E3.2** | REQ-SYNC-1/1a/2/3 |
| **E3.3** | REQ-STATE-1 · REQ-STATE-3 |
| **E3.4** | REQ-SESS-5/6 · REQ-SHOT-1 |
| **E3.5** | REQ-SYNC-4 |
| **E4.1** | REQ-SESS-3 (store half) |
| **E4.2** | REQ-SESS-3 (state half) |
| **E4.3** | REQ-SESS-1 · REQ-META-2 |
| **E5.1** | REQ-REPLAY-2 |
| **E5.2** | REQ-REPLAY-1/3 · REQ-NAV-1 |
| **E5.3** | REQ-STATE-4 |
| **E6.1** | REQ-MARK-3 |
| **E6.2** | REQ-MARK-1 |
| **E6.3** | REQ-MARK-2 |
| **E7.1 / E7.2** | REQ-REPLAY-4 |
| **E8.1** | REQ-LIGHT-1/2 · REQ-CAP-4 (partial) |
| **E8.2** | REQ-SETUP-1/3 |
| **E8.3** | REQ-SETUP-2 |
| **E9.1** | — (enables E9.2) |
| **E9.2** | REQ-OFF-3/8/9 |
| **E9.3** | REQ-OFF-12 · REQ-SHOT-6 (with D-REV-1) |
| **E9.4** | REQ-OFF-2 |
| **E10.1** | REQ-OBS-1/2/3 |
| **E10.3** | REQ-OBS-4 |
| **E11.1** | REQ-STATE-5 |
| **E11.2** | REQ-RES-1/2 |
| **E11.3** | REQ-RES-3/4/5 · REQ-STATE-2 |
| **E13.2** | REQ-STANDALONE-6 |
| **E13.3** | REQ-STANDALONE-1 |
| **E14.3** | REQ-PORT-2 |
| **E14.4** | REQ-VER-3 |
| **E15.1** | REQ-DISC-5 |
| **E16.1** | REQ-DISC-1/3 |
| **E16.3** | REQ-DISC-4 |
| **E-M1** | REQ-TEST-1/2 · REQ-EXP-3 · REQ-PORT-10 (values) |
| **E-M2** | REQ-TEST-6 |
| **E-M3** | REQ-TEST-7 |
| **E-M4** | REQ-CAP-2 · REQ-ENC-4 · REQ-RES-4/5 |
| **E-M5** | REQ-MIC-3 (a measured value) |
| **E-R1** | REQ-LIC-6 |
| **E-R2** | REQ-PRIV-2 (the label) · REQ-LIC-4 |

## Requirements with no owning epic

Three, and each for a stated reason:

| Req | Why |
|---|---|
| REQ-EXP-2a | Host-side declaration. This peer declares symmetrically already; the obligation binds a third-party host |
| REQ-HOST-1 | PinPointStudio's camera abstraction |
| REQ-LIC-1 | `libppcp` publishes the specification |
