# PinPointCapture — the online MVP

**A capture device that finds PinPointStudio, connects to it, and sends it every shot.**

| | |
|---|---|
| Status | Scope and plan. ✅ **(a)'s mechanisms proven 25 Aug** — [#96](https://github.com/PinPoint-Golf/PinPointCapture/issues/96) closed. ✅ **Phase 0 clear 25 Aug** — [#98](https://github.com/PinPoint-Golf/PinPointCapture/issues/98), [#101](https://github.com/PinPoint-Golf/PinPointCapture/issues/101), [#102](https://github.com/PinPoint-Golf/PinPointCapture/issues/102). ✅ **Sync ([#25](https://github.com/PinPoint-Golf/PinPointCapture/issues/25)) done 26 Aug.** ✅ **PREVIEW IS DONE, 28 Aug** — [#108](https://github.com/PinPoint-Golf/PinPointCapture/issues/108) and [#107](https://github.com/PinPoint-Golf/PinPointCapture/issues/107) closed, a picture in Studio at connect (§3.3, §4c). ⛔ **Next: (c), shots crossing — [#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27), §3.2** — and it is gated on a hardware session, not on code (§7) |
| Date | 24 August 2026 · revised 25, 26 August · **revised 28 August** |
| Scope of this document | Delivery order for one demonstrable outcome. [`delivery-scope.md`](delivery-scope.md) remains the authority on *what the product is*; this says what is built next, in what order, and what is deliberately left out |
| Source of truth | [`capture-companion-requirements.md`](../design/capture-companion-requirements.md) · [`ppcp-conformance.md`](../conformance/ppcp-conformance.md) · `PPCP-RV` revision 9 |
| Cross-repository | ✅ **Preview's viewer half delivered 28 Aug** (PinPointStudio `83e5afd`) — one consumer per camera Source from `declare`, live tile on Settings → Cameras. ⛔ **A dependency floor now exists: `libppcp@a9785bb` or later** (§4c). ⚠ *Config from PPS* is still unscoped on both sides — now [#118](https://github.com/PinPoint-Golf/PinPointCapture/issues/118) |

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

