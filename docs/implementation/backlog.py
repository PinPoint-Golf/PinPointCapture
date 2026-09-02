#!/usr/bin/env python3
"""Generate the GitHub backlog manifest from the delivery scope.

This is the source of the board at
https://github.com/orgs/PinPoint-Golf/projects/1 — 16 epic parents, 52 capability
levels as their sub-issues, 7 decisions, 5 measurement epics, 2 release gates and
a 9-item v2/v3 shelf. 91 issues, plus the 16 labels they use.

It is kept because the board and `delivery-scope.md` must not drift. When a level
is added, split or reworded in the scope document, change it here too and re-run:
the manifest is regenerated, and creation is idempotent by issue title, so only
genuinely new items are created.

    python3 docs/implementation/backlog.py     # writes backlog.json beside itself

Emitting the manifest is all this does — it touches nothing on GitHub. The two
scripts that consume it (issue creation via `gh issue create --parent`, and
project population via the GraphQL field mutations) were run once to bootstrap the
board and are not kept here; the manifest is the artefact worth versioning.

⚠ The counts asserted at the bottom are deliberate. They caught a real
miscount in the scope document — fifty-one levels stated where fifty-two were
defined — and are what stops the two documents disagreeing again.
"""
import json
import os

REPO = "PinPoint-Golf/PinPointCapture"
BLOB = f"https://github.com/{REPO}/blob/main/docs"
SCOPE = f"{BLOB}/implementation/delivery-scope.md"
TRACE = f"{BLOB}/implementation/traceability.md"
PRD = f"{BLOB}/design/capture-companion-requirements.md"
CONF = f"{BLOB}/conformance/ppcp-conformance.md"

LABELS = [
    # layer
    ("layer: protocol", "1D76DB", "libppcp — consumed, not written here"),
    ("layer: core", "0E8A16", "Packages/Core — platform-neutral logic"),
    ("layer: platform", "D93F0B", "Sources/Platform — the only place platform types live"),
    ("layer: ui", "5319E7", "Sources/UI, Sources/App"),
    # blocked-on
    ("blocked-on: phone", "B60205", "Needs a physical device to prove"),
    ("blocked-on: rig", "B60205", "Needs a measurement rig or a field session"),
    ("blocked-on: decision", "FBCA04", "Waiting on an open decision"),
    ("blocked-on: external", "FBCA04", "Waiting on libppcp or PinPointStudio"),
    # release
    ("release: v1", "0052CC", "PRD §10.1"),
    ("release: v2", "6699DD", "PRD §10.2"),
    ("release: v3", "AACCEE", "PRD §10.3"),
    # kind
    ("epic", "3E4B9E", "Parent issue holding capability levels"),
    ("decision", "E99695", "A decision, not engineering work"),
    ("measurement", "C2E0C6", "Rig work — produces a number the product assumes"),
    ("release-gate", "F9D0C4", "Pre-submission gate"),
    ("design-needed", "D4C5F9", "Needs a design pass before engineering"),
]

def level(id, title, cap, components, exitc, reqs, release="v1",
          layer=None, blocked=None, note=None, deps=None):
    return dict(id=id, title=title, cap=cap, components=components, exit=exitc,
                reqs=reqs, release=release, layer=layer, blocked=blocked,
                note=note, deps=deps)

