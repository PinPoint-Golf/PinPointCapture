# PinPointCapture — the online MVP

**A capture device that finds PinPointStudio, connects to it, and sends it every shot.**

| | |
|---|---|
| Status | Scope and plan. ⚠ Phase 1 done 24 Aug; guided pairing removed from scope the same day. ⛔ **(a) is mechanism-complete and journey-incomplete** — §2.2a |
| Date | 24 August 2026 |
| Scope of this document | Delivery order for one demonstrable outcome. [`delivery-scope.md`](delivery-scope.md) remains the authority on *what the product is*; this says what is built next, in what order, and what is deliberately left out |
| Source of truth | [`capture-companion-requirements.md`](../design/capture-companion-requirements.md) · [`ppcp-conformance.md`](../conformance/ppcp-conformance.md) · `PPCP-RV` revision 9 |
| Cross-repository | ✅ **None outstanding.** Studio's advertising landed 24 Aug; `libppcp`'s RV-6 work is out of MVP scope (§2) |

**Why this document exists.** The delivery scope is organised by capability level, which is right for deciding what a level means and wrong for deciding what to do on Monday. Everything through 24 August built foundations — the ring, clip extraction, the sidecar, one multi-source timeline — and none of it is demonstrable, because nothing crosses to Studio. This is the shortest honest path to something a person can watch work.

---

## 1. The MVP, as agreed

| | Requirement |
|---|---|
| **(a)** | The capture device **finds PinPointStudio and connects to it** — by QR code the first time, and without one thereafter |
| **(b)** | The device captures video, and supports **preview** and **hi-res capture** |
| **(c)** | After every shot and every candidate, the data reaches Studio |
| **(d)** | **Online only** — no offline catch-up, no store-and-forward |

⚠ **(d) is a scope reduction, not a product decision.** It removes E9 entirely, most of E4, `SessionOfferService` and the offline half of E21. ⛔ It does **not** remove the bundle: `CORE`'s *live bytes are bundle bytes* means the same records go to the wire and to disk, so the writer stays and the device keeps its own session library. §4.2 makes that a demo step precisely so "online only" cannot quietly become "online or nothing".

### ⛔ (a) was stated backwards until 24 August, and the table below always had it right

An earlier revision read *"PinPointStudio discovers the capture device and connects to it"*. **PinPointCapture is never a TLS server**, and cannot be: App Store and export-compliance considerations aside, `RV` 3.5d already forbids it on measured grounds — Apple's TLS listener has no server-side PSK resolver, which is finding **F-D1-1, raised from this repository in session S1**.

So the constraint is not new. What was new was a sentence in this document that never got reconciled with it, taken from CR-01's framing and left standing beside a table in §2.2 that stated the direction correctly all along. ⚠ Same shape as the day's other corrections: the precise thing was right and the prose beside it was wrong.

**There are two connections and only one of them is *the* connection:**

| | What it is | Who dials |
|---|---|---|
| The **bootstrap** (`RV` §11) | ⚠ **plaintext, momentary, carries no PPCP and no TLS** (11.2c, 1.3c1) — two ephemeral public keys, a hash and two MACs. ⛔ Out of MVP scope entirely (§2), so in the MVP this row never happens | PinPointStudio dials a window the device opened |
| **The session** — every PPCP byte that ever crosses | TLS-PSK, `RV` §5 | ⛔ **always the capture device** |

⛔ The device accepting a *bootstrap* socket is not the device being a server in the sense that matters: nothing confidential crosses it, and `95add3e` implements 11.2b's role swap so that the moment a pairing exists the device dials. **Every PPCP session in this product is outbound from the phone.**

### Where each requirement stands

