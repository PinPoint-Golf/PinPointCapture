# Capability spike — iOS hard limits and build parameters

**What the hardware and the platform will actually do, and the numbers the build is parametrised with.**

| | |
|---|---|
| Status | First pass, 23 August 2026 |
| Purpose | To replace scattered literals with one parametrised set, and to state the hard limits that must not be exceeded whatever a device claims |
| Source | [PRD](capture-companion-requirements.md) · [conformance claim](../conformance/ppcp-conformance.md) · the tree as at `d4768ca` |
| Scope | iPhone and iPad, iOS 18+. Android is [§17](capture-companion-requirements.md#17-platform-portability)'s problem and appears here only where a number would not survive the port |

## ⛔ How to read the provenance column

This project's governing habit is that nothing claims to be measured when it is not — plan A12, `CORE` 5.8b, and the reason `DeviceProfiles.json` is a wall of `assumed`. A capability spike is exactly where that discipline is most easily lost, because a table of confident numbers reads as authority.

So every figure below carries one of these, and **the majority are not measurements**:

| Mark | Meaning |
|---|---|
| **M** | **Measured** on this project's hardware, with the date and the instrument |
| **V** | **Vendor-documented** — Apple's published figure or an API contract |
| **D** | **Derived** by arithmetic from an M or a V, shown |
| **A** | **Assumed** — a defensible starting value nobody has verified. ⚠ The largest column |

⚠ **An `A` in this document is not a decision.** It is a parameter with a plausible value and no evidence, and it stays `A` until [§9](#9-what-must-be-measured-before-any-of-this-hardens) retires it.

---

## 1. The device tier

**OPEN-3** asks what the floor is. The frame-rate half is implemented as `HostIngestPolicy.pinPointStudioCurrent` — 1080p at ≥120 fps — and REQ-CAP-6 now requires the app to name whose policy that is. The optical half does not exist: no device has a measured noise or contrast figure.

| Class | Capability | Provenance |
|---|---|---|
| iPhone 16 / 16 Pro and later | 1080p at 120 and 240 fps, wide and ultra-wide | **M** — `enumerateCapability` on an iPhone 16, 23 Aug |
| iPad Pro (M4), iPad Air (M4) | 1080p at 120 and 240 fps, single rear camera | **V** — Apple tech specs, quoted in PRD §7.2 |
| Older iPads | 720p120 only on a 2015 iPad Pro | **V** — PRD §7.2 |
| Android | `CONSTRAINED_HIGH_SPEED_VIDEO` required; 720p/1080p at 120/240 widely available, vendor-variable | **V** — PRD §7.2 |

⚠ **Ranking is frame-rate-first, then resolution, then lens** (REQ-FPS-1, amended 23 Aug). An iPhone 16 reports a 4032×3024 stills format that beats 1080p240 on pixels; a naive "best format" selection put it on the capability card. The lens term exists because the same device offers 1080p240 on **both** wide and ultra-wide and REQ-OPT-6 forbids changing lens mid-session — so an arbitrary tie-break can fix a session's calibration against the distorting lens.

---

## 2. Camera and `AVCaptureSession`

### Hard limits

⛔ **One physical camera, one format, for the life of a session.** Not a policy — REQ-OPT-5 forbids virtual multi-lens devices (they switch physical lenses on scene and focus distance, silently changing intrinsics), and REQ-OPT-6 makes a lens change invalidate calibration.

⛔ **No `AVCaptureMultiCamSession`.** It exists, and on paper two cameras at once is attractive for DTL-plus-face-on from one device. It is ruled out on three independent grounds, any one of which is sufficient: it does not support the high-frame-rate formats (**A** — needs confirming per model, and it is the one worth confirming); it raises thermal load on the axis that is already binding; and REQ-OPT-6's per-session lens fixity means two lenses is two calibrations. **Two viewpoints is two devices** (UC-6), not one device with two cameras.

⛔ **`alwaysDiscardsLateVideoFrames = false` on the capture path.** Already so, and deliberately the opposite of the self-test, which sets it `true` because it wants drops visible (REQ-CAP-3). §9.2 makes capture degrade last, so the capture path must not be the place frames are thrown away.

⛔ **Locks are set once, at warm, and not touched again**: focus, exposure, white balance, stabilisation off, per REQ-OPT-1..4. Stabilisation is doubly forbidden — it warps geometry *and* is incompatible with per-frame intrinsics delivery.

### Parameters

| Parameter | Value | Prov | Note |
|---|---|---|---|
| `activeFormat` | best by (fps, height, lens) | **M** | `AVFoundationCaptureDevice.bestMode` |
| Frame-rate range | both ends pinned | **M** | Setting only the max lets the device drop |
| `isCameraIntrinsicMatrixDeliveryEnabled` | `true` | **M** | Free calibration data (REQ-OPT-7); requires stabilisation off, which is required anyway |
| Exposure convention | `nominal_frame_start` | **M** | Every AVFoundation source. Requires the offset field and its provenance (`CORE` I22) |
| `frame_start_to_exposure_offset_ns` | `0` | **A** | ⚠ Every device profile. No model has been through an LED rig |
| Rolling-shutter readout | `1.0 × frame interval` | **A** | ⚠ Placeholder. Real values differ per sensor and per binning mode |

---

## 2a. Capabilities checked and rejected

⚠ **This section exists so nobody reaches for these again.** Each was a reasonable
idea, each was checked against the **iOS 27.0 SDK headers** on 24 August 2026, and
each is written down with what was searched — so the next person can confirm the
answer has not changed rather than re-derive it.

### Retrospective capture — "ask the camera for the last N seconds"

**Not available.** `AVCapture*.h` and `AVAssetWriter*.h` contain no `retrospective`,
`preRoll`, `prerecord`, `rollingBuffer` or `pastFrames` — zero hits across the
capture headers.

The one built-in retrospective mechanism is **Live Photos**
(`AVCapturePhotoOutput.livePhotoMovieFileURL`, ~1.5 s either side of the shutter),
and it is the wrong shape on every axis: it is tied to a still capture rather than a
continuous armed session; the movie is a fixed low-rate format and cannot be driven
at 1080p150; the window is not adjustable; and it cannot be triggered from an
acoustic detector with a sample-accurate `t₀`. The stock Camera app's
capture-before-the-shutter behaviour is private plumbing.

⛔ **So the ring is ours to own, and its correctness is ours too.** There is no
platform guarantee that fragment boundaries are IDR-aligned or that a concatenation
of retained fragments decodes — `RingBufferRecorder` must guarantee both, and E1.2
must prove it rather than assume the writer did it.

⚠ This is a case where the absence is *fortunate*. An iOS-only ring API would have
been a trap: `REQ-BUF-4`/`REQ-PORT-9` note that Android's constrained high-speed
session offers no clean per-frame access either, so encode-to-fragments is the one
design that survives both platforms.

### Frame clipping / region of interest

**Not available in the sense that would help.** On a machine-vision camera, ROI
reduces *sensor readout* — fewer rows means a higher frame rate and less
rolling-shutter skew. That is the trade worth reaching for, and iOS does not offer
it: a format fixes the readout, and there is no partial-readout API.

What the headers do contain, and what each actually is:

| Symbol | What it is | Use to us |
|---|---|---|
| `focusRectOfInterest`, `exposureRectOfInterest` | iOS 26 — where the camera *meters* | None. Metering region, not readout |
| `AVCaptureMetadataOutput.rectOfInterest` | where to look for barcodes and faces | None |
| `centerStageRectOfInterest` | `API_UNAVAILABLE(ios)`, and Center Stage is disqualified anyway | None |
| `AVCaptureScreenInput.cropRect` | **screen recording, macOS** | None — not the camera |
| `videoScaleAndCropFactor`, `videoZoomFactor` | a genuine crop, applied **after** readout | See below |

A post-readout digital crop gives **no** frame-rate gain, **no** rolling-shutter
improvement — the same rows are read, so the skew across the frame is unchanged —
and worse SNR if the result is scaled back up. The only saving is encode-side, and
that is bought more cheaply and more honestly by setting the bitrate, which
**E-M2** will do by measurement.

⛔ **And a crop is not free.** REQ-OPT-7 has this device delivering the per-frame
intrinsic matrix; cropping moves the principal point and changes focal length in
pixels. A crop is therefore a *calibration-affecting decision* in exactly the sense
REQ-OPT-6 means — the same class as a lens change, which is forbidden mid-session.
Were ROI ever adopted it would have to be **fixed at session start and declared** on
the `CaptureProfile` (`CORE` §5.7), or the host's intrinsics would silently disagree
with the frames it was given.

✅ **The supported route to "fewer pixels, faster" needs no ROI API at all.** A
device offering a binned or windowed high-speed mode exposes it as an ordinary
`AVCaptureDevice.Format`, and `bestMode`'s frame-rate-first ranking picks it up
already.

### `AVCaptureMultiCamSession`

Covered in [§2](#2-camera-and-avcapturesession) — ruled out on three independent
grounds. Restated here because it is the third thing that looks like an obvious win
and is not: **two viewpoints is two devices**, and three simultaneous device links
to one host were verified against PinPointStudio on 23 August.

---

## 3. Encoder and `VideoToolbox`

### Hard limits

⛔ **One encode session while armed.** The hardware encoder is a shared, finite resource. A second concurrent high-rate encode — a preview transcode, an export, a thumbnail batch — competes with the ring, and the ring is the thing that must not lose a frame.

⛔ **`ExpectedFrameRate` must be set explicitly.** Apple DTS confirmed an otherwise identical pipeline reached only 80–90 fps of a requested 120 until this property was set (**V**, PRD §7.7). A silently degraded encode rate manifests as ring-buffer drops, which is the failure REQ-CAP-3 exists to detect.

⛔ **`AllowFrameReordering = false`, `RealTime = true`.** B-frames add reordering delay and complicate frame-accurate extraction from a ring. Correct independently of any bitrate decision.

### Parameters

| Parameter | Value | Prov | Note |
|---|---|---|---|
| Codec | HEVC | **V** | Stock camera records 1080p240 HEVC |
| Level | 5.1 at 1080p150 | **V** | Caps at 40 Mbps Main tier, **160 Mbps High tier** |
| Operating bitrate | **50 Mbps** | **A** | ⚠ Load-bearing and unmeasured — see E-M2. Above the 40 Mbps Main-tier cap, so whether VideoToolbox emits High tier **must not be assumed** |
| GOP / fragment | 0.5 s, IDR at each boundary | **A** | Fixed by two independent requirements (REQ-BUF-2) and explicitly not a bitrate knob |
| Throughput headroom | 1080p150 ≈ 311 Mpixel/s vs ≈996 demonstrated at 4K120 | **D** | Between a quarter and a half of demonstrated capability |

⚠ **The bitrate is the single most consequential `A` in this document.** REQ-BUF-3 requires it be set by measurement against shaft-detection RMSE, never by perceptual judgement. 50 Mbps is a placeholder chosen to sit between the sweep's endpoints, not a result.

---

## 4. Ring buffer

**Disk-backed, not RAM.** Raw 1080p150 is ~466 MB/s (**D**: 1920×1080×1.5 bytes NV12 × 150) and is not a memory ring. `RingBufferRecorder` uses `AVAssetWriter` segmented output; what is retained is an index of encoded fragments.

| Parameter | Value | Prov | Derivation |
|---|---|---|---|
| `fragmentSeconds` | 0.5 | **A** | REQ-BUF-1/2 |
| `fragmentCapacity` | 20 | **A** | REQ-BUF-1 "~20 fragments" |
| Retained window | **10.0 s** | **D** | 0.5 × 20 |
| Ring footprint at 50 Mbps | **≈62 MB** | **D** | 10 s × 6.25 MB/s |
| Clip window | 1.5 s pre + 3.0 s post = **4.5 s** | **A** | `DetectAndMint.Configuration` |
| Clip size at 50 Mbps | **≈28 MB** | **D** | 4.5 s × 6.25 MB/s |

### ⚠ Two numbers in the PRD do not survive this arithmetic

**§16.2 says a session is ~50 shots × 3 s = ~150 s, ~940 MB at 50 Mbps.** The detector's actual clip window is **4.5 s**, not 3 s. So a 50-shot session is **~225 s and ~1.4 GB** — half again as large as the figure REQ-OFF-2's "many sessions on a modern device" rests on.

Either the clip window should come down to 3 s, or §16.2's volume figures should go up. **They must not disagree**, because REQ-OFF-2's storage floor and A7's "room for about 40 sessions" are both computed from it. My recommendation is to fix the PRD rather than the window: 1.5 s of pre-roll is defensible for a swing that starts before impact, and a shorter post-roll is the cheaper cut if one is needed.

### What the desktop buffer teaches, and where the substrate diverges

PinPointStudio has a mature, tested event buffer (`src/Buffer/`) solving a problem
that rhymes with this one: many sources at different rates, merged onto one
timeline, with a bounded window extracted around an event. It is worth reading
before building E1, and worth **not** copying.

**The substrate cannot transfer.** `SourceRing` is a RAM ring of *raw frames* —
pre-allocated slots, one producer per source, seqlock zero-copy reads validated by
a generation counter. Its window is 4 s, sized per source as the next power of two
≥ `rate × window_seconds`. That works on a desktop with machine-vision cameras. On
a phone the arithmetic ends it:

| 4 s of 1080p150 | Bytes | |
|---|---|---|
| Raw, NV12 | 1920×1080×1.5 × 150 × 4 | **≈1.87 GB** — **D** |
| Encoded at 50 Mbps | 6.25 MB/s × 4 | **≈25 MB** — **D** |

⛔ **Three orders of magnitude, and the larger number is past what iOS will let a
foreground app hold.** This is REQ-BUF-1's "encode to fragments, not raw frames"
restated as a measurement, and it is why `RingBufferRecorder` exists. A second,
independent blocker: the high-speed path offers no clean per-frame access anyway,
so a slot-based producer has nothing reliable to put in a slot (REQ-PORT-9).

**Three things do transfer, and should be reimplemented rather than linked:**

- **`TimelineIndex`** — a power-of-two ring of index *entries* with multi-source
  merge and `snapshot(t_start, t_end)`. PPC needs it: `FragmentRing` indexes video
  only, while a session also carries audio windows, IMU samples and interruption
  records. Entries are not payloads, so the memory objection does not apply.
- **The `SwingWindow` / payload-source *shape*** — a frozen, bounded time-range
  view over a pluggable backing. PPC treats "extract a clip" (E1.2) and "read a
  bundle back" (E4.1) as unrelated problems; this says they are one problem with
  two backings. ⚠ **Put the boundary one level up from where PPS has it:**
  `SwingPayloadSource::payloadOf` returns `SourceRing::ReadHandle`, so even the
  disk source must manufacture a RAM-ring handle. PPC should return an opaque
  handle its own substrate defines.
- **Apple thread QoS** — `thread_policy.cpp` sets `QOS_CLASS_USER_INTERACTIVE` for
  capture. PPC sets no QoS on the sample queue at all today.

**Two things not to inherit.** `reorder_window_us = 5000` encodes a multi-camera
desktop assumption; on this device camera and microphone share a timebase and CT-I4
asserts *zero* relations, so intra-device reordering is a smaller and different
problem. And `int64_t timestamp_us` is too coarse — 150 fps is 6.67 ms per frame,
and REQ-EXP-2's exposure corrections need nanoseconds on a monotonic base.

⛔ **Reimplement; do not extract a shared library.** The usual objection is
REQ-LIC-3, "two hand-written implementations always drift" — but that requirement
is about the **wire format**, where drift is an interop failure. A buffer is
internal and the two never speak. What genuinely must not drift is what a clip
extraction *produces*, and `CORE` §5.14/§8.4 already specifies that, with the
conformance suite testing both ends against it. That is a stronger guarantee than
shared source.

Extraction would also cost three things it need not: a third repo or a dependency
on PPS's release cadence; a **second** C-family dependency beside `libppcp`, whose
bridging surface is deliberately confined to twelve documented files; and a
refactor of working, tested desktop code for a consumer that is not asking for it.

⚠ **Port the tests as specifications, though.** `src/Buffer/tests` pins things
learned the hard way — `SeqlockNeverCorruptsValidatedRead`, `SequenceNumberWrapAround`,
`OverrunNoCorruption`, `PublishOnInvalidSlotIsNoop`, `LatestSequenceNeverDecreases`.
Several survive the change of substrate unchanged in intent: a fragment ring still
overruns, still needs monotonic sequence, and still must no-op a publish into a slot
that rolled away while the writer held it. Reimplementing without carrying that
intent across rediscovers those bugs in the field.

---

## 5. The two channels

`CORE` T2 requires control and bulk, independently flow-controlled. Preview is optional and, per 5.11j, **never queued**.

### Measured frame sizes

⚠ **These are real** — read off `ppcp-sim` wire transcripts during the 23 August soaks, so they are the bytes the library actually emits.

| Message | Bytes | Prov |
|---|---|---|
| `heartbeat` | 49 | **M** |
| `heartbeat_ack` | 108 | **M** |
| `sync_probe` | 103 | **M** |
| `sync_reply` | 155 | **M** |
| `relation_update` | 249–253 | **M** |

### Control channel budget

| Load | Rate | Prov | Derivation |
|---|---|---|---|
| Heartbeat steady state | **≈157 B/s** | **D** | (49 + 108) × 1 Hz |
| Sync burst on connect | **≈4.1 KB** | **D** | 16 × (103 + 155) |
| Relation updates | ≈250 B each, bursty | **M** | Rate is scenario-dependent |
| Per swing | candidate + shot + announce | **A** | ⚠ Not yet measured with real detections |
| **Steady-state ceiling** | **≤ 10 KB/s** | **A** | A budget, not a measurement — see §9 |

⛔ **Control must never be starved by bulk.** REQ-SESS-5 exists because a shot's *event* must cross in milliseconds while its video may take minutes. They are separate channels precisely so a gigabyte of payload cannot delay a 250-byte `shot`.

### Bulk channel

⛔ **No off-device streaming while armed, beyond a strict budget.** Continuous streaming of capture off the device is not a mode this product has: REQ-SESS-5/6 make transfer queued, resumable and backpressure-aware, and §9.2 makes capture degrade last. Bulk is *shipping stored clips*, not streaming live video.

| Parameter | Value | Prov | Note |
|---|---|---|---|
| `PayloadTransferQueue.pump` budget | 4 MiB per pump | **A** | Existing default |
| Concurrent payload transfers | **1** | **A** | ⛔ Hard limit. Parallel uploads add contention against the ring for no throughput on a single link |
| Transfer while armed | permitted, budgeted, yields first | **A** | REQ-RES-2's ordering: replay and transfer degrade before the ring loses a frame |
| Preview stream | live-only, shed as `absent`/`not_retained` | **M** | 5.11j — never queued, never bundled |

> ⚠ **I read one of the brief's examples two ways and cannot resolve it from the PRD.** "No off devices streaming at once" is stated above as *no live streaming off the device while armed*. If it meant *no two devices streaming to one host at once*, that is a different limit — and it is now contradicted by evidence: three simultaneous device links were verified against PinPointStudio on 23 August. Worth settling explicitly.

---

## 6. Audio, motion and the other sources

| Subsystem | Parameter | Value | Prov |
|---|---|---|---|
| `AVAudioSession` | mode | `.measurement` — AGC, EQ and NS off | **M** |
| | IO buffer | small; onset refined to sample index | **A** ⚠ never run on a real microphone |
| | Sample rate | 48 kHz | **A** |
| Audio retention | window | 2.0 s, 1.0 s pre-roll | **A** |
| | cap | **150 candidates** | **A** |
| | bound | **≈300 s per session** | **D** — 150 × 2 s |
| `CoreMotion` | device motion rate | 100 Hz | **A** — 200 Hz is reachable on modern hardware |
| Time of flight | mic-to-ball default | 1.5 m, provenance `estimated` | **A** ⚠ nothing has surveyed one |

⛔ **The candidate cap is enforced by eviction, and retention is bounded in *candidates*, not shots** (REQ-PRIV-6, amended 23 Aug). Candidates outnumber shots by an amount the user does not control, and the privacy label is a claim about this number.

---

## 7. Thermal, power and memory

| Limit | Value | Prov | Note |
|---|---|---|---|
| Sustained encode rate | **unknown** | ⚠ | REQ-ENC-4 wants ~40 min under load; the self-test runs 3 s and says so |
| Battery target | 90-minute session | **A** | REQ-RES-4 calls it a *measured* target. It is not measured |
| Charging while capturing | net effect unknown | **A** | REQ-RES-5 — adds heat on the binding axis |
| Thermal reporting | `ProcessInfo.thermalState`, polled at 1 Hz | **M** | Now live (E11-adjacent work, 23 Aug) |
| Foreground memory | ring is on disk, so jetsam is not the binding constraint | **D** | The design choice that makes this true is REQ-BUF-1 |

⛔ **Background execution is not a capture mode.** Capture requires foreground (which is also why REQ-DISC-1 makes the device the advertiser). Backgrounding tears the host link down and reports it — E3.1's behaviour, deliberately, because a link claiming to be up on return is worse than one that says it dropped.

---

## 8. The parameter set, in one place

What the build should be parametrised with. Every one of these is currently a literal somewhere.

```
capture.videoBitrateBps            50_000_000     A   ⚠ E-M2 sets this
capture.fragmentSeconds            0.5            A
capture.fragmentCapacity           20             A
capture.ringSeconds                10.0           D   fragmentSeconds × fragmentCapacity
capture.clipPreNs                  1_500_000_000  A
capture.clipPostNs                 3_000_000_000  A   ⚠ see §4 — disagrees with PRD §16.2
capture.expectedFrameRate          = activeFormat A   ⛔ must be set explicitly
capture.allowFrameReordering       false          V
capture.realTime                   true           V

detect.audioWindowNs               2_000_000_000  A
detect.audioPreNs                  1_000_000_000  A
detect.maxRetainedCandidates       150            A
detect.micToBallDefaultMetres      1.5            A   provenance: estimated

link.heartbeatHz                   1              V   CORE 7.4a
link.pumpTickIntervalNs            100_000_000    A
link.syncBurstTarget               16             A   ⚠ every UI string says "twenty"
link.controlCeilingBytesPerSec     10_000         A
link.concurrentPayloadTransfers    1              A   ⛔ hard limit
link.payloadPumpBudgetBytes        4_194_304      A

host.ingestMinimumHeight           1080           V   PinPointStudio policy, not protocol
host.ingestMinimumFPS              120            V   ⛔ REQ-CAP-5: never encoded on the wire

device.settleEstimateMs            1200           A   ⚠ no rig has measured this
device.storageFloorBytes           —              ⚠   REQ-OFF-2 has no value yet
```

⚠ **`link.syncBurstTarget` is 16 and every user-facing string says "twenty"** — `HostLinkState.explanation`, `PairingView`'s "Why the wait" card. One of the two is wrong and they have disagreed since D6.

⚠ **`device.storageFloorBytes` has no value at all.** REQ-OFF-2 requires refusing to arm below a floor, and no floor exists. A defensible first value is *one session plus headroom* — ≈1.4 GB by §4's arithmetic, not the ≈940 MB the PRD implies.

---

## 9. What must be measured before any of this hardens

Nine of the parameters above are `A` and load-bearing. In rough order of what a wrong value costs:

| Parameter | Retired by | Cost of being wrong |
|---|---|---|
| `videoBitrateBps` | **E-M2** bitrate sweep | Starved bitrate destroys shaft measurement exactly where motion is fastest |
| Rolling-shutter readout, exposure offset | **E-M1** LED timecode rig | A systematic, exposure-dependent time error indistinguishable from clock bias — which corrupts PinPoint's fusion clock-bias estimator |
| Sustained encode rate | **E-M4** 40-min thermal run | The cold number quietly becomes the displayed one (`CORE` 5.8b's named failure) |
| `clipPostNs` vs PRD §16.2 | a decision, not a rig | Storage floor and "room for N sessions" are both computed from it |
| Optical quality gate | **E-M1/E-M4** | REQ-CAP-4's gate does not exist, so A1's verdict is frame-rate-only wearing a fuller claim's words |
| Mic-to-ball distance | **E-M5** | A shipping session currently declares **no** `tof_correction` rather than an assumed one |
| `settleEstimateMs` | a rig | A peer's own estimate that no one has timed |
| Control-channel ceiling | a soak with real detections | Only the idle path has been measured |
| `MultiCamSession` high-rate support | a device check | Cheap to confirm, and it is the one that could reopen the one-camera limit |

---

## 10. Hard limits, collected

The list that should survive being read on its own.

1. **One physical camera, one format, per session.** No virtual devices, no lens changes, no `MultiCamSession`.
2. **One hardware encode session while armed.**
3. **Two viewpoints means two devices**, not two cameras.
4. **No live off-device video streaming.** Bulk ships stored clips, queued and resumable.
5. **One concurrent payload transfer.**
6. **Control is never starved by bulk**, and never shares its budget.
7. **Preview is live-only** — shed as absent, never queued, never bundled.
8. **Capture degrades last.** Replay, transfer and preview yield before the ring loses a frame.
9. **Refuse to arm below the storage floor** rather than evicting anything unconfirmed.
10. **No capture in the background.** The link drops and says so.
11. **Frame-rate floors are host policy** and never cross the wire (REQ-CAP-5).
12. **Capture the full sensor format.** No region of interest, no live crop. iOS
    offers no partial readout, so a crop costs intrinsics and buys nothing the
    bitrate cannot buy more honestly ([§2a](#2a-capabilities-checked-and-rejected)).
13. **The ring is ours.** No platform retrospective-capture API exists, so
    IDR alignment and the decodability of a concatenation are this
    application's guarantees to make and to test.
14. **Nothing emits `measured` that was not measured.** Including everything in this document.