EPICS = [
 dict(id="E1", title="Clip capture: bytes on the ring", layer="platform",
  summary="The single largest gap in the product, and the one everything visual sits behind.",
  why=("Connecting the ring, configuring the encoder honestly, assembling a clip on trigger and "
       "writing the sidecar are one mechanism seen at four depths. Splitting them across epics "
       "would let a half-connected ring look finished."),
  deps="A physical device. E-M2 gates E1.4 only — E1.1–E1.3 proceed on a provisional bitrate, and must not harden one.",
  levels=[
   # ✅ CLOSED 2 Sep 2026 (#17). The two "not built" lines below were true when
   # this was written and are kept as history rather than rewritten: the encoder
   # config turned out to have been set all along, which is why the original ○
   # was wrong and is recorded as wrong. What actually closed it was a device
   # run producing numbers rather than an impression.
   level("E1.1","Frames reach the ring",
     "Frames actually arrive in the rolling buffer and roll over.",
     ["Live `AVCaptureVideoDataOutput` → `RingBufferRecorder`, one state-gated "
      "delegate ✅",
      "Encoder config: `ExpectedFrameRate`, `RealTime`, `AllowFrameReordering = "
      "false` ✅ *(was already set — the original \"not set today\" was wrong)*",
      "Fragment index into `Core.FragmentRing`, rollover at 20 ✅",
      "`RingStats`, including the encoded profile/level read off the `hvcC` box ✅",
      "REQ-OPT-1..7 locks verified on hardware ✅"],
     "Twenty 0.5 s fragments on disk, rolling, at the claimed rate, with `alwaysDiscardsLateVideoFrames = false`.",
     "REQ-BUF-1, REQ-ENC-1, REQ-ENC-2, REQ-ENC-3, REQ-OPT-1..4 (hardware verification), REQ-FPS-2",
     layer="platform",
     note="Done 2 Sep 2026 on an iPhone 16: 20/20 held, 239.5 fps against a "
          "claimed 240, max inter-arrival 4.18 ms against a 4.17 ms period, zero "
          "drops of any kind, locks re-read after the run, and the encoder's own "
          "`hvcC` reading **HEVC Main, High tier, level 5.1** — so the "
          "provisional 50 Mbps sits inside the level it declares. E1.4 still "
          "owns the bitrate itself."),
   # ✅ CLOSED 2 Sep 2026 (#18).
   level("E1.2","A clip you can extract",
     "A trigger produces a playable clip instead of `absent`.",
     ["Trigger → `CaptureAssembly` concatenation ✅",
      "`CaptureDevice.extractClip` over real fragments ✅",
      "`retainedClip(aroundNs:preNs:postNs:)` answering a host's "
      "`capture_request`, after the post-roll has reached the ring ✅",
      "Thumbnail at the impact anchor, zero generator tolerance ✅"],
     "`extractClip` returns a playable MP4 at t₀ ± window instead of `absent` / `outside_buffer`.",
     "REQ-STANDALONE-3, REQ-SHOT-2", layer="platform",
     note="Done 2 Sep 2026: 15.0 MB opening as one video track of 2.500 s, "
          "`hvc1`, 599 frames at 239.49 fps, a 3.3 KB JPEG at the anchor — and "
          "from the other direction, a live PinPointStudio's `capture_request` "
          "answered with 15–25 MB clips. ⚠ Every such answer was `partial`, "
          "never `complete`; that is E3.4's question."),
   level("E1.3","A clip that is self-describing",
     "The sidecar carries everything REQ-CLIP-1 lists.",
     ["Per-frame timestamps, intrinsics, attitude and gravity",
      "Exposure and ISO per frame, thermal timeline",
      "Achieved frames, stream coverage, gaps",
      "Schema complete and **filled on hardware 2 Sep 2026** — exposure "
      "measured at 4.038 ms rather than the hardcoded zero, thermal points "
      "carried, intrinsics correctly absent at 240 fps and never synthesised"],
     "On-device `make conform` unblocks **CT-S7 (4)**, **CT-S1 (1–5)**, **CT-I30's third assertion** and **IOP-2's second half**.",
     "REQ-CLIP-1, REQ-CAP-3, REQ-FPS-3, REQ-META-1", layer="platform",
     note="✅ Closed 2 Sep 2026 (#19) with the criterion NARROWED, recorded as a "
          "narrowing: the conformance run above has still not happened. This "
          "level's job is that a clip describes itself and it does — the run is "
          "a conformance-CLAIM obligation, and it survives as E3.4's exit "
          "criterion and as the claim's own `blocked: a phone` rows."),
   level("E1.4","Bitrate hardened",
     "The operating bitrate is set by measurement rather than judgement.",
     ["Operating bitrate from the sweep",
      "All-intra fallback adopted or retired, with the measurement recorded"],
     "REQ-BUF-3 satisfied by measurement, not judgement.",
     "REQ-BUF-3", layer="platform", blocked="rig", deps="Waits on E-M2."),
  ]),

 dict(id="E2", title="Acoustic detection on real hardware", layer="platform",
  summary="The detector is built and tested against injected audio. What has never happened is a real transient.",
  why="The detector, the candidate factory, the Mint engine and the retention cap all exist and pass. The microphone has never run.",
  deps="A device. E2.3 needs E3.5 (the residual series) and E-M5. E1 is *not* a dependency — detection can be proven before clips exist.",
  levels=[
   level("E2.1","A real transient produces a candidate",
     "The microphone runs, and a real club strike mints a Shot.",
     ["`AVAudioSession` `.measurement`, AGC/EQ/NS off, small IO buffer — written, never run",
      "`AVAudioTime` → capture timebase conversion — written, never run",
      "Sample-index onset refinement — written, never run"],
     "A real club strike at a real mat mints a Shot with an honest instant.",
     "REQ-MIC-1, REQ-MIC-2", layer="platform", blocked="phone"),
   level("E2.2","Candidates you can trust",
     "The transient taxonomy meets field audio and is tuned against it.",
     ["Tune impact / ball-into-screen / club-on-mat / dropped club / adjacent player / speech",
      "Confidence calibrated — emitted today, uncalibrated",
      "Retention cap exercised over a full session"],
     "A range session's candidates can be reviewed from retained audio, and the classifier's mistakes are the ones it says they are.",
     "REQ-MIC-5", layer="core", blocked="rig",
     note="`CONF` §6 puts *which* candidates a Mint peer promotes outside conformance. What is in scope is that every nomination is emitted."),
   level("E2.3","Time of flight without a tape measure",
     "ToF resolves as a free parameter rather than a user measurement.",
     ["Estimate ToF from accumulated per-shot residuals — **not built**",
      "Surveyed distance and sigma from the rig"],
     "REQ-MIC-4 satisfied without user measurement. A session declares a real `tof_correction` rather than none.",
     "REQ-MIC-3, REQ-MIC-4", layer="core", blocked="rig",
     deps="Waits on E3.5 and E-M5."),
  ]),

 dict(id="E3", title="The live host link in the app", layer="core",
  summary="Every piece exists and is exercised by the conformance harness. What does not exist is the composition.",
  why=("Eight tested Live subsystems have no `AppModel` caller and `hostLink` is a fixture. The levels below are "
       "ordered so each is separately demonstrable against `ppcp-sim`."),
  deps="E1.2 for E3.4's payload. A host — `ppcp-sim` suffices for E3.1–E3.3 and most of E3.5; PinPointStudio for confirmation semantics.",
  levels=[
   level("E3.1","Connected, and honest about it",
     "The app holds a real link and derives its state from telemetry.",
     ["Compose transport + `DevicePeerLive` + `PeerLinkPump` in `AppModel` — **not built**",
      "Connect/disconnect lifecycle — **not built**",
      "Version and capability negotiation from the first message — built, uncalled",
      "`HostLink` state from telemetry, not fixtures — **fixture today**"],
     "B2's four progress rows are driven by a real handshake.",
     "REQ-VER-1, REQ-TIME-3, REQ-TIME-4 (emission)", layer="core"),
   # ✅ CLOSED 26 Aug 2026 (#25).
   level("E3.2","Synchronised",
     "Offset and drift are measured, filtered and shown.",
     ["Sync burst 10–20 on connect, network change and thermal event ✅",
      "Per-timebase, filtered never stepped ✅",
      "Settle to heartbeat cadence ✅",
      "Real offset, **uncertainty** and drift on B3 ✅ — the uncertainty, not "
      "the raw offset, which between two since-boot clocks is meaningless"],
     "B3 *Connected* shows a measured offset and drift; **CT-I21** and **CT-I18** hold live.",
     "REQ-SYNC-1, REQ-SYNC-1a, REQ-SYNC-2, REQ-SYNC-3", layer="core",
     note="Done 26 Aug 2026. Measured against a live PinPointStudio on 2 Sep: "
          "± 1.29 ms at 23/16 filtered exchanges, crossing 6.1f's 5 ms "
          "arbitration gate before arming."),
   level("E3.3","Under host control",
     "The host arms the device; the device reports readiness, never a state name.",
     ["Arm/disarm from the host ✅ — **a host armed this device 2 Sep 2026**",
      "Readiness measurement on the wire, state names never ✅, with every "
      "`arm()` exit reporting one of `CORE` 5.15's four `blocked_reason` values",
      "The torch as a CR-02 Actuator, acked with the state the hardware "
      "achieved rather than the state requested ✅",
      "`device_status` per Source and `buffer_status` for the ring, from "
      "`warmUp` rather than `arm` ✅",
      "Keepalive lapse → cold ✅ *(warm → cold only — 7.4d forbids a lapse "
      "costing a captured frame)*"],
     "The host arms the device; **RT-10's message half** closes.",
     "REQ-STATE-1, REQ-STATE-3", layer="core",
     note="✅ Closed 2 Sep 2026 (#26) — a host armed this device and commanded "
          "its torch. ⚠ Closed OVER the criterion's second clause, which cites "
          "RT-10 (`session_resume` refused without a handshake) and does not "
          "read on arming; the on-device conformance run it implied was not "
          "done."),
   level("E3.4","Shots crossing",
     "A swing announces immediately; its video follows on the bulk channel.",
     ["`capture_announce` on control immediately ✅",
      "Payload queued on bulk, backpressure-aware ✅ — 7 908 pump passes "
      "carrying 247 MB in one hardware run",
      "`capture_request` answered from the ring, after the post-roll ✅",
      "Per-shot and per-session progress ◐ — the device's own view only",
      "Confirmation → `In Studio` ⛔ **unreachable**: no host has ever sent "
      "`capture_committed`",
      "`SessionOfferService` and `PreviewProducer` composed ✅"],
     "A swing announces in milliseconds and its video follows minutes later; **CT-I19's consumer half (CT-S3)** closes.",
     "REQ-SESS-5, REQ-SESS-6, REQ-SHOT-1", layer="core", deps="Needs E1.2.",
     note="✅ Closed 2 Sep 2026 (#27). It crossed against a live "
          "PinPointStudio — `capture_request` converted, the post-roll waited "
          "for, 25 MB queued, an 82 MB bundle beside it. ⚠ Closed with CT-S3 "
          "UNRUN and the swing injected (E2.1); `In Studio` is still "
          "unreachable. Two faults the run surfaced are #119 and #120."),
   level("E3.5","Surviving the network",
     "The link can be lost and recovered without costing a frame.",
     ["Lost → Back transition ✅",
      "`session_resume` with a fresh burst before bulk resumes ✅ — and 4.3b's "
      "**ordering** now has the test it never had",
      "Gap reported explicitly ✅",
      "Per-shot residual against the acoustic fiducial, computed, reported, "
      "logged ✅"],
     "Pull the network mid-session: capture **never stops**, six shots queue, and they cross correctly on reconnect. **CT-S4 (7)** and **CT-I32's silent-host half** close.",
     "REQ-SYNC-4", layer="core",
     note="✅ Closed 2 Sep 2026 (#28) — ⛔ and the run was NEVER DONE. The code "
          "is complete and unit-tested including 4.3b's ordering; no phone has "
          "lost its network mid-session, so \"capture never stops and six shots "
          "queue\" is reasoned rather than observed. ⚠ A residual has been "
          "computed on hardware (0.0 ms against an injected swing the host "
          "adopted unchanged) — 8.2i1 satisfied, REQ-SYNC-4 not measured."),
  ]),

 dict(id="E4", title="Session library on real storage", layer="core",
  summary="`SessionStore` writes bundles and nothing reads them back. The UI shows a fixture session.",
  why="The store, the sync-state model and the C3 screen are three views of one object.",
  deps="E1.2 (thumbnails), E2.1 (shots to list), E3.4 (sync state to be true about).",
  levels=[
   level("E4.1","Sessions survive a relaunch",
     "The library is backed by the store rather than a fixture.",
     ["Session/shot projection over `SessionStore` — **not built**",
      "Session list — **not built**",
      "The open session resumed after a cold start — **not built**"],
     "Kill the app mid-session and reopen it: the session is there, open, and complete.",
     "REQ-SESS-3 (store half)", layer="core"),
   level("E4.2","Per-shot sync state",
     "`In Studio` means the host confirmed it, and nothing else can produce that chip.",
     ["local / sent / confirmed as an independent store, not a cache",
      "Nothing unconfirmed is evicted — already held via `ppcp_transfer_is_evictable`",
      "C3 bound to the store; transfer banner from the real queue"],
     "`In Studio` means the host confirmed it, and no other state can produce that chip.",
     "REQ-SESS-3 (state half)", layer="core"),
   level("E4.3","Context on a shot",
     "A shot list a coach can read.",
     ["Club tagging on C1 and C3 — **not built**",
      "Session naming — **not built**",
      "Roster and calibration state carried — built, uncalled",
      "Time and location capture (REQ-META-2) — **not built**"],
     "A shot list a coach can read. *Voice* club tagging is v2 (E19).",
     "REQ-SESS-1, REQ-META-2", layer="ui"),
  ]),

 dict(id="E5", title="Replay", layer="platform",
  summary="C2's frame area is a placeholder and every transport control is an empty closure.",
  why="Decoding, addressing the timeline in time, and stepping at capture rate are one mechanism.",
  deps="E1.2, E4.1. REQ-BUF-2's fragment length is what makes reverse stepping tractable and must not be renegotiated here.",
  levels=[
   level("E5.1","It plays",
     "A stored shot plays back, addressed in time.",
     ["Frame reader over the stored clip, addressed in **time** and never by index — **not built**",
      "Playback — **not built**",
      "C2's frame area replacing `ReplayFramePlaceholder`"],
     "A shot plays back on the device, timeline zeroed on impact.",
     "REQ-REPLAY-2", layer="platform"),
   level("E5.2","Frame-accurate",
     "Step through impact frame by frame, in both directions, at capture rate.",
     ["Bi-directional stepping at capture rate — **not built**",
      "Speed control — **not built**",
      "Impact fiducial and top-of-backswing anchor as scrub targets — drawn at fixed positions today"],
     "Step backwards through impact frame by frame at 150 fps.",
     "REQ-REPLAY-1, REQ-REPLAY-3, REQ-NAV-1", layer="ui"),
   level("E5.3","Reviewing costs nothing",
     "\"Still armed\" is true under load, not just in copy.",
     ["Demonstrated armed-and-reviewing under contention",
      "The yield mechanism itself is **E11.2**"],
     "C2's \"still armed\" is true under load, not just in copy.",
     "REQ-STATE-4", layer="core", deps="Needs E11.2."),
  ]),

 dict(id="E6", title="Markup", layer="ui",
  summary="`Annotation` and `AnnotationStore` are built and tested; there is no drawing surface.",
  why="The model exists and passes CT-I37. What is missing is authoring and the round trip.",
  deps="E5.1, E3.4. External: PinPointStudio must accept device-authored annotations for E6.3.",
  levels=[
   level("E6.1","Draw on a frame",
     "Line, circle and freehand tools that anchor to a frame.",
     ["Drawing surface; line, circle, freehand — **not built**",
      "48pt targets that do not shrink (gloved hands)",
      "Anchored to shot id + frame timestamp — model already correct"],
     "A line drawn near impact stays on the frame it was drawn on.",
     "REQ-MARK-3", layer="ui"),
   level("E6.2","It persists",
     "Markup survives a relaunch and an export, losslessly.",
     ["`AnnotationStore` bound and persisted — built, uncalled",
      "Lossless round trip through the bundle — already asserted",
      "No path from an Annotation to a Shot or relation — CT-I37 holds"],
     "Markup survives a relaunch and an export; **CT-I37** holds in the app.",
     "REQ-MARK-1", layer="core"),
   level("E6.3","It reaches Studio",
     "A line drawn on the phone appears in PinPoint.",
     ["Device-originated annotations on the wire — built, uncalled"],
     "A line drawn on the phone appears in PinPoint.",
     "REQ-MARK-2", layer="core", blocked="external",
     note="External: PinPointStudio must accept device-authored annotations."),
  ]),

 dict(id="E7", title="Two-shot comparison", layer="ui",
  summary="**Not designed.** The design handoff names *Compare* and explicitly does not design it.",
  why="This epic needs a design pass before it needs an engineer.",
  deps="E5.2. A design decision.",
  levels=[
   level("E7.1","Designed",
     "A design pass at the fidelity of the rest of the handoff.",
     ["The comparison screen, its transport model, and its entry points on C2 and D1"],
     "A design pass at the fidelity of the rest of the handoff.",
     "REQ-REPLAY-4 (design half)", layer="ui",
     note="Startable immediately — it does not depend on E1."),
   level("E7.2","Synchronised on impact",
     "Two shots compared, aligned on impact rather than clip start.",
     ["Dual timeline synchronised on **impact, not clip start**",
      "Two decoders under the priority rule"],
     "REQ-REPLAY-4 satisfied.",
     "REQ-REPLAY-4", layer="ui", deps="Needs E7.1 and E5.2."),
   level("E7.3","Overlay and onion-skin",
     "Beyond anything the PRD requires.",
     ["Overlay and onion-skin comparison modes"],
     "Deferred deliberately — no requirement asks for it.",
     "—", release="v2", layer="ui"),
  ]),

 dict(id="E8", title="Framing and setup validation", layer="platform",
  summary="A6 is the screen that prevents a wasted session, and every one of its four rows is a fixture.",
  why="**E8.1 is the highest-value level in this epic and needs no Vision at all**, which makes it startable today.",
  deps="A device and a warm capture session. **E1 is not required** — a warm session suffices.",
  levels=[
   level("E8.1","The light gate is real",
     "A6's light row carries measured numbers instead of invented ones.",
     ["Achievable exposure and ISO measured from a warm session — **fixture today**",
      "The marginal-light row and its stated consequence",
      "*Use 120 fps* re-enumerating and re-measuring rather than relabelling"],
     "A6's light row carries measured numbers, and the 120 fps trade produces a genuinely different measurement.",
     "REQ-LIGHT-1, REQ-LIGHT-2, REQ-CAP-4 (partial)", layer="platform", blocked="phone",
     note="The PRD calls achievable exposure \"the binding constraint on how useful the video is\", and the app currently displays an invented number for it."),
   level("E8.2","The pose checks are real",
     "The checklist changes as the golfer moves.",
     ["Vision body pose — framing validation, not analysis — **no `Vision` import exists anywhere**",
      "In frame at address **and** at top of backswing",
      "Steadiness from `MotionMetadataSource` — built, uncalled"],
     "The checklist changes as you move in front of the phone.",
     "REQ-SETUP-1, REQ-SETUP-3", layer="platform", blocked="phone",
     note="REQ-POSE-1..4's provenance rules bind the moment Vision output exists, even though advisory pose itself is v2."),
   level("E8.3","It classifies itself",
     "The device says what view it is; the user never configures it.",
     ["Viewpoint self-classification — \"DTL, right-handed\" — **fixture today**"],
     "The device says what view it is; the user never configures it.",
     "REQ-SETUP-2", layer="core", blocked="phone"),
  ]),

 dict(id="E9", title="Export and offline delivery", layer="core",
  summary="`onExportSession` is an empty closure. Bundles are written into the app container and never leave.",
  why=("REQ-OFF-1 collapses the export bundle, the fixture format and the store-and-forward path into one "
       "artefact. Splitting them would re-create the second ingest path the requirement exists to prevent."),
  deps="E1.3, E4.1. External: PinPointStudio importing a bundle this device wrote.",
  levels=[
   level("E9.1","A bundle off the device",
     "A range session leaves the phone as one file.",
     ["Share sheet / Files export of the complete session bundle — **not built**",
      "C3's *Export the whole session* wired"],
     "A range session leaves the phone as one file.",
     "— (enables E9.2)", layer="ui"),
   level("E9.2","Resumable and idempotent",
     "An interrupted transfer never presents as a whole session.",
     ["Chunked, resumable, content-addressed — **not built**",
      "Idempotent re-import — already holds (CT-I34)",
      "Metadata and sensor streams **before** video — **not built**",
      "Wall clock labels, monotonic measures — **nothing in the tree distinguishes them**",
      "Completeness explicit, never inferred — already holds",
      "Any subset of streams a valid bundle — already holds (CT-I12)"],
     "Interrupt a transfer: the partial session does not present as whole. Re-import twice: a no-op.",
     "REQ-OFF-3, REQ-OFF-8, REQ-OFF-9", layer="core",
     note="REQ-OFF-8 is a real gap in a delivered-looking area — there is no wall-clock field and no observed discontinuity between wall and monotonic anywhere."),
   level("E9.3","Reconciliation without merging",
     "B5 shows real candidates with their evidence, and never auto-merges.",
     ["`SessionMatch` candidates with evidence rows into B5 — B5 is passed an **empty array** today",
      "Explicit confirmation, never auto-merge",
      "Coverage gaps surfaced"],
     "B5 shows real candidates against a Studio that already holds part of the session.",
     "REQ-OFF-12, REQ-SHOT-6 (with D-REV-1)", layer="core", blocked="decision",
     deps="REQ-SHOT-6's narrowing is D-REV-1."),
   level("E9.4","Storage discipline",
     "The app refuses a session it cannot keep.",
     ["Low free-space warning — **not built**",
      "**Refuse to arm** below a floor — **not built**"],
     "The app refuses a session it cannot keep, rather than losing swings.",
     "REQ-OFF-2", layer="core"),
  ]),

 dict(id="E10", title="Observability: the diagnostic bundle", layer="core",
  summary="No type of that name exists. This is the project's only channel into the field.",
  why="REQ-OBS-1 lists seven data series that must arrive as one artefact.",
  deps="E1.3, E2.2, E3.5 supply the series.",
  levels=[
   level("E10.1","One file a maintainer can diagnose from",
     "A field report arrives with everything needed and no follow-up question.",
     ["Sync residual history, achieved frame intervals, drop counts",
      "Thermal timeline, detection events with confidences",
      "Transfer queue history, capability triple",
      "User-initiated export, attachable to an issue"],
     "A \"it lost sync\" report arrives with everything needed and no follow-up question.",
     "REQ-OBS-1, REQ-OBS-2, REQ-OBS-3", layer="core"),
   level("E10.2","The connection log",
     "Link transitions are legible after the fact.",
     ["The log screen behind B3's row — `onOpenConnectionLog` is empty today"],
     "Link transitions are legible after the fact.",
     "— (supports REQ-OBS-1)", layer="ui"),
   level("E10.3","Diagnostic mode",
     "False *negatives* become diagnosable.",
     ["Lowered candidate emission threshold",
      "Sub-threshold audio retained",
      "**Default off, expiring with the session**"],
     "False *negatives* become diagnosable — a shot the detector never fired on produces no candidate and no evidence.",
     "REQ-OBS-4", layer="core", blocked="decision", deps="Waits on D-REV-2."),
  ]),

 dict(id="E11", title="Resource, thermal and lifecycle discipline", layer="core",
  summary="§9.2's priority rule — *capture degrades last* — is honoured in the design everywhere and enforced nowhere.",
  why="It is not a feature; it is a property enforced in several places at once and demonstrated as one thing.",
  deps="E1, E3, E5. E-M4 for the two measured numbers.",
  levels=[
   level("E11.1","Interruptions recover and report",
     "Take a call mid-session: the app re-arms itself and says what it missed.",
     ["Automatic re-arm after a call, audio interruption or backgrounding",
      "The gap reported explicitly with B3's *Back* treatment",
      "Keepalive lapse → cold"],
     "Take a call mid-session: the app re-arms itself and says exactly what it missed.",
     "REQ-STATE-5", layer="platform",
     note="`InterruptionMonitor` writes an honest record with a `recovered` flag and `AVCaptureSession` resumes itself — but nothing returns the state to `.armed` or surfaces the gap."),
   level("E11.2","The priority rule enforced",
     "Under contention the ring loses nothing and replay degrades first.",
     ["Replay never disarms and never tears down the capture session",
      "Replay yields decode bandwidth, smoothness and resolution before the ring drops a frame"],
     "Under induced contention the ring loses nothing and replay visibly degrades first. **CT-I36a under load** closes.",
     "REQ-RES-1, REQ-RES-2 (§9.2 sense)", layer="core", blocked="phone"),
   level("E11.3","Thermal and battery honest",
     "REQ-RES-4 becomes a verified requirement rather than a stated one.",
     ["Thermal state surfaced and acted on — reported, never acted on today",
      "The 90-minute battery target verified",
      "Charging trade-off stated",
      "`estimated_ready_ms` replaced by a measurement (currently an assumed 1 200)"],
     "REQ-RES-4 is a *verified* requirement rather than a stated one.",
     "REQ-RES-3, REQ-RES-4, REQ-RES-5, REQ-STATE-2", layer="platform", blocked="rig",
     deps="Waits on E-M4."),
  ]),

 dict(id="E12", title="iPad", layer="ui",
  summary="No size-class or idiom handling exists anywhere. D1 is the one design-pack screen not built.",
  why="What an iPad earns is capture and review at once (UC-3), so both panes are permanent rather than swapped.",
  deps="E1.2, E5.1. Scheduling E12.2 before them produces two placeholders side by side.",
  levels=[
   level("E12.1","It runs properly on iPad",
     "Every existing screen is correct on an iPad in both orientations.",
     ["Size-class routing",
      "Onboarding and pairing as centred sheets — the same screens, not a redesign",
      "No regressions on iPhone"],
     "Every existing screen is correct on an iPad in both orientations.",
     "— (UC-3)", layer="ui"),
   level("E12.2","The two-pane",
     "Capture and review at once, on one device.",
     ["Permanent landscape capture-left, review-right",
      "Larger status type across the top — an iPad sits further away"],
     "UC-3 on one device without swapping screens.",
     "— (UC-3)", layer="ui"),
   level("E12.3","External display",
     "The lesson second screen.",
     ["Host-computed results on an external display"],
     "Deferred — this is E20's territory.",
     "— (UC-5)", release="v2", layer="ui"),
  ]),

 dict(id="E13", title="Review mode and error surfaces", layer="ui",
  summary="No failure mode in the app is currently visible, and the App Store reviewer's path runs straight through here.",
  why="All of it is \"what the app does when the happy path is not available\".",
  deps="E1–E5. Gates E-R2.",
  levels=[
   level("E13.1","Failures are visible",
     "No failure mode in the app is silent.",
     ["`capabilityError` and `recordingError` rendered rather than silently held",
      "No-sessions-yet state",
      "Storage floor reached",
      "Thermal limit reached"],
     "No failure mode in the app is silent, and §9.2's one rule is never quietly broken.",
     "REQ-OFF-2, REQ-RES-3", layer="ui"),
   level("E13.2","Review mode",
     "An App Store reviewer with no host and no golf club can exercise the whole path.",
     ["A simulated paired host walking arm → capture → detect → review → transfer"],
     "An App Store reviewer with no host and no golf club can exercise the whole path.",
     "REQ-STANDALONE-6", layer="ui",
     note="`DebugScreenGallery` and `ConformanceHarness` are `#if DEBUG` and are not this. Gates E-R2."),
   level("E13.3","The standalone audit",
     "Every capability degrades to a stated standalone behaviour.",
     ["Sweep every capability against REQ-STANDALONE-1",
      "No feature errors where the PRD requires a defined offline path"],
     "No feature errors where the PRD requires a defined offline path.",
     "REQ-STANDALONE-1", layer="ui"),
  ]),

 dict(id="E14", title="Repository, dependency and policy hygiene", layer="protocol",
  summary="A clean checkout still needs a sibling `libppcp`, and the port surface is not yet a documented artefact.",
  why="Small, independent, and startable immediately — none of it waits on E1.",
  deps="`libppcp` tagging is the library's call.",
  levels=[
   level("E14.1","libppcp tagged and consumed by version",
     "A clean checkout builds without a sibling repository.",
     ["`Package.swift` off the sibling path onto the versioned git URL",
      "The URL is already recorded in a comment"],
     "A clean checkout builds without a sibling repository.",
     "— (REQ-LIC-3 support)", layer="protocol", blocked="external"),
   level("E14.2","CI",
     "The conformance claim cannot silently rot.",
     ["`test-core`, `test-app` and `conform` on every push",
      "RT-17's standing TLS review recorded as a recurring check"],
     "The conformance claim cannot silently rot.",
     "— (supports the whole claim)", layer="protocol"),
   level("E14.3","The port surface published",
     "A second-platform implementer has one page to read.",
     ["Enumerate the port surface as a documented artefact rather than an emergent property",
      "The Core README's three-row table is a start, not the artefact"],
     "A second-platform implementer has one page to read.",
     "REQ-PORT-2", layer="core"),
   level("E14.4","Version support-window policy",
     "N releases back, written, plus the unknown-dialect behaviour.",
     ["A written N-releases-back policy with a deprecation path",
      "The app's behaviour facing an unknown host dialect"],
     "REQ-VER-3 satisfied.",
     "REQ-VER-3", layer="core", blocked="decision", deps="Waits on OPEN-5."),
  ]),

 dict(id="E15", title="USB transport (SHOULD)", layer="platform",
  summary="B1's \"Use a cable instead\" row is drawn and its closure is empty.",
  why="Lower and far more stable latency floor for UC-2, so minimum-RTT filtering converges faster. ⚠ And larger than that: it resolves the reconnection half of `RV` 3.5d on the wired path, because identity resolution moves to the client — so the MVP's requirement (a), connected without a per-session scan, holds over a cable today (#94). Both listeners bind `127.0.0.1`, so the wired path is also exempt from the iOS local-network permission.",
  deps="E3. The `usbmuxd`/libimobiledevice half is LGPL and belongs on the PinPoint side (REQ-TRANS-3, REQ-LIC-5).",
  levels=[
   # ⛔ Criterion reworded on closing (#64, 31 Aug 2026). It read "a USB
   # `PeerTransport` implementation exists alongside the TLS one" — no such type
   # was written and writing one would have been wrong: usbmux presents a plain
   # TCP socket on loopback, so TLS runs over it unchanged and the transport on
   # the cable IS `PpcpListener`, bound to 127.0.0.1 instead of all interfaces.
   # What the level actually needed was `RV` §3 advertisement semantics delivered
   # over a cable, and neither that nor the listener lifecycle had been sized.
   level("E15.1","The device end of the tunnel",
     "The device listens and the host dials, inverting `RV` 2d.",
     ["`WiredPresence` — the CBOR record, `ENC` 4e order `dl, pv, role, peers`",
      "`WiredPresenceListener` — one plaintext presence listener on the fixed "
      "port, one `PpcpListener` per held pairing behind it, all bound `127.0.0.1`",
      "A 2 s reconcile in `AppModel` holding one level rule",
      "A `PairingSecretStore` generation, bumped inside `mutate()`",
      "`PpcpLog` to both the unified log and stdout, so a cabled phone can be read"],
     "A cable carries a real PPCP session: the device publishes the identity it "
     "registered, the host verifies it under 5.3b and dials, and the link "
     "survives a host restart unattended.",
     "REQ-DISC-5", layer="platform"),
   level("E15.2","End-to-end with the host side",
     "A cable session works from B1.",
     ["Host-side tunnel — **LGPL, belongs on the PinPoint side** — delivered "
      "and hardware-verified",
      "B1's `onUseCable` closure — still `{}` at `RootView.swift:427`",
      "A first pairing carried on the presence record. `WiredPresence` "
      "deliberately carries no `rid` so that a scanned-but-not-yet-connected "
      "code can ride it (design §6.5); nothing calls it"],
     "B1's *Use a cable instead* completes a pairing.",
     "REQ-DISC-5", layer="platform", blocked="external",
     note="Downgrade or defer without embarrassment; it is a SHOULD. ⛔ But "
          "\"the transport abstraction already accommodates it\" was wrong — "
          "it accommodated the socket and nothing else, and the expensive half "
          "is now spent."),
  ]),

 dict(id="E16", title="Rendezvous completion on hardware", layer="platform",
  summary="Rendezvous is built and passes its static vectors. Three properties need a device to prove.",
  why="Startable immediately — none of it waits on E1.",
  deps="A device, a second device, and an App ID capability.",
  levels=[
   level("E16.1","Discovery on a real network",
     "mDNS advertise and browse against a real AP.",
     ["Advertise and browse against a real AP ✅ — **the dial completed 2 Sep "
      "2026**, four times in one run over Wi-Fi with no code, which is the "
      "MVP's requirement (a) end to end",
      "The multicast-fails path exercised deliberately ⛔ — observed by "
      "accident (two 4.5-minute sweeps found nothing beside an advertising "
      "Studio; a third found it on sweep four), never driven"],
     "REQ-DISC-1 and REQ-DISC-3 proven outside a simulator.",
     "REQ-DISC-1, REQ-DISC-3", layer="platform",
     note="⚠ Closed 2 Sep 2026 (#66) with the second component UNDONE: the "
          "multicast-fails path was observed and never driven deliberately."),
   level("E16.2","Pairing that does not ride a backup",
     "Keychain `ThisDeviceOnly` verified across a real restore.",
     ["A pairing must not ride a backup onto a second device",
      "Not observable from a test at any layer — needs a device and a backup"],
     "**RT-15** completes.",
     "— (RV 7.4c)", layer="platform",
     note="⚠ Closed 2 Sep 2026 (#67) — ⛔ NO RESTORE WAS PERFORMED. The file is "
          "created backup-excluded and that is asserted in code; a real device "
          "restore proving a pairing did not ride it has never happened."),
   level("E16.3","Hotspot join",
     "B4 joins a host-provided network on a device.",
     ["`NEHotspotConfiguration` with Hotspot Configuration enabled on the App ID",
      "The entitlement is already in `Support/PinPointCapture.entitlements`"],
     "B4 joins a host-provided network on a device.",
     "REQ-DISC-4", layer="platform",
     note="⚠ Closed 2 Sep 2026 (#68) — ⛔ no device has joined one. The App ID "
          "entitlement it needs is still listed as a submission requirement by "
          "E-R2."),
  ]),
]

