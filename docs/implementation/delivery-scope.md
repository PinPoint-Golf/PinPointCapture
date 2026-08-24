# PinPointCapture — delivery scope

**What is built, what is not, and the epics that close the gap.**

| | |
|---|---|
| Status | Draft for review — scope only, no estimates and no dates |
| Date | 23 August 2026 |
| Source of truth | [`capture-companion-requirements.md`](../design/capture-companion-requirements.md) (the PRD), [`ppcp-conformance.md`](../conformance/ppcp-conformance.md) (the conformance claim), [`design/mockup v1/README.md`](../design/mockup%20v1/README.md) (the design handoff) |
| Traceability | [`traceability.md`](traceability.md) — every requirement to its epic, level and evidence |
| Scope of this document | The `PinPointCapture` repository only. Work owned by `libppcp` or `PinPointStudio` appears as a **named external dependency** on an epic, never as an epic here. |
| Horizon | PRD v1 decomposed in full. PRD v2 and v3 carry epic IDs and one-line scope so the board can hold them, but are not decomposed. |
| Purpose | To seed a GitHub Project v2 board. Every **capability level** below is intended to become an issue; every epic, a milestone or parent issue. |

**How to read it.** §1 is the audit — what the build actually is today, verified against the tree rather than against the commit log. §2 restates that by architectural layer, because the layering is a PRD requirement (REQ-PORT-1) and the port surface has to stay legible. §3 is the epics and their capability levels, which is the part that becomes the board. §4 sequences them. §5–§7 carry the decisions, the measurement work and the release gates that engineering waits on. §8 is the v2/v3 shelf.

### A note on the level numbering

Each epic is cut into **capability levels** — `E1.1`, `E1.2`, `E1.3` — where every level is independently shippable and demonstrably more capable than the one before it. Level 1 is generally *the mechanism exists and can be seen working*; level 2 is *it satisfies the MUSTs*; level 3 and beyond are the SHOULDs, the hardening, and anything that waits on a measurement.

They are deliberately **not** called v1/v2/v3, because the PRD already uses that vocabulary for product releases (§10.1–§10.3) and the two would collide on the board. Each level instead carries a **Release** column naming the PRD release it belongs to, so both readings are available at once.

**Status legend.**

| Mark | Meaning |
|---|---|
| ✅ | Built, tested, and reached by the running app |
| ◐ | Built and tested, but **nothing in the app calls it** |
| ▨ | Built, but standing on fixture data rather than measurement |
| ○ | Not built |
| ⛔ | Blocked on hardware, a decision, or another repository |

---

## 1. Where the build actually is

### 1.1 The one-paragraph version

The **protocol and neutral-logic layer is substantially complete and genuinely good** — 174 tests green in 23 suites, `libppcp` consumed as a package rather than reimplemented, layer purity mechanically enforced, and a conformance claim with real interoperability rows against a counterpart this repository did not write. The **platform layer is written but only partly connected**. The **UI is a complete, faithful rendering of the design handoff — driven almost entirely by fixtures**. The gap between the app you can run and the app the PRD describes is not spread evenly: it concentrates in three seams where a built subsystem has no caller, and behind those three seams sits nearly everything a user would call a feature.

### 1.2 What is verified green

```
make test-core   →  174 tests, 23 suites, pass    (host, no simulator)
make test-app    →  28 tests, 5 deliberate skips  (simulator, needs a port)
make conform     →  ppcp-conform drives the device; every applicable row passes
make conform-iop →  IOP-1 and IOP-2, two counterparts in one simulator launch
```

Forty-seven conformance rows are claimed: **38 `pass`** (24 outright, 14 qualified with the half this peer owns), **7 `impl`** with the remaining half named, 1 `review`, and 1 blocked outright. Separately, §5 of the claim lists **15 deferred items — 9 of them waiting on nothing but a phone**.

### 1.3 The three unwired seams

These are the spine of the remaining work. Each is a subsystem that exists, is tested, and is not reached from `Sources/App/AppModel.swift`.

| Seam | What exists | What is missing | Consequence |
|---|---|---|---|
| **The ring buffer never receives a frame** | `Platform/Capture/RingBufferRecorder.swift` (segmented `AVAssetWriter`, 0.5 s fragments, 20-deep), `Core/Capture/FragmentRing.swift`, `CaptureAssembly` | The live `AVCaptureVideoDataOutput` drives only the self-test's rate probe. Nothing appends a fragment. | `CaptureDevice.extractClip` answers `absent` / `outside_buffer` on every device. **There is no video anywhere in the product.** No clip, no thumbnail, no replay, no payload to transfer, no bundle with bytes in it. |
| **The microphone has never run** | `Platform/Capture/MicrophoneOnsetSource.swift`, `Core/Detect/*` — detector with a transient taxonomy, confidence, candidate factory, Mint engine, candidate-attached audio retention with an enforced cap | `AppModel` starts the source on `arm`, but it has only ever been fed injected audio. No real transient, at a real sample rate, with a real `AVAudioTime`. | Detection is unproven on hardware. Every shot in the app today is a fixture. |
| ~~**There is no live host link**~~ ✅ **closed by E3.1** | as before, plus `App/HostLinkSession` | ~~Nothing composes the peer, the pump and the transport into the running app.~~ **`AppModel.connect` now does**, over the transport `RendezvousCoordinator.takeEstablishedLink()` hands over. Pairing succeeds against PinPointStudio. | What remains is per-level: sync (E3.2), arm-from-host (E3.3), transfer (E3.4), resume (E3.5). `HostLinkDriver`, `SessionOfferService`, `PreviewProducer`, `TransferQueue` and `SessionResume` still have no caller. |

The conformance claim is candid about all three (§5, "What is deferred, and on what"). That candour is worth preserving: the code does not pretend, and neither should the board.

### 1.4 Built, tested, and with no caller (◐)

Work that is done and only needs composing. It is cheap relative to its apparent size, and it should be scheduled as such.

