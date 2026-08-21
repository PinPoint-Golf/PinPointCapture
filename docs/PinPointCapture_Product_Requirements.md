# PinPointCapture

**Product description and requirements**

A mobile device as a time-synchronised high-speed capture source for PinPoint Studio, and the open protocol that makes it possible.

| | |
|---|---|
| Status | Draft for review |
| Date | 21 August 2026 |
| Product | **PinPointCapture** — mobile capture and replay app. iOS/iPadOS first, Android a near-term possibility ([§17](#17-platform-portability)). |
| Protocol | **PPCP** — PinPoint Capture Protocol. Open specification. |
| Library | **libppcp** — reference implementation, MIT. |
| Licence | Protocol: open specification. Library: MIT. App: see [OPEN-4](#open-decisions). |
| Related | PinPointStudio (GPL, desktop), `libwrist` (MIT, wrist sensor) |

## Repositories

Under the `PinPointGolf` GitHub organisation, alongside `PinPointStudio`, `libwrist` and `Website`.

| Repo | Contents | Licence |
|---|---|---|
| `PinPointGolf/libppcp` | PPCP specification, reference library, conformance test suite, fixture format, device profiles | MIT |
| `PinPointGolf/PinPointCapture` | iOS/iPadOS app (and later Android) | [OPEN-4](#open-decisions) |

Spec and reference implementation share a repo so they cannot drift and so conformance tests can exercise both. The app is separate because its licence differs, its release cadence is gated by App Store review rather than library tags, and library consumers should not be gated on the app.

A third repo may become necessary for recorded-session fixtures ([REQ-TEST-3](#132-harness)) once they outgrow git-lfs. Do not pre-empt it.

---

## 1. Purpose

High-speed cameras are the principal cost barrier to swing analysis. A pair of machine-vision cameras, lenses and mounts runs to several hundred pounds before any lighting. Meanwhile most golfers already carry a device with a 120–240 fps camera, a microphone, an IMU, a BLE radio and a hardware video encoder.

This project makes that device a first-class capture source for PinPoint Studio, and defines the open protocol by which it — or any other device — talks to a host.

Three deliverables, in dependency order:

1. **PPCP**, an open specification for time-synchronised capture devices. Published, versioned, implementable by anyone.
2. **libppcp**, an MIT-licensed reference implementation of the protocol, used by both ends so the two cannot drift.
3. **PinPointCapture**, a mobile application that implements PPCP as a capture device, and adds local replay and markup.

The specification is the primary artefact. The library is one implementation of it; the app is one user of the library.

### 1.1 Why a new protocol

A survey of existing work found nothing covering this shape — a controllable device that timestamps, buffers locally, detects events independently and delivers clips retrospectively:

- **Streaming/broadcast** (RTP/RTCP, WebRTC, SMPTE ST 2110, NDI, ONVIF) assumes continuous streaming to a server-side consumer. No ring buffer, no on-device event detection, no retrospective retrieval.
- **Industrial vision** (GenICam/GigE Vision over IEEE 1588) solves clock sync properly but assumes wired, genlockable hardware. No phone implementation.

Relevant prior art to borrow from rather than adopt wholesale:

- **libsoftwaresync** (Ansari et al., ICCP 2019; Google Research, Android) — sub-250 µs multi-phone sync via SNTP-style clock estimation followed by camera phase alignment.
- **Sub-millisecond Video Synchronization of Multiple Android Smartphones** (arXiv:2107.00987) — extends phase alignment to video recording; measured drift below 1.2 ms/minute across 47 device models.
- **RTCP sender reports** — the pattern of mapping a stream-local timestamp to a common wallclock.

**Design distinction from the prior art:** libsoftwaresync aims at *phase alignment* — actively shifting streams so frames are co-timed. PPCP aims at *accurate timestamping* — frames need not coincide, but each must carry a precise time. Timestamping is strictly weaker, far more robust, and does not require per-device tuning. Phase alignment may become relevant for multi-device stereo (see [10.3](#103-v3-and-beyond)); the protocol must not preclude it, but v1 does not attempt it.

---

## 2. Scope: where the line is drawn

The PinPoint analysis pipeline runs:

> transport → discovery and calibration → high-speed capture → shot detection → **pose inference** → fusion and synthesis → phase segmentation → metric extraction → diagnostics → session assessment

**Governing rule:**

> **PinPointCapture may *display* any stage of the pipeline. It may only *compute* up to advisory pose.**

This separates presentation from computation. Showing host-computed diagnostics on the phone as a second screen is presentation and does not move the line.

### 2.1 Stage allocation

| Stage | PinPointCapture | Host | Authority |
|---|---|---|---|
| Transport | ✓ | ✓ | shared library |
| Discovery & pairing | ✓ | ✓ | — |
| Calibration | intrinsics, gravity, framing, viewpoint self-classification | extrinsics, multi-device registration | host |
| High-speed capture | ✓ | ✓ | device owns its own frames |
| Shot detection | ✓ independent | ✓ independent | host arbitrates ID and t₀ |
| Pose inference | advisory only (v2) | ✓ | **host, always** |
| Fusion & synthesis | ✗ | ✓ | host |
| Phase segmentation | navigation anchors only | ✓ full P1–P8 | host |
| Metrics / diagnostics / session assessment | ✗ (display only) | ✓ | host |
| Markup & replay | ✓ | ✓ | **device, when authored there** |

### 2.2 Non-goals

PinPointCapture will not compute metrics, evaluate diagnostic conditions, apply normative corridors, or produce any artefact that a PinPoint producer could consume. Forking the diagnostics model into a second language and a second maintenance burden is explicitly rejected.

### 2.3 Advisory pose (v2)

Device-side pose exists only to support replay annotation (e.g. hand-path tracing on a DTL view) and navigation. It is not analysis.

- **REQ-POSE-1 (MUST)** Device pose is tagged `provenance: device-advisory` with model identity and version.
- **REQ-POSE-2 (MUST)** Device pose is never ingested by any producer, never reaches a norm, corridor, signal or condition.
- **REQ-POSE-3 (MUST)** Host pose silently supersedes device pose. No reconciliation, no diff view, no user-visible disagreement.
- **REQ-POSE-4 (SHOULD)** Use a visibly different estimator from the host's (e.g. Apple Vision body pose rather than a reduced ViTPose). Nothing to ship or version, and — the substantive reason — it makes "just use the phone's numbers" obviously wrong to any future reader. Accepted cost: the phone skeleton will not match PinPoint's.

### 2.4 Navigation anchors, not segmentation

- **REQ-NAV-1 (MUST)** The device may derive coarse scrub targets (impact, top of backswing) for replay navigation.
- **REQ-NAV-2 (MUST)** These are named distinctly from host phase data in the schema and are never persisted as P1–P8 phases.
- **REQ-NAV-3 (MUST)** Impact anchor derives from the acoustic detector, not from pose.

---

## 3. Use cases

### UC-1 — Entry-level capture (primary)

A golfer with no machine-vision hardware places a phone on a tripod at a mat, indoors or at a range. The phone captures, detects shots, retains clips and lets them review immediately. Video reaches PinPoint when a host is available — possibly not until they get home.

**Implication:** the host may be absent for the whole session, and this is the *normal* case rather than a fallback. See [§4](#4-standalone-operation) and [§16](#16-offline-capture-and-export).

### UC-2 — Occlusion recovery (primary)

An existing studio with FLIR cameras face-on and DTL adds a phone as a third view, frequently **behind the golfer** (6 o'clock), to resolve occlusion. Precise alignment to the existing capture matters more than anything else here.

**Implication:** arbitrary placement, arbitrary distance from the ball, arbitrary lens.

### UC-3 — Range replay (primary)

The same device, same session, alternating between capture and review shot by shot. The golfer looks at the last swing while remaining armed for the next.

**Implication:** capture and replay contend for the same thermal, decode and encode budget. See [§9.2](#92-priority-rule).

### UC-4 — Offline sensor capture (primary, follows video)

A golfer at a range with no host and no network captures video *and* wrist/IMU data to the device, then exports the whole session to PinPoint later. Once sensors arrive, this is the only way to capture that data at a range at all.

**Implication:** the device becomes the session's time authority for every attached sensor. See [§16.3](#163-clock-authority-inverts).

### UC-5 — Lesson second screen (secondary)

Coach at the host, golfer at the phone. Host-computed results display on the phone, which the golfer is facing.

### UC-6 — Multi-device (v3)

Two or more devices as a stereo pair for users with no fixed hardware.

---

## 4. Standalone operation

The app is **an autonomous capture device with an optional real-time link**, not a remote camera.

- **REQ-STANDALONE-1 (MUST)** Every capability degrades to a stated standalone behaviour. A feature that only works with a host present requires a defined offline path, not an error.
- **REQ-STANDALONE-2 (MUST)** The wire format and the on-disk format are the same schema. The host has exactly one ingest path, whether data arrives over a socket or from a filesystem.
- **REQ-STANDALONE-3 (MUST)** Clips are self-describing. See [§7.4](#75-clip-container).
- **REQ-STANDALONE-4 (MUST)** The device can mint its own shot identity for offline reconciliation. See [§6.3](#63-shot-identity).
- **REQ-STANDALONE-5 (MUST)** Session is a first-class object independent of host presence. See [§8](#8-session-model).

**Note on App Store review:** requiring a host is *not* itself grounds for rejection — iOS has no equivalent of the tvOS standalone rule (2.4.3), and companion apps are an established category. The real constraint is that a reviewer must be able to exercise the app. Apple permits a fully-featured demo mode in lieu of a demo account, and explicitly cites a sample QR code as the kind of resource to supply.

- **REQ-STANDALONE-6 (MUST)** Ship a review mode that simulates a paired host well enough to walk the full path: arm → capture → detect → review → transfer.

The standalone architecture above is justified on product grounds (UC-1, and WiFi failure mid-session even when a host is present), not on review policy.

---

## 5. Protocol (PPCP)

### 5.1 Timebase contract

The single most important requirement in the document.

- **REQ-TIME-1 (MUST)** Every timestamped sample declares its **reference timebase by identity**.
- **REQ-TIME-2 (MUST)** A device declares, for each pair of its timebases, whether they are known-equal, related-by-measured-offset (with uncertainty), or unrelated.
- **REQ-TIME-3 (MUST)** The host may refuse a device whose declared timebase uncertainty exceeds policy.

**Why this is not over-engineering.** On iOS, `AVCaptureSession` video and audio sample buffers share `CMClockGetHostTimeClock()` — camera and mic are known-equal, and intra-device alignment is free. On Android, `SENSOR_INFO_TIMESTAMP_SOURCE` reports either `REALTIME` (`elapsedRealtimeNanos`, shared with sensors and audio — known-equal) or `UNKNOWN` (an arbitrary monotonic base comparable with nothing). An `UNKNOWN` device must be *expressible as degraded*, not silently wrong. Without this contract, porting to Android is a rewrite.

- **REQ-TIME-4 (MUST)** Timestamps use `mach_continuous_time` semantics or equivalent — a base that does not halt across device sleep. Discontinuities are detected and reported.
- **REQ-TIME-5 (MUST)** Time is never inferred from frame index. Frames drop; indices lie. Every frame carries its own timestamp.

### 5.2 Exposure convention

- **REQ-EXP-1 (MUST)** The canonical instant for a frame is **mid-exposure**.
- **REQ-EXP-2 (MUST)** Devices declare their native convention (start-of-exposure, nominal frame start, etc.) and the exposure duration per frame, so the host can convert.
- **REQ-EXP-3 (MUST)** Rolling-shutter devices declare readout time and readout direction. No public API exposes this; it is calibrated per model (see [§13.1](#131-led-timecode-rig)) and shipped as a device profile.

**Rationale.** FLIR timestamps start-of-exposure; AVFoundation PTS is nominal frame start; IMU is a third convention. Without a canonical instant, the mismatch produces an exposure-dependent systematic offset indistinguishable from clock bias — which will corrupt the existing clock-bias estimator (PinPoint fusion P1).

### 5.3 Clock synchronisation

- **REQ-SYNC-1 (MUST)** Two-way timestamp exchange with minimum-RTT filtering, estimating both **offset and rate**. Not a one-shot handshake.
- **REQ-SYNC-2 (MUST)** Burst 10–20 exchanges on connect, after any network change, and after a thermal event; settle to heartbeat cadence for maintenance. The heartbeat rate must not set the sync rate.
- **REQ-SYNC-3 (MUST)** The estimate is filtered, never stepped. A stepped offset mid-session produces a discontinuity in fused output that is very hard to diagnose later.
- **REQ-SYNC-4 (MUST)** Per-shot residual against the acoustic fiducial is computed, reported and logged.

**Drift budget.** At 20 ppm (~1.2 ms/minute, the measured cross-device figure) a full 150 fps frame slips every ~5.5 minutes. Skew estimation is mandatory, not an optimisation.

### 5.4 Streams

- **REQ-STREAM-1 (MUST)** The protocol carries **typed streams**: video, event, metadata, IMU, relayed-sensor. Adding a stream type is an extension, not a new protocol.
- **REQ-STREAM-2 (MUST)** Nothing in the protocol assumes iOS, or a phone.
- **REQ-STREAM-3 (SHOULD)** Where a device and host are both capable of owning a sensor connection (e.g. a BLE wrist sensor via `libwrist`), ownership is negotiated at session start.

### 5.5 Capability declaration

Three distinct things, all on the wire, routinely different:

- **REQ-CAP-1 (MUST)** **Claimed** — what the device advertises it can do.
- **REQ-CAP-2 (MUST)** **Measured** — what it observed itself sustaining, from self-test. Re-measured after OS updates.
- **REQ-CAP-3 (MUST)** **Achieved** — what actually happened on this specific shot, including realised frame intervals, drops and thermal state.
- **REQ-CAP-4 (MUST)** Capability includes optical quality, not only frame rate: achieved exposure, ISO, and a measured noise or contrast figure at requested settings. "120 fps capable" can hide frames the shaft detector cannot use.
- **REQ-CAP-5 (MUST)** Frame-rate thresholds are **host ingest policy, not protocol constraints**. A device may honestly declare 60 fps; the host may reject it. PinPoint's current floor is 120 fps (consistent with the documented ≥100 fps requirement for full-swing shaft tracking), but the wire format must not encode it.

*Vendor variance justifies the claimed/measured split: Samsung's developer team states 60+ fps is unsupported through the normal Camera2 path on Galaxy devices for thermal reasons, available only via the constrained high-speed session; and high-speed capability has regressed across firmware updates on some models.*

### 5.6 Versioning

- **REQ-VER-1 (MUST)** Capability and version negotiation from the first message.
- **REQ-VER-2 (MUST)** Unknown fields are ignored, never fatal, on both ends.
- **REQ-VER-3 (MUST)** A written support-window policy: how many versions back the host accepts, and what the app does facing an unknown host dialect. See [OPEN-5](#open-decisions).

**Rationale.** App Store releases are slow and users do not update; PinPoint moves at FOSS pace. Old-app/new-host is the permanent normal case, not an edge case.

### 5.7 Transport independence

- **REQ-TRANS-1 (MUST)** The library accepts an established bidirectional byte stream and is agnostic to its origin — TCP over WiFi, TLS-PSK, USB tunnel.
- **REQ-TRANS-2 (MUST)** Discovery and transport are a pluggable locator interface, consistent with PinPoint's factory pattern for all device integrations.
- **REQ-TRANS-3 (MUST)** Transport-specific dependencies stay outside the MIT library. `usbmuxd`/libimobiledevice is LGPL and belongs on the PinPoint side as one transport implementation.

---

## 6. Discovery, pairing and shot detection

### 6.1 Discovery

- **REQ-DISC-1 (MUST)** **The device advertises; the host browses.** The host then only ever needs the mDNS querier role, which can send from an ephemeral port with the unicast-response bit set and never bind UDP 5353 — avoiding conflict with `mDNSResponder` (macOS), Avahi (Linux), and the absence of any assumable responder on Windows. Advertising also fits the topology: capture requires foreground, so the device is the party reliably present.
- **REQ-DISC-2 (MUST)** **QR is the primary pairing path**, not the fallback. Host displays a QR carrying endpoint(s), port, session id and pre-shared key. mDNS is the convenience path for reconnection only.
- **REQ-DISC-3 (MUST)** Assume multicast fails. It is rate-limited or dropped on many consumer APs, blocked by client isolation on guest networks, and does not cross VLANs. It will not work at a range.
- **REQ-DISC-4 (SHOULD)** Extend the QR to carry SSID and passphrase, driving `NEHotspotConfiguration` so the device can join a host-provided hotspot — removing the network problem rather than working around it.
- **REQ-DISC-5 (SHOULD)** Support a USB transport for co-located use (UC-2): lower and far more stable latency floor, so minimum-RTT filtering converges much faster.
- **REQ-DISC-6 (MUST)** Detect and explain iOS Local Network permission denial. `NSLocalNetworkUsageDescription` and `NSBonjourServices` are required, there is no public API to read back permission state, and a single "Don't Allow" makes the app appear permanently broken. Direct-IP connection from QR degrades more gracefully than multicast browsing.

### 6.2 Pairing and authentication

- **REQ-AUTH-1 (MUST)** PSK from the QR feeds TLS-PSK (`NWProtocolTLS` on iOS, OpenSSL on the host). No PKI, no certificates, no CA.
- **REQ-AUTH-2 (MUST)** Discovery, pairing and authentication complete in a single user action. On a shared network, swing video must never reach an unpaired host.

### 6.3 Shot identity

- **REQ-SHOT-1 (MUST)** **Any participant may nominate a shot candidate** — device mic, host mic, FLIR-side detection, launch monitor. The host arbitrates and issues a canonical shot ID and t₀.
- **REQ-SHOT-2 (MUST)** The device accepts "send me the clip at t₀=X" for shots it never detected itself.
- **REQ-SHOT-3 (MUST)** The device mints its own identity (UUID + device timebase + acoustic fiducial) when no host is present, for later reconciliation — including against independently recorded launch monitor records.
- **REQ-SHOT-4 (MUST)** Candidates carry the nominating device's own timestamp and a confidence value.

### 6.4 Acoustic detection

The microphone's primary value is **not** annotating the device's own frames — on a known-equal timebase device, mic and camera are already aligned to sample precision. Its value is as a **shared physical fiducial** between device and host, and as a replay alignment reference.

Three distinct jobs, which together justify treating it as core rather than corroborative:

1. Independent phone↔host clock verification per shot.
2. Exact impact anchor for replay navigation.
3. Alignment reference for two-shot comparison ([REQ-REPLAY-4](#101-v1)).

Requirements:

- **REQ-MIC-1 (MUST)** `AVAudioSession` mode `.measurement` (or platform equivalent) to disable AGC, EQ and noise suppression. Small IO buffer.
- **REQ-MIC-2 (MUST)** Onset refined to sample index within the buffer, not buffer granularity.
- **REQ-MIC-3 (MUST)** Correct for acoustic time of flight. At 343 m/s, ~2.9 ms/m; a device 2 m from the ball lags 5.8 ms — most of a frame at 150 fps. Host and device mic distances differ.
- **REQ-MIC-4 (MUST)** Time-of-flight distance must not require user measurement. Either solve it during per-session calibration, or estimate it as a free parameter from accumulated per-shot residuals between acoustic fiducial and network clock estimate. The latter is confounded with clock offset on a single shot but resolves over a session, and is nearly free given [REQ-SYNC-4](#53-clock-synchronisation). Placement behind the golfer (UC-2) makes this mandatory — the distance is user-chosen and cannot be hardcoded.
- **REQ-MIC-5 (MUST)** Discriminate transients: impact, ball-into-screen (~9 ms later at 3 m), club-on-mat, dropped club, adjacent player, speech. Onset detection is trivial; classification is the work.
- **REQ-MIC-6 (SHOULD)** Report detection confidence and transient classification with each candidate.

---

## 7. Capture

### 7.1 Optical configuration

- **REQ-OPT-1 (MUST)** Video stabilisation **off**. It warps geometry and destroys 2D shaft measurement. It is also incompatible with per-frame intrinsics delivery.
- **REQ-OPT-2 (MUST)** Autofocus locked — focus changes change focal length, and therefore intrinsics.
- **REQ-OPT-3 (MUST)** Auto-exposure locked — otherwise motion blur varies mid-swing.
- **REQ-OPT-4 (MUST)** Auto white balance locked.
- **REQ-OPT-5 (MUST)** Open a **physical** capture device, never a virtual multi-lens device. Virtual devices switch physical lenses automatically on scene and focus distance, silently changing intrinsics mid-session.
- **REQ-OPT-6 (MUST)** Lens selection is a calibration-affecting decision, recorded as such. Lens change within a session is forbidden, or invalidates calibration. Behind-the-golfer placement in a small studio may force ultra-wide, with heavy distortion and often a lower maximum frame rate.
- **REQ-OPT-7 (MUST)** Enable per-frame intrinsic matrix delivery where available (`isCameraIntrinsicMatrixDeliveryEnabled` on iOS). Free calibration data; requires stabilisation off in any case.

### 7.2 Frame rate

- **REQ-FPS-1 (MUST)** Enumerate supported formats and frame-rate ranges; never assume from a spec sheet.
- **REQ-FPS-2 (MUST)** Verify achieved rate from realised timestamp deltas. A format reporting a 1–240 range will accept a 150 fps request; confirm it is not delivering 120 with duplicates.
- **REQ-FPS-3 (MUST)** Report achieved intervals per shot ([REQ-CAP-3](#55-capability-declaration)).

**Device landscape (verify at implementation):** iPad Pro (M4) and iPad Air (M4) both list 1080p at 120 and 240 fps, so current iPads clear a 120 fps gate at 1080p — an earlier assumption that iPads were replay-only was wrong. They remain single-rear-camera f/1.8 with no lens choice and a smaller sensor than a contemporary iPhone Pro, so they pass the frame-rate gate but must be independently assessed on the light gate ([REQ-CAP-4](#55-capability-declaration)). Older iPads are far weaker (2015 iPad Pro: 720p120 only). On Android, high-speed capture requires the `CONSTRAINED_HIGH_SPEED_VIDEO` capability and a constrained session; 720p and 1080p at 120/240 are widely available but vendor-variable.

### 7.3 Resolution

- **REQ-RES-1 (MUST)** Target **1080p at the highest sustainable frame rate**. Do not reach for 4K.
- **REQ-RES-2 (SHOULD)** Do not foreclose 4K. Capability declaration ([§5.5](#55-capability-declaration)) already lets a device offer 4K120 and the host accept or ignore it. No requirement changes are needed to keep the door open.

**Rationale.** Resolution is not the binding constraint, and reaching for it costs on four axes that are:

- **The reference results were obtained at 1080p-class resolution.** The FLIR Chameleon3 cameras behind the 0.49° face-on RMSE are sub-2MP, and the candidate IMX273 upgrade sensors are 1440×1080. 4K on the phone would make it the highest-resolution camera in the rig, adding heterogeneous-resolution handling to fusion for an undemonstrated benefit. The DTL/face-on accuracy gap (2.44° vs 0.49°) is geometry and contrast, not pixel count.
- **Motion blur does not improve.** Where blur dominates — near impact, where the wedge regime exists — the streak is twice as long in pixels but the shaft is also twice as wide. The ratio is unchanged, so no accuracy is recovered in the hardest regime.
- **SNR degrades.** 1080p high-speed modes use binned readout; 4K reads closer to native. Same exposure, smaller effective photosite, more noise — entering directly into the `min(|I−B|, |I−I_prev|)` differencing used for motion evidence. Light is already the scarcest resource ([REQ-LIGHT-1](#74-light)).
- **Rolling shutter degrades.** Readout time scales with rows read, so 4K means materially more skew across the frame — a direct geometric error on exactly the fast-moving object being measured.

Additionally, 4K forces 120 fps where 1080p allows 150+ (trading temporal for spatial is the wrong direction given the documented ≥100 fps requirement and streak-based speed measurement); it multiplies ring buffer, encode, storage, transfer and thermal cost fourfold; and 4K120 exists only on iPhone 16 Pro and later — a poor fit for [UC-1](#uc-1--entry-level-capture-primary), whose defining characteristic is that the user could not afford machine-vision cameras.

Resolve by measurement rather than argument — see [REQ-TEST-7](#133-capture-path-experiments).

### 7.4 Light

- **REQ-LIGHT-1 (MUST)** Measure achievable exposure before committing to a capture profile. At 150 fps the exposure ceiling is 6.67 ms, but blur control wants ~0.5 ms; a small sensor at 1/2000 s indoors will be noisy. This is the binding constraint on how useful the video is.
- **REQ-LIGHT-2 (SHOULD)** Surface a light warning at arm time when the achievable exposure will not support the requested analysis.

### 7.5 Clip container

- **REQ-CLIP-1 (MUST)** MP4/HEVC plus a sidecar carrying: per-frame timestamps, intrinsics, device attitude and gravity, exposure and ISO per frame, detected event times and confidences, acoustic time-of-flight constant, thermal state timeline, clock-sync residuals, capability triple, calibration state, lens identity.
- **REQ-CLIP-2 (MUST)** Identical schema on wire and on disk ([REQ-STANDALONE-2](#4-standalone-operation)).
- **REQ-CLIP-3 (MUST)** Timing information must not live only in the wire protocol, or store-and-forward becomes impossible to add later.

### 7.6 Buffering

- **REQ-BUF-1 (MUST)** Continuous capture into a rolling buffer of hardware-encoded fragments (~0.5 s, IDR at each boundary), retaining ~20 fragments; concatenate on trigger. Raw 1080p150 is ~466 MB/s and is not a RAM ring buffer.
- **REQ-BUF-2 (MUST)** The fragment/GOP length is fixed by two independent requirements — ring-buffer tractability and frame-accurate reverse stepping at capture rate ([REQ-REPLAY-1](#101-v1)). Record this rationale; it must not later be "optimised" for bitrate.
- **REQ-BUF-3 (MUST)** Determine the operating bitrate by measurement against the shaft detection pipeline, not by perceptual judgement. See [REQ-TEST-6](#133-capture-path-experiments).
- **REQ-BUF-4 (SHOULD)** The buffer design must tolerate platforms that do not offer clean per-frame access. Android's constrained high-speed session accepts only batched request lists and a limited surface set, typically preview plus recorder — encode-to-fragments works on both platforms where a raw frame buffer does not.

**On compression fidelity.** The risk is bitrate starvation, not inter-frame prediction as such. At 150 fps a clubhead at 100 mph travels ~0.3 m between frames — far outside any practical motion-estimation search range — so the encoder finds no match and codes those blocks as intra. It degrades into locally-intra behaviour precisely where motion is fastest, which is the desired behaviour; what it needs to do that well is bits. All-intra encoding is held in reserve as a fallback should the bitrate sweep show an uncomfortably high knee. Session footage totals only ~150 s ([§16.2](#162-volume-and-storage)), so all-I is affordable if needed — but note that 1080p150 sits at HEVC Level 5.1, capping at 40 Mbps Main tier and 160 Mbps High tier, and whether VideoToolbox emits High Tier should not be assumed.

### 7.7 Encoder configuration

- **REQ-ENC-1 (MUST)** Set `kVTCompressionPropertyKey_ExpectedFrameRate` (or platform equivalent) explicitly. The encoder does **not** infer frame rate from the buffers it is fed. Apple DTS confirmed that an otherwise identical capture-to-ring-buffer pipeline reached only 80–90 fps of a requested 120 until this property was set, after which it reached full rate on the same hardware. In this system a silently degraded encode rate manifests as dropped frames in the ring buffer — exactly the failure [REQ-CAP-3](#55-capability-declaration) exists to detect.
- **REQ-ENC-2 (MUST)** `RealTime = true`.
- **REQ-ENC-3 (MUST)** `AllowFrameReordering = false`. B-frames introduce reordering delay and complicate frame-accurate extraction from a ring buffer. Correct independently of any bitrate or GOP decision.
- **REQ-ENC-4 (MUST)** Verify sustained encode rate **under thermal load after ~40 minutes**, not from cold. Published throughput figures are cold-start measurements.

**Throughput is not the constraint.** 4K120 (~996 Mpixel/s) is demonstrated on current hardware. 1080p120 is ~249 Mpixel/s, 1080p150 ~311, 1080p240 ~497 — between a quarter and a half of demonstrated capability. Stock camera apps already record 1080p240 in HEVC.

---

## 8. Session model

- **REQ-SESS-1 (MUST)** Session is a first-class object: start, calibration state, device roster, context changes (club, shot type), end.
- **REQ-SESS-2 (MUST)** Sessions exist without a host.
- **REQ-SESS-3 (MUST)** The device library is an **independent store with per-shot sync state** (local / sent / confirmed), not a cache of PinPoint.
- **REQ-SESS-4 (MUST)** Nothing unconfirmed is evicted, regardless of retention policy.
- **REQ-SESS-5 (MUST)** Decouple event from payload: a small event message (timestamps, confidence, thumbnail) goes immediately on a low-latency channel; video follows on a bulk channel permitted to lag, queue, resume, or never complete within the session.
- **REQ-SESS-6 (MUST)** Bulk transfer is queued, resumable and backpressure-aware. A rapid range session produces shots faster than upload.

A session where every shot is correlated and half the video syncs later is a success, not a failure.

---

## 9. Device lifecycle and resource management

### 9.1 State machine

Host-controlled, three capture states crossed with review state.

| State | Session | Buffer | Entered by |
|---|---|---|---|
| **Cold** | torn down | none | keepalive lapse, thermal/battery limit |
| **Warm** | running, locked, settled | not retained | host connect |
| **Armed** | running, locked, settled | retaining | host arm command |

- **REQ-STATE-1 (MUST)** Capture start/stop is host-controlled, not app-controlled.
- **REQ-STATE-2 (MUST)** Warm exists so arming incurs no AE/AF settling penalty. Rebuilding a capture session costs roughly a second plus settling time — and the first shot after a cold re-arm is exactly the one not to lose.
- **REQ-STATE-3 (MUST)** Keepalive lapse drops warm → cold. This is a battery mechanism as much as a thermal one.
- **REQ-STATE-4 (MUST)** Armed + reviewing is the normal range state (UC-3), not an edge case.
- **REQ-STATE-5 (MUST)** Handle and recover from platform interruptions (calls, audio session interruption, backgrounding) with automatic re-arm and explicit reporting of the gap.

### 9.2 Priority rule

> **Capture is non-recoverable; replay is repeatable. Under any resource constraint, replay degrades first and capture degrades last.**

- **REQ-RES-1 (MUST)** Replay never disarms capture and never tears down the capture session.
- **REQ-RES-2 (MUST)** Replay yields decode bandwidth, playback smoothness and resolution before the ring buffer loses a single frame.
- **REQ-RES-3 (MUST)** Thermal state is a first-class protocol field, so the host can report degradation rather than silently producing worse data.
- **REQ-RES-4 (MUST)** State a measured battery target — e.g. a 90-minute session on a full charge — and treat it as a verified requirement.
- **REQ-RES-5 (SHOULD)** Address the charging trade-off explicitly: charging during capture adds heat and may cost more thermally than it gains in battery.

---

## 10. Application functionality

### 10.1 v1

**Guided setup and framing validation.** Case UC-1 users will place the device badly and will not know it.

- **REQ-SETUP-1 (MUST)** At arm time, verify the golfer is fully in frame at address *and* at top of backswing (the club exits frame constantly), light is sufficient for the required exposure, and the device is stable.
- **REQ-SETUP-2 (SHOULD)** The device classifies its own viewpoint ("DTL, right-handed") and reports it, rather than asking the user to configure it.
- **REQ-SETUP-3 (MUST)** Framing validation may use platform body-pose detection. This is not analysis and does not move the line ([§2.3](#23-advisory-pose-v2)).

**Local replay.**

- **REQ-REPLAY-1 (MUST)** Frame-accurate stepping in both directions at capture rate.
- **REQ-REPLAY-2 (MUST)** The timeline is addressed in **time**, never frame index.
- **REQ-REPLAY-3 (MUST)** Impact fiducial rendered on the timeline and available as a scrub target.
- **REQ-REPLAY-4 (MUST)** Two-shot comparison synchronised on **impact**, not clip start.

**Markup.**

- **REQ-MARK-1 (MUST)** Markup is a **user artefact, not derived data**: anchored to shot ID plus frame timestamp, round-trips losslessly.
- **REQ-MARK-2 (MUST)** Markup authored on the device appears in PinPoint. The link is bidirectional for content, not only for commands — the protocol must permit host-originated and device-originated payloads in v1 even if only annotations flow back initially.
- **REQ-MARK-3 (SHOULD)** Finger-drawn plane and alignment lines. This is one of the few interactions genuinely better on a touch device than with a mouse.

**Metadata that cannot be recovered later.**

- **REQ-META-1 (MUST)** Capture device attitude and gravity continuously — this constrains extrinsics substantially and costs nothing.
- **REQ-META-2 (SHOULD)** Time, location, and for outdoor sessions weather. Capture from v1 even if nothing consumes it yet.

### 10.2 v2

- Advisory pose for replay annotation (hand path DTL, etc.) — [§2.3](#23-advisory-pose-v2)
- Upload triage: a local check for "real swing / golfer in frame / club moved" to avoid spending bandwidth on practice swings and dropped clubs. This is where on-device inference earns its place — triage, not analysis.
- Voice club tagging. Hands hold a club; the device is 2 m away on a tripod. The audio stream is already open, so this is a second consumer of existing infrastructure. Club context is not cosmetic: diagnostics corridors are club-specific.
- Second screen for host-computed results (UC-5).
- Offline sensor capture and export: IMU, then HackMotion via `libwrist` ([§16.6](#166-sequencing)).

### 10.3 v3 and beyond

- Multi-device stereo (UC-6). The acoustic oracle stops being corroborative and becomes essential — two devices share no wired clock, so impact is the only common fiducial. Confirm the sync design tolerates peer-to-peer, not only star.
- Relayed BLE sensors via `libwrist` — the device as portable capture hub. Enabled by [REQ-STREAM-1](#54-streams) as a new stream type rather than a new protocol.
- Camera phase alignment for co-timed stereo frames.
- Android implementation.

---

## 11. Security and privacy

- **REQ-PRIV-1 (MUST)** No unpaired host receives video. TLS-PSK from QR ([REQ-AUTH-1](#62-pairing-and-authentication)).
- **REQ-PRIV-2 (MUST)** Audio retention policy is explicit, user-visible and configurable, and honestly reflected in the platform purpose string and privacy label. See [OPEN-2](#open-decisions).
- **REQ-PRIV-3 (MUST)** No telemetry. Field diagnosis is via user-initiated export ([§12](#12-observability)).

The lesson use case (UC-5) means continuous audio may capture a coach and pupil in conversation. That has a materially different privacy posture from video of a swing.

---

## 12. Observability

FOSS project, no analytics, users reporting "it lost sync" on GitHub. The diagnostic bundle is the only channel into the field.

- **REQ-OBS-1 (MUST)** Exportable diagnostic bundle as a first-class output, not a debug log: sync residual history, achieved frame intervals, drop counts, thermal timeline, detection events with confidences, transfer queue history, capability triple.
- **REQ-OBS-2 (MUST)** User-initiated, attachable to an issue.
- **REQ-OBS-3 (SHOULD)** The same bundle serves as the project's own validation record.

---

## 13. Testing and validation

A distributed timing system cannot be debugged by manual testing on a mat.

### 13.1 LED timecode rig

Build this **before** the protocol.

- **REQ-TEST-1 (MUST)** A host-driven LED flashing a binary-coded pattern at ~1 kHz, in view of both the device and the FLIR cameras. Each frame decodes an absolute host timestamp.
- **REQ-TEST-2 (MUST)** This yields per-frame ground truth on end-to-end alignment, and — because different sensor rows decode different codes — measures rolling-shutter readout time in the same experiment ([REQ-EXP-3](#52-exposure-convention)).

### 13.2 Harness

- **REQ-TEST-3 (MUST)** A recorded-session fixture format (frames, timestamps, audio, sync exchanges) replaying deterministically through the whole library. Capture once, regress forever.
- **REQ-TEST-4 (MUST)** An injectable clock, so offset and skew can be simulated.
- **REQ-TEST-5 (MUST)** A software device simulator the host side develops against. Without it, every PinPoint-side change needs a physical device and a golf swing.

### 13.3 Capture path experiments

Two measurements close the remaining open questions in the capture path. Both run on the same rig in one session, and both are scored on **shaft RMSE against an uncompressed reference**, never on a perceptual metric.

- **REQ-TEST-6 (MUST)** **Bitrate sweep.** Short-GOP, no-B-frame HEVC at ~30 / 60 / 100 Mbps. Expected outcome: a knee well below the Level 5.1 ceiling, retiring the all-intra question without needing to answer it. Result sets the operating bitrate ([REQ-BUF-3](#76-buffering)).
- **REQ-TEST-7 (MUST)** **Resolution comparison.** Same swing, same lighting, 1080p150 versus 4K120. Expected outcome: 4K loses on SNR and rolling shutter with the temporal loss compounding it ([§7.3](#73-resolution)). Record the measurement in the device profile rather than the expectation in this document.

---

## 14. Licensing and distribution

- **REQ-LIC-1 (MUST)** Protocol specification published openly.
- **REQ-LIC-2 (MUST)** `libppcp` MIT-licensed, so GPL PinPoint may link it and App Store apps may use it — the same reasoning that drove `libwrist`'s relicensing.
- **REQ-LIC-3 (MUST)** One implementation of the wire format, used by both ends. Two hand-written implementations always drift.
- **REQ-LIC-4 (MUST)** The **app's** licence is a distribution decision independent of the library's. GPL and App Store distribution are contested (the VLC precedent) because store redistribution terms conflict with GPL §6. See [OPEN-4](#open-decisions).
- **REQ-LIC-5 (MUST)** LGPL and other copyleft dependencies stay out of the MIT library ([REQ-TRANS-3](#57-transport-independence)).

### 14.1 Name clearance — pre-submission gate

- **REQ-LIC-6 (MUST)** Complete a trademark clearance check on "PinPointCapture" and "PinPoint" **before first App Store submission**, not before development starts.

**Rationale and current position (checked 21 August 2026, treat as a snapshot).**

Apple will not reject the name. Apple performs no trademark assessment; app names need only be unique within App Store Connect, and Guideline 4.1(c) targets deliberate copycats rather than coincidental use of a common word. "PinPointCapture" appears free as a string — the App Store holds many Pinpoint apps (Mobile, Workforce, Status, Tracking, AI, Works, GPS, Connect, Positioning), overwhelmingly GPS and fleet tracking, but none named PinPointCapture and none in golf. At 16 characters it is inside the 30-character name limit.

The exposure is separate and Apple neither screens for it nor protects against it: a rights holder files through Apple's Content Dispute process, Apple defers to the parties, and the app can be removed after the brand is established.

Marks worth resolving, US register:

| Mark | Serial | Relevance |
|---|---|---|
| PIN POINT GOLF | 98753725 (filed Sep 2024) | Golf training apparatus, practice mats and nets; **Class 9 distance measuring apparatus and laser range finders**. Closest live conflict. Status was unexamined at filing and needs current verification via USPTO TSDR. |
| PIN POINT | 90476482 | Golf balls, Notice of Allowance 2021 |
| PINPOINT | 78122554 | Golf clubs and balls — abandoned 2005 |
| PINPOINT (Bose) | 90244159 | Class 9 noise-reduction software — different goods, unlikely to bite |

Equivalent UKIPO search required, the project being UK-based. Suggested classes: 9, 28, 41.

**Note on scope.** The exposure attaches to *PinPoint*, not to *Capture*. If it is real, `PinPointStudio`, the organisation name and the website already carry it — App Store submission does not create the risk, it makes it commercially visible in the golf field, which is precisely what a golf-sector rights holder monitors. Engineering does not depend on this resolving; branding and store submission do.

This document records register searches, not legal clearance. A qualified opinion is proportionate given four repos, a website and a store listing will carry the name.

### 14.2 Open protocol commitment

Publishing the specification means the second of these, not the first:

| | PinPoint's protocol | Open capture protocol |
|---|---|---|
| Spec | follows implementation | normative, precedes implementation |
| Breaking changes | acceptable | require deprecation cycle |
| Conformance | none | test suite |
| Documentation | for the author | for implementers |
| Platform assumptions | iOS-shaped is fine | must not assume any platform |

This is a substantially larger commitment and is the stated intent. It is the reason [§5.1](#51-timebase-contract) and [REQ-CAP-5](#55-capability-declaration) are written as they are.

---

## 15. Host-side integration

- **REQ-HOST-1 (MUST)** The device lands behind PinPoint's existing camera abstraction as another device implementation, not as a bespoke integration — consistent with the standing rule that all device and product-specific code uses abstract base classes and a factory from the start.
- **REQ-HOST-2 (MUST)** One ingest path for both live and store-and-forward data.

---

## 16. Offline capture and export

Offline is not a degraded mode of the online path. It is the path [UC-1](#uc-1--entry-level-capture-primary) users spend most of their time in, and — once sensors arrive — the only way to capture wrist and IMU data at a range at all.

### 16.1 The unifying insight

- **REQ-OFF-1 (MUST)** An exported offline session **is a recorded PPCP stream replayed from a file**. The host gains a *file transport* for `libppcp`, not an importer.

Three artefacts collapse into one format: the export bundle, the test fixture format ([REQ-TEST-3](#132-harness)), and the store-and-forward path already required by [REQ-STANDALONE-2](#4-standalone-operation). One parser, one schema, one set of conformance tests. A separate "import" feature is how two ingest paths and a drifting schema come about.

Corollary: the regression harness is fed by real range sessions at no additional cost, which is a materially better corpus than anything synthesised.

### 16.2 Volume and storage

A session is ~50 shots × 3 s = **~150 seconds of video**, not continuous recording. At 50 Mbps that is ~940 MB; sensor streams are ~1 MB for per-shot windows, or ~35 MB even at 200 Hz continuous for 90 minutes. The video:sensor ratio is roughly 30:1, but the absolute figures are small.

- **REQ-OFF-2 (MUST)** Warn on low free space and refuse to arm below a floor. Graduated retention degradation is **not** required — at ~1 GB per session a modern device holds many sessions, so [REQ-SESS-4](#8-session-model) ("nothing unconfirmed is evicted") is straightforwardly satisfiable and is not in tension with storage pressure.
- **REQ-OFF-3 (MUST)** Export metadata and sensor streams **before** video. Not because video is slow — ~1 GB is seconds over USB and under a minute over decent WiFi — but so the host can validate, reconcile and commit before bulk data arrives, and so an interrupted transfer still yields an analysable session.

### 16.3 Clock authority inverts

Online, the host is the time authority. **Offline, the device is** — and it must do the job PinPoint's fusion layer currently performs: estimate offset and skew for every BLE sensor against its own clock.

- **REQ-OFF-4 (MUST)** The device estimates the device↔sensor clock mapping **live and continuously**, per sensor. Same machinery as [REQ-SYNC-1](#53-clock-synchronisation), pointed at BLE rather than the network.
- **REQ-OFF-5 (MUST)** The bundle carries **both** the estimated mapping **and** the raw arrival evidence (packet arrival times, connection-interval jitter, round-trip characteristics). Estimates age; evidence does not.
- **REQ-OFF-6 (MUST)** Every offline sample is expressed in the device's declared timebase with stated uncertainty ([REQ-TIME-2](#51-timebase-contract)).
- **REQ-OFF-7 (MUST)** The device's clock estimate is a **prior**, not authoritative. The host may re-solve on import with better algorithms.

**Why this is the section to get right.** The evidence needed to solve the sensor↔device mapping exists only at capture time. A device that records raw sensor timestamps and defers reconciliation to import has destroyed the information required to do it well, irrecoverably.

### 16.4 Wall clock versus monotonic

- **REQ-OFF-8 (MUST)** **Wall clock labels; monotonic measures.** Never compute an interval from wall clock. Record both, plus any observed discontinuity between them, and state in the bundle which is which. The device wall clock jumps on NTP correction, timezone change, manual adjustment and DST.

### 16.5 Export mechanics

- **REQ-OFF-9 (MUST)** Chunked, resumable and content-addressed.
- **REQ-OFF-10 (MUST)** Idempotent. Re-importing the same session is a no-op, never a duplicate. Users will connect twice.
- **REQ-OFF-11 (MUST)** Completeness is explicit session-level state, never inferred from what happens to have arrived. A partially transferred session must not present to the host as whole.
- **REQ-OFF-12 (MUST)** **Do not auto-merge on reconciliation.** The host may already hold partial data for the same session — a launch monitor record, or an online portion captured before WiFi failed. Surface candidate matches and require confirmation. A silent mis-merge corrupts the session record in a way that is hard to notice and harder to undo.

  Matching itself is tractable: ~50 ordered shots with inter-shot intervals is a well-determined sequence-alignment problem, and interval structure alone should be near-unique. The confirmation requirement is about the cost of being wrong, not the difficulty of being right.

- **REQ-OFF-13 (MUST)** Sensor dropout is recorded as an explicit **gap** with timestamps, never interpolated across. BLE will drop and offline there is no host to notice. Import must know exactly which shots have wrist coverage so a producer never silently runs on absent data.
- **REQ-OFF-14 (MUST)** **Any subset of streams is a valid bundle** — video-only, IMU-only, video+wrist, all three. Video-only bundles will exist for months before anything else does ([§16.6](#166-sequencing)), so the schema must tolerate missing streams from day one rather than gaining optionality later.

### 16.6 Sequencing

1. **Video offline capture and export.** First deliverable.
2. **IMU.** Before HackMotion, and not only on effort. The WitMotion integration is already understood, making it the honest testbed for BLE-under-capture. HackMotion carries unretired protocol risk — the device is not yet powered on, `libwrist` is young, and provisioning may prove to require the vendor app. The least-certain sensor must not define the offline sensor architecture.
3. **HackMotion via `libwrist`.**

- **REQ-OFF-15 (MUST)** Measure BLE + 120 fps capture + hardware encode, sustained, on one device, before the design hardens. The host-side ceiling was ~2 IMUs at 200 Hz on a standard adapter; iOS negotiates connection intervals conservatively and the radio is shared with WiFi.

### 16.7 Offline multi-device

- **REQ-OFF-16 (SHOULD)** Two devices capturing offline, both recording audio, can be aligned at import by cross-correlating the impact transient. No shared clock, no host required. This is the fourth distinct job the acoustic oracle performs ([§6.4](#64-acoustic-detection)) and is a further argument for treating it as core.

---

## 17. Platform portability

iOS/iPadOS ships first. Android is a near-term possibility, not a certainty. The requirement is therefore **not** to build Android now, but to ensure that building it later is a port rather than a rewrite.

[§5](#5-protocol-ppcp) already handles this at the protocol level. This section covers the **application**, which is where portability is usually lost.

### 17.1 Layering

- **REQ-PORT-1 (MUST)** The app decomposes into four layers with explicit boundaries:

| Layer | Shared? | Contents |
|---|---|---|
| Protocol | shared (`libppcp`) | wire format, clock sync, capability negotiation, session and shot model |
| Core logic | shared | state machine, ring buffer policy, shot arbitration client, transfer queue, session store, sync-state tracking |
| Platform capture | per-platform | camera, microphone, encoder, motion, storage, network primitives |
| UI | per-platform | native |

- **REQ-PORT-2 (MUST)** The **port surface** — the set of interfaces a new platform must implement — is explicitly enumerated and kept small. It is a documented artefact, not an emergent property of the code.
- **REQ-PORT-3 (MUST)** No platform type crosses an internal API boundary. `CMSampleBuffer`, `AVCaptureDevice`, `Image`, `CaptureResult` and their equivalents stay inside the platform capture layer.
- **REQ-PORT-4 (MUST)** The platform capture layer uses an abstract base class and factory from the start, consistent with the standing rule applied to all device and product-specific code in PinPointStudio.

### 17.2 Technology choice

- **REQ-PORT-5 (MUST)** UI is native per platform. Camera and encoder access must be native regardless, since neither high-speed capture nor hardware encode is meaningfully abstractable.
- **REQ-PORT-6 (MUST)** Shared layers are written in a language that binds cleanly to both platforms without a runtime — C or C++, consistent with `libwrist`.
- **REQ-PORT-7 (MUST NOT)** Do not use Qt for this app despite its use in PinPointStudio. Two independent reasons: camera, audio and encoder must be native on both platforms anyway, so the framework buys nothing where the difficulty actually is; and Qt's LGPL terms are a poor fit for App Store distribution, while a commercial licence is disproportionate to the project. This is a deliberate departure from the desktop stack, recorded so it is not revisited by habit.

### 17.3 Android-specific hazards to design around

These are known now and cheap to accommodate; they are expensive to retrofit.

- **REQ-PORT-8 (MUST)** **Do not assume camera and microphone share a timebase.** On iOS they do — `AVCaptureSession` video and audio buffers are both on `CMClockGetHostTimeClock()`. On Android, `SENSOR_INFO_TIMESTAMP_SOURCE` may report `UNKNOWN`, placing camera timestamps on a base comparable with nothing else on the device, while audio sits on `CLOCK_MONOTONIC`. The mic-to-camera offset is therefore a **measured, uncertainty-bearing value with a known-equal special case**, never a hardcoded zero. This is the app-level consequence of [REQ-TIME-2](#51-timebase-contract), and the single most likely place a port turns into a rewrite.
- **REQ-PORT-9 (MUST)** The capture abstraction must survive a platform that does not offer clean per-frame access. Android's constrained high-speed session accepts only batched request lists via `createHighSpeedRequestList` and a limited surface set, typically preview plus recorder. Encode-to-fragments ([REQ-BUF-1](#76-buffering)) works on both platforms where a raw frame buffer does not — see [REQ-BUF-4](#76-buffering).
- **REQ-PORT-10 (MUST)** Device profiles — rolling-shutter readout time, exposure convention, lens characteristics, measured capability — ship as **data keyed by device model**, not as code. Android's device population makes a code-based approach untenable and iOS will benefit equally.
- **REQ-PORT-11 (MUST)** Capability is expressed in protocol vocabulary, never in platform vocabulary. An `AVCaptureDevice.Format` and a `StreamConfigurationMap` entry must reduce to the same declared capability structure ([§5.5](#55-capability-declaration)).
- **REQ-PORT-12 (MUST)** The on-disk session store and clip sidecar schema contain no platform-specific concepts. A session captured on Android must be indistinguishable to the host from one captured on iOS, except where the device honestly declares a difference.
- **REQ-PORT-13 (SHOULD)** Permission, discovery and background-execution models differ materially. Keep permission acquisition and its failure handling in the platform layer, and have core logic consume a platform-neutral readiness state rather than platform permission results.

### 17.4 Scope discipline

- **REQ-PORT-14 (SHOULD)** Do not build platform abstractions speculatively beyond the port surface. The obligation is that the seams exist and no platform type leaks across them, not that every interface be pre-generalised against a hypothetical second implementation.

---

## Open decisions

| ID | Decision | Recommendation |
|---|---|---|
| ~~OPEN-1~~ | ~~Naming.~~ | **Resolved.** PinPointCapture (app), PPCP (protocol), libppcp (library). The vendor-name concern was overstated — licence and specification quality drive adoption, not the acronym. Trademark clearance tracked separately as [REQ-LIC-6](#141-name-clearance--pre-submission-gate). |
| **OPEN-2** | Audio retention. Keep the full track, a window around impact, or none? | Retain a short window around impact only; discard the rest at the ring buffer; make it user-visible and configurable. **Blocks schema work** — decide first. |
| **OPEN-3** | Minimum device tier. Is 120 fps the floor, and at what resolution and light level? | 120 fps at 1080p as ingest policy; add a measured optical quality gate ([REQ-CAP-4](#55-capability-declaration)) rather than relying on frame rate alone. |
| **OPEN-4** | App licence and distribution channel. | Non-GPL for the app if App Store distribution is wanted; the library stays MIT either way. |
| **OPEN-5** | Version support window ([REQ-VER-3](#56-versioning)). | State a minimum of N releases back, with a written deprecation path. |
| **OPEN-6** | Does v1 ship tethered-only, deferring the standalone UI? | Defensible. But the **formats** must be standalone-ready from day one — the UI can wait, the schema cannot. |
| **OPEN-7** | How much core logic is genuinely shared vs. reimplemented natively per platform ([§17.1](#171-layering))? | Decide when the port surface is first enumerated, not now. The binding requirement is that the seams exist and no platform type leaks across them ([REQ-PORT-3](#171-layering)); how much sits behind them can be settled later. |

---

## Appendix A — Governing principles

Stated in the same register as PinPoint's diagnostics specification principle, and intended to constrain future change rather than describe current behaviour.

1. **The device may display anything and compute nothing beyond advisory pose.** Moving this line requires an explicit decision recorded against this requirement, not an incremental feature.
2. **Capture degrades last.** Every resource-contention decision resolves in favour of frames retained.
3. **Every capability degrades to standalone.** A host-only feature requires a stated offline behaviour, not an error.
4. **One schema, one ingest path.** Wire and disk formats are identical.
5. **Offline is the normal case, not the fallback.** An exported session is a recorded protocol stream; the host has one ingest path for both.
6. **Nothing assumes a platform.** Timebases, capabilities and conventions are declared, not implied — in the protocol, and equally in the app. No platform type crosses an internal boundary.

---

## Appendix B — References

- Ansari, Wadhwa, Garg, Chen. *Wireless Software Synchronization of Multiple Distributed Cameras.* ICCP 2019. arXiv:1812.09366. Implementation: `google-research/libsoftwaresync`.
- *Sub-millisecond Video Synchronization of Multiple Android Smartphones.* arXiv:2107.00987.
- *Twist-n-Sync: Software Clock Synchronization with Microseconds Accuracy Using MEMS Gyroscopes.*
- Apple: iPad Pro (M4) and iPad Air (M4) technical specifications; App Review Guidelines and Before You Submit.
- Android: `CameraConstrainedHighSpeedCaptureSession`, `CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE`.
- PinPoint Studio: shaft detection validation (face-on 0.49° RMSE; DTL 2.44° RTS RMSE, ≥100 fps requirement), IMU/vision fusion architecture (P1 clock bias estimation).