DECISIONS = [
 ("OPEN-3","Minimum device tier — is 120 fps the floor, and at what resolution and light level?",
  "Gates the A1 verdict, **E8.1**, and **E-M3/E-M4**.",
  ["The frame-rate half is implemented and now correctly attributed (REQ-CAP-6).",
   "REQ-CAP-4's optical quality gate is **not** implemented — no device has a measured noise or contrast figure.",
   "Cannot be closed honestly until E-M1 and E-M4 have run.",
   "Carries an unanswered sub-question: should a connected host's policy be adopted for future standalone sessions?"], "rig"),
 ("OPEN-4","App licence and distribution channel",
  "Gates **E-R2**.",
  ["The library stays MIT either way.",
   "Non-GPL for the app if App Store distribution is wanted — GPL and store distribution are contested (the VLC precedent)."], None),
 ("OPEN-5","Version support window (REQ-VER-3)",
  "Gates **E14.4**.",
  ["Needs a minimum of N releases back, with a written deprecation path.",
   "Also needs a defined behaviour facing an unknown host dialect.",
   "The negotiation machinery it would govern already exists — this decision is the only thing standing between REQ-VER-3 and closure."], None),
 ("OPEN-6","Does v1 ship tethered-only, deferring the standalone UI?",
  "Scopes **E9** and **E13**.",
  ["**Recommendation: close as \"no\".** The premise has been overtaken.",
   "The standalone path is the *more* complete half of what has been built — hostless sessions, bundle write and read, and the whole zero-host path pass end to end.",
   "The live host link is the part with no caller.",
   "Deferring the standalone UI now would defer the half that works in order to ship the half that does not."], None),
 ("OPEN-7","How much core logic is shared vs. reimplemented natively per platform?",
  "Gates **E25** (Android) only. Not a v1 gate.",
  ["The seams exist and are mechanically enforced — a layer-purity test fails the build on a forbidden import.",
   "The shared layer is presently Swift and deliberately temporary; the substitution toward libppcp has started.",
   "Decide when the port surface is enumerated in E14.3."], None),
 ("D-REV-1","Does REQ-SHOT-6 narrow to *live* nominators, with file-imported launch monitor records reconciled through `ShotLink`?",
  "Gates **E9.3**.",
  ["From PRD review comment 2, 22 August 2026 — still open.",
   "The launch monitor this project integrates with is a filesystem-watched CSV with no Peer, no Timebase and no clock relation, so it cannot be a Source in the sense REQ-SHOT-6 requires.",
   "Needs a protocol-side answer so `CORE` and the PRD do not disagree.",
   "`SessionMatch` already models the file-imported case as a match rather than as a nomination, so the delivery consequence is bounded."], "external"),
 ("D-REV-2","When does REQ-OBS-4's diagnostic mode turn itself off?",
  "Gates **E10.3**.",
  ["From PRD review comment 4, 22 August 2026 — still open.",
   "A diagnostic mode left on by a user who was helping debug something in March is a retention posture nobody chose.",
   "Recommendation stands: it expires with the session.",
   "\"Expires with the session\" and \"expires on restart\" are different implementations, not different wordings — settle it before E10.3 is built."], None),
]