| | Built | Missing |
|---|---|---|
| **(a)** | The **mechanisms**, all of them: pairing by code, proved 30/30 two-sided; the persisted pairing; day-two reconnect by discovery across a change of host address (`0b62394`) | ⛔ **The journey.** The scan path cannot produce a persisted pairing, so reconnect has nothing to work with — §2.2 |
| **(b)** | Hi-res: the ring, clip extraction, the sidecar, thumbnails — `8a371c3`. Unverified on a camera | **Preview**: no `preview` Stream is opened and nothing produces frames for one |
| **(c)** | `LiveDetectionSink`, `HostLinkDriver`, `TransferQueue`, `PayloadTransferQueue`, `SessionResume` — all tested | **Every one of them has no caller.** Composition only, which is the shape E1.1 was |
| **(d)** | — | Nothing. It is a subtraction |

---

## 2. Rendezvous — the pairing-code path, and nothing new

⛔ **Guided pairing (`PPCP-RV` §11, RV-6) is OUT of the MVP.** Decided 24 August: it is a future capability, not a first-release one.

⚠ **That is a scope decision and not a judgement on the work.** RV-6 is being built in this repository now — `BootstrapAcceptor`, `BootstrapWindow`, `BootstrapAdvertiser`, `CryptoKitKeyAgreement`, `GuidedPairingCoordinator`, `CompareDigitsView` and their tests. None of it is discarded; it stops being a **gate** on the MVP and becomes a capability that lands when it lands.

### 2.1 What the MVP uses instead — which is what already works

| | Mechanism | State |
|---|---|---|
| **First pairing** | The **pairing code**, `RV` §4. Studio displays it, the device scans and dials, Studio listens | ✅ **REQUIRED of every implementation by 2a**, working, and measured **30/30 two-sided** against Studio's real listener on 23 Aug |
| **Every session after** | The persisted pairing of `RV` §7.4 — `PRK` in the Keychain, opt-in and revocable | ✅ built |
| **Finding Studio again** | Studio advertises `_ppcp._tcp` `role: host`; the device browses, resolves the `rid` against its held pairings and dials (§2.2) | ⚠ **Built both sides, 24 Aug**, and survives the host changing address — ⛔ but unreachable today, §2.2 |

⛔ **The consequence worth stating plainly: the MVP is no longer gated on RV-6, on `libppcp`, or on RT-20c.** What was Phase 0 across three repositories is a path that was already proved against the real Studio before today began, and nothing is owed by another team. ⚠ Requirement (a) is **not** finished, but what remains is a design question in this repository rather than a dependency — §2.2.

⚠ **9g still binds when RV-6 does ship.** A conformance claim to §11 must name RT-20c and state its result, and must not report an aggregate pass while it is unrun. Out of the MVP does not mean out of the claim — this repository will simply not be claiming §11 yet.

### 2.2 ✅ Day-two reconnect — resolved and built, 24 August

Both halves landed the same evening:

- **PinPointStudio advertises** `_ppcp._tcp` with `role: host`, per 3.5e. The dependency asked three times in this document is discharged.
- **This device browses and dials** — `ReconnectCoordinator` (`bb73b06`, `0b62394`), resolving each advertisement's `rid` against every held pairing (3.4b) and refusing an unresolvable one (3.4c).

⛔ **Confirmed to survive the host's address changing**, which is the case that decided the mechanism. An earlier revision of this section recommended trying a **cached endpoint** first and falling back to discovery; that is now dropped from scope. The cached endpoint existed only to avoid a round trip, and its one weakness — a host on DHCP — is precisely what discovery handles by resolving a *service* rather than an address.

⚠ **Discovery failure is still not an error** (3.6a), and `ReconnectCoordinator` says so in its own header. On a network where multicast is dropped the device falls back to the code, which is why 2a makes that path REQUIRED.

### ⛔ 2.2a — and none of it is reachable yet

The integration test on 24 August **aborted before it could exercise any of the above**, and the reason is not in the reconnect code, which behaved as designed. **It was never given a pairing to work with.**

> The phone cannot produce a persisted pairing on the path a normal user takes: the consent toggle lives only on the enter-a-code screen, while the primary screen pairs the moment the camera sees a code.

⚠ **The constraint underneath is real.** At scan time the code has not been read, `mu` is unknown, and `RV` 7.4f forbids offering persistence that might then be refused. So consent cannot be asked *before* the scan — it has to come after, as Studio already does.

