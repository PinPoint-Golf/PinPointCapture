# PinPointCapture — the online MVP

**A capture device that PinPointStudio finds, connects to, and receives every shot from — and the RV-6 work that has to land first.**

| | |
|---|---|
| Status | Scope and plan. ⛔ **Not started** — Phase 0 gates everything below it |
| Date | 24 August 2026 |
| Scope of this document | Delivery order for one demonstrable outcome. [`delivery-scope.md`](delivery-scope.md) remains the authority on *what the product is*; this says what is built next, in what order, and what is deliberately left out |
| Source of truth | [`capture-companion-requirements.md`](../design/capture-companion-requirements.md) · [`ppcp-conformance.md`](../conformance/ppcp-conformance.md) · `PPCP-RV` revision 9 |
| Cross-repository | ⚠ Phase 0 spans **three** repositories. Work owned by `libppcp` or `PinPointStudio` is named here as a dependency, never as this repository's task |

**Why this document exists.** The delivery scope is organised by capability level, which is right for deciding what a level means and wrong for deciding what to do on Monday. Everything through 24 August built foundations — the ring, clip extraction, the sidecar, one multi-source timeline — and none of it is demonstrable, because nothing crosses to Studio. This is the shortest honest path to something a person can watch work.

---

## 1. The MVP, as agreed

| | Requirement |
|---|---|
| **(a)** | PinPointStudio **discovers** the capture device and connects to it |
| **(b)** | The device captures video, and supports **preview** and **hi-res capture** |
| **(c)** | After every shot and every candidate, the data reaches Studio |
| **(d)** | **Online only** — no offline catch-up, no store-and-forward |

⚠ **(d) is a scope reduction, not a product decision.** It removes E9 entirely, most of E4, `SessionOfferService` and the offline half of E21. ⛔ It does **not** remove the bundle: `CORE`'s *live bytes are bundle bytes* means the same records go to the wire and to disk, so the writer stays and the device keeps its own session library. §4.2 makes that a demo step precisely so "online only" cannot quietly become "online or nothing".

### Where each requirement stands

| | Built | Missing |
|---|---|---|
| **(a)** | Pairing code path, proved 30/30 two-sided against real Studio. `browse(against identityKeys:)`, resolving per 3.4b and refusing per 3.4c. B1's discovered-host screen | **RV-6 guided pairing** — the whole of Phase 0. And Studio advertising for reconnection |
| **(b)** | Hi-res: the ring, clip extraction, the sidecar, thumbnails — `8a371c3`. Unverified on a camera | **Preview**: no `preview` Stream is opened and nothing produces frames for one |
| **(c)** | `LiveDetectionSink`, `HostLinkDriver`, `TransferQueue`, `PayloadTransferQueue`, `SessionResume` — all tested | **Every one of them has no caller.** Composition only, which is the shape E1.1 was |
| **(d)** | — | Nothing. It is a subtraction |

---

## 2. Phase 0 — RV-6, and it spans three repositories

⛔ **Nothing in §3 starts until this lands.** (a) is the reason the MVP exists, and RV-6 is the only conformant way to reach it.

### 2.1 Where RV-6 came from, and where it now stands

