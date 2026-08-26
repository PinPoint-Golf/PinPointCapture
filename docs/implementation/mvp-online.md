# PinPointCapture — the online MVP

**A capture device that finds PinPointStudio, connects to it, and sends it every shot.**

| | |
|---|---|
| Status | Scope and plan. ⚠ Phase 1 done 24 Aug; guided pairing removed from scope the same day. ✅ **(a) is DONE and proven end to end on hardware, 25 Aug** — [#96](https://github.com/PinPoint-Golf/PinPointCapture/issues/96) closed, both ends showing connected. ✅ **Phase 0 is clear** — [#98](https://github.com/PinPoint-Golf/PinPointCapture/issues/98), [#101](https://github.com/PinPoint-Golf/PinPointCapture/issues/101), [#102](https://github.com/PinPoint-Golf/PinPointCapture/issues/102) closed the same day. ✅ **Sync (#25) is DONE and converging live against Studio, 26 Aug** — B3 shows a real offset and uncertainty, not the fixture (§3.2). ⛔ **Next: (b), preview — §3.3** |
| Date | 24 August 2026 · revised 25 August · **revised 26 August** |
| Scope of this document | Delivery order for one demonstrable outcome. [`delivery-scope.md`](delivery-scope.md) remains the authority on *what the product is*; this says what is built next, in what order, and what is deliberately left out |
| Source of truth | [`capture-companion-requirements.md`](../design/capture-companion-requirements.md) · [`ppcp-conformance.md`](../conformance/ppcp-conformance.md) · `PPCP-RV` revision 9 |
| Cross-repository | ⚠ **One, reopened 25 Aug.** Preview's Studio half — a viewer, and whatever *config from PPS* means — is PinPointStudio's to scope (§3.3). Studio's advertising landed 24 Aug; `libppcp`'s RV-6 work is out of MVP scope (§2) |

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
| **(a)** | The mechanisms *and* the journey (`0d0df74`, `af3d80c`, 25 Aug). A pairing is kept by default; the four-screen opening pairs at the Mac before the phone is set down. ✅ **A phone held a pairing and browsed for it** — §2.2b | ⛔ **The last step: the dial completing.** Reaching Studio with no code has still never happened |
| **(b)** | Hi-res: the ring, clip extraction, the sidecar, thumbnails — `8a371c3`. ⚠ Ring counters now read off a phone, and they are **not** the clean 24 Aug figures — §3.1 | **Preview**: no `preview` Stream is opened and nothing produces frames for one. ⛔ And nothing can open one while [#98](https://github.com/PinPoint-Golf/PinPointCapture/issues/98) stands |
| **(c)** | `LiveDetectionSink`, `HostLinkDriver`, `TransferQueue`, `PayloadTransferQueue`, `SessionResume` — all tested. ✅ **`HostLinkDriver` composed, 26 Aug** — wired into `HostLinkSession`'s tick, converges live against Studio (§3.2) | **`LiveDetectionSink`, `TransferQueue`, `PayloadTransferQueue`, `SessionResume` still have no caller.** Shots crossing ([#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27)) is what remains of (c) — the shape three defects found on 25 Aug also had (§3.0a) |
| **(d)** | — | Nothing. It is a subtraction |

---

## 2. Rendezvous — the pairing-code path, and nothing new

⛔ **Guided pairing (`PPCP-RV` §11, RV-6) is OUT of the MVP.** Decided 24 August: it is a future capability, not a first-release one.

⚠ **That is a scope decision and not a judgement on the work.** RV-6 is being built in this repository now — `BootstrapAcceptor`, `BootstrapWindow`, `BootstrapAdvertiser`, `CryptoKitKeyAgreement`, `GuidedPairingCoordinator`, `CompareDigitsView` and their tests. None of it is discarded; it stops being a **gate** on the MVP and becomes a capability that lands when it lands.

### 2.1 What the MVP uses instead — which is what already works

| | Mechanism | State |
|---|---|---|
| **First pairing** | The **pairing code**, `RV` §4. Studio displays it, the device scans and dials, Studio listens | ✅ **REQUIRED of every implementation by 2a**, working, and measured **30/30 two-sided** against Studio's real listener on 23 Aug |
| **Every session after** | The persisted pairing of `RV` §7.4 — `PRK` in a backup-excluded file this app owns, opt-in and revocable (**the Keychain until erratum E56**) | ✅ built |
| **Finding Studio again** | Studio advertises `_ppcp._tcp` `role: host`; the device browses, resolves the `rid` against its held pairings and dials (§2.2) | ⚠ **Built both sides, 24 Aug**, and survives the host changing address — ⛔ but unreachable today, §2.2 |

⛔ **The consequence worth stating plainly: the MVP is no longer gated on RV-6, on `libppcp`, or on RT-20c.** What was Phase 0 across three repositories is a path that was already proved against the real Studio before today began, and nothing is owed by another team. ⚠ Requirement (a) is **not** finished, but what remains is a design question in this repository rather than a dependency — §2.2.

⚠ **9g still binds when RV-6 does ship.** A conformance claim to §11 must name RT-20c and state its result, and must not report an aggregate pass while it is unrun. Out of the MVP does not mean out of the claim — this repository will simply not be claiming §11 yet.

### 2.2 ✅ Day-two reconnect — resolved and built, 24 August

Both halves landed the same evening:

- **PinPointStudio advertises** `_ppcp._tcp` with `role: host`, per 3.5e. The dependency asked three times in this document is discharged.
- **This device browses and dials** — `ReconnectCoordinator` (`bb73b06`, `0b62394`), resolving each advertisement's `rid` against every held pairing (3.4b) and refusing an unresolvable one (3.4c).

⛔ **Confirmed to survive the host's address changing**, which is the case that decided the mechanism. An earlier revision of this section recommended trying a **cached endpoint** first and falling back to discovery; that is now dropped from scope. The cached endpoint existed only to avoid a round trip, and its one weakness — a host on DHCP — is precisely what discovery handles by resolving a *service* rather than an address.

⚠ **Discovery failure is still not an error** (3.6a), and `ReconnectCoordinator` says so in its own header. On a network where multicast is dropped the device falls back to the code, which is why 2a makes that path REQUIRED.

### ✅ 2.2a — resolved 25 August 2026: the phone remembers by default

The integration test on 24 August **aborted before it could exercise any of the above**, and the reason is not in the reconnect code, which behaved as designed. **It was never given a pairing to work with.**

> The phone cannot produce a persisted pairing on the path a normal user takes: the consent toggle lives only on the enter-a-code screen, while the primary screen pairs the moment the camera sees a code.

⚠ **The constraint underneath is real.** At scan time the code has not been read, `mu` is unknown, and `RV` 7.4f forbids offering persistence that might then be refused. So consent cannot be asked *before* the scan — it has to come after, as Studio already does.

✅ **Answered by reversing the default** — Mark, 25 August 2026 (issue #96). **The stance is to remember; forgetting is the deliberate action.** The consent question disappears from the flow entirely, which also dissolves the 7.4f tension above rather than working around it: nothing is promised before the scan, and B2 *states* the outcome afterwards, when `mu` has been read.

What landed:

- **`PairingSecretStore.save` no longer takes a `consent` flag**, and `StoreError.consentNotGiven` is gone. A pairing that completes is written. ⛔ 7.4f is untouched — a `mu > 1` code is still refused outright, through the library's own predicate.
- **B2 gained a settled state.** The phone says the connection worked and what became of the pairing, in three sentences for three outcomes — remembered, not remembered because the code pairs several devices, not remembered because the store could not be written. ⚠ The last of those used to be a `try?`: a phone could report a remembered Studio while holding nothing.
- **B3a — Remembered Studios**, reached from the B3 settings list. `pairings()` and `revoke(_:)` had been correct and callerless since D7, so `RV` 7.4b's *individually revocable* had never actually been offered.
- **7.4c binds for the first time.** `bind(sessionId:toCounterpart:)` also had no caller; it now runs on `hello`, inside the authenticated channel.

⚠ **The specification moved the same day and in the same direction.** [Erratum E57](../../../libppcp/docs/specification/ppcp-rv.md) made `RV` 7.4b a **SHOULD**, on the reasoning that opt-in/visible/revocable describes screens and §1.3 already excludes those. So declining the opt-in half is a decision this application is entitled to take, and it is recorded as one in [the conformance document](../conformance/ppcp-conformance.md). ⛔ E57 also removes any requirement that a means of revoking *exists* — which is exactly why B3a is part of this change rather than a follow-up.

⛔ **Requirement (a) is still journey-incomplete until a phone proves it.** The mechanism is now reachable end to end and no unit test in this target can show that: the 24 August defect was a missing call site, and `RendezvousTeardownTests` explains at length why a suite cannot see one. What closes it is the run — pair, kill the app, reopen, reach Studio with no code — and until that happens the demo's step 7 is unproven rather than passing.

### 2.2b ✅ On hardware, 25 August — three of the four steps

A screenshot from the phone shows the C1 host chip reading `PinPointStudio` over `not found · 62s`. That chip names a Studio **only when exactly one pairing is held**, and `ReconnectCoordinator` browses only when `identityKeys()` is non-empty. So, evidenced rather than reasoned:

- ✅ **The phone persisted a pairing on the path a normal user takes.** This is the thing that could not happen on 24 August and the reason that test aborted.
- ✅ The sweep runs on foreground, resolves against the held pairing, and reports honestly for 62 seconds.
- ⛔ **The dial did not complete.** `not found` is 3.6a — Studio was not running, or that network does not carry discovery between its clients. Nothing here says the mechanism is wrong; it says the counterpart was absent.

⚠ **So demo step 7 needs a session with Studio running on a network that carries multicast**, and nothing more from this repository. That is the whole of what (a) still owes.

### 2.3 What each repository owes

| Repository | Owes |
|---|---|
| **PinPointCapture** | ✅ §2.2a answered and built; Phase 0 clear. ⛔ Now: (b) preview — §3.3 |
| **PinPointStudio** | ✅ **Advertising for reconnection — delivered 24 August.** Nothing outstanding for the MVP |
| **libppcp** | ⚠ **Nothing the MVP waits on.** Its RV-6 work continues on its own timetable |

## 3. Phases

### 3.0 ✅ Phase 0 — cleared, 25 August, and what it cost

A day on a phone. Five issues closed, four of them found while fixing the first.

| | | |
|---|---|---|
| [#98](https://github.com/PinPoint-Golf/PinPointCapture/issues/98) | Shots minted with nothing recorded | `libppcp` originates nothing over a 64 KiB per-channel queue, and both `ENC` 6f's SHOULD `chunk_bytes` of 262144 **and** a conformant `AchievedFrames` at 240 fps exceed it. The call site was following the specification. Chunk lowered to 32 KiB as a recorded deviation; **F-E1-1** and **F-E1-2** raised for `libppcp` |
| [#101](https://github.com/PinPoint-Golf/PinPointCapture/issues/101) | Arming stalled the sensor up to nine seconds | `sessionPreset` was inherited rather than stated. `.inputPriority` removed it: 1080p120 went from a 8854 ms gap and 85.9 fps to **8.34 ms and 119.9 fps, zero drops**. `arm()` also now waits for the ring before claiming `armed` |
| [#102](https://github.com/PinPoint-Golf/PinPointCapture/issues/102) | Every rate but the fastest discarded | Enumeration keyed on geometry, so 1080p120 did not exist and *Use 120 fps* silently gave 4K60 on the ultra-wide. 28 → 40 modes; one ranking rule; Streams now name a profile that was actually declared |
| [#96](https://github.com/PinPoint-Golf/PinPointCapture/issues/96) | Remember / forget / reconnect | Closed — the dial completes, confirmed at **both** ends |
| [#97](https://github.com/PinPoint-Golf/PinPointCapture/issues/97) | The four-screen opening | Closed |

⛔ **And a crash on `arm()`** — `Int64(NaN)` reading `exposureDuration` before it settled, symbolicated off the device. It had been a race the user was winning by hand.

⚠ **What §3.1's contradiction turned out to be.** The `↕100.2 ms` reading was a **startup transient**, not a sustained defect: over 38 s at 1080p240 the distribution is 8994 inter-arrivals under 5 ms and one over 10 ms. `maxInterArrivalNs` could say how bad and not *when*, so `RingStats` now buckets every gap and timestamps the largest. E1.1 holds the claimed rate for a whole session at both rates.

⚠ **Still open from that day, and none of it blocks preview:** [#103](https://github.com/PinPoint-Golf/PinPointCapture/issues/103) minting stops after ~31 candidates — the one that bites a real range session soonest; [#99](https://github.com/PinPoint-Golf/PinPointCapture/issues/99) the primary button's label and the Session's state are decided separately; [#19](https://github.com/PinPoint-Golf/PinPointCapture/issues/19) the intrinsics overclaim, now unblocked because 1080p120 exists; and [#17](https://github.com/PinPoint-Golf/PinPointCapture/issues/17)'s last item, the encoded profile/level at the provisional 50 Mbps. ✅ **[#100](https://github.com/PinPoint-Golf/PinPointCapture/issues/100) closed 26 Aug** — a session can now be swiped away from the library, deleting its bundle from the device.

### 3.0a ⚠ What 25 August says about *how* this codebase fails

Three defects landed and were fixed in one day, and they share one shape worth naming before planning the next tranche:

| Defect | Shape |
|---|---|
| *Arm* dead on every launch after the first, on every device | `refreshCapability()` had no caller outside onboarding |
| `endPairing`, `revoke`, `pairings`, `bind` | all written, all correct, **none called** (findings F-D12-1, and #96) |
| B3's full-width button | six titles wired to one behaviour |

⛔ **This target cannot test for a missing call site**, and `RendezvousTeardownTests` says so at length. Worse, the suites *hide* it: every test that touches arming calls `refreshCapability()` in its own setup, doing for the model exactly what the application forgot to do — so a green run said nothing about the app.

⚠ **The practical consequence for planning:** budget a **wiring pass** at the end of each level in (b) and (c) — read the call sites, on a phone — rather than trusting a green suite. And when a guard can refuse, make it say why: *Arm* shipped dead for weeks because `warmUp` returned silently, and became findable within an hour of being given a sentence.

### 3.1 The device session — ✅ done 24 August, ⚠ contradicted 25 August

✅ **Run on 24 August** (`42e92d0`). E1.1's exit criterion met on an iPhone 16: 239.5 fps realised against a claimed 240, **max inter-arrival 4.18 ms against a 4.17 ms frame period**, zero drops of any kind, 20/20 fragments held, and the REQ-OPT locks holding through the run. A real clip decoded and a thumbnail generated at the impact anchor.

⛔ **The same instrument said something different on 25 August**, on a different phone and a different run: `20/20 · 239 fps · ↕100.2 ms`, with the gap flagged. At 239 fps a frame period is ~4.2 ms, so that is **twenty-four frame periods** — against the 4.18 ms measured on 24 August. Twenty fragments still rolled and the rate was still achieved, so this is not the ring failing; something stalled delivery for a tenth of a second. ⚠ **E1.1's criterion says *at the claimed rate*, and one clean run plus one stalled run is not a pass.** Recorded on [#17](https://github.com/PinPoint-Golf/PinPointCapture/issues/17); it may well be the same cause as [#98](https://github.com/PinPoint-Golf/PinPointCapture/issues/98) and should be looked at together.

⛔ **Three findings came out of the 24 August run and two are still open**: `warmUp` crashed on its first hardware execution and is fixed; the declaration **overclaims `intrinsics: per_frame`** at 1080p240 where the connection delivers none ([#19](https://github.com/PinPoint-Golf/PinPointCapture/issues/19), planned, blocked on one measurement whose first attempt had a focus-position confound); and the on-device `make conform` run that closes [#17](https://github.com/PinPoint-Golf/PinPointCapture/issues/17) and [#18](https://github.com/PinPoint-Golf/PinPointCapture/issues/18) has not been done.

### 3.2 (c) — shots and candidates crossing

⚠ **Numbered before (b) and now sequenced after it** — the section numbers are historical, the order in §6 is current. See §3.3 for why, and for the one dependency that has since resolved it.

✅ **Sync — done, 26 August** ([#25](https://github.com/PinPoint-Golf/PinPointCapture/issues/25), E3.2). `HostLinkDriver.pump(nowNs:throughputMbitPerSecond:)` is composed into `HostLinkSession`'s tick — the burst, the filtering, the settle to heartbeat cadence, all running. Verified against a real PinPointStudio: the burst converges, offset and rate both measured. Two findings surfaced by that run rather than by testing — `AppModel.hostLink` was never refreshed after the initial connect, so a converged link still read as frozen `Pairing`; and the raw offset between two peers' own since-boot clocks is correct but can print as several million milliseconds, which is meaningless to a golfer. B3 now polls the live link and shows the clock agreement's **uncertainty**, not its magnitude. ⛔ This was required before anything else in (c) — `.connected` was deliberately unreachable without a settled clock estimate — and it now is reachable.

**The fan-out sink.** A small `DetectionSink` wrapping `CaptureSessionRecorder` and `LiveDetectionSink`, so the same records reach the bundle and the wire. **Decided: both**, per §1's note on (d).

**Shots crossing** ([#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27), E3.4). Announce on control immediately; payload queued on bulk behind its own flow control — `CORE` 3.1/T2, so a 25 MB clip cannot head-of-line block the next shot's `candidate`. `HostLinkSession.handle` currently drops every event that is not `connected`/`declared`/`error`, deliberately and with a comment; that switch is where this lands.

⚠ **The hosted-session question, unresolved and flagged.** `AppModel.arm()` builds a `HostlessRecordingSession` unconditionally. Online mode wants a hosted Session carrying the host's arbitration parameters. The type may generalise or may need a sibling — resolve at implementation time. ⛔ 7.3b's *records no `arm`* is the **hostless** case's rule and must not leak into the hosted one.

### 3.3 (b) — preview, and configuring the device from Studio

⛔ **Promoted to the next tranche after [#98](https://github.com/PinPoint-Golf/PinPointCapture/issues/98)** — Mark, 25 August: *"preview and config in PPS (from preview stream in PPC) and then actual capture and transmission post shot."* That reverses this document's earlier order, which put (c) before (b), and the reason is sound: **preview is the first thing that makes the link visible to a human.** A frame arriving in Studio proves the session, the Streams and the transport in one glance, and it is what an operator needs in order to aim and configure the device at all.

⚠ **The dependency to check before committing to that order.** `.connected` is deliberately unreachable without a settled clock estimate (§3.2's sync, [#25](https://github.com/PinPoint-Golf/PinPointCapture/issues/25)), and the B3 panel will keep saying `pairing` until it settles. Whether a `preview` Stream may usefully flow *before* sync settles is an open question for implementation time — preview frames need timestamps, but not necessarily agreed ones. ⛔ Resolve it deliberately rather than discovering it: if preview needs sync, then sync leads and this order is unchanged from the old one in practice.

**The Studio half is new scope in this document.** Preview is not merely frames leaving the phone: it is frames *arriving somewhere a person is looking*, and a device the operator can then configure. What that costs on the Studio side — a view, a decoder, and whatever control surface "config" turns out to mean — has not been scoped here and is **PinPointStudio's to size**. ⚠ This is the first cross-repository dependency to reappear since 24 August; §2.3's "nothing outstanding" no longer holds.

**On the device side**, the only piece with nothing to compose. `PreviewProducer` exists and is uncalled; nothing produces frames and no `preview` Stream is opened — `HostlessRecordingSession.streams` builds video, audio and metadata only.

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
7. Close the app and reopen it. The device reconnects **with no pairing step and no code**. ⚠ **Three of its four steps are proven on hardware** (§2.2b) — a pairing is held, the sweep runs, it resolves against what is held. What has never happened is the dial completing, and that needs Studio running on a network that carries multicast between its clients. ⚠ Worth running once with the host's address deliberately changed, since that is the case the mechanism was chosen for.

### 4.2 The check that (d) stayed honest

⚠ On the device afterwards: five clips in the session library with thumbnails, and a bundle carrying the same records that went over the wire. If this step fails, "online only" has become "online or nothing", which is a different product.

---

## 4a. What changed on 25 August, and what it adds

A day of work on a phone. Two commits — `0d0df74`, `af3d80c` — and the plan above absorbs most of it. What follows is what a reader returning to this document needs that is not already in §§1–4.

### The specification moved twice, both on 25 August

| Erratum | Change | What it costs us |
|---|---|---|
| **E56** | `RV` 7.2c becomes a SHOULD — storage is the application's decision | The `PRK` left the Keychain for a backup-excluded file this app owns. ⚠ **Side effect worth knowing: deleting the app now really does forget every pairing**, which was not true of the Keychain. It is also why the reconnection sweep stopped reporting *no pairings held* while the phone was locked |
| **E57** | `RV` 7.4b becomes a SHOULD — opt-in/visible/revocable describes screens, and §1.3 excludes those | Lets this app decline *opt-in* deliberately (#96). ⛔ **Read together, nothing normative protects a persisted `PRK` any more** — not where it is kept, not that a user can see or remove it. 7.4c, 7.4d and 7.4f are unchanged MUSTs |

### A UI workstream appeared that (a)–(d) does not describe

⚠ **This document is organised by protocol capability and the day's work was mostly not.** Recorded so it is not rediscovered as unplanned:

- **A design pass** — [`opening-v2`](../design/opening-v2/README.md), published as a canvas. Supersedes the A-series and B1 of `mockup v1`, with three departures named in its README.
- **The opening is four screens, not seven** ([#97](https://github.com/PinPoint-Golf/PinPointCapture/issues/97), closed): Welcome → What it needs → Pair my phone → Now set it down. The order follows where the golfer is standing, because the code is on the Studio screen and framing first meant carrying a framed phone to the Mac.
- **A vocabulary settled** for four things that were tangled: **End session** closes the Session, **Disconnect** drops the link, **Forget** ends the pairing, deleting the app ends all of it. Each now does only its own job.
- **The host chip renders `RV` §3** — looking, not found with how long, nothing paired, refused. `AppModel` had published that state since D7 with nothing reading it.

### Open questions this raised, for the next planning session

| Question | Why it matters |
|---|---|
| ⛔ Should **Disarm pause** rather than end? | Today one arm is one Session, and *End session* says so honestly. But a golfer between buckets has no pause — re-arming splits the round in two and the halves do not merge. A real change to the Session lifecycle and to what Studio receives |
| ⚠ Is there a **framing check per session**, not just per install? | The phone is re-placed every session. *Check framing* now reaches A6 from the capture screen, but nothing prompts it |
| ⚠ What does **"config from PPS"** actually cover? | Named on 25 Aug as part of the next tranche (§3.3) and not yet scoped on either side. Capture format? Retention? Viewpoint? |
| ⚠ **iPad** is unbroken, not designed | Fixed heights are gone and screens no longer render wrong on a 13-inch ([#54](https://github.com/PinPoint-Golf/PinPointCapture/issues/54) still owns the two-pane) |

---

## 4b. What changed on 26 August, and what it adds

One day, four commits. §3.2 and §6 absorb the substance; this is what a reader returning to this document needs that is not already folded in above.

- **Sync (#25) landed** — see §3.2. `.connected` is reachable now; B3 shows the real clock agreement instead of the fixture switcher's canned numbers.
- **[#100](https://github.com/PinPoint-Golf/PinPointCapture/issues/100) closed** — a session can be swiped away from the library on-device; deletion removes the bundle directory from disk, no confirmation dialog, device-local only (§3.0).
- **Arm renamed to Capture** on the button and the C1 status pill. The mechanism is unchanged; the word now names what the app is for rather than the mechanism underneath it.
- **Autofocus now converges before locking.** `warmUp` used to lock focus/exposure/white balance the instant the format was assigned, before AF/AE had settled on the subject — including on the QR pairing path, which shares the same camera. Fixed; the scanner now forces its own continuous AF/AE/WB. A capture-quality defect, not an (a)–(d) item, recorded here because it touched the pairing screen.

⚠ **Nothing here moves preview (§3.3).** It remains the next tranche, and the one cross-repository dependency — PinPointStudio's viewer and config surface — is unmoved.

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
   §2.2's answer          ✅ DONE 25 Aug — built, deployed, walked on a phone
        ·
   0    #98 + #17's gap   ✅ CLEARED 25 Aug — see §3.0
        ▼
   1    device session    ✅ DONE — and the 25 Aug contradiction is resolved (§3.1)
        ▼
   2    sync (#25)        ✅ DONE 26 Aug — HostLinkDriver composed, converges live against Studio (§3.2)
        ▼         ⚠ settles the order question raised 25 Aug — §3.3's dependency was real, and sync led
   3    preview  (+ Studio's viewer and config surface)        = (b)
        ▼
   4    fan-out sink → shots crossing (#27)                    = (c)
        ▼
   5    demo — step 7 needs Studio on a multicast-carrying network
```

✅ **Phase 0 is clear, 25 August.** It was a single defect in this repository ([#98](https://github.com/PinPoint-Golf/PinPointCapture/issues/98)) that stopped a Session writing its payloads, and it brought three more out with it — see §3.0. All closed the same day. **Preview (§3.3) is next and nothing blocks it.**

⚠ **One cross-team dependency has reappeared.** Preview's Studio half — a viewer, and whatever "config from PPS" means — is PinPointStudio's to scope (§3.3). §2.3's *"nothing outstanding"* held for one day.

⚠ **Budget a wiring pass per level** (§3.0a). Three defects on 25 August were all "written, correct, never called", and this target cannot test for that.