| | Built | Missing | Owned by |
|---|---|---|---|
| **(a)** | The mechanisms *and* the journey (`0d0df74`, `af3d80c`, 25 Aug). A pairing is kept by default; the four-screen opening pairs at the Mac before the phone is set down. ✅ **A phone held a pairing and browsed for it** — §2.2b | ⛔ **The last step: the dial completing.** Reaching Studio with no code has still never happened | [#66](https://github.com/PinPoint-Golf/PinPointCapture/issues/66) E16.1 · [#67](https://github.com/PinPoint-Golf/PinPointCapture/issues/67) E16.2 |
| **(b)** | ✅ **Preview — done 28 Aug.** A picture arrives in Studio at connect, 600+ segments in a run (§3.3, §4c). Hi-res: the ring, clip extraction, the sidecar, thumbnails — `8a371c3` | ⚠ **Hi-res is unproven on a real camera on the current build** — no clip has been pulled off a phone since `8a371c3`, and E1.1's encoded profile/level has never been printed | [#17](https://github.com/PinPoint-Golf/PinPointCapture/issues/17) · [#18](https://github.com/PinPoint-Golf/PinPointCapture/issues/18) · [#19](https://github.com/PinPoint-Golf/PinPointCapture/issues/19) · preview residue [#109](https://github.com/PinPoint-Golf/PinPointCapture/issues/109)–[#116](https://github.com/PinPoint-Golf/PinPointCapture/issues/116) |
| **(c)** | `LiveDetectionSink`, `HostLinkDriver`, `TransferQueue`, `PayloadTransferQueue`, `SessionResume` — all tested. ✅ **`HostLinkDriver` composed, 26 Aug**; the hosted `RecordingSession` and the mint-on-the-link-peer move landed with it | ⛔ **Shots crossing has never been watched on a phone.** And ⚠ **the candidate half has no MVP owner in this document** — a real club strike minting a Shot is [#21](https://github.com/PinPoint-Golf/PinPointCapture/issues/21) E2.1, which §6 never sequenced | [#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27) E3.4 · ⚠ [#21](https://github.com/PinPoint-Golf/PinPointCapture/issues/21) E2.1 |
| **(d)** | — | Nothing. It is a subtraction. ⚠ Its **check** (§4.2) deliberately has no issue — it is a demo step, and if it fails the failure belongs to whichever level broke it | — |

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
| **PinPointCapture** | ✅ §2.2a answered and built; Phase 0 clear; ✅ **preview done 28 Aug**. ⛔ Now: (c) shots crossing — §3.2, and it needs a phone rather than code (§7) |
| **PinPointStudio** | ✅ Advertising, 24 Aug. ✅ **The preview viewer and its always-on consumer, 28 Aug** (`83e5afd`). ⚠ Owed: their half of *config from PPS* ([#118](https://github.com/PinPoint-Golf/PinPointCapture/issues/118)), and their half of [#113](https://github.com/PinPoint-Golf/PinPointCapture/issues/113)'s two numbers |
| **libppcp** | ⛔ **The MVP now has a floor: `a9785bb` or later.** The transfer-table reclaim ([#107](https://github.com/PinPoint-Golf/PinPointCapture/issues/107)) is load-bearing — below it, preview kills capture in thirteen seconds. ⚠ Two MVP-adjacent items wait on it: [#105](https://github.com/PinPoint-Golf/PinPointCapture/issues/105) and [#106](https://github.com/PinPoint-Golf/PinPointCapture/issues/106) |

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

⚠ **Still open from that day, and none of it blocks preview:** [#103](https://github.com/PinPoint-Golf/PinPointCapture/issues/103) minting stops after ~31 candidates — the one that bites a real range session soonest; [#99](https://github.com/PinPoint-Golf/PinPointCapture/issues/99) the primary button's label and the Session's state are decided separately; [#19](https://github.com/PinPoint-Golf/PinPointCapture/issues/19) the intrinsics overclaim, now unblocked because 1080p120 exists; and [#17](https://github.com/PinPoint-Golf/PinPointCapture/issues/17)'s last item, the encoded profile/level at the provisional 50 Mbps. ⚠ **[#100](https://github.com/PinPoint-Golf/PinPointCapture/issues/100) is half-closed and this document said otherwise.** [#104](https://github.com/PinPoint-Golf/PinPointCapture/issues/104) shipped 26 Aug — a session swipes away and its bundle leaves the disk — but #100's own exit criterion covers **per-shot** deletion, whose manifest-rewrite question is unresolved. It stays open, correctly.

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

### 3.3 ✅ (b) — preview: DONE 28 August, and it had never once worked

⛔ **Promoted to the next tranche after [#98](https://github.com/PinPoint-Golf/PinPointCapture/issues/98)** — Mark, 25 August: *"preview and config in PPS (from preview stream in PPC) and then actual capture and transmission post shot."* The reason was sound: **preview is the first thing that makes the link visible to a human.**

✅ **It works.** `2f604b1`, against `libppcp@a9785bb` and PinPointStudio `83e5afd`: a picture in **Settings → Cameras** with nothing pressed on the phone, 600+ segments in one run, `tapped == sent`, zero decode failures. [#108](https://github.com/PinPoint-Golf/PinPointCapture/issues/108)'s acceptance test — *"if a picture requires anything to be pressed on the phone first, this is not done"* — passes.

⛔ **And before that, no preview frame had ever left this application.** Not intermittently: `PreviewProducer.deliver` could not succeed as written. Nine defects across three repositories, five stacked on the delivery path, each invisible until the one in front of it was cleared. The full record is [#117](https://github.com/PinPoint-Golf/PinPointCapture/issues/117); §4c has what a reader of *this* document needs.

⚠ **The order question this section raised on 25 August is answered, and the answer was not the one expected.** It asked whether preview needs sync to settle first. It does not — but it turned out to need something this document never considered: **an instrument**. Five defects sat behind one swallowed error each and produced identical silence at both ends. What found them was three counters and a named reason, not reasoning about clauses.

**What is left of (b), and none of it blocks (c):**

| | | Status |
|---|---|---|
| [#109](https://github.com/PinPoint-Golf/PinPointCapture/issues/109) | ✅ **CLOSED 28 Aug.** Three tests in `LiveLinkTests.swift`, and both reverts were run: undoing the `.present` fix fails 3, undoing the chunking fails 1. Suite 308 green | ✅ Done |
| [#110](https://github.com/PinPoint-Golf/PinPointCapture/issues/110) ⛔ | The `try?` audit on the delivery path | Todo |
| [#111](https://github.com/PinPoint-Golf/PinPointCapture/issues/111) | The `print("[preview] …")` instrumentation, converted keeping its shape (E10) | Todo |
| [#112](https://github.com/PinPoint-Golf/PinPointCapture/issues/112) | ⚠ **The arm transition — still unmeasured.** Preview must announce an `absent` segment across the camera reconfiguration, not go quiet | Todo · needs a phone |
| [#113](https://github.com/PinPoint-Golf/PinPointCapture/issues/113) | Two numbers from the run neither team can yet explain | Todo · with PPS |
| [#114](https://github.com/PinPoint-Golf/PinPointCapture/issues/114) | Who owns `link_bind` — `DevicePeer.setLinkId` is dead code | Todo |
| [#115](https://github.com/PinPoint-Golf/PinPointCapture/issues/115) | Product: only the running camera can preview. Framing on the ultra-wide means a calibration-affecting lens switch | Todo · **a decision** |
| [#116](https://github.com/PinPoint-Golf/PinPointCapture/issues/116) | Hold a Stream open and assert a Capture keeps arriving — neither conformance suite does | Todo · with PPS |
| [#118](https://github.com/PinPoint-Golf/PinPointCapture/issues/118) | ⚠ **The other half of this section's title.** *Config from PPS* has been an open question since 25 August and was never an item | Todo · **a decision** |

⚠ **The device-side notes this section carried are now history rather than plan**, and each turned out to matter: the tap is off the **existing** sample callback (a second `AVCaptureVideoDataOutput` starts `hardwareCost` metering — [`capability-spike.md`](../design/capability-spike.md) §2a); it drops rather than queues, because 5.11j makes preview never-queued; and `shed` expresses non-retention as an `absent` segment, never a gap — which is exactly the clause [#113](https://github.com/PinPoint-Golf/PinPointCapture/issues/113)'s first number is asking about.

---

## 4. Done looks like

### 4.1 The demo

1. **Pair by code.** Studio displays it; the device scans and dials. ⚠ The path `RV` 2a makes REQUIRED, and the one already proved 30/30 two-sided.
2. **The device dials Studio under §5**, and from here it always will. Link up, both ends reporting `TLS 1.2 / TLS_PSK_WITH_AES_128_GCM_SHA256 / no forward secrecy`. ⛔ Every PPCP session in this product is outbound from the phone — §1.
3. Sync burst runs. The device reports `.connected` with a real offset and uncertainty on B3 — **not** the fixture it shows today.
4. ✅ **Preview appears in Studio** — and it does, since 28 Aug ([#108](https://github.com/PinPoint-Golf/PinPointCapture/issues/108)). ⚠ It appears at **step 2**, not here: the picture is live from connect, before any of steps 3–5. Watch it survive step 5's arming — [#112](https://github.com/PinPoint-Golf/PinPointCapture/issues/112).
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
| ⛔ Should **Disarm pause** rather than end? *(no issue — a lifecycle decision)* | Today one arm is one Session, and *End session* says so honestly. But a golfer between buckets has no pause — re-arming splits the round in two and the halves do not merge. A real change to the Session lifecycle and to what Studio receives |
| ⚠ Is there a **framing check per session**, not just per install? | The phone is re-placed every session. *Check framing* now reaches A6 from the capture screen, but nothing prompts it |
| ⚠ What does **"config from PPS"** actually cover? | Named on 25 Aug as part of the next tranche (§3.3) and not yet scoped on either side. Capture format? Retention? Viewpoint? ⛔ **Still unscoped three days later — now [#118](https://github.com/PinPoint-Golf/PinPointCapture/issues/118)**, which is what an open question with no item does |
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

## 4c. What changed on 27–28 August: preview, and what it cost

Two days in which **preview did not work and nothing said so**. The full record is [#117](https://github.com/PinPoint-Golf/PinPointCapture/issues/117), with PinPointStudio's handover attached verbatim. What a reader of *this* document needs:

### The MVP moved

✅ **(b)'s preview half is done** — §3.3. ⛔ **And it had never worked at all**, which this document had no way to know: §3.3 previously read *"the only piece with nothing to compose"*, and that was true and irrelevant. The pieces composed. They were wired to each other correctly. **No frame left the phone**, and the reason was five defects in a row, each hidden by the one in front of it.

### ⛔ A dependency floor, which the MVP did not have before

**`libppcp@a9785bb` or later.** The 64-segment preview budget that [#107](https://github.com/PinPoint-Golf/PinPointCapture/issues/107) describes is **deleted**; below that library version the transfer table never reclaims and preview kills capture after thirteen seconds. §2.3's *"nothing the MVP waits on"* has become *"a version the MVP requires"*.

### Three things that change how this document should be read

⛔ **1. A library-issued ack is not an application ack.** libppcp answers `stream_open` on its own authority *before* this application's code runs. PinPointStudio logged `opened=1, refused=0` from a peer that had just refused to produce anything. ⚠ **Every "✅ proven against Studio" claim in this document rests on evidence of that kind** and is worth re-reading with this in mind — §3.2's sync is the strongest, because a converging offset is a computed number rather than an ack.

⛔ **2. Clause-by-clause review cannot find this class of defect.** Nine defects, not one of which violates a clause: wrong counts, wrong sizes, wrong ordering, swallowed errors. §3.0a said *"budget a wiring pass — read the call sites, on a phone"*. That advice was right and insufficient: these call sites were read, were correct, and were reached. What was missing was an **instrument** — three counters and a named reason, which turned five invisible stacked defects into five sequential visible ones in one evening.

⛔ **3. `try?` on a link write is the defect, not the style.** [#110](https://github.com/PinPoint-Golf/PinPointCapture/issues/110). Five defects, one symptom, complete silence at both ends.

---

## 5. Explicitly out

| Out | Why |
|---|---|
| [#28](https://github.com/PinPoint-Golf/PinPointCapture/issues/28) E3.5 — network recovery | A dropped link ends the demo rather than surviving it. ⚠ **This row is now out of date as a statement about the code**: `0485bd3` built it and the hardware run has a test for it (§7). Out of the *demo*, not out of the tree |
| [#26](https://github.com/PinPoint-Golf/PinPointCapture/issues/26) E3.3 — arm from host | Nice to have. Arm on the device. ⚠ **Also out of date**: `5dfb47c` composed arm/disarm from the host, and PinPointStudio built their half on 27 Aug. The two have never met — that is a test on the list, not a gap in scope |
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
   2    sync (#25)        ✅ DONE 26 Aug — HostLinkDriver composed, converges live against Studio
        ▼
   3    preview (#108)    ✅ DONE 28 Aug — a picture at connect, 600+ segments (§3.3, §4c)
        ▼               ⚠ Studio's viewer landed with it; the CONFIG half is #118 and unscoped
        ▼
   3a   THE HARDWARE RUN  ⛔ NEXT, and it is not code — docs/implementation/hardware-run-2026-08-27.md
        ▼               eight tests, and #18 #19 #26 #27 #28 #66 #112 close or fall on them (§7)
        ▼
   4    a real strike     ⚠ #21 E2.1 — never sequenced here, and (c)'s candidate half needs it
        ▼
   5    shots crossing    #27 = (c). Its exit is `make conform` ON THE DEVICE closing CT-S3
        ▼
   6    demo — step 7 needs Studio on a multicast-carrying network
```

⛔ **The critical path is now a phone, not a keyboard.** Every remaining MVP level is built and green on this Mac; seven open issues turn on tests nobody has run. That is §7, and it is the single most useful thing anyone could do next.

⚠ **Budget a wiring pass per level** (§3.0a). Three defects on 25 August were all "written, correct, never called", and this target cannot test for that. ⛔ **28 August added the harder version of the same lesson**: five defects were written, called, *and reached* — and still did nothing, because every error on the path was swallowed. A wiring pass is not enough on its own; the path needs an instrument that counts (§4c).

---

## 7. Board coverage — every MVP requirement, and the issue that owns it

⚠ **Why this section exists.** This document and the board drifted: §3.0 claimed [#100](https://github.com/PinPoint-Golf/PinPointCapture/issues/100) closed when only half of it was, §5 listed [#26](https://github.com/PinPoint-Golf/PinPointCapture/issues/26) and [#28](https://github.com/PinPoint-Golf/PinPointCapture/issues/28) as *"out"* long after both were built, and the whole of E2 — without which requirement (c) has no candidate to send — was never sequenced anywhere in §6. **Audited against the board, 28 August 2026.**

### 7.1 The requirements

| | Requirement | Owned by | Status |
|---|---|---|---|
| **(a)** | Finds Studio and connects, by code once and never again | [#66](https://github.com/PinPoint-Golf/PinPointCapture/issues/66) E16.1 · [#67](https://github.com/PinPoint-Golf/PinPointCapture/issues/67) E16.2 | ⚠ Mechanisms proven; **the dial completing has never happened** |
| | *first contact without a code at all* | [#94](https://github.com/PinPoint-Golf/PinPointCapture/issues/94) F-MVP-1 | ⛔ A change request against `RV` 2c. **Not MVP** — the code path is |
| **(b)** | Preview | [#108](https://github.com/PinPoint-Golf/PinPointCapture/issues/108) ✅ · [#107](https://github.com/PinPoint-Golf/PinPointCapture/issues/107) ✅ · [#109](https://github.com/PinPoint-Golf/PinPointCapture/issues/109) ✅ | ✅ **Done 28 Aug** |
| | *preview residue* | [#110](https://github.com/PinPoint-Golf/PinPointCapture/issues/110) [#111](https://github.com/PinPoint-Golf/PinPointCapture/issues/111) [#112](https://github.com/PinPoint-Golf/PinPointCapture/issues/112) [#113](https://github.com/PinPoint-Golf/PinPointCapture/issues/113) [#114](https://github.com/PinPoint-Golf/PinPointCapture/issues/114) [#115](https://github.com/PinPoint-Golf/PinPointCapture/issues/115) [#116](https://github.com/PinPoint-Golf/PinPointCapture/issues/116) | Todo — none of it blocks (c) |
| | Hi-res capture | [#17](https://github.com/PinPoint-Golf/PinPointCapture/issues/17) E1.1 · [#18](https://github.com/PinPoint-Golf/PinPointCapture/issues/18) E1.2 · [#19](https://github.com/PinPoint-Golf/PinPointCapture/issues/19) E1.3 | ⚠ In Progress, all three **blocked on a phone** |
| | *bitrate* | [#20](https://github.com/PinPoint-Golf/PinPointCapture/issues/20) E1.4 | Out of MVP (§5) — the 50 Mbps placeholder holds |
| | *config from Studio* | [#118](https://github.com/PinPoint-Golf/PinPointCapture/issues/118) | ⛔ **Newly filed.** §3.3's other half, unowned since 25 Aug |
| **(c)** | Every **shot** reaches Studio | [#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27) E3.4 | In Progress. Exit is `make conform` **on the device**, closing CT-S3 |
| | Every **candidate** reaches Studio | [#21](https://github.com/PinPoint-Golf/PinPointCapture/issues/21) E2.1 | ⛔ **The gap this audit found.** A real strike minting a Shot is unproven, and §6 never sequenced it |
| | *candidates you can trust* | [#22](https://github.com/PinPoint-Golf/PinPointCapture/issues/22) E2.2 | Out of MVP — (c) says candidates cross, not that they are all real |
| **(d)** | Online only | — | A subtraction. Its check is §4.2, deliberately not an issue |

### 7.2 ⛔ The critical path is a hardware session, and it is one afternoon

Seven open issues turn on tests **nobody has run**. [`hardware-run-2026-08-27.md`](hardware-run-2026-08-27.md) is the script; its own status line still reads *"Not run"*, and tests 1–2 have since been overtaken by preview working.

| Test | Closes or falls | Blocked on |
|---|---|---|
| 1 — a clip exists at all | [#18](https://github.com/PinPoint-Golf/PinPointCapture/issues/18) E1.2 | A phone |
| 2 — preview across the **arm transition** | [#112](https://github.com/PinPoint-Golf/PinPointCapture/issues/112) | A phone |
| 3 — a swing crosses | [#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27) E3.4 *(with `make conform` on device)* | A phone |
| 4 — host control, first time the two halves meet | [#26](https://github.com/PinPoint-Golf/PinPointCapture/issues/26) E3.3 | A phone |
| 5 — the network drops | [#28](https://github.com/PinPoint-Golf/PinPointCapture/issues/28) E3.5 | A phone |
| 6 — the residual, REQ-SYNC-4 | [#28](https://github.com/PinPoint-Golf/PinPointCapture/issues/28)'s last component | A phone |
| 7 — reconnect with no code | [#66](https://github.com/PinPoint-Golf/PinPointCapture/issues/66) E16.1, and **(a)'s last step** | A phone |
| 8 — the honesty check | (d), §4.2 | A phone |
| *afterwards* — `make conform` on the device build | [#19](https://github.com/PinPoint-Golf/PinPointCapture/issues/19) E1.3, and CT-S3 for [#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27) | A phone |
| *a real club strike at a real mat* | [#21](https://github.com/PinPoint-Golf/PinPointCapture/issues/21) E2.1 — **not currently on that list, and should be** | A phone |

✅ **The one prerequisite that was code has been added, 28 August.** [#17](https://github.com/PinPoint-Golf/PinPointCapture/issues/17) E1.1 could not close on any session while the encoded **profile/level** went unprinted: `AVVideoProfileLevelKey` is unset, so VideoToolbox chooses, and nothing read back what it chose. `RingStats.encodedProfileLevel` now parses the `hvcC` box out of the initialisation segment — **the encoder's own declaration, not what we asked for** — and `make test-device` prints it and asserts the run found it.

⚠ **The tier is the half that matters.** At level 5.1, HEVC **Main** tier caps at 40 Mbit/s and this application asks for a provisional **50** ([#20](https://github.com/PinPoint-Golf/PinPointCapture/issues/20)). High tier means the ask is within the level it declares; Main tier means the stream exceeds a level a decoder is entitled to believe. ⛔ **Nobody knows which yet** — that is now one line of a run's output away rather than an unbuilt instrument.

### 7.3 What could not be closed, and why

⚠ Audited one by one rather than assumed. **Nothing on this board is stale-open**: every one of the 118 issues is on the project, and no board status disagrees with its issue state.

| | Why it stays open |
|---|---|
| [#17](https://github.com/PinPoint-Golf/PinPointCapture/issues/17) | One unreported number — §7.2's note. Its own comment says do not close on it |
| [#18](https://github.com/PinPoint-Golf/PinPointCapture/issues/18) [#19](https://github.com/PinPoint-Golf/PinPointCapture/issues/19) [#26](https://github.com/PinPoint-Golf/PinPointCapture/issues/26) [#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27) [#28](https://github.com/PinPoint-Golf/PinPointCapture/issues/28) [#66](https://github.com/PinPoint-Golf/PinPointCapture/issues/66) [#67](https://github.com/PinPoint-Golf/PinPointCapture/issues/67) | A phone, and only a phone |
| [#99](https://github.com/PinPoint-Golf/PinPointCapture/issues/99) | ⛔ Still real. `arm()`'s `guard let recording, let mode` still returns after `startRecording()` opened a Session and without unwinding it — checked against the current tree, not the issue text |
| [#100](https://github.com/PinPoint-Golf/PinPointCapture/issues/100) | Half-shipped. [#104](https://github.com/PinPoint-Golf/PinPointCapture/issues/104) delivered whole-session deletion; **per-shot** deletion and the manifest-rewrite question are this issue's actual criterion |
| [#92](https://github.com/PinPoint-Golf/PinPointCapture/issues/92) | An umbrella with no crisp criterion, and deliberately so — it is the "mid-integration" record |
| [#94](https://github.com/PinPoint-Golf/PinPointCapture/issues/94) | A change request against another repository's specification |
| [#105](https://github.com/PinPoint-Golf/PinPointCapture/issues/105) [#106](https://github.com/PinPoint-Golf/PinPointCapture/issues/106) | ⛔ Both need `libppcp` — a `shot_disposition` message, and a prober-side twin of `ppcp_peer_sync_reply_stamps` |
| [#113](https://github.com/PinPoint-Golf/PinPointCapture/issues/113) [#116](https://github.com/PinPoint-Golf/PinPointCapture/issues/116) | Joint with PinPointStudio |
| [#115](https://github.com/PinPoint-Golf/PinPointCapture/issues/115) [#118](https://github.com/PinPoint-Golf/PinPointCapture/issues/118) | Decisions, and neither is mine to take |

⛔ **So the honest summary is: the code is not what is holding the MVP.** One afternoon with a phone, a mat and Studio running would resolve more of this board than any amount of further building.