`SessionOfferService` · `PreviewProducer` · `HostLinkDriver` · `TransferQueue` · `SessionResume` · `LiveDetectionSink` · `AnnotationStore` · `SessionMatch` · `MotionMetadataSource` · `RingBufferRecorder`

✅ **Composed since this list was written:** `PeerLinkPump` and `DevicePeer`'s live extensions (E3.1) · `SessionStore.bundles()`, `ThermalTimeline` via `DeviceHealthService`, and `InterruptionMonitor`'s record (#92).

⚠ `HostLinkDriver` is the one to read before using: zero call sites, **no test**, it double-pumps liveness and sync against `PeerLinkPump.tickOnce`, and its `public private(set)` state is written on the pump's executor and read on the MainActor. E3.1 deliberately derived `HostLink` from pump events instead.

### 1.5 What the PRD asks for that has no code at all (○)

Verified by absence across `Sources/` and `Packages/Core/Sources/`:

- **No `Vision`.** A6's framing checklist, the golfer-in-frame box, the steadiness check and the DTL/right-handed self-classification are all fixture (REQ-SETUP-1/2/3).
- **No video decode or playback.** C2's frame area is `ReplayFramePlaceholder`; `onStepFrame`, `onTogglePlayback`, `onCycleSpeed` and `onCompare` are empty closures (REQ-REPLAY-1/2/3/4).
- **No markup surface.** `Annotation` and `AnnotationStore` exist in Core with tests; `onSelectTool` is empty and there is no drawing view (REQ-MARK-1/2/3).
- **No diagnostic bundle.** No type of that name exists. `onExportDiagnostics` and `onOpenConnectionLog` are empty (REQ-OBS-1/2/4).
- **No export.** `onExportSession` is empty. `SessionStore` writes `.ppcpbndl` files into the app container and nothing gets them off the device (REQ-OFF-3, REQ-OFF-9/10/11).
- **No storage floor.** `StorageHeadroom` is computed and shown on A7; nothing refuses to arm below a floor (REQ-OFF-2).
- **No iPad layout.** No size-class or idiom handling anywhere. D1 is undesigned in code (UC-3).
- **No review mode.** `DebugScreenGallery` and `ConformanceHarness` are `#if DEBUG` and are not this (REQ-STANDALONE-6).
- **No USB transport.** B1's "Use a cable instead" row is drawn; its closure is empty (REQ-DISC-5).
- **No empty or error states.** The design handoff names five as undesigned; none exists. `capabilityError` and `recordingError` are set and never rendered.

### 1.6 Where the code is ahead of the PRD

Three of the four review comments dated 22 August 2026 were already answered in code. **These have now been folded into the PRD** (§1.6 of this document was the finding; the PRD edit is the fix):

- **REQ-PRIV-6's arithmetic.** `Core/Detect/CandidateAudioRetention.swift` is expressed in **candidates**, carries an explicit cap (`maximumRetainedCandidates`, default 150), enforces it by eviction with the evicted window re-announced `absent`, and generates the user-facing retention sentence from the cap. The PRD now says so.
- **The A1 verdict's attribution.** `DeviceCapability.verdictSentence(_:)` takes a `HostIngestPolicy`, defaults to `.pinPointStudioCurrent`, and names the policy in the sentence. Now **REQ-CAP-6** in the PRD.
- **Format ranking.** `bestMode` ranks frame-rate-first, resolution second, lens third, so the wide lens wins a tie with ultra-wide. Now stated in **REQ-FPS-1** and **REQ-OPT-6**.

**REQ-EXP-2's third field is closed in `libppcp`**, not merely planned: `ppcp_timing_make_nominal_frame_start` takes `frame_start_to_exposure_offset_ns`, its sigma and its provenance as **required parameters**, and the sibling constructor refuses the convention outright.

Two review items remain genuinely open and are carried in §5: **REQ-SHOT-6's narrowing to live nominators**, and **REQ-OBS-4's stated expiry**.

---

## 2. Scope by architectural layer

REQ-PORT-1 fixes four layers with explicit boundaries. The seams are currently clean — `LayerPurityTests` fails the build on a forbidden import and walks the tree recursively — and every epic below is written to keep them that way.

### 2.1 Protocol — `libppcp`, consumed not written

**External to this repository.** `import CPPCP` appears in exactly twelve files, each named in `Packages/Core/README.md` with the rule the library owns there. Nothing is deferred on `libppcp` today: L6 (peer engine), L8 (bundle writer/reader) and L17 (errata E5–E29) have all landed and been adopted.

**Remaining dependency on it:** a tagged release. `Package.swift` currently uses a sibling path checkout with the git URL recorded in a comment (**E14.1**).

### 2.2 Core logic — `Packages/Core/CaptureCore`

Platform-free Swift, 42 files, 174 tests. The most complete layer in the product.

| Area | State | Remaining | Epic |
|---|---|---|---|
| Declaration, capability, timing profile, achieved | ✅ | Optical quality figure for REQ-CAP-4; `measured` needs a sustained run | E-M1, E-M4 |
| Session model, store, bundle read/write | ✅ ◐ | A projection the UI can bind to | E4.1 |
| Detect — onset, classification, candidate, mint | ✅ ◐ | ToF estimation from accumulated residuals | E2.3 |
| Live — pump, driver, offer, preview, transfer, resume | ◐ | Composition only | E3.1–E3.5 |
| Markup — annotation, store | ◐ | A UI to author them, and the host round trip | E6 |
| Rendezvous — pairing code, advertisement, derivation | ✅ | — | — |
| Capture — fragment ring, assembly, coverage, readiness | ◐ | Fed by nothing until the ring is wired | E1.1 |
| `SessionMatch` (reconciliation candidates) | ◐ | B5 is passed an empty array | E9.3 |

**Judgement:** this layer needs very little new construction. What it needs is callers. Estimating it by file count will overstate it badly.

### 2.3 Platform capture — `Sources/Platform`

The only place `AVFoundation`, `VideoToolbox`, `CoreMotion`, `CoreMedia` and `Network` may appear, and the contract is well documented in `Sources/Platform/README.md`.

| Component | State | Remaining | Epic |
|---|---|---|---|
| `AVFoundationCaptureDevice` — enumeration, locks, warm-up, self-test, storage | ✅ | REQ-OPT-1..7 locks verified on hardware | E1.1 |
| `PermissionsService` | ✅ | — | — |
| `DeviceProfiles.{swift,json,md}` (REQ-PORT-10) | ▨ | Every provenance is `assumed` | E-M1 |
| `Network/PpcpTransport` — TLS-PSK | ✅ | RT-17 is a standing review item | E14.2 |
| `Rendezvous/*` — advertiser, coordinator, Keychain, hotspot join | ✅ ⛔ | Device and App ID capability | E16 |
| `Capture/RingBufferRecorder` | ◐ | **Not connected** | E1.1 |
| `Capture/FrameTimeline` | ✅ | — | — |
| `Capture/MicrophoneOnsetSource` | ⛔ | Never run on a real microphone | E2.1 |
| `Capture/MotionMetadataSource`, `ThermalTimeline`, `InterruptionMonitor` | ◐ | Recorded, not acted on | E8.2, E11.1, E11.3 |
| Video decode / frame reader for replay | ○ | Does not exist | E5.1 |
| Vision-based framing validation | ○ | Does not exist | E8.2 |
| Export / share / file delivery | ○ | Does not exist | E9.1 |

### 2.4 UI — `Sources/UI`, `Sources/App`

Sixteen of the design handoff's seventeen screens are built to the specified fidelity, with a design system and no tab bar, as specified. Routing is centralised in `RootView`; screens own no navigation and take Core values with closures back, which is the right shape.

| Screens | Built | Real data |
|---|---|---|
| A1–A7 onboarding | ✅ 7/7 | A1 and A7's capability are **real**. A6's framing is entirely fixture |
| B1–B6 host connectivity | ✅ 6/6 | B1's scan path is real (all six failure branches routed). B2 and B3 are fixture |
| C1–C3 capture/replay/library | ✅ 3/3 | All fixture. C2's frame and C1's preview are placeholder views |
| D1 iPad | ○ | Not built |

**Empty closures currently in `RootView`,** each of which is a feature: `onCompare`, `onStepFrame`, `onTogglePlayback`, `onCycleSpeed`, `onSelectTool`, `onExportSession`, `onExportDiagnostics`, `onOpenConnectionLog`, `onPrimaryAction`, `onOpenSettings`, `onConnectByCable`, `onUseCable`.

---

## 3. Epics and capability levels

Sixteen engineering epics cut into **fifty-two capability levels**, plus five measurement epics and two release epics. Nine further epics hold the v2/v3 shelf (§8).

---

### E1 — Clip capture: bytes on the ring

> The single largest gap in the product, and the one everything visual sits behind.

**Why it clusters.** Connecting the ring, configuring the encoder honestly, assembling a clip on trigger and writing the sidecar are one mechanism seen at four depths. Splitting them across epics would let a half-connected ring look finished.

⚠ **E1.1 wired 24 Aug 2026, and the "needs a phone" claim turned out to be too broad.** The ring is fed by the live capture session through one state-gated delegate, the discard policy follows the routing state, and `arm()` refuses to reach `armed` on a device that cannot retain.

✅ **What a simulator proved** (`Tests/RingBufferRecorderTests.swift`, synthetic frames through the real `AVAssetWriter`): fragments land at the 0.5 s cadence with nothing refused by the encoder; the ring rolls at 20 and evicted fragments take their files with them; an interval outside the window answers `absent`; orphans from a previous run are swept on start; and the initialisation segment plus fragments **decodes as one video track, while the same fragments without it do not open**. That last one is the contract `capability-spike.md` §2a said E1.2 must prove rather than assume — it is proved, before E1.2 starts.

⛔ **What still needs the phone is the camera half**: 1080p at the *claimed* rate rather than 30 fps of synthetic video, the REQ-OPT-1..4 locks holding after a run and not just after `warmUp`, thermal behaviour, and whether VideoToolbox emits High tier at the provisional 50 Mbps (§3 flags it as above the Main-tier cap). `maxInterArrivalNs` is what separates a steady 150 fps from an average one; until those numbers are recorded here, this level is **wired and half-proven**.

| Level | Capability | Components | Release | Exit criterion |
|---|---|---|---|---|
| **E1.1** | **Frames reach the ring** | Live `AVCaptureVideoDataOutput` → `RingBufferRecorder`, through one state-gated delegate ✅ · encoder config: `ExpectedFrameRate`, `RealTime`, `AllowFrameReordering = false` ✅ *(was already set — the earlier ○ was wrong)* · fragment index into `Core.FragmentRing`, rollover at 20 ✅ · `RingStats` — inter-arrival, evictions, uncounted frames ✅ · verify REQ-OPT-1..7 locks hold on hardware ▨ | v1 | Twenty 0.5 s fragments on disk, rolling, at the claimed rate with `alwaysDiscardsLateVideoFrames = false` |
| **E1.2** | **A clip you can extract** | Trigger → `CaptureAssembly` concatenation ◐ · `CaptureDevice.extractClip` over real fragments ◐ · thumbnail at the impact anchor ○ | v1 | `extractClip` returns a playable MP4 at t₀ ± window instead of `absent` |
| **E1.3** | **A clip that is self-describing** | Full REQ-CLIP-1 sidecar: per-frame timestamps, intrinsics, attitude and gravity, exposure and ISO, thermal timeline, achieved frames, stream coverage, gaps ◐ ✅ | v1 | On-device `make conform` unblocks **CT-S7 (4)**, **CT-S1 (1–5)**, **CT-I30's third assertion**, **IOP-2's second half** |
| **E1.4** | **Bitrate hardened** | Operating bitrate set from the sweep; all-intra fallback adopted or retired with the measurement recorded ⛔ | v1 | REQ-BUF-3 satisfied by measurement, not judgement. **Waits on E-M2** |

**Dependencies.** A physical device. **E-M2** gates E1.4 only — E1.1–E1.3 proceed on a provisional bitrate, and must not harden one.

**PRD coverage.** REQ-BUF-1/2/3/4 · REQ-ENC-1/2/3 · REQ-CLIP-1/2/3 · REQ-CAP-3 · REQ-FPS-2/3 · REQ-TIME-4/5 · REQ-META-1 · REQ-OPT-1..7 · REQ-PORT-9.

---

### E2 — Acoustic detection on real hardware

**Why it clusters.** The detector, the candidate factory, the Mint engine and the retention cap are built and tested against injected audio. What has never happened is a real transient.

| Level | Capability | Components | Release | Exit criterion |
|---|---|---|---|---|
| **E2.1** | **A real transient produces a candidate** | `AVAudioSession` `.measurement`, AGC/EQ/NS off, small IO buffer ▨ · `AVAudioTime` → capture timebase ▨ · sample-index onset refinement ▨ | v1 | A real club strike at a real mat mints a Shot with an honest instant |
| **E2.2** | **Candidates you can trust** | Transient taxonomy tuned against field audio — impact, ball-into-screen, club-on-mat, dropped club, adjacent player, speech ▨ · confidence calibrated ✅ · retention cap exercised over a full session ✅ | v1 | A range session's candidates can be reviewed from retained audio and the classifier's mistakes are the ones it says they are |
| **E2.3** | **Time of flight without a tape measure** | ToF as a free parameter estimated from accumulated per-shot residuals ○ · surveyed distance and sigma from the rig ⛔ | v1 | REQ-MIC-4 satisfied without user measurement. A session declares a real `tof_correction` rather than none. **Waits on E3.5 and E-M5** |

**Dependencies.** A device. E2.3 needs **E3.5** (the residual series) and **E-M5**. E1 is *not* a dependency — detection can be proven before clips exist.

**PRD coverage.** REQ-MIC-1..6 · REQ-SHOT-3/4/5 · REQ-PRIV-4/5/6/7 · REQ-NAV-3 · REQ-PORT-8.

---

### E3 — The live host link in the app

**Why it clusters.** Every piece exists and is exercised by the conformance harness. What did not exist is the composition. The levels below are ordered so each one is separately demonstrable against `ppcp-sim` — and E3.1 proved that ordering works: `make conform SCENARIO=reference-host ROW=e31` drives the app's own path against the simulator, which `make conform` alone never did (it only ever proved the `#if DEBUG` harness).

| Level | Capability | Components | Release | Exit criterion |
|---|---|---|---|---|
| **E3.1** ✅ | **Connected, and honest about it** | Compose transport + peer + `PeerLinkPump` in `AppModel` ✅ · connect/disconnect lifecycle ✅ · version negotiation from the first message ✅ · `HostLink` derived from telemetry, not fixtures ✅ | v1 | **Done** (#24, `94f185b`). ⚠ Exit criterion narrowed to **three** of B2's four rows: the clock row is E3.2's and renders `.pending` |
| **E3.2** | **Synchronised** | Sync burst 10–20 on connect, network change and thermal event ◐ · per-timebase, filtered never stepped ◐ · settle to heartbeat ◐ · real offset, uncertainty and drift on B3 ▨ | v1 | B3 *Connected* shows a measured offset and drift; **CT-I21** and **CT-I18** hold live |
| **E3.3** | **Under host control** | Arm/disarm from the host ◐ · readiness measurement on the wire, state names never ◐ · keepalive lapse → cold ○ | v1 | The host arms the device; **RT-10's message half** closes |
| **E3.4** | **Shots crossing** | `capture_announce` on control immediately ◐ · payload queued on bulk, backpressure-aware ◐ · per-shot and per-session progress ▨ · confirmation → `In Studio` ◐ · `SessionOfferService` and `PreviewProducer` composed ◐ | v1 | A swing announces in milliseconds and its video follows minutes later; **CT-I19's consumer half (CT-S3)** closes |
| **E3.5** | **Surviving the network** | Lost → Back transition ▨ · `session_resume` with a fresh burst before bulk resumes ◐ · gap reported explicitly ◐ · per-shot residual against the acoustic fiducial computed, reported, logged ○ | v1 | Pull the network mid-session: capture **never stops**, six shots queue, and they cross correctly on reconnect. **CT-S4 (7)** and **CT-I32's silent-host half** close |

**Dependencies.** **E1.2** for E3.4's payload. A host — `ppcp-sim` suffices for E3.1–E3.3 and most of E3.5; PinPointStudio for confirmation semantics.

**PRD coverage.** REQ-SYNC-1/1a/2/3/4 · REQ-STATE-1/3/6 · REQ-SESS-5/6 · REQ-VER-1/2 · REQ-RES-3 · REQ-SHOT-1/2 · REQ-TIME-1/2/3 · REQ-STREAM-1.

---

### E4 — Session library on real storage

| Level | Capability | Components | Release | Exit criterion |
|---|---|---|---|---|
| **E4.1** | **Sessions survive a relaunch** | Session/shot projection over `SessionStore` ○ · session list ○ · the open session resumed after a cold start ○ | v1 | Kill the app mid-session and reopen it: the session is there, open, and complete |
| **E4.2** | **Per-shot sync state** | local / sent / confirmed as an independent store, not a cache ◐ · nothing unconfirmed evicted ✅ · C3 bound to the store ▨ · transfer banner from the real queue ▨ | v1 | `In Studio` means the host confirmed it, and no other state can produce that chip |
| **E4.3** | **Context on a shot** | Club tagging on C1 and C3 ○ · session naming ○ · roster and calibration state carried ◐ | v1 | A shot list a coach can read. *Voice* club tagging is v2 (**E19**) |

**Dependencies.** **E1.2** (thumbnails), **E2.1** (shots to list), **E3.4** (sync state to be true about).

**PRD coverage.** REQ-SESS-1..6 · REQ-STANDALONE-5 · REQ-OFF-11 · REQ-PORT-12.

---

### E5 — Replay

| Level | Capability | Components | Release | Exit criterion |
|---|---|---|---|---|
| **E5.1** | **It plays** | Frame reader over the stored clip, addressed in **time** and never by index ○ · playback ○ · C2's frame area replacing the placeholder ▨ | v1 | A shot plays back on the device, timeline zeroed on impact |
| **E5.2** | **Frame-accurate** | Bi-directional stepping at capture rate ○ · speed control ○ · impact fiducial and top-of-backswing anchor as scrub targets ▨ | v1 | Step backwards through impact frame by frame at 150 fps |
| **E5.3** | **Reviewing costs nothing** | Demonstrated armed-and-reviewing under contention; the yield mechanism itself is **E11.2** ○ | v1 | C2's "still armed" is true under load, not just in copy |

**Dependencies.** **E1.2**, **E4.1**. REQ-BUF-2's fragment length is what makes reverse stepping tractable and must not be renegotiated here.

**PRD coverage.** REQ-REPLAY-1/2/3 · REQ-NAV-1/2/3 · REQ-STATE-4 · REQ-RES-1/2 (§9.2 sense).

---

### E6 — Markup

| Level | Capability | Components | Release | Exit criterion |
|---|---|---|---|---|
| **E6.1** | **Draw on a frame** | Drawing surface; line, circle, freehand ○ · 48pt targets that do not shrink ○ · anchored to shot id + frame timestamp ✅ | v1 | A line drawn near impact stays on the frame it was drawn on |
| **E6.2** | **It persists** | `AnnotationStore` bound and persisted ◐ · lossless round trip through the bundle ✅ · no path from an Annotation to a Shot or relation ✅ | v1 | Markup survives a relaunch and an export; **CT-I37** holds in the app |
| **E6.3** | **It reaches Studio** | Device-originated annotations on the wire ◐ | v1 | A line drawn on the phone appears in PinPoint. **External: PinPointStudio must accept them** |

**Dependencies.** **E5.1**, **E3.4**.

**PRD coverage.** REQ-MARK-1/2/3.

---

### E7 — Two-shot comparison

**Flagged: not designed.** The handoff names *Compare* and explicitly does not design it. This epic needs a design pass before it needs an engineer.

| Level | Capability | Release | Exit criterion |
|---|---|---|---|
| **E7.1** | **Designed** — the comparison screen, its transport model and its entry points on C2 and D1 | v1 | A design pass at the fidelity of the rest of the handoff |
| **E7.2** | **Synchronised on impact** — dual timeline, two decoders under the priority rule, aligned on **impact, not clip start** | v1 | REQ-REPLAY-4 satisfied |
| **E7.3** | **Overlay and onion-skin** — beyond anything the PRD requires | v2 | Deferred deliberately |

**Dependencies.** **E5.2**. A design decision.

---

### E8 — Framing and setup validation

**Why it clusters.** A6 is the screen that prevents a wasted session, and every one of its four rows is a fixture today. **E8.1 is the highest-value level in this epic and needs no Vision at all.**

| Level | Capability | Components | Release | Exit criterion |
|---|---|---|---|---|
| **E8.1** | **The light gate is real** | Achievable exposure and ISO measured from a warm session ▨ · the marginal-light row and its stated consequence ▨ · *Use 120 fps* re-enumerating and re-measuring rather than relabelling ▨ | v1 | A6's light row carries measured numbers, and the 120 fps trade produces a genuinely different measurement |
| **E8.2** | **The pose checks are real** | Vision body pose — framing validation, not analysis ○ · in frame at address **and** at top of backswing ○ · steadiness from `MotionMetadataSource` ◐ | v1 | The checklist changes as you move in front of the phone |
| **E8.3** | **It classifies itself** | Viewpoint self-classification — "DTL, right-handed" — reported, not asked ○ | v1 (SHOULD) | The device says what view it is; the user never configures it |

**Dependencies.** A device and a warm capture session. **E1 is not required** — a warm session suffices, which is what makes this parallelisable from day one.

**PRD coverage.** REQ-SETUP-1/2/3 · REQ-LIGHT-1/2 · REQ-POSE-1..4 (the provenance rules bind the moment Vision output exists).

---

### E9 — Export and offline delivery

**Why it clusters.** REQ-OFF-1 collapses the export bundle, the fixture format and the store-and-forward path into one artefact. Splitting them would re-create the second ingest path the requirement exists to prevent.

| Level | Capability | Components | Release | Exit criterion |
|---|---|---|---|---|
| **E9.1** | **A bundle off the device** | Share sheet / Files export of the complete session bundle ○ · C3's *Export the whole session* wired ▨ | v1 | A range session leaves the phone as one file |
| **E9.2** | **Resumable and idempotent** | Chunked, resumable, content-addressed ○ · idempotent re-import ✅ · metadata and sensor streams **before** video ○ · completeness explicit, never inferred ✅ · any subset of streams a valid bundle ✅ | v1 | Interrupt a transfer: the partial session does not present as whole. Re-import twice: a no-op. **CT-I34** holds |
| **E9.3** | **Reconciliation without merging** | `SessionMatch` candidates with evidence rows into B5 ◐ · explicit confirmation, never auto-merge ◐ · coverage gaps surfaced ✅ | v1 | B5 shows real candidates against a Studio that already holds part of the session |
| **E9.4** | **Storage discipline** | Low free-space warning ○ · **refuse to arm** below a floor ○ | v1 | The app refuses a session it cannot keep, rather than losing swings |

**Dependencies.** **E1.3**, **E4.1**. External: **PinPointStudio** importing a bundle this device wrote — this side already writes two and checks them in.

**PRD coverage.** REQ-OFF-1/2/3/9/10/11/12/14 · REQ-STANDALONE-1/2/3/4 · REQ-SESS-3/4 · REQ-HOST-2 · REQ-OFF-8.

---

### E10 — Observability: the diagnostic bundle

**Why it clusters.** REQ-OBS-1 lists seven data series that must arrive as one artefact. It is the project's only channel into the field.

| Level | Capability | Components | Release | Exit criterion |
|---|---|---|---|---|
| **E10.1** | **One file a maintainer can diagnose from** | Bundle assembly: sync residual history, achieved frame intervals, drop counts, thermal timeline, detection events with confidences, transfer queue history, capability triple ○ · user-initiated export, attachable to an issue ○ | v1 | A "it lost sync" report arrives with everything needed and no follow-up question |
| **E10.2** | **The connection log** | The log screen behind B3's row ○ | v1 | Link transitions are legible after the fact |
| **E10.3** | **Diagnostic mode** | Lowered candidate emission threshold ○ · sub-threshold audio retained ○ · **default off, expiring with the session** ○ | v1 (SHOULD) | False *negatives* become diagnosable. **Waits on decision D-REV-2** |

**Dependencies.** **E1.3**, **E2.2**, **E3.5** supply the series.

**PRD coverage.** REQ-OBS-1/2/3/4 · REQ-PRIV-3 (satisfied by absence).

---

### E11 — Resource, thermal and lifecycle discipline

**Why it clusters.** §9.2's priority rule — *capture degrades last* — is not a feature; it is a property enforced in several places at once and demonstrated as one thing.

| Level | Capability | Components | Release | Exit criterion |
|---|---|---|---|---|
| **E11.1** | **Interruptions recover and report** | Automatic re-arm after a call, audio interruption or backgrounding ▨ · the gap reported explicitly with B3's *Back* treatment ▨ · keepalive lapse → cold ○ | v1 | Take a call mid-session: the app re-arms itself and says exactly what it missed |
| **E11.2** | **The priority rule enforced** | Replay never disarms and never tears down the capture session ○ · replay yields decode bandwidth, smoothness and resolution before the ring drops a frame ○ | v1 | Under induced contention the ring loses nothing and replay visibly degrades first. **CT-I36a under load** closes |
| **E11.3** | **Thermal and battery honest** | Thermal state surfaced and acted on ◐ · the 90-minute battery target verified ⛔ · charging trade-off stated ⛔ | v1 | REQ-RES-4 is a *verified* requirement rather than a stated one. **Waits on E-M4** |

**Note.** `InterruptionMonitor` writes an honest `InterruptionRecord` with a `recovered` flag, and `AVCaptureSession` resumes itself after a suspension — but nothing in `AppModel` returns the state to `.armed` or surfaces the gap. That is what E11.1 closes.

**PRD coverage.** REQ-RES-1..5 (§9.2 sense) · REQ-STATE-2/3/5 · REQ-ENC-4.

---

### E12 — iPad

| Level | Capability | Release | Exit criterion |
|---|---|---|---|
| **E12.1** | **It runs properly on iPad** — size-class routing, no regressions, onboarding and pairing as centred sheets rather than a redesign | v1 | Every existing screen is correct on an iPad in both orientations |
| **E12.2** | **The two-pane** — permanent landscape capture-left, review-right; larger status type across the top | v1 | UC-3 on one device without swapping screens |
| **E12.3** | **External display** — the lesson second screen | v2 (**E20**) | Deferred |

**Dependencies.** **E1.2**, **E5.1**. Scheduling E12.2 before them produces two placeholders side by side.

---

### E13 — Review mode and error surfaces

**Why it clusters.** All of it is "what the app does when the happy path is not available", and the App Store reviewer's path runs straight through the middle of it.

| Level | Capability | Components | Release | Exit criterion |
|---|---|---|---|---|
| **E13.1** | **Failures are visible** | `capabilityError` and `recordingError` rendered rather than silently held ▨ · no-sessions-yet, storage floor reached, thermal limit reached ○ | v1 | No failure mode in the app is silent, and §9.2's one rule is never quietly broken |
| **E13.2** | **Review mode** | A simulated paired host walking arm → capture → detect → review → transfer ○ | v1 | An App Store reviewer with no host and no golf club can exercise the whole path. **Gates E-R2** |
| **E13.3** | **The standalone audit** | Every capability's stated standalone behaviour verified against REQ-STANDALONE-1 ○ | v1 | No feature errors where the PRD requires a defined offline path |

**Dependencies.** **E1**–**E5**.

**PRD coverage.** REQ-STANDALONE-1/6 · REQ-OFF-2 · REQ-RES-3.

---

### E14 — Repository, dependency and policy hygiene

| Level | Capability | Release | Exit criterion |
|---|---|---|---|
| **E14.1** | **`libppcp` tagged and consumed by version** — `Package.swift` off the sibling path onto the versioned git URL | v1 | A clean checkout builds without a sibling repository |
| **E14.2** | **CI** — `test-core`, `test-app` and `conform` on every push; RT-17's standing TLS review recorded as a recurring check | v1 | The conformance claim cannot silently rot |
| **E14.3** | **The port surface published** — enumerated as a documented artefact rather than an emergent property (REQ-PORT-2) | v1 | A second-platform implementer has one page to read. The Core README has a start; it is not yet the artefact |
| **E14.4** | **Version support-window policy** — N releases back, written, plus the app's behaviour facing an unknown host dialect | v1 | REQ-VER-3 satisfied. **Waits on OPEN-5** |

---

### E15 — USB transport *(SHOULD)*

Lower and far more stable latency floor for UC-2, so minimum-RTT filtering converges faster. B1's row is drawn and inert.

| Level | Capability | Release |
|---|---|---|
| **E15.1** | The device end of the tunnel, behind the existing `PeerTransport` abstraction | v1 (SHOULD) |
| **E15.2** | End-to-end with the host side | v1 (SHOULD) — **external: the `usbmuxd`/libimobiledevice half is LGPL and belongs on the PinPoint side** (REQ-TRANS-3, REQ-LIC-5) |

Downgrade or defer without embarrassment; it is a `SHOULD` and the transport abstraction already accommodates it.

---

### E16 — Rendezvous completion on hardware

| Level | Capability | Release | Exit criterion |
|---|---|---|---|
| **E16.1** | **Discovery on a real network** — mDNS advertise and browse against a real AP, including the multicast-fails path | v1 | REQ-DISC-1/3 proven outside a simulator |
| **E16.2** | **Pairing that does not ride a backup** — Keychain `ThisDeviceOnly` verified across a real restore | v1 | **RT-15** completes |
| **E16.3** | **Hotspot join** — `NEHotspotConfiguration` with Hotspot Configuration enabled on the App ID | v1 (SHOULD) | B4 joins a host-provided network on a device |

**PRD coverage.** REQ-DISC-1..6 · REQ-AUTH-1/2 · REQ-PRIV-1.

---

## 4. Sequencing

```
                    ┌─────────────────────────────────────────┐
   E-M2 ──(E1.4)───►│  E1  Clip capture — bytes on the ring   │◄─── a phone
                    │  E1.1 ring → E1.2 clip → E1.3 sidecar   │
                    └────────────┬────────────────────────────┘
                                 │
        ┌────────────────────────┼────────────────────────┬──────────────┐
        ▼                        ▼                        ▼              ▼
  ┌──────────┐          ┌────────────────┐        ┌────────────┐   ┌───────────┐
  │ E2 Mic   │          │ E4 Library     │        │ E5 Replay  │   │ E8 Framing│
  │ .1 .2 .3 │          │ .1 .2 .3       │        │ .1 .2 .3   │   │ .1 .2 .3  │
  └────┬─────┘          └───────┬────────┘        └──────┬─────┘   └───────────┘
       │                        │                        │          ▲ independent
       │   ┌────────────────────┴────────┐        ┌──────┴──────┬──────────┐
       └──►│ E3  Live host link          │        ▼             ▼          ▼
    (E2.3  │ .1 .2 .3 .4 .5              │   ┌────────┐  ┌──────────┐ ┌────────┐
   needs   └───┬──────────┬──────────────┘   │E6 Markup│  │E7 Compare│ │E12 iPad│
    E3.5)      │          │                  │ .1 .2 .3│  │ .1 .2    │ │ .1 .2  │
               ▼          ▼                  └────────┘  └──────────┘ └────────┘
        ┌───────────┐ ┌────────────┐            (E7.1 is a design pass — start now)
        │E9 Export  │ │E10 Diag    │
        │ .1 .2 .3 .4│ │ .1 .2 .3  │
        └───────────┘ └────────────┘
                 │          │
                 └────┬─────┘
                      ▼
              ┌───────────────┐      ┌──────────────────┐
              │E11 Resources  │─────►│E13 Review/errors │────► E-R2 submission
              │ .1 .2 .3      │      │ .1 .2 .3         │
              └───────────────┘      └──────────────────┘
```

**The critical path is E1.1 → E1.2.** Six epics depend on a clip existing; four more transitively. Nothing about the product is demonstrable until `extractClip` returns bytes.

**Independent of E1, and therefore startable immediately:** **E8.1** (needs only a warm session), **E2.1/E2.2** (needs only a microphone), **E7.1** (a design pass), **E14** entirely, **E16** entirely, and all of §6.

**Cheap relative to appearance.** **E3**, **E4.2**, **E6.2** and **E9.2/E9.3** are mostly composition of already-tested code. Sizing them from the scope description will overstate them substantially.

**A useful first slice.** E1.1 + E1.2 + E2.1 + E4.1 + E5.1 is the smallest set that produces *an app that captures a real swing and plays it back* — the point at which every subsequent conversation is about a real artefact rather than a fixture.

---

## 5. Decisions that gate work

These belong on the board as decision issues with an owner, not as engineering tickets.

| ID | Decision | Gates | Position |
|---|---|---|---|
| **OPEN-3** | Minimum device tier: is 120 fps the floor, at what resolution and light level? | A1's verdict, **E8.1**, **E-M3/E-M4** | `HostIngestPolicy.pinPointStudioCurrent` implements 1080p ≥120 fps today, and **REQ-CAP-6** now makes that attribution explicit. REQ-CAP-4's optical quality gate is **not** implemented — no device has a measured noise figure. Needs **E-M1/E-M4** to close honestly |
| **OPEN-4** | App licence and distribution channel | **E-R2** | Library stays MIT either way. Non-GPL for the app if the App Store is wanted |
| **OPEN-5** | Version support window (REQ-VER-3) | **E14.4** | Needs an N-releases-back policy and a defined behaviour facing an unknown host dialect |
| **OPEN-6** | Does v1 ship tethered-only, deferring the standalone UI? | Scope of **E9**, **E13** | **Recommend closing as "no".** The standalone path is already the more complete half — hostless sessions, bundle write and read, and CT-S4's zero-host path all pass. Deferring the UI now would defer the part that works |
| **OPEN-7** | How much core logic is shared vs. reimplemented per platform? | Android (**E25**) only | Not a v1 gate. Decide when the port surface is enumerated in **E14.3** |
| **D-REV-1** | REQ-SHOT-6 narrowed to **live** nominators; file-imported launch monitor records reconciled through `ShotLink`, not candidate nomination | **E9.3** | PRD review comment 2, still open. Needs a protocol-side answer and a PRD edit |
| **D-REV-2** | REQ-OBS-4's diagnostic mode must state its exit | **E10.3** | PRD review comment 4. The PRD's own recommendation: it expires with the session |
| **D-ID-1** | **Duplicate requirement ID.** `REQ-RES-1/2` names both §7.3's resolution target and §9.2's priority rule | The traceability matrix | **Resolved in the PRD**: §7.3's pair renamed `REQ-RESOL-1/2`. Every existing reference in code and design means the §9.2 sense and stays correct |

---

## 6. Measurement and rig workstream

Every one of these produces a **number the product currently assumes**. Plan A12 is applied consistently in the code — nothing emits `measured` where nothing measured it — which makes these the difference between a device profile that is honest and one that is useful.

| ID | Work | Requirement | Unblocks |
|---|---|---|---|
| **E-M1** | **LED timecode rig** — host-driven binary-coded flash at ~1 kHz, in view of the device and the FLIR cameras. Per-frame ground truth on end-to-end alignment, and rolling-shutter readout from the same experiment | REQ-TEST-1/2, REQ-EXP-3 | Moves every `DeviceProfiles.json` entry from provenance `assumed` to `measured`. The PRD says build this **before** the protocol; it is now the other way round, which is worth stating plainly |
| **E-M2** | **Bitrate sweep** — short-GOP, no-B-frame HEVC at ~30/60/100 Mbps, scored on shaft RMSE against an uncompressed reference | REQ-TEST-6, REQ-BUF-3 | **E1.4** |
| **E-M3** | **Resolution comparison** — same swing, same light, 1080p150 vs 4K120, same scoring | REQ-TEST-7, REQ-RESOL-1/2 | **OPEN-3**'s resolution half. Result goes in the device profile, not in the PRD |
| **E-M4** | **Sustained capability** — encode rate under thermal load after ~40 minutes, not from cold; the 90-minute battery target; the charging trade-off | REQ-ENC-4, REQ-CAP-2, REQ-RES-4/5 | **E11.3**, and A7's *Measured, sustained* row. `runSelfTest` currently runs for three seconds and the code says outright that this demonstrates the path works rather than measuring anything |
| **E-M5** | **Acoustic time of flight** — a surveyed distance with a real sigma on this device, and validation of the residual-based estimator | REQ-MIC-3/4 | **E2.3**. A shipping session currently declares **no** `tof_correction` rather than an assumed one |

**Already satisfied, and not to be re-scoped:** REQ-TEST-3 (recorded-session fixture format) is the bundle, per REQ-OFF-1's collapse — bundles are checked into `docs/conformance/bundles/`. REQ-TEST-4 (injectable clock) is `libppcp` §5.1. REQ-TEST-5 (software device simulator) is `ppcp-sim`, driven by `make conform`.

---

## 7. Release and legal

| ID | Work | Requirement | Note |
|---|---|---|---|
| **E-R1** | Trademark clearance on "PinPointCapture" and "PinPoint" — USPTO TSDR verification of PIN POINT GOLF (98753725), equivalent UKIPO search, classes 9/28/41, and a qualified opinion | REQ-LIC-6 | A **pre-submission** gate, explicitly not a pre-development one. Engineering does not wait on it |
| **E-R2** | App Store submission readiness | REQ-STANDALONE-6, REQ-PRIV-2, REQ-DISC-4/6 | Bundles: review mode (**E13.2**); the privacy label stated in **candidates** with the retention cap, matching `CandidateAudioRetention`'s own sentence and the amended REQ-PRIV-6; purpose strings; `NSLocalNetworkUsageDescription` and `NSBonjourServices`; Hotspot Configuration on the App ID (**E16.3**); and **OPEN-4** closed |

---

## 8. The v2 / v3 shelf

Carried as epic IDs so the board can hold them without pretending they are scoped. Requirements tracing to these appear in the matrix as *deferred*, not as *missing*.

| ID | Epic | Release | PRD |
|---|---|---|---|
| **E17** | Advisory pose for replay annotation, under REQ-POSE-1..4's provenance rules | v2 | §2.3, §10.2 |
| **E18** | Upload triage — real swing / golfer in frame / club moved | v2 | §10.2 |
| **E19** | Voice club tagging, as a second consumer of the open audio stream | v2 | §10.2 |
| **E20** | Second screen for host-computed results | v2 | UC-5, §10.2 |
| **E21** | Offline sensor capture and export — **IMU first**, then HackMotion via `libwrist`, in that order and for the stated reason | v2 | §16.3–§16.6 |
| **E22** | Multi-device stereo, where the acoustic oracle stops being corroborative | v3 | UC-6, §10.3 |
| **E23** | Relayed BLE sensors as a new stream type, not a new protocol | v3 | §10.3 |
| **E24** | Camera phase alignment for co-timed stereo frames | v3 | §10.3 |
| **E25** | **Android** — the port REQ-PORT-1..14 exist to make possible | v3 | §17 |

**Never (PRD §2.2)** — metrics, diagnostic conditions, normative corridors, or any artefact a PinPoint producer could consume.

---

## 9. Mapping to GitHub Project v2

A suggested shape, offered rather than assumed:

- **Issue per capability level** (`E3.2 — Synchronised`), with the components as a task list. **Epic as a parent issue or milestone** (`E3 — The live host link`). Fifty-two v1 level-issues across sixteen epics is a board you can actually run; sixteen epic-issues is not, and 159 requirement-issues is worse.
- **Fields:** `Epic` · `Level` · `Release` (v1/v2/v3, from the level's Release column) · `Layer` (Protocol / Core / Platform / UI — record the *primary* where a level spans several) · `Blocked on` (a phone / a rig / a decision / another repo / nothing) · `Requirements` (the REQ- ids from the matrix) · `Conformance rows` (what it unblocks in `ppcp-conformance.md`).
- **Decisions from §5 as issues in a separate view**, so a decision blocking three levels is one item rather than three notes.
- **§6 and §7 as their own views** — they run on a different clock from engineering and should not compete for the same columns.
- The **`Blocked on: a phone`** filter is the single most useful view this board can have. It is currently the binding constraint on nine of the fifteen deferred items in the conformance claim, and grouping that work lets one device session close a great deal of it at once.
- **The traceability matrix ([`traceability.md`](traceability.md)) is generated from this document and the PRD** and should be updated whenever a level closes — it is what makes "are we done?" a question with an answer.