MEASUREMENT = [
 ("E-M1","LED timecode rig",
  "Host-driven LED flashing a binary-coded pattern at ~1 kHz, in view of both the device and the FLIR cameras.",
  ["Per-frame ground truth on end-to-end alignment",
   "Rolling-shutter readout time measured in the same experiment (different sensor rows decode different codes)"],
  "Moves every `DeviceProfiles.json` entry from provenance `assumed` to `measured`.",
  "REQ-TEST-1, REQ-TEST-2, REQ-EXP-3, REQ-PORT-10 (values)",
  "**The PRD says build this *before* the protocol. It is now the other way round.** That is the root of the whole measurement debt — every rolling-shutter readout and exposure offset the device declares carries provenance `assumed`."),
 ("E-M2","Bitrate sweep",
  "Short-GOP, no-B-frame HEVC at ~30 / 60 / 100 Mbps, scored on shaft RMSE against an uncompressed reference — never on a perceptual metric.",
  ["Expected outcome: a knee well below the Level 5.1 ceiling",
   "Retires the all-intra question without needing to answer it"],
  "Sets E1.4's operating bitrate.", "REQ-TEST-6, REQ-BUF-3",
  "Runs on the same rig as E-M3, in one session."),
 ("E-M3","Resolution comparison",
  "Same swing, same lighting, 1080p150 versus 4K120, scored the same way.",
  ["Expected outcome: 4K loses on SNR and rolling shutter, with the temporal loss compounding it",
   "Record the measurement in the device profile rather than the expectation in the PRD"],
  "Closes OPEN-3's resolution half.", "REQ-TEST-7, REQ-RESOL-1, REQ-RESOL-2",
  "Runs on the same rig as E-M2, in one session."),
 ("E-M4","Sustained capability",
  "Encode rate under thermal load after ~40 minutes, not from cold; the 90-minute battery target; the charging trade-off.",
  ["Published throughput figures are cold-start measurements",
   "`runSelfTest` currently runs for three seconds and the code says outright that this demonstrates the path works rather than measuring anything",
   "Also produces the real `estimated_ready_ms`, currently an assumed 1 200"],
  "Unblocks E11.3 and A7's *Measured, sustained* row.",
  "REQ-CAP-2, REQ-ENC-4, REQ-RES-4, REQ-RES-5", None),
 ("E-M5","Acoustic time of flight",
  "A surveyed distance with a real sigma on this device, and validation of the residual-based estimator.",
  ["`AcousticTimeOfFlight` takes a surveyed or estimated distance and its sigma",
   "Nothing has measured either, so a shipping session declares **no** `tof_correction` rather than an assumed one"],
  "Unblocks E2.3.", "REQ-MIC-3, REQ-MIC-4", None),
]

