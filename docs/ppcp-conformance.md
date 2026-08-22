# PinPointCapture — PPCP conformance claim

**What this application claims of `ppcp/1.0`, and the command that reproduces each claim.**

| | |
|---|---|
| Implementation | PinPointCapture (iOS) |
| Role | `capture` |
| Against | `PPCP-CORE` revision 9, `PPCP-MSG`, `PPCP-ENC`, `PPCP-CONF` 1.0; `PPCP-RV` revision 8 |
| Companion | [`libppcp/docs/conformance/matrix.md`](https://github.com/PinPoint-Golf/libppcp) — the compliance record this file feeds |
| Status | **In progress.** Session S2: **D1 reworked for erratum E1**, **D2 landed** (declaration from the real capture stack, and the peer engine over `ppcp_peer`), **D3 landed** (the session store writes a `PPCPBNDL` through `ppcp_bundle_writer`). Nothing is deferred on `libppcp` any longer — see §5. |
| Depends on | `libppcp` — MIT, consumed as a SwiftPM package (plan A5), product `CPPCP`. Path `../../../libppcp` during co-development; `https://github.com/PinPoint-Golf/libppcp.git` once tagged. |
| Date | 22 August 2026 (S2) |

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
| CT-I31 | static | provenance on offset, readout **and `AchievedFrames.exposure_ns`** | D2, D4 | — | — | impl |
| CT-I34 | fixture | idempotent re-import; identity is `Capture.id` by session and peer | D3 | — | — | pass |
| CT-S4 (1) | injected | the zero-host path end to end, including bundle write and read | D3, D4, D5 | — | — | impl (bundle half passes) |
| CT-S7 (1) | injected | every emitted timing constant carries a provenance; unmeasured is `assumed` | D2 | — | — | pass |
| CT-S7 (2) | injected | a device-profile entry with no rig measurement cannot emit `measured` | D2 | — | — | pass |
| CT-S7 (3) | injected | `exposure_provenance` honest: `per_frame` only where the platform attaches it | D4 | — | — | — |
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

**CT-I31 — `impl`.** Reproduce with `make test-core`.

- *Passing*: every `frame_start_to_exposure_offset_ns` and every `rolling_shutter.readout_ns` this implementation emits carries a provenance, and every one is `assumed` (plan A12 — no model has been through an LED timecode rig, REQ-TEST-1/2).
- *Not yet*: CT-I31's third clause is `AchievedFrames.exposure_ns`, which does not exist until D4 puts a clip on the wire. The cell stays `impl` until it does.

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

What is left for the row is the rest of the zero-host path: minting a Shot (`authority: device`, D5) and putting a real clip in a Capture (D4). Those are `libppcp` L10 and this repository's D4/D5, not a block.

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

---

## 5. What is deferred, and on what

**Nothing is deferred on `libppcp` any more.** L6 (the peer engine) and L8 (the bundle writer and reader) landed on 22 August 2026, and both fences this file described in the previous revision — `PPCP_L6_PEER_ENGINE` and `PPCP_L8_BUNDLE_WRITER` — are gone rather than merely defined. The code behind them was rewritten against the real API, not switched on: the planned signatures had changed in three places (`ppcp_peer_feed` gained `out_consumed`, `ppcp_peer_config` gained `versions`/`min_version`/`listener`, and `ingest_policy` gained `out_reason`), and a fence turned on unread would have compiled against none of them.

| Work | Waiting on | Where it sits |
|---|---|---|
| CT-S7 (4) — a converted instant against a peer that declares a **non-zero** measured offset | `ppcp-sim` (**L13**) | Nothing to write yet. `CONF` §2c: an unmeasured zero is correct relative to any other implementation that also declared zero. |
| CT-I31's third clause — provenance on `AchievedFrames.exposure_ns` | this repository's **D4** | There is no clip on the wire yet. |
| CT-I19's consumer half (CT-S3) | this repository's **D6** | The engine exists; meeting a *different* peer's declaration does not. |
| Interop "device, no host → bundle" | **PinPointStudio** | This side writes and re-reads its own bundle; only the other application reading it closes the row. |

## 6. Reproducing

```
make test-core      # the neutral layer, the RV §10 vectors and the bundle round trip, on the host
make test-app       # the TLS-PSK handshake and the ENC §2.1 bind, on a simulator
make gen && make build
```

⚠ **`make test-core` is green: 89 tests, 12 suites.** Every `pass` in §3 is one of
them and none needs a simulator.

⛔ **`make test-app` does not complete, and that is an open defect rather than a
result.** The app target builds and every non-loopback suite passes, as do the
first five transport tests. The run then goes silent in or just before
`LinkBindLoopbackTests` — the `.serialized` suite added for erratum E1 — and
neither the suite's own `withTimeout` guards nor `xcodebuild`'s
`-default-test-execution-time-allowance` recovers it; the test host exits and
`xcodebuild` waits forever. **Which test hangs is not yet known**, and no `RT-*`
row in §3 may be advanced on the strength of this suite until it is.

⚠ The `impl` states on RT-4, RT-10 and RT-14 above rest on the transport tests
that *did* pass in this run and in D1's, not on the E1 suite. Nothing in §3 was
promoted from it.

⚠ `-jobs 3` on every `xcodebuild`, and `-j 3` on every `swift build`/`swift test`.
This is a 16 GB machine and an unbounded build has already taken it down once.

`make test-core` needs a sibling `../libppcp` checkout until the package is tagged.
