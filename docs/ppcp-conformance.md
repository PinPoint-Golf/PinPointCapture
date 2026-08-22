# PinPointCapture — PPCP conformance claim

**What this application claims of `ppcp/1.0`, and the command that reproduces each claim.**

| | |
|---|---|
| Implementation | PinPointCapture (iOS) |
| Role | `capture` |
| Against | `PPCP-CORE` revision 9, `PPCP-MSG`, `PPCP-ENC`, `PPCP-CONF` 1.0; `PPCP-RV` revision 8 |
| Companion | [`libppcp/docs/conformance/matrix.md`](https://github.com/PinPoint-Golf/libppcp) — the compliance record this file feeds |
| Status | **In progress.** Session S3 wave 1: **D4 landed** — the REQ-BUF-1 ring extracts a clip around a `t0` into a Capture with `achieved_summary` on the announce and `achieved_frames` with the payload, a `continuous` `metadata` Stream accounts for its own interval (I36), readiness crosses as a measurement and an interruption records its gap. S2: D1 reworked for erratum E1, D2 and D3 landed. Nothing is deferred on `libppcp` — see §5. |
| Depends on | `libppcp` — MIT, consumed as a SwiftPM package (plan A5), product `CPPCP`. Path `../../../libppcp` during co-development; `https://github.com/PinPoint-Golf/libppcp.git` once tagged. |
| Date | 22 August 2026 (S3, wave 1) |

---

## 1. Profile set

`CORE` §2.2.3, "full mobile capture device".

| Profile | Claimed | Notes |
|---|---|---|
| **Core** | yes | The mandatory base. |
| **Capture** | yes | Clips as Captures, retained on device and transferred on the bulk channel. |
| **Detect** | yes | Acoustic onset nomination from the device microphone. |
| **Mint** | yes | Hostless operation mints its own Shots, `authority: device`. |
| **Live** | yes | Sessions with a host, sync, heartbeat, arm. |
| **Offline** | yes | The session store *is* the bundle (plan A9). |
| **Markup** | yes | Device-authored annotations, host annotations stored opaque. |
| **Arbitrate** | **no** | Host-only by `CORE` I20. The negative test applies: this application parses `capture_request` and **never originates it**, and never originates `session_link`. |

## 2. PPCP-RV

`RV` 9d requires an implementation to state which optional parts it provides.

| Part | Claimed | State |
|---|---|---|
| **Pairing code** (`RV` §4) — REQUIRED of any RV implementation | yes | D7. The device is the **scanner**, therefore the dialler and the TLS client (`RV` 2d, 5.2g). |
| **Key derivation and TLS** (`RV` §5) | yes | D0 + D1 landed. The derivation is `libppcp`'s (`ppcp_rv_derive`, `ppcp_rv_psk_identity`); TLS lives in the application and never in the library (plan A7). |
| **Security model** (`RV` §7) | yes | D1 landed the transport half; the secret-handling half is D7. |
| **Service discovery** (`RV` §3) | **intended, and now in doubt** | See the finding in §4. The device can advertise, but a Network.framework listener cannot accept a conformant rotating PSK identity, and on the discovery path the advertiser listens. |
| **Network join** (`RV` §6) | intended | D7. `NEHotspotConfiguration` with consent before the endpoint walk. |

---

## 3. Conformance rows

Rows in the format of [`matrix.md`](https://github.com/PinPoint-Golf/libppcp) §5, so they transplant into it unchanged. Only the **PinPointCapture** column is this file's to fill.

| Test | Method | Asserts | Work packages | `libppcp` | PinPointStudio | PinPointCapture |
|---|---|---|---|---|---|---|
| RT-1 | static | §10.1 derivation vectors | L12 | — | — | pass |
| RT-4 | injected | strongest mode negotiated, never plaintext, outcome surfaced | H1, D1 | n/a | — | impl |
| RT-10 | injected | `session_resume` refused without a completed handshake | H1, D1 | n/a | — | impl |
| RT-14 | static | §10.2 PSK identity; differs per connection; empty hint at TLS 1.2 | L12, H1, D1 | — | — | impl |
| RT-17 | **review** | every platform mode offered, from a capability query | H1, D1 | n/a | — | review |
| CT-I4 | static | two Sources on one clock share one `timebase_id`; no relation asserts identity | D2 | — | — | pass |
| CT-I12 | fixture | video-only, IMU-only and empty-stream bundles all load | D3 | — | — | pass (own half) |
| CT-I19 | injected | every Source declares timing, geometry and intrinsics | D2 | — | — | pass (own half) |
| CT-I22 | static | offset present iff `nominal_frame_start`; a defaulted zero is not producible | D2 | — | — | pass |
| CT-I28 | static | no self-test, no `measured`; an onboarding sample is `cold_sample` | D2 | — | — | pass |
| CT-I31 | static | provenance on offset, readout **and `AchievedFrames.exposure_ns`** | D2, D4 | — | — | pass |
| CT-I34 | fixture | idempotent re-import; identity is `Capture.id` by session and peer | D3 | — | — | pass |
| CT-I2 | fixture | no sample's time is derived from its index | D4 | — | — | pass (own half) |
| CT-I10 | paired | `absent` appears only where the owner asserted it | D4 | — | — | pass (owner half) |
| CT-I11 | fixture | gaps explicit, never spanned, and only on `continuous` streams | D4 | — | — | pass |
| CT-I17 | injected | see CT-S1 | D4, L13 | — | — | impl |
| CT-I27 | static | exactly one anchor key; `{stream: true}` refused on `shot_windowed` | D4 | — | — | pass |
| CT-I30 | paired | announce carries summary only; `payload_begin` carries the series; locked series are scalars | D4 | — | — | pass (own half) |
| CT-I36 | fixture | announced segments and gaps account for the whole open interval | D4 | — | — | pass |
| CT-I36a | paired | preview sheds as `absent`/`not_retained`, never `pending`, never bundled | D4 | — | — | pass (own half) |
| CT-S1 (6) | injected | the scalar form and an equivalent constant array convert identically | D4 | — | — | pass |
| CT-S4 (1) | injected | the zero-host path end to end, including bundle write and read | D3, D4, D5 | — | — | impl (bundle half passes, with a real Capture) |
| CT-S7 (1) | injected | every emitted timing constant carries a provenance; unmeasured is `assumed` | D2 | — | — | pass |
| CT-S7 (2) | injected | a device-profile entry with no rig measurement cannot emit `measured` | D2 | — | — | pass |
| CT-S7 (3) | injected | `exposure_provenance` honest: `per_frame` only where the platform attaches it | D4 | — | — | pass |
| CT-S7 (4) | injected | converted instants differ by exactly a synthetic peer's declared offset | D4 | — | — | blocked: `ppcp-sim` (L13) |

### What each state rests on

**RT-1 — `pass — make test-core`.** `Packages/Core/Tests/CaptureCoreTests/RendezvousTests.swift`. `PRK`, `K_tls` and `K_id` reproduce byte for byte from the §10.1 `psk` and `sid`, through `libppcp`'s `ppcp_rv_derive` — not through an HKDF of this application's own, which is the point of plan A5. Re-deriving from a persisted `PRK` (5.1c) lands on the same two keys.

**RT-4 — `impl`.** Reproduce with `make test-app`
(`Tests/TransportLoopbackTests.swift`, commit `bb85a06`).

- *Never plaintext* (5.2f): held by construction — `Sources/Platform/Network/PpcpTransport.swift` contains no plaintext branch, and `PpcpByteChannel.open` has no return value meaning "connected without TLS". A mismatched `K_tls` fails closed, asserted.
- *Outcome surfaced* (5.4k): `NegotiatedSecurity` carries the achieved version, ciphersuite and key-exchange mode; both ends of the loopback agree on it. **Measured: TLS 1.2, `0x00A8`, `TLS_PSK_WITH_AES_128_GCM_SHA256`, no forward secrecy** — `RV` 5.4b1 reproduced exactly, on iOS 27.
- *Not yet demonstrated*: "a handshake negotiating a weaker mode than both peers can reach is refused" (5.2b1). Both ends of this loopback share the same platform limitation, so the pair cannot reach anything stronger and the assertion is vacuous here. It needs an instrumented counterpart or a wire capture (`RV` 5.2i) — `ppcp-conform` (L14), or the PinPointStudio leg where the counterpart *can* reach TLS 1.3 (S5 interop).

**RT-10 — `impl`.** Reproduce with `make test-app` and `make test-core`.

- The transport half is done and tested: a `PpcpByteChannel` refuses to carry a byte until its connection is `.ready` with TLS metadata (`RV` 1.3c, 7.7a), false start is disabled, and Network.framework exposes no 0-RTT switch to leave on (`RV` 7.5d).
- The message half — `session_resume` refused for a `sid` not bound to the connection (7.5b) — needs the peer engine (L6) and D6. Nothing to run yet.

**RT-14 — `impl`.** Reproduce with `make test-core` and `make test-app`.

- *Byte for byte*: `ppcp_rv_psk_identity` with §10.2's `rn2` produces `010f1e2d3c4b5a6978b355ada60b4b5aa8` exactly, and the result contains no `sid` (5.3e).
- *Differs across connections* (5.3a): sixty-four identities from the default `SystemRandomNumberGenerator` source are sixty-four distinct values, with only the `0x01` version octet stable.
- *Wire half*: the 17 octets are handed to the platform as bytes with no transcoding, no UTF-8 validation and no truncation (5.3f), and the §10.2 identity completes a handshake unchanged — 5.4b2 reproduced on iOS 27. A Core test asserts an identity that is deliberately invalid UTF-8 survives a round trip.
- *All that is left*: the **empty `psk_identity_hint`** at TLS 1.2 (5.2h property 3, RT-14's tail). The listener sets it explicitly to zero length rather than leaving it unset, but whether the platform sends it empty or omits it entirely is not observable from the API — `RV` 5.2i names this exact case. It needs a wire capture, and nothing else does.
- *Not this column*: "resolves under the correct `K_id` only" belongs to the resolver (`ppcp_rv_resolve_psk_identity`), which D7 exercises — and which, per the finding in §4, cannot be reached from inside a Network.framework handshake.

**CT-I4 — `pass — make test-core`.**
`Packages/Core/Tests/CaptureCoreTests/DeclarationTests.swift`. The camera Sources, the microphone and the IMU all reference `tb:hosttime`, and the declaration carries **zero** `TimebaseRelation`s. `CORE` §5.3 states the platform fact this rests on — "on iOS, camera and microphone Sources both reference `tb:hosttime` and no relation exists because none is needed" — and the negative half is the load-bearing one: an implementation that declared an identity relation would look more thorough and would be wrong.

⚠ **A port must re-derive this, not copy it.** An Android device reporting `SENSOR_INFO_TIMESTAMP_SOURCE == UNKNOWN` must declare two ids and a relation, and §5.3 says there is "no third option and no silent default".

**CT-I19 — `pass` for this peer's own declaration — `make test-core`.**
Every camera `CaptureProfile` this device emits declares `timing`, `geometry` and `intrinsics`, and every Source declares `timebase_id`. ⚠ The cell is not a whole `pass`: `CONF` gives CT-I19's method as *injected* and points at CT-S3, which tests a **consumer** meeting a declaration different from its own. That half needs the peer engine (L6) and arrives with D6. What is asserted today is the declaring half, which is the half this application owns.

**CT-I22 — `pass — make test-core`.**
Two assertions, and the second is the one that matters.

- *Present iff*: every camera profile is `nominal_frame_start` and carries the offset; the microphone and IMU profiles are `mid` and carry none.
- *A defaulted zero is not producible*: asserted by **calling `ppcp_timing_make` with `PPCP_CONV_NOMINAL_FRAME_START` and watching it refuse**. `libppcp` has two constructors and only `ppcp_timing_make_nominal_frame_start` takes an offset — and it takes the provenance in the same call, so an offset without one is equally unconstructible. That is why the Core test target binds to `CPPCP` directly: it is a claim about the library's signatures, not about this application's values.

**CT-I28 — `pass — make test-core`.**
A profile with no self-test carries no `measured` block. Three refusals are asserted: no self-test at all; a self-test of a *different* profile (5.8c — 1080p240 and 1080p120 are separate results, and so are the wide and ultra-wide instances of the same mode); and a self-test with no `observed_at` in the capture timebase, which produces no block rather than an invented instant (I1, 5.3b).

`method` is decided in `AVFoundationCaptureDevice.measureSustainedRate` from the run's own duration and thermal evidence, not passed in by a caller — 5.8b, and the specification's own diagnosis that "without `method` the cold number quietly becomes the displayed one".

⚠ `MeasuredCapability` had no `method`, no `duration_ns` and no `observed_at` before S2. It carried a `Date`. Three mandatory protocol fields were absent from a type whose comment already said "a measurement taken from cold is not a measurement" — REQ-PORT-11's "views over the library's structs" made that visible, which is the point of the requirement.

**CT-I31 — `pass — make test-core` and `make test-app`.**

- Every `frame_start_to_exposure_offset_ns` and every `rolling_shutter.readout_ns` this implementation emits carries a provenance, and every one is `assumed` (plan A12 — no model has been through an LED timecode rig, REQ-TEST-1/2).
- The third clause, `AchievedFrames.exposure_ns`, closed with D4. `ppcp_achieved_frames_set_exposure` takes the provenance as a **parameter**, so the pair cannot be split; and one layer up, `ExposureObservation` has one case per honest answer with the wire form built into the case, so `per_frame` with a scalar is not typeable. See CT-S7 (3).

### D4 — the capture path

Every row below reproduces with **`make test-core`** unless it says otherwise;
the file is `Packages/Core/Tests/CaptureCoreTests/CapturePathTests.swift`, and the
platform half is `Tests/CapturePathAppTests.swift` under `make test-app`.

**CT-I2 — `pass` for this peer's own half — `make test-core`.**
The ring's frame timeline is the timestamps the platform stamped, carried through extraction unchanged, and the realised rate is computed from the **span between first and last**, never from a count over an interval and never from an index (5.8e: "frames drop; indices lie"). The fixture puts frames on a 6,666,666 ns grid rather than on millisecond boundaries, because a fixture on round numbers hides exactly the arithmetic that a real 1/150 s interval exposes; it also puts every fragment's frames on **one** grid, since the sensor does not restart at a fragment boundary. ⚠ The cell is not a whole `pass`: `CONF` gives the method as *fixture* and the fixture a third party would replay is the interop row.

**CT-I10 — `pass` for the owner half — `make test-core`.**
`CORE` 8.4b: a request for an interval the ring no longer holds is answered with `completeness: absent` and `absent_reason: outside_buffer`. Asserted as a **result and not a failure** — `FragmentRing.extract` has no error case for a miss, which is `PPCP-MSG` 7.3b ("an absent capture is a result, not a failure") made structural. The half this column cannot hold is the receiver's: CT-I10's assertion is that a *receiver* does not infer `absent` from a withheld payload, and that is PinPointStudio's.

**CT-I11 — `pass — make test-core`.**
Both halves, and the negative one is against the library.

- *Positive*: a 250 ms hole between two retained fragments — a recording interruption, not an eviction — is found by extraction and reported. On a `continuous` Stream it becomes a `gaps` entry; on `shot_windowed` it becomes the reason the Capture is `partial` and is reported no other way.
- *Negative*: a Capture carrying gaps is handed to `ppcp_capture_validate_in_stream` against a real `shot_windowed` `ppcp_stream` and **refused**. The same Capture validates in isolation, which is the point: the rule needs the Stream, and asserting it without one would assert nothing.

**CT-I27 — `pass — make test-core`.**
Zero keys and two keys are not constructible: `libppcp` has three constructors and one tagged union, and `PpcpCaptureAnchor` is the same shape one layer up. The second assertion — `{stream: true}` refused on a `shot_windowed` Stream — is asserted against `ppcp_capture_validate_in_stream` with a real `ppcp_stream`, not against our own idea of it. ⚠ See F-D4-1: the *engine* does not apply that check at origination although it holds the stream table, so this row passes on a validator a peer must remember to call.

**CT-I17 / CT-S1 (6) — assertion 6 `pass`, the row `impl`.**
"The scalar form and an equivalent constant array produce identical canonical instants." Asserted through `ppcp_achieved_frames_canonical_at` for a `nominal_frame_start` profile with a 120,000 ns offset, over both forms, frame by frame. ⚠ **This is the path that ships**: the application locks exposure (REQ-OPT-3), so the scalar form is what a real clip carries, and `CONF` says in as many words that "a conversion test that exercises only the varying-exposure path does not test what ships". Assertions 1–5 need the synthetic peer of L13 and are CT-S7 (4)'s block, not this one's.

**CT-I30 — `pass` for this peer's own half — `make test-core`.**
Three assertions, and the encoded size is measured rather than asserted by inspection.

- *The announce carries no per-frame series*: structural. `ppcp_capture` has **no `achieved_frames` member at all**, so there is nowhere to put one, and `PpcpCaptureRecord` has none either.
- *Measured*: a 3 s clip at 150 fps carries 450 frame timestamps — over 3 KB of int64 before anything else — and its `capture_announce` frame is under 800 bytes. `payload_begin` carries the series, through `ppcp_peer_payload_begin`'s `frames` parameter, which is the only entry point in the library that takes one.
- *Locked series are scalars, including `intrinsics`*: the encoded `AchievedFrames` with `.constant` exposure and `.constant` intrinsics is smaller than the equivalent constant arrays, and `ENC` 4.1d's first-element rule for `intrinsics` is the library's.

⚠ The cell is not a whole `pass`: `CONF` gives the method as *paired*, and the third assertion — `capture_update` carries `achieved_frames` **only** for a Capture whose `transfer` is `failed` — needs a peer on the other end. It arrives with D6.

**CT-I36 — `pass — make test-core`.** All four cases.

- **(a) a removed middle segment is a defect** — ⛔ *not producible*. `StreamCoverage` never takes a segment's start; it is where the last one ended. So the hole the test creates by hand cannot be created by this implementation, and 5.14e's no-overlap rule comes free from the same fact. A segment ending before the last one is refused rather than silently overlapping.
- **(b) an `absent` segment satisfies coverage** — a segment with an `interval` and `absent_reason: storage_full` between two present ones leaves nothing unaccounted. The interval is mandatory there (5.14d) and the library refuses a segment without one.
- **(c) truncation in a `partial` Session is not a defect** and **(d) the same truncation in a `complete` one is** — the same recorder, the same unaccounted three seconds, and `close(completeness:)` writes the first and refuses the second. ⚠ This is the only place the two cases differ, which is why they are one test.

**CT-I36a — `pass` for this peer's own half — `make test-core`.**
5.11j's three assertions. Shed preview intervals are `absent` with `not_retained` and carry **no gaps** (5.11c3: "deliberate non-retention is never a gap"); a present preview segment with `transfer: pending` is refused by `StreamCoverage` *and* by `ppcp_capture_validate_in_stream` *and* by `ppcp_peer_capture_announce`, which takes an `is_preview` flag for that purpose; and `SessionBundleWriter.announce(_:isPreview:)` refuses one outright, so none can reach a bundle. ⚠ The cell is not a whole `pass`: `CONF` gives the method as *paired under induced contention*, and there is no counterpart yet.

**CT-S7 (3) — `pass — make test-core` and `make test-app`.**
"`per_frame` only where the platform attaches it" (5.8h). ⛔ Made unconstructible rather than checked: `ExposureObservation` has one case per honest provenance and **each case carries the wire form that goes with it**, so `per_frame` with a scalar — the way a peer over-claims — cannot be typed at all.

⚠ **What was actually checked on the platform, and it is written down in `Sources/Platform/Capture/FrameTimeline.swift` so it is not re-decided optimistically.** The documented `kCMSampleBufferAttachmentKey_*` set carries no exposure duration and no ISO. `AVCaptureDevice.exposureDuration` and `.iso` are *device* properties read at the moment the frame arrives, which is `sampled` by 5.8's own definition. `AVCapturePhotoOutput` attaching exposure to photo metadata is not evidence about the video path. So this application emits `locked_constant` with the scalar form under the REQ-OPT-3 lock, `sampled` with an array without it, and **never** `per_frame`. Intrinsics get the opposite treatment because `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` really is a per-frame attachment — the difference is what the platform does, not a policy.

**§5.15a — `pass — make test-core`.** Not a `CT-*` row, and asserted anyway because it is the clause easiest to breach by accident.

> **(5.15a) MUST NOT** A device state-machine name (`cold`, `warm`, `armed` or any equivalent) cross the wire.

A session is recorded with a `readiness` for every one of `CaptureState`'s three cases, and the **encoded bytes** are searched for each name. Asserting on the API would only say this application did not choose to send one today; searching the bundle says none is there. `ReadinessMeasurement.measuring(_:)` is one-way by design — a receiver that could recover `armed` from a `Readiness` would have the state name back — and `warm` and `armed` produce the *same* measurement, because the question 5.15 asks is about the next shot and not about this peer's bookkeeping.

**§7.3d — `pass — make test-core` and `make test-app`.**
The interruption reaches the bundle as a frame, with its gap as a half-open interval in the Stream's timebase. ⛔ Recording the gap is the half of 7.3d that gets dropped — recovering is visible in the UI and everybody implements it, while an interruption that re-armed cleanly and said nothing leaves a hole a consumer reads as a dropout (5.14b). The platform mapping from `AVCaptureSessionInterruptionReasonKey` onto §7.3d's three names is asserted under `make test-app`; ⛔ the platform's own reason code does not cross the wire, for the same reason 5.15a keeps a state name off it.

**CT-S7 (1) and (2) — `pass — make test-core`.**
Assertion 2 is tested the way `CONF` asks — "by supplying a device-profile entry with no rig measurement and asserting the emitted provenance is not `measured`" — and is **structural rather than promised**. `DeviceProfiles.json` expresses an unmeasured readout as a *rule* (a fraction of the profile's nominal frame interval), not as a number, and a rule can only produce `assumed`. A placeholder written as a number is indistinguishable from a rig number once it is in the file, and the next person to edit it cannot tell which they are looking at.

⛔ **What these two cannot catch, and `CONF` §2c says so plainly**: "an unmeasured offset declared as `0` is correct relative to any other implementation that also declared `0`." That is **CT-S7 assertion 4**, which needs the synthetic peer of L13 and is marked `blocked` above rather than quietly folded into the rows that do pass.

**CT-I12 — `pass` for this peer's own half — `make test-core`.**
`Packages/Core/Tests/CaptureCoreTests/SessionBundleTests.swift`. Both ends of the subset are written and read back: a **video-only** Session and a Session with **no Streams at all**. `CORE` I12 says "any subset of Streams is valid, including none", and `ppcp_session_validate` has no minimum — the failure this guards against is a writer that quietly requires audio. ⚠ The cell is not a whole `pass`: `CONF` gives the method as *fixture*, and the fixture a third party would load is the interop row below.

**CT-I34 — `pass — make test-core`.**
The same bundle's frames are fed to one reader twice, which is what a user AirDropping the same session twice looks like from the index's point of view. The second import is a no-op and the capture count stays at one. ⛔ The index is `libppcp`'s `ppcp_capture_index` and not this application's: identity is `Capture.id` scoped by `Session.id` and the minting `Peer.id` (8.5c), and **`digest` is not in the key** — a `complete` + `pending` Capture has no digest yet and an `absent` one never will, so keying on it would import both of those twice.

**CT-S4 (1) — `impl`, with the bundle half passing — `make test-core`.**
The zero-host path's *recording* is done and asserted: a hostless `session_open` with **no arbitration parameters** (`CORE` 4.1d, 5.10e — `ppcp_session_make_hostless` cannot be given them and there is no setter), Streams, `readiness`, `capture_announce`, `session_manifest`, then payload frames, read back through `ppcp_bundle_reader`.

`CORE` 7.3b is asserted **twice over, and the first is the stronger**: `ppcp_peer_arm` refuses this peer outright, because 7.3a makes arming host-controlled and this peer is `role: capture` — so the frame does not exist to be recorded. The writer's own refusal of `arm` after a hostless `session_open` is the backstop for a *host* writing a bundle. `readiness` still appears, because 7.3c confers it through **Capture** rather than Live.

Also asserted, each a writer refusal rather than a check of ours: `ENC` 7c (a `payload_*` frame before `session_manifest`), 7g (a `link_bind` frame in a bundle — exercised by making the peer really queue one), 7e (`finish` emits no bytes and refuses a further append), and 7d's three-way completeness answer, including the middle row — an unasserted, truncated bundle reads as `partial` and is never upgraded (I10).

**Since D4 the bundle carries a real Capture.** The clip comes out of the REQ-BUF-1 ring rather than out of a fixture: a shot-anchored Capture with its realised `interval`, `completeness`, and an `achieved_summary` carrying frame count, drops, realised rate in millihertz, the exposure and ISO `{min,max,median}` and a thermal timeline — and a `payload_begin` carrying the `AchievedFrames` behind it. A `continuous` `metadata` Stream is open alongside it and accounts for its whole interval (I36), so the Session can honestly assert `complete`.

What is left for the row is minting a Shot (`authority: device`) — `libppcp` L10 and this repository's **D5**. Not a block.

⚠ **A bug this round trip caught.** `SessionStore.readHeader` handed `ppcp_bundle_header_parse` the bytes *after* the eight magic bytes and demanded 24 in total. `PPCP_BUNDLE_HEADER_BYTES` is 16 and **includes** the magic, which the library's own parser starts by comparing — so the check refused every conformant bundle. It had passed review twice. Only writing one and reading it back found it, which is the argument for the round trip over a golden byte string.

**RT-17 — `review`.** The code to read is the block at the top of `PpcpTlsProfile` in
`Sources/Platform/Network/PpcpTransport.swift`, commit `bb85a06`. ⚠ **A named reviewer is still to be assigned** — a `review` row is not discharged by its author.

What the reviewer is being asked to confirm:

- The version ceiling is `.TLSv13` set as a *maximum*, not a constant "use 1.2", so a platform that gains TLS 1.3 external PSK negotiates it with no edit.
- The offered ciphersuite set is walked from `tls_ciphersuite_group_t.init(rawValue:)` at run time, so it is derived from the platform's own enumeration rather than from a list in this repository, and an SDK that adds a group offers that group with no edit.
- Nothing is withheld: no group is skipped, and no suite is named as a constant anywhere in the offer path.
- ⚠ And that this changes nothing on iOS, which is the point. The platform's enumeration names no PSK suite at all, so the suite that negotiates cannot be requested or excluded — compliance with 5.2b1 **by construction** (`RV` 5.2i), which is why the row is `review` and not a test.

**Re-read this row whenever the TLS setup path is touched and whenever a platform SDK is updated.** RT-17 says so, and it is the requirement now carrying property 2 of 5.2h.

---

## 4. Findings against the specification

Raised from D1, reported rather than worked around (`libppcp` implementation plan ground rule 3).

**F-D1-1 — `RV` 5.3a/5.3b are not implementable in a Network.framework listener.**
Measured on iOS 27 (`Tests/TransportLoopbackTests.swift`): a listener refuses a PSK identity it did not register in advance, with `PSK_IDENTITY_NOT_FOUND` → alert 115 `unknown_psk_identity`. The only server-side entry point is `sec_protocol_options_add_pre_shared_key`, which registers a (key, identity) pair up front; `sec_protocol_options_set_pre_shared_key_selection_block` is documented as "invoked when **the client** must choose a PSK identity given a hint from its peer" and has no server-side counterpart. Since 5.3a makes the identity fresh per connection, a conformant client cannot reach a device listener, and 5.3b's resolver has nowhere to live. This bears on `RV` §3.5b, which recommends the **capture peer advertise** — making this device the listener on the discovery path it is least able to serve. The pairing-code path, which `RV` 2a makes the required one, is unaffected: there the device dials.

**F-D1-2 — `RV` 5.3c is unachievable on this platform, but the gap is not reachable through RV's own key schedule.**
Measured: an unresolvable identity fails early with alert 115; a resolved identity over a wrong key fails at Finished with `bad_record_mac`, alert 20. Different content, different timing, no interface to make them uniform, and 5.3c is a MUST.

⚠ The mitigation is in the specification already, and it is worth recording so the finding is not over-read. `K_tls` and `K_id` both expand from the same `PRK` (`RV` §5.1), so a peer holding the wrong secret computes the wrong identity tag *as well* — every real mismatch, whether a photographed code from another session or a revoked pairing, lands in the unresolvable case. The second case has to be constructed by hand (a registered identity paired with a key it was never derived from) and cannot be produced by a scanned code, a persisted pairing, or an attacker without `PRK`. Both cases are asserted in `Tests/TransportLoopbackTests.swift`.

The API gap remains real for any future derivation that separated the two keys. The matrix marks RT-11 `n/a` for this column, which is right for the pairing-code path where the device dials — and would not be for the discovery path, where it listens.

Neither finding is worked around in code. Both are recorded in the source at the point an implementer meets them.

### Raised from D2

**F-D2-1 — `tb:hosttime` is `mach_absolute_time`, and it is `monotonic`, not `continuous`.**
The D2 brief specified `tb:hosttime` as `mach_continuous_time` with `kind: continuous`. This implementation declares it as `mach_absolute_time` / `CMClockGetHostTimeClock` with `kind: monotonic`, and declares `mach_continuous_time` **separately** as `tb:continuous`.

The reason is a platform fact. **AVFoundation stamps `CMSampleBuffer` presentation timestamps with the host time clock, which is `mach_absolute_time`** — and on iOS that clock halts across device sleep, which is what `mach_continuous_time` was added to avoid. `CORE` 5.6a makes every Source declare "which clock its samples are in"; declaring the continuous clock for samples stamped by the halting one is wrong by exactly the accumulated sleep time, silently, and only after the first backgrounded session. That is I31's failure mode wearing I1's clothes: everything agrees until it meets a peer that measured.

`tb:continuous` is declared alongside because `CORE` 5.5b requires a `ClockDiscontinuity`'s `observed_at` to be "in a reference timebase that did **not** step", and the sleep gap in `tb:hosttime` is only observable at all by differencing the two clocks. No Source references it. The observer is `Sources/Platform/PpcpTimebases.swift`.

**⚠ This is a plan question, not a specification defect, and it is for the orchestrator.** If the programme wants every peer on a continuous clock, the change is a conversion in the capture path — not a relabelling of this declaration.

**F-D2-2 — `rolling_shutter.direction` carries no provenance while `readout_ns` does.**
`CORE` 5.7e makes `readout_provenance` mandatory beside `readout_ns` "because no public platform API exposes it, so an implementation that has not been through a timecode rig is guessing (I31)". Every word of that applies to `direction`, which sits in the same structure and carries nothing. This implementation declares `top_to_bottom` from the physical orientation of every rear iPhone sensor — a guess — and is indistinguishable on the wire from one that measured it. There is no field to be honest in. Recorded in `DeviceTimingProfile.swift` and in `DeviceProfiles.md`.

**F-D2-3 — `CaptureProfile.format.codec` is ambiguous where delivery and payload differ.**
`CORE` 5.7 gives `format` as `{ codec, width, height, pixel_format }` without saying whether `codec` describes what the Source *delivers* or what the Capture payload is *encoded as*. On this platform they differ: the video data output hands over uncompressed buffers in `pixel_format` and the clip is written as HEVC. The receiving end cares about the second, so that is what is declared, with the first carried beside it — but a third-party host has no way to know which convention a peer chose.

**F-D2-4 — erratum E1 added a MUST with no conformance row.**
`ENC` §2.1 and `MSG` §3.0 are four new MUSTs (2.1a–2.1c) governing how every direct-transport link is assembled, and `CONF` has no `CT-*` row for any of them. Interoperability at the bind is exactly what E1 exists to secure — two implementations built two implicit rules and neither would have met the other — and it is currently untested by the suite. This application tests it against itself in `Tests/TransportLoopbackTests.swift` (`LinkBindLoopbackTests`), which is the shape of test `CONF` §2c warns is not sufficient.

**F-D2-5 — `libppcp`'s SwiftPM umbrella exposes every header, so `planned.h` collides with real ones.**
A SwiftPM C target with `publicHeadersPath: "include"` generates an umbrella module map over **all** headers, not just `ppcp/ppcp.h`. When L4's `model.h` and L5's `message.h` landed, `planned.h` still declared `ppcp_role`, `ppcp_peer_desc` and `ppcp_msg_class`, and the module failed to build with `redefinition of …` — blocking this repository's build entirely for part of the session. PinPointStudio does not meet this: it consumes the library through CMake and includes `ppcp/ppcp.h`, which does not include `model.h`.

⚠ Not a specification defect and not worked around — `libppcp` is not this team's to edit. It is a **consumption hazard worth a rule**: a symbol promoted out of `planned.h` must leave it in the same commit, or the Swift consumer breaks. Reported for the orchestrator.

✅ **Closed, 22 August 2026.** `planned.h` now declares only L9–L11 and the collision is gone; this repository builds against the umbrella again. The rule stands, because the next promotion will meet the same edge.

### Raised from D2 part two and D3

**F-D3-1 — `ppcp_msg` is 48 KB and a C union imports into Swift with *computed* members, so the obvious binding overflows the stack.**
Plan A5 makes these headers a Swift-facing artefact, and `message.h` already pays one word for a tagged union so Swift names it `ppcp_msg_body`. That is not enough. Swift imports a C union as a struct whose members are **computed properties**, so `msg.body.session_manifest.captures = …` is a get-modify-set of the *whole* union — a 48 KB stack temporary per field touched. Writing a `session_manifest` the obvious way killed this test suite with `SIGBUS`, which is what a stack overflow looks like on arm64, and it did so from a synchronous test function doing nothing else unusual.

The working pattern is: allocate the `ppcp_msg` on the heap; take **one** pointer to `body`, which *is* a stored property and therefore directly addressable; `withMemoryRebound` it to the arm you want; and write through that pointer. It is in `SessionStore.swift` and `LinkBind.swift` with the reason beside it.

⚠ **Reported, not worked around, because the workaround is not discoverable.** The natural Swift spelling compiles, passes a small test, and dies on the message that matters. Two things would fix it at the source: a short note in `message.h` beside the tagged-union comment, and — better — a `ppcp_msg_manifest_*` setter family, since `session_manifest` is the one message a bundle author must build by hand.

**F-D3-2 — `bundle.h` has no entry point for `session_manifest`, the one message `ENC` 7c makes mandatory in a bundle.**
Every other frame a hostless bundle needs has a `ppcp_peer_*` originator: `declare`, `session_open`, `stream_open`, `readiness`, `capture_announce`, `payload_*`. `session_manifest` has none, so an embedding must build a 48 KB `ppcp_msg` itself and pass it to `ppcp_peer_send` — which is exactly the union access F-D3-1 is about, and it is required of every peer that writes a bundle. `ppcp_peer_session_manifest(p, session_id, streams, n, entries, m, completeness, counts)` would remove the only place a bundle author touches the union.

**F-D3-3 — `ppcp_link_binder_offer` takes a `stream_channel` a stream-per-connection transport cannot supply.**
The parameter is documented as the channel the stream arrived on "as far as the transport is concerned", and 2.1c has the binder refuse a `link_bind` whose `channel` disagrees with it. On a multiplexed transport (QUIC stream types, say) the transport really does know. On **TCP with one connection per channel** — which is what `ENC` §2.1 was written for, and what this application uses — a freshly accepted connection carries no channel number anywhere except the frame header of the `link_bind` itself. An embedding can only fill the parameter by parsing that header first, at which point the library is checking the body against a value the embedding read out of the header two lines earlier. The check is still worth having; the *parameter* is not the transport's fact that the header says it is. Reading the channel from the frame header inside `offer` would make the API honest and lose nothing.

⚠ This application's listener therefore still assembles links in its own actor (`Sources/Platform/Network/PpcpTransport.swift`) rather than through `ppcp_link_binder`. The decode is now the library's — `ppcp_msg_decode` rather than a hand-written CBOR walk — but the link table is not. **Unfinished, and named as such**, not claimed.

### Raised from D4

**F-D4-1 — `ppcp_peer_capture_announce` does not apply `ppcp_capture_validate_in_stream`, although the engine holds the stream table.**
`libppcp` has the rule and has the data, and does not join them. `ppcp_peer` keeps `p->streams` — it has to, because it originated every `stream_open` — and `ppcp_capture_validate_in_stream` is the function that enforces CT-I27's second assertion (`{stream: true}` refused on a `shot_windowed` Stream) and CT-I11's negative half (gaps only on `continuous`). `ppcp_peer_capture_announce` calls neither: it validates the Capture in isolation and queues the frame. So a conformant-looking peer can originate a stream-anchored Capture on a `shot_windowed` Stream it opened itself, or a Capture carrying gaps on one, and nothing stops it until a receiver checks.

⚠ This matters more than a missing assertion, because the two rules are *stream-relative* and a producer is the only party that can be sure which Stream it meant. The library already refuses the analogous preview violation here (8.1i, through `ppcp_transfer_observe_announce`), which is the shape the fix should take. This repository's own suite asserts both rules by calling the validator directly — but calling it is a thing an implementer must remember, which is what CT-I27 and CT-I11 exist to remove. Reported for the orchestrator.

**F-D4-2 — an `absent` shot-anchored Capture cannot say which interval it failed to cover.**
`CORE` §5.14 makes `interval` "absent when `completeness: absent` — **except** on a stream-anchored Capture, where it is always mandatory", and 5.14d gives the reason for the exception in words that apply equally to the case it excludes: "an `absent` segment *with* an interval is how a peer states that a named span was not recorded".

A device answering a `capture_request` with `outside_buffer` (8.4b) is in exactly that position and may not say it. Where the announce answers a request the host can recover the span from its own `pre_ns`/`post_ns`, so the loss is small. Where the announce is **unsolicited** — a hostless peer minting its own Shot and finding the clip already evicted, which is precisely v1's path — there is no request to recover it from, and the Capture states that *something* around a `t0` was not retained without saying what. The asymmetry looks like an oversight rather than a decision: the reasoning §5.14d gives for segments is the reasoning against the restriction everywhere.

**F-D4-3 — `AchievedSummary` is defined in camera words but §5.11b requires it on every `continuous` Stream.**
`frame_count`, `realised_rate_mhz`, `exposure_ns` and `iso` are the vocabulary of a camera Capture. §5.11b makes every `continuous` Stream — including `metadata`, `imu`, `event` and `wrist` — realise itself as stream-anchored Captures, and 5.11k assumes an `AchievedSummary` on each segment. For an attitude-and-gravity `metadata` Stream at 100 Hz there is no frame, and this implementation reports the **sample** count in `frame_count` and the realised sample rate in `realised_rate_mhz` because those are the only fields there are. That is a reasonable reading and it is a *reading*: two implementations could differ on whether a non-camera segment carries a summary at all. One sentence in §5.8 saying `frame_count` means "samples in the Capture, whatever a sample is for this Stream kind" would settle it.

**F-D4-4 — two editorial inconsistencies in `CONF`, both harmless and both worth a line.**
CT-S1 closes with "Assertion 2 is the whole test. The other four are why it is worth writing carefully" over **six** assertions — 5 and 6 were added without updating the sentence. And CT-S4 assertion 1 lists `arm` among the steps of the zero-host path end to end, which sits against `CORE` 7.3b's "records no `arm` or `disarm`"; the two are reconcilable (7.3b forbids recording the *message*, assertion 1 lists lifecycle steps) but a reader meeting them cold has to do that work. `CONF` §5b2's adjacent-MUST sweep is the right home for the second.

⚠ **Not a finding, a naming note.** `I36a` is not an invariant. `CONF` §3 says so — "thirty-eight invariants, thirty-nine tests — I36 carries two, because the coverage rule and the preview-shedding rule fail in different ways" — so CT-I36 and CT-I36a both test **I36**. The D4 brief and this file's earlier drafts both wrote "I36a" as though it were one.

---

## 5. What is deferred, and on what

**Nothing is deferred on `libppcp` any more.** L6 (the peer engine) and L8 (the bundle writer and reader) landed on 22 August 2026, and both fences this file described in the previous revision — `PPCP_L6_PEER_ENGINE` and `PPCP_L8_BUNDLE_WRITER` — are gone rather than merely defined. The code behind them was rewritten against the real API, not switched on: the planned signatures had changed in three places (`ppcp_peer_feed` gained `out_consumed`, `ppcp_peer_config` gained `versions`/`min_version`/`listener`, and `ingest_policy` gained `out_reason`), and a fence turned on unread would have compiled against none of them.

| Work | Waiting on | Where it sits |
|---|---|---|
| CT-S7 (4) — a converted instant against a peer that declares a **non-zero** measured offset | `ppcp-sim` (**L13**) | Nothing to write yet. `CONF` §2c: an unmeasured zero is correct relative to any other implementation that also declared zero. |
| CT-I19's consumer half (CT-S3) | this repository's **D6** | The engine exists; meeting a *different* peer's declaration does not. |
| CT-S1 assertions 1–5 — the conversion against a peer declaring a different convention | `ppcp-sim` (**L13**) | Assertion 6 (scalar and constant array agree) passes today; the rest need a counterpart. |
| CT-I30's third assertion — `capture_update` carries `achieved_frames` only for `transfer: failed` | this repository's **D6** | Needs a peer on the other end. |
| CT-I36a under **induced contention** | this repository's **D6** | The refusals are asserted; a live preview Stream degrading under load is not. |
| `RingBufferRecorder`'s segment delivery | **a phone** | The simulator has no 150 fps camera. The ring's index and every protocol-constrained decision around it are covered; the `AVAssetWriter` segment path is wiring that has not run. |
| Interop "device, no host → bundle" | **PinPointStudio** | This side writes and re-reads its own bundle; only the other application reading it closes the row. |

## 6. Reproducing

```
make test-core      # the neutral layer, the RV §10 vectors and the bundle round trip, on the host
make test-app       # the TLS-PSK handshake and the ENC §2.1 bind, on a simulator
make gen && make build
```

⚠ **`make test-core` is green: 107 tests, 13 suites.** Every `pass` in §3 is one of
them and none needs a simulator.

⚠ **`make test-app` is green: 21 tests, 4 suites.** It hung for one session; see the
finding below.

⚠ `-jobs 3` on every `xcodebuild`, and `-j 3` on every `swift build`/`swift test`.
This is a 16 GB machine and an unbounded build has already taken it down once.

---

## 7. A defect found by the suite hanging, and what it was

**`make test-app` hung indefinitely in `LinkBindLoopbackTests`, and the cause was
a transport defect rather than a test one.**

`PpcpListener.accept()` parked on a `CheckedContinuation` that was resumed only
when a link assembled or when `stop()` was called. `ENC` 2.1c gives a listener one
action for a stream it refuses — close it — and closing a stream resumes nobody,
which is correct. What was not correct is that the waiter then had **no way out**:
`Task.cancel()` reached a continuation with no cancellation handler, so a caller
that gave up could not leave. `PpcpPeerLink.channelBound()` had the same shape,
and it is the more ordinary case — 2.1d makes a `preview` channel one the
counterpart *may* open, so waiting for one that never comes is normal.

Underneath both, every `NWConnection` await in `PpcpByteChannel` — `open`, `send`,
`receive` — ignored cancellation too. Network.framework has no per-call cancel, so
the only way to end one is to cancel the connection, and nothing did.

⛔ **Why that became a hang rather than a slow test.** A `withThrowingTaskGroup`
does not return until every child has finished, so `group.cancelAll()` is a
request. A child parked on a continuation that ignores cancellation keeps the
group suspended for ever — which means a structured timeout around uncancellable
work is not a slow timeout, it is **no timeout at all**. Both the suite's
`withTimeout` and the listener's own `withDeadline` are built that way, so the
"20-second guard" in the test could never fire, and the test never returned, so
its `defer { await listener.stop() }` — the one thing that would have freed the
waiter — never ran. The listener's `withDeadline` had the same hole in production:
a peer that completed TLS and then said nothing would have parked an intake task
for ever, which is the exact case its comment claimed to bound.

**Fixed at the cause**, in `Sources/Platform/Network/PpcpTransport.swift`:
`PpcpByteChannel.open`/`send`/`receive` cancel the `NWConnection` on cancellation;
`accept()` and `channelBound()` hold withdrawable waiters and resume them with
`CancellationError`, with a flag closing the race where cancellation arrives
before the continuation is installed. `withDeadline` now bounds what it says it
bounds. No test is skipped and no timeout was lengthened to paper over it.

⚠ A test-side bridge was needed as well: `try await task.value` is **not**
cancellable, so a timeout wrapped around an unstructured `Task` cannot end it
however cancellable the work inside is. `Task.value(within:)` in the suite cancels
the task when the deadline fires.

⚠ **No `RT-*` row moves on this.** The fix restores the suite to running; it does
not add an assertion. `RT-4`, `RT-10` and `RT-14` keep the `impl` states they had,
which rested on the transport tests that were already passing.

`make test-core` needs a sibling `../libppcp` checkout until the package is tagged.