[CR-01](https://github.com/PinPoint-Golf/PinPointCapture/issues/94) was raised from this repository on 24 August and **granted in part**: the code transfer goes, the operator stays. `PPCP-RV` revision 9 gains **§11 (RV-6 — guided pairing)**, §3.5e, §3.7 and §10.4. The finding behind it is `F-MVP-1` in [`ppcp-conformance.md`](../conformance/ppcp-conformance.md) §4.

**Both teams then reviewed the disposition and accepted it. Six findings were raised and all six applied — errata E34–E39.** Two were blocking, both from PinPointStudio, and neither was visible in the worked vectors:

| | Finding | Effect here |
|---|---|---|
| **R-01** | the bootstrap version `v` was carried on the wire and bound into nothing | ⛔ **§10.4's vectors changed.** `sas_raw`, the SAS, `K_c` and both MACs now bind `transcript = v ‖ pk_i ‖ pk_a`. **The SAS is `435948`, not `313164`** |
| **R-02** | only the *acceptor* was serialised to one attempt | 11.3d1 added. ⚠ The natural host implementation — dial every discovered window, show the operator a list — was permitted and hands an attacker N blind draws |
| **R-03** | = our `F-R9-1`. `invalid_key` named an observable no library produces | Accepted with our addition: a rejected key MUST NOT be retried or treated as a transport error |
| **R-04** | 11.4f's rationale was inverted | ⚠ **The MAC is not an authentication check.** An interposed attacker holds `Z` on both legs and forges both MACs correctly; the *comparison* is the authentication. Read this before implementing 11.9c |
| **F-R9-2** | ours — the transcript is an offline verifier for `Z` | Added to §11.8. The real force of 11.5a's CSPRNG MUST |
| **R-05** | *"implements §11"* described a narrower capability than a reader would take it for | 9e1 added. ⛔ See §2.3 — it decides which role this repository must build |

**This repository re-verified §10.4 after E34**, with the same independent implementation, and all eight rows reproduce — the four that changed and the four that did not, `PRK` included.

⚠ **A16 was corrected, and it changes who supplies the curve.** It assumed *"the host's crypto library"*; `libppcp` has none by construction and says so in `include/ppcp/hash.h`. X25519 will come from the embedding through a seam, as `ppcp_rv_random_fn` already does for entropy — recorded as `B17`. **On this platform that seam is `CryptoKit.Curve25519.KeyAgreement`, which is measured and works.**

⛔ **B14 is discharged bar one run.** The measurement was on the iOS *simulator* SDK. `RV` 5.4b exists because this document once accepted a desktop proxy for a device measurement on reasoning of exactly this quality. **The device run is required before shipping a guided pairing.** It does not gate writing the code — a negative result reopens A16 only.

### 2.2 The two directions, and why both are right

This is the part most easily got wrong, so it is stated as a table rather than as prose.

| | Who advertises | Who dials | Governed by |
|---|---|---|---|
| **First contact** | the **capture device** opens a bootstrap window | **PinPointStudio** | `RV` 11.2a — no PSK is involved, so 3.5d does not reach it |
| **Every session after** | **PinPointStudio** (`role: host`) | the **capture device** | `RV` 3.5d, 3.4d2, 3.5e — Apple's listener cannot resolve a rotating PSK identity |

⛔ **The peers swap roles between the two connections** (11.2b), and neither direction contradicts the other. "Studio finds the phone" is true at first contact, which is where the operator is standing and where the requirement came from. It is *not* true of reconnection, and `F-MVP-1` records why that is settled rather than open.

### 2.3 ⚠ The venue premise — corrected, and it was ours to get wrong

⛔ **An earlier revision of this section, committed as `f0d354b`, was wrong**, and the correction is `PPCP-RV` erratum **E53**:

> CR-01 was raised for *"a venue where a range operator sets up several bays"*, and that deployment **does not exist**: the host is never at the range. A capture device there works standalone and its session travels home as a bundle; the two peers meet on a **home or coaching-studio network**, which the user controls and where multicast behaves.

That section argued 3.6a's *"it will not work at a range"* made RV-6 *"a feature that works in an office and not at the venue it was requested for"*, and put 3.7h — an endpoint entered out of band — into MVP scope on that basis. **If the host is never at the range, none of it follows.** 3.6a never bounded this feature, 3.7h is an ordinary `MAY`, and the second demo step this document added is not the run that matters.

⚠ **Nobody checked the premise, including us.** E53 records that *"four review passes and twenty findings never asked whether the deployment existed"* — both implementation teams inherited it from the request and so did the protocol owner. This repository went further than inheriting it: it escalated a consequence of the premise into delivery scope and shipped a demo step for it. Recorded here rather than quietly reverted, because the failure is worth more than the correction.

### ✅ Confirmed by the product owner, 24 August 2026

**The host is never at the range. It is in the studio.** E53's premise is correct, and this document follows it: discovery over mDNS on a home or studio network, 3.7h not implemented, no discovery-disabled run in §4.1.

⚠ Recorded because E53's premise is now load-bearing in a specification — it narrowed RV-6's justification, resized B15's fleet case to a studio's two or three stereo devices, and resized 3.4d3's rotation to a handful of pairings. Those four clauses rest on this sentence, so the sentence is worth having written down on this side too.

⛔ **And the lesson, which is the useful part.** The deployment model was in the product's name the whole time — *PinPoint **Studio*** is the host, and a studio is not a range. Four review passes, twenty findings, two implementation teams and a protocol owner reasoned carefully about clauses, arithmetic and premises without anyone reading the name. It is the same failure as the three arithmetic ones this repository made today, in its most economical form: **everything stated as a number got checked, and nothing stated as a word did.**

### 2.4 What each repository owes

⚠ Named as dependencies. This document does not assign work outside this repository — except where the protocol owner has already assigned it to us, which §5 of the review response does once.

| Repository | Owes |
|---|---|
| **libppcp** | The five bootstrap frames on `PPCP-ENC` channel `255`; the derivation chain of §11.6 including E34's transcript binding; §10.4 as vectors; conformance rows RT-18, RT-20, RT-21, RT-24, RT-25, RT-26. ⛔ **Not X25519** — B17's seam takes it from the embedding |
| **PinPointCapture** | The **acceptor** role (see below); opening and advertising the window (§3.7); the plaintext bootstrap connection — ⛔ **not** TLS, 11.2c; `CryptoKit` X25519 behind B17's seam; the six-digit comparison UI (11.7d) and abort copy (11.9c), now assertable under RT-26; then the swap to §5. **Plus RT-20's relay** |
| **PinPointStudio** | The **initiator** role; the same comparison UI; and — separately, still unanswered — **advertising `_ppcp._tcp` with `role: host`** for reconnection (3.5e) |

⛔ **This repository must implement the acceptor, and it is not a preference.** R-05/9e1 records that **PinPointStudio will ship initiator-only**, and *two initiator-only peers cannot pair*. 11.2b already puts the capture device on the acceptor side of first contact, so the two agree — but it means an acceptor-only build here and an initiator-only build there is the whole of the interoperable set, with no slack if either is descoped.

⚠ **RT-20's relay is ours to build, in `libppcp/tools`.** We offered to host it; PinPointStudio argued it should live beside `ppcp-conform` so both teams run the same relay, and that reasoning won — two relays would be two harnesses each correct against its own author, which is the failure mode the test exists to catch. The build is still ours.

⛔ **Until RT-20 runs, RV-6 is a design with vectors and not a demonstrated one**, and no conformance claim here will say otherwise. It cannot run until PinPointStudio implements §11: a relay needs two real ends.

⚠ **A collaboration, not a handoff.** The three ends must agree byte for byte on a derivation whose failure mode is a successful-looking comparison followed by `PSK_IDENTITY_NOT_FOUND` — which looks exactly like the 3.5d platform limitation and will be misdiagnosed as one. §10.4 is the shared oracle, and E34 has already shown it can move: **check the erratum level of the vectors before trusting a reproduction.** A recomputation yielding `11e66a4c` is reading revision 9 as first published.

---

## 3. Phases

### 3.1 The device session — gates §3.2 onward

⚠ One session on the iPhone closes the camera halves of [#17](https://github.com/PinPoint-Golf/PinPointCapture/issues/17), [#18](https://github.com/PinPoint-Golf/PinPointCapture/issues/18) and [#19](https://github.com/PinPoint-Golf/PinPointCapture/issues/19). It goes early because a surprise there — sustained rate, thermal, whether VideoToolbox emits High tier at the provisional 50 Mbps — invalidates assumptions the rest of this plan rests on. `make deploy` targets the real device; `RingStatsOverlay` makes the run produce numbers rather than an impression.

### 3.2 (c) — shots and candidates crossing

**Sync first** ([#25](https://github.com/PinPoint-Golf/PinPointCapture/issues/25), E3.2). Compose `HostLinkDriver.pump(nowNs:throughputMbitPerSecond:)` into `HostLinkSession`'s tick — the burst, the filtering, the settle to heartbeat cadence are all written. ⛔ Required before anything else in (c): `.connected` is deliberately unreachable without a settled clock estimate.

**The fan-out sink.** A small `DetectionSink` wrapping `CaptureSessionRecorder` and `LiveDetectionSink`, so the same records reach the bundle and the wire. **Decided: both**, per §1's note on (d).

**Shots crossing** ([#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27), E3.4). Announce on control immediately; payload queued on bulk behind its own flow control — `CORE` 3.1/T2, so a 25 MB clip cannot head-of-line block the next shot's `candidate`. `HostLinkSession.handle` currently drops every event that is not `connected`/`declared`/`error`, deliberately and with a comment; that switch is where this lands.

⚠ **The hosted-session question, unresolved and flagged.** `AppModel.arm()` builds a `HostlessRecordingSession` unconditionally. Online mode wants a hosted Session carrying the host's arbitration parameters. The type may generalise or may need a sibling — resolve at implementation time. ⛔ 7.3b's *records no `arm`* is the **hostless** case's rule and must not leak into the hosted one.

### 3.3 (b) — preview

The only piece with nothing to compose. `PreviewProducer` exists and is uncalled; nothing produces frames and no `preview` Stream is opened — `HostlessRecordingSession.streams` builds video, audio and metadata only.

- Declare and open the `preview` Stream (§5.11's table fixes it `continuous`).
- Downscale and JPEG off the **existing** sample callback, ~10 fps. ⛔ Not on the 6.7 ms frame path — hop to its own queue and **drop** rather than queue, because 5.11j makes preview never-queued and §9.2 makes the capture path the one that must not lose a frame to it.
- `PreviewProducer.shed` expresses what was not delivered — 5.11c3 makes deliberate non-retention an `absent` segment, never a gap.

⚠ **Off the existing output deliberately.** A second `AVCaptureVideoDataOutput` is legal since iOS 16 but starts `AVCaptureSession.hardwareCost` metering, and `> 1.0` refuses to start — see [`capability-spike.md`](../design/capability-spike.md) §2a. E1.1 rejected a second output for that reason and preview should not quietly reintroduce it.

---

## 4. Done looks like

### 4.1 The demo

1. Studio browses, finds the device's open bootstrap window, and dials it. Six digits on both screens; the operator confirms at each end. **No code is carried between screens.**
   - ⚠ On a home or studio network, which is where E53 says the two peers actually meet. A discovery-disabled run is **not** required — see §2.3, and the premise question in it.
2. The pairing exists. The device dials Studio under §5. Link up, both ends reporting `TLS 1.2 / TLS_PSK_WITH_AES_128_GCM_SHA256 / no forward secrecy`.
3. Sync burst runs. The device reports `.connected` with a real offset and uncertainty on B3 — **not** the fixture it shows today.
4. Preview appears in Studio.
5. Hit a ball. Within a second: `candidate` on control, then `shot`, then `capture_announce`, then the clip on bulk — and the device's own row turning `In Studio` when the host confirms.
6. Five shots, no reconnect.
7. Close the app and reopen it. The device finds Studio by browsing and reconnects **with no pairing step** — this is 3.5e, and it fails if Studio does not advertise.

### 4.2 The check that (d) stayed honest

⚠ On the device afterwards: five clips in the session library with thumbnails, and a bundle carrying the same records that went over the wire. If this step fails, "online only" has become "online or nothing", which is a different product.

---

## 5. Explicitly out

| Out | Why |
|---|---|
| [#28](https://github.com/PinPoint-Golf/PinPointCapture/issues/28) E3.5 — network recovery | A dropped link ends the demo rather than surviving it |
| [#26](https://github.com/PinPoint-Golf/PinPointCapture/issues/26) E3.3 — arm from host | Nice to have. Arm on the device |
| [#20](https://github.com/PinPoint-Golf/PinPointCapture/issues/20) E1.4 — bitrate | The 50 Mbps placeholder holds. E-M2 owns it, and it is now load-bearing in shipped code |
| E9 export, E5 replay, E6 markup, `SessionOfferService` | Offline catch-up is what (d) removes |
| The fleet case — one confirmation per device per host | `RV` B15. Its prerequisite is B2's per-peer re-keying, not a fifth rendezvous path. ⚠ E22's multi-device stereo makes this bite sooner than CR-01's "several bays" suggested |
| ⛔ Any rendezvous mechanism not in `PPCP-RV` | Standing |

---

## 6. Order

```
Phase 0   RV-6 across three repositories        ⛔ gates everything
   │      └─ RT-20 before any conformance claim
   ▼
   1      device session                        closes #17 #18 #19's camera halves
   ▼
   2      sync (#25) → fan-out sink → shots crossing (#27)      = (c)
   ▼
   3      preview                                               = (b)
   ▼
   4      demo
```

⚠ Phase 1 does not depend on Phase 0 and can run alongside it — it needs a phone, not a protocol. Everything from Phase 2 needs a link that reaches `.connected`, and that needs a pairing.