⛔ **The UX that is there now is not the answer and is to be replaced rather than patched.** This is a **design** task, taken together, and the first thing to check is [the design handoff](../design/mockup%20v1/README.md): seventeen screens are specified there, B2 is the pairing view, and its copy is treated as decisions rather than suggestions. If it has a position on where persistence consent sits, that is the starting point — and if it has none, that absence is worth knowing before anything is drawn.

**Until then requirement (a) is mechanism-complete and journey-incomplete**, and the demo's step 7 cannot pass.

### 2.3 What each repository owes

| Repository | Owes |
|---|---|
| **PinPointCapture** | ⛔ §2.2a — the persistence-consent design, together. Then §3 — everything in (b) and (c) |
| **PinPointStudio** | ✅ **Advertising for reconnection — delivered 24 August.** Nothing outstanding for the MVP |
| **libppcp** | ⚠ **Nothing the MVP waits on.** Its RV-6 work continues on its own timetable |

## 3. Phases

### 3.1 The device session — ✅ done, 24 August

✅ **Run on 24 August** (`42e92d0`). E1.1's exit criterion met on an iPhone 16: 239.5 fps realised against a claimed 240, **max inter-arrival 4.18 ms against a 4.17 ms frame period**, zero drops of any kind, 20/20 fragments held, and the REQ-OPT locks holding through the run. A real clip decoded and a thumbnail generated at the impact anchor.

⛔ **Three findings came out of it and two are still open**: `warmUp` crashed on its first hardware execution and is fixed; the declaration **overclaims `intrinsics: per_frame`** at 1080p240 where the connection delivers none ([#19](https://github.com/PinPoint-Golf/PinPointCapture/issues/19), planned, blocked on one measurement whose first attempt had a focus-position confound); and the on-device `make conform` run that closes [#17](https://github.com/PinPoint-Golf/PinPointCapture/issues/17) and [#18](https://github.com/PinPoint-Golf/PinPointCapture/issues/18) has not been done.

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

1. **Pair by code.** Studio displays it; the device scans and dials. ⚠ The path `RV` 2a makes REQUIRED, and the one already proved 30/30 two-sided.
2. **The device dials Studio under §5**, and from here it always will. Link up, both ends reporting `TLS 1.2 / TLS_PSK_WITH_AES_128_GCM_SHA256 / no forward secrecy`. ⛔ Every PPCP session in this product is outbound from the phone — §1.
3. Sync burst runs. The device reports `.connected` with a real offset and uncertainty on B3 — **not** the fixture it shows today.
4. Preview appears in Studio.
5. Hit a ball. Within a second: `candidate` on control, then `shot`, then `capture_announce`, then the clip on bulk — and the device's own row turning `In Studio` when the host confirms.
6. Five shots, no reconnect.
7. Close the app and reopen it. The device reconnects **with no pairing step and no code**. ⛔ **Cannot pass today** — §2.2a. ⚠ Worth running once with the host's address deliberately changed, since that is the case the mechanism was chosen for.

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
| ⛔ **Guided pairing — `RV` §11, RV-6** | Decided 24 Aug: a future capability. ⚠ Being built now, and not discarded — it stops gating the MVP. Its conformance obligation under 9g applies whenever it *is* claimed |
| ⛔ Any rendezvous mechanism not in `PPCP-RV` | Standing |

---

## 6. Order

```
   §2.2's answer          ⚠ needed by demo step 7, not by anything before it
        ·
   1    device session    ✅ DONE — E1.1's criterion met on hardware, 24 Aug
        ▼
   2    sync (#25) → fan-out sink → shots crossing (#27)      = (c)
        ▼
   3    preview                                               = (b)
        ▼
   4    demo
```

⛔ **There is no Phase 0 any more.** It was RV-6 across three repositories and it gated everything; the MVP now rests on the pairing-code path, which was already working before today. Phase 2 can start immediately.

⚠ **No cross-team dependencies remain.** (d) is a subtraction and (a)'s mechanisms are built, so everything left — §2.2a's design, (b) and (c) — is in this repository.