RELEASE = [
 ("E-R1","Trademark clearance",
  "Complete a trademark clearance check on \"PinPointCapture\" and \"PinPoint\" **before first App Store submission**.",
  ["USPTO TSDR verification of PIN POINT GOLF (serial 98753725, filed Sep 2024) — the closest live conflict, Class 9 included",
   "Equivalent UKIPO search, the project being UK-based",
   "Suggested classes: 9, 28, 41",
   "A qualified opinion — the PRD records register searches, not legal clearance"],
  "REQ-LIC-6",
  "A **pre-submission** gate, explicitly not a pre-development one. Engineering does not wait on it. The exposure attaches to *PinPoint*, not to *Capture* — PinPointStudio, the org name and the website already carry it."),
 ("E-R2","App Store submission readiness",
  "Everything that must be true before the first submission.",
  ["Review mode (**E13.2**)",
   "Privacy label stated in **candidates** with the retention cap, matching REQ-PRIV-6 and `CandidateAudioRetention`'s own sentence",
   "Purpose strings for camera, microphone, motion",
   "`NSLocalNetworkUsageDescription` and `NSBonjourServices`",
   "Hotspot Configuration enabled on the App ID (**E16.3**)",
   "**OPEN-4** closed"],
  "REQ-STANDALONE-6, REQ-PRIV-2, REQ-DISC-4, REQ-DISC-6, REQ-LIC-4", None),
]

SHELF = [
 ("E17","Advisory pose for replay annotation","v2","§2.3, §10.2",
  "Device-side pose to support replay annotation (hand-path tracing on a DTL view) and navigation. **Not analysis.**",
  ["Tagged `provenance: device-advisory` with model identity and version (REQ-POSE-1)",
   "Never ingested by any producer (REQ-POSE-2)",
   "Host pose silently supersedes — no reconciliation, no diff view (REQ-POSE-3)",
   "A visibly different estimator from the host's, so \"just use the phone's numbers\" is obviously wrong to a future reader (REQ-POSE-4)"]),
 ("E18","Upload triage","v2","§10.2",
  "A local check for \"real swing / golfer in frame / club moved\", to avoid spending bandwidth on practice swings and dropped clubs.",
  ["This is where on-device inference earns its place — triage, not analysis"]),
 ("E19","Voice club tagging","v2","§10.2",
  "Hands hold a club; the device is 2 m away on a tripod.",
  ["A second consumer of an audio stream that is already open",
   "Club context is not cosmetic — diagnostics corridors are club-specific"]),
 ("E20","Second screen for host-computed results","v2","UC-5, §10.2",
  "Coach at the host, golfer at the phone.",
  ["Display is presentation, not computation — it does not move the §2 line",
   "Carries a materially different privacy posture: a lesson may capture coach and pupil in conversation"]),
 ("E21","Offline sensor capture and export","v2","§16.3–§16.6",
  "**IMU first, then HackMotion via `libwrist`** — in that order, and for a stated reason.",
  ["The WitMotion integration is already understood, making it the honest testbed for BLE-under-capture",
   "HackMotion carries unretired protocol risk; the least-certain sensor must not define the offline sensor architecture",
   "Device becomes the time authority: estimate the device↔sensor clock mapping live and continuously (REQ-OFF-4)",
   "The bundle carries both the estimate **and** the raw arrival evidence — estimates age, evidence does not (REQ-OFF-5)",
   "Sensor dropout recorded as an explicit gap, never interpolated across (REQ-OFF-13)",
   "Measure BLE + 120 fps capture + hardware encode, sustained, before the design hardens (REQ-OFF-15)"]),
 ("E22","Multi-device stereo","v3","UC-6, §10.3",
  "Two or more devices as a stereo pair for users with no fixed hardware.",
  ["The acoustic oracle stops being corroborative and becomes essential — two devices share no wired clock, so impact is the only common fiducial",
   "Confirm the sync design tolerates peer-to-peer, not only star",
   "Offline: two devices aligned at import by cross-correlating the impact transient (REQ-OFF-16)"]),
 ("E23","Relayed BLE sensors","v3","§10.3",
  "The device as a portable capture hub.",
  ["Enabled by REQ-STREAM-1 as a new stream type rather than a new protocol"]),
 ("E24","Camera phase alignment","v3","§10.3",
  "Co-timed stereo frames.",
  ["PPCP aims at accurate *timestamping*, not phase alignment — the protocol must not preclude this, but v1 does not attempt it"]),
 ("E25","Android","v3","§17",
  "The port that REQ-PORT-1..14 exist to make possible.",
  ["`SENSOR_INFO_TIMESTAMP_SOURCE` may report `UNKNOWN` — camera and mic on unrelated timebases (REQ-PORT-8). **The single most likely place a port turns into a rewrite**",
   "Constrained high-speed session takes batched request lists over a limited surface set (REQ-PORT-9)",
   "Device profiles as data keyed by model — Android's device population makes a code-based approach untenable (REQ-PORT-10)",
   "Depends on OPEN-7 and on E14.3's port surface artefact"]),
]

# ---------------------------------------------------------------- rendering

FOOTER = (f"\n\n---\n\n<sub>Scope: [delivery-scope.md]({SCOPE}) · "
          f"Requirements: [traceability.md]({TRACE}) · "
          f"PRD: [capture-companion-requirements.md]({PRD}) · "
          f"Conformance: [ppcp-conformance.md]({CONF})</sub>")

BLOCK_LABEL = {"phone":"blocked-on: phone","rig":"blocked-on: rig",
               "decision":"blocked-on: decision","external":"blocked-on: external"}

def epic_body(e):
    b = [f"> {e['summary']}", "", "## Why this clusters", e["why"], "", "## Capability levels", ""]
    b.append("| Level | Capability | Release |")
    b.append("|---|---|---|")
    for l in e["levels"]:
        b.append(f"| **{l['id']}** | {l['title']} | {l['release']} |")
    b += ["", "Each level is independently shippable. They are tracked as sub-issues of this one.", ""]
    if e.get("deps"):
        b += ["## Dependencies", e["deps"], ""]
    reqs = sorted({r.strip() for l in e["levels"] for r in l["reqs"].split(",")
                   if r.strip().startswith("REQ-")})
    if reqs:
        b += ["## Requirements covered", ", ".join(reqs), ""]
    return "\n".join(b).rstrip() + FOOTER

def level_body(l, e):
    b = [f"**Epic:** {e['id']} — {e['title']}",
         f"**Release:** {l['release']} · **Layer:** {(l['layer'] or e['layer']).title()}"
         + (f" · **Blocked on:** {l['blocked']}" if l["blocked"] else ""), "",
         f"> {l['cap']}", "", "## Components", ""]
    b += [f"- {c}" for c in l["components"]]
    b += ["", "## Exit criterion", "", l["exit"], ""]
    if l.get("note"):
        b += ["## Note", "", l["note"], ""]
    if l.get("deps"):
        b += ["## Dependencies", "", l["deps"], ""]
    b += ["## Requirements", "", l["reqs"], ""]
    return "\n".join(b).rstrip() + FOOTER

def labels_for(l, e):
    out = [f"layer: {(l['layer'] or e['layer'])}", f"release: {l['release']}"]
    if l["blocked"]: out.append(BLOCK_LABEL[l["blocked"]])
    if e["id"] == "E7" and l["id"] == "E7.1": out.append("design-needed")
    return out

issues = []
for e in EPICS:
    issues.append(dict(kind="epic", key=e["id"], title=f"{e['id']} — {e['title']}",
                       body=epic_body(e), labels=["epic", f"layer: {e['layer']}", "release: v1"],
                       parent=None))
    for l in e["levels"]:
        issues.append(dict(kind="level", key=l["id"], title=f"{l['id']} — {l['title']}",
                           body=level_body(l, e), labels=labels_for(l, e), parent=e["id"]))

for id, title, gates, points, blocked in DECISIONS:
    body = [f"> {gates}", "", "## Position", ""] + [f"- {p}" for p in points]
    body += ["", "This is a **decision**, not engineering work. Closing it unblocks the levels named above.", ""]
    lab = ["decision", "release: v1"]
    if blocked: lab.append(BLOCK_LABEL[blocked])
    issues.append(dict(kind="decision", key=id, title=f"{id} — {title}",
                       body="\n".join(body).rstrip()+FOOTER, labels=lab, parent=None))

for id, title, desc, points, unblocks, reqs, note in MEASUREMENT:
    body = [f"> {desc}", "", "## What it involves", ""] + [f"- {p}" for p in points]
    body += ["", "## Why it matters", "", unblocks, ""]
    if note: body += ["## Note", "", note, ""]
    body += ["## Requirements", "", reqs, ""]
    issues.append(dict(kind="measurement", key=id, title=f"{id} — {title}",
                       body="\n".join(body).rstrip()+FOOTER,
                       labels=["measurement", "release: v1", "blocked-on: rig"], parent=None))

for id, title, desc, points, reqs, note in RELEASE:
    body = [f"> {desc}", "", "## What it involves", ""] + [f"- {p}" for p in points]
    body += [""]
    if note: body += ["## Note", "", note, ""]
    body += ["## Requirements", "", reqs, ""]
    issues.append(dict(kind="release", key=id, title=f"{id} — {title}",
                       body="\n".join(body).rstrip()+FOOTER,
                       labels=["release-gate", "release: v1"], parent=None))

for id, title, rel, prd, desc, points in SHELF:
    body = [f"> {desc}", "", f"**PRD:** {prd} · **Release:** {rel}", "", "## Scope", ""]
    body += [f"- {p}" for p in points]
    body += ["", "Held on the shelf so requirements tracing here read as **deferred**, not missing. "
             "Not decomposed — that happens when it is scheduled.", ""]
    issues.append(dict(kind="shelf", key=id, title=f"{id} — {title}",
                       body="\n".join(body).rstrip()+FOOTER,
                       labels=[f"release: {rel}"], parent=None))

json.dump(dict(repo=REPO, labels=LABELS, issues=issues), open(os.path.join(os.path.dirname(os.path.abspath(__file__)),"backlog.json"),"w"), indent=1)

from collections import Counter
c = Counter(i["kind"] for i in issues)
print(f"{len(issues)} issues:", dict(c))
print(f"{len(LABELS)} labels")
assert c["epic"] == 16, c["epic"]
assert c["level"] == 52, c["level"]
assert len(issues) == 91, len(issues)
print("counts check out")
