# PinPointCapture — the online MVP

**A capture device that finds PinPointStudio, connects to it, and sends it every shot.**

| | |
|---|---|
| Status | Scope and plan. ✅ **(a) IS DONE, 2 Sep** — a phone reached Studio over Wi-Fi **with no code and nobody touching it**, four times in one run (§2.2c). ✅ **(b) is done** — preview 28 Aug, and hi-res proven on a real sensor 2 Sep: **the whole of E1 through E1.3 closed**, [#17](https://github.com/PinPoint-Golf/PinPointCapture/issues/17) [#18](https://github.com/PinPoint-Golf/PinPointCapture/issues/18) [#19](https://github.com/PinPoint-Golf/PinPointCapture/issues/19) (§3.1). ✅ **(c) HAS HAPPENED** — a host arbitrated a Shot, asked for it, and received 25 MB of clip; 7 908 pump passes and 247 MB on bulk in one run (§3.2). ⛔ **Next: a real club strike, [#21](https://github.com/PinPoint-Golf/PinPointCapture/issues/21)** — the one MVP requirement with no evidence of any kind, and now the only open item on the whole (a)–(d) path (§7) |
| Date | 24 August 2026 · revised 25, 26, 28 August · **revised 2 September** |
| Scope of this document | Delivery order for one demonstrable outcome. [`delivery-scope.md`](delivery-scope.md) remains the authority on *what the product is*; this says what is built next, in what order, and what is deliberately left out |
| Source of truth | [`capture-companion-requirements.md`](../design/capture-companion-requirements.md) · [`ppcp-conformance.md`](../conformance/ppcp-conformance.md) · `PPCP-RV` revision 9 |
| Cross-repository | ✅ **Preview's viewer half delivered 28 Aug** (PinPointStudio `83e5afd`) — one consumer per camera Source from `declare`, live tile on Settings → Cameras. ✅ **The cable's host half, 31 Aug** — `PpcpWiredLink` dials the preview channel over a fresh usbmux tunnel; neither half works alone (§4d). ⛔ **A dependency floor: `libppcp@a9785bb` or later** (§4c). ⚠ *Config from PPS* is still unscoped on both sides — [#118](https://github.com/PinPoint-Golf/PinPointCapture/issues/118) |

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
| **(a)** | ✅ **All four steps, 2 Sep.** A pairing is kept by default; the four-screen opening pairs at the Mac; the phone browses, resolves the `rid` against what it holds, and **the dial completes** — over Wi-Fi, no code, four times in one run (§2.2c). And a second path exists that did not on 24 Aug: **the cable** (§4d) | ⛔ A first pairing over the cable is unbuilt ([#65](https://github.com/PinPoint-Golf/PinPointCapture/issues/65)) — reclassified 2 Sep as **rendezvous work, not transport work**, and it is the only open item left anywhere in rendezvous | [#16](https://github.com/PinPoint-Golf/PinPointCapture/issues/16) E16 ✅ — **all three levels closed 2 Sep** |
| **(b)** | ✅ **Preview done 28 Aug**, and over the cable 31 Aug. ✅ **Hi-res proven on a real sensor 2 Sep** — 239.5 fps against a claimed 240 at a **max inter-arrival of 4.18 ms**, 20/20 fragments, a 15.0 MB clip that opens as one 2.500 s video track, a thumbnail at the anchor, and the encoder's own `hvcC` reading **HEVC Main, High tier, level 5.1**. [#17](https://github.com/PinPoint-Golf/PinPointCapture/issues/17), [#18](https://github.com/PinPoint-Golf/PinPointCapture/issues/18) and [#19](https://github.com/PinPoint-Golf/PinPointCapture/issues/19) all closed 2 Sep | ⚠ Preview residue [#110](https://github.com/PinPoint-Golf/PinPointCapture/issues/110)–[#116](https://github.com/PinPoint-Golf/PinPointCapture/issues/116), none of it blocking. ⛔ E1.4's bitrate is out of MVP and waits on E-M2 ([#20](https://github.com/PinPoint-Golf/PinPointCapture/issues/20)) | — · residue [#110](https://github.com/PinPoint-Golf/PinPointCapture/issues/110)–[#116](https://github.com/PinPoint-Golf/PinPointCapture/issues/116) |
| **(c)** | ✅ **Watched on a phone, 2 Sep.** The host arbitrated a Shot over our Candidate, sent `capture_request`, and the ring answered it with 15–25 MB of clip; **7 908 pump passes carrying 247 MB on bulk** in one run and 81 MB bundles were written beside them (§3.2) | ⚠ **[#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27) closed 2 Sep with CT-S3 unrun** — `make conform` on the device is now a claim's obligation, not a level's. ⛔ **`In Studio` has never been reached** — no host has sent `capture_committed`. ⚠ And the shot was **injected**: a real club strike is [#21](https://github.com/PinPoint-Golf/PinPointCapture/issues/21) E2.1, still untouched | [#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27) E3.4 ✅ · ⛔ [#21](https://github.com/PinPoint-Golf/PinPointCapture/issues/21) E2.1 |
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
| **Finding Studio again** | Studio advertises `_ppcp._tcp` `role: host`; the device browses, resolves the `rid` against its held pairings and dials (§2.2) | ✅ **Proven on hardware, 2 Sep** — the dial completes over Wi-Fi with no code (§2.2c). ⚠ On an unreliable AP it can take four sweeps or find nothing for nine minutes, which is 3.6a working as designed |
| **Finding Studio on a cable** | usbmux inverts the direction: the device publishes what it registered on loopback, the host verifies the identity under 5.3b and dials (§4d) | ✅ **Built and running, 29–31 Aug** — [#64](https://github.com/PinPoint-Golf/PinPointCapture/issues/64) E15.1 closed. Cable link up in 3 s from a cold host; the phone reconnects unattended after a host restart |

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

⛔ **Requirement (a) is still journey-incomplete until a phone proves it.** The mechanism is now reachable end to end and no unit test in this target can show that: the 24 August defect was a missing call site, and `RendezvousTeardownTests` explains at length why a suite cannot see one. What closes it is the run — pair, kill the app, reopen, reach Studio with no code — and until that happens the demo's step 7 is unproven rather than passing. ✅ **It happened on 2 September — §2.2c.** This paragraph is kept as written because it names the only thing that could close (a), and that is exactly what closed it.

### 2.2b ✅ On hardware, 25 August — three of the four steps

A screenshot from the phone shows the C1 host chip reading `PinPointStudio` over `not found · 62s`. That chip names a Studio **only when exactly one pairing is held**, and `ReconnectCoordinator` browses only when `identityKeys()` is non-empty. So, evidenced rather than reasoned:

- ✅ **The phone persisted a pairing on the path a normal user takes.** This is the thing that could not happen on 24 August and the reason that test aborted.
- ✅ The sweep runs on foreground, resolves against the held pairing, and reports honestly for 62 seconds.
- ⛔ **The dial did not complete.** `not found` is 3.6a — Studio was not running, or that network does not carry discovery between its clients. Nothing here says the mechanism is wrong; it says the counterpart was absent.

⚠ **So demo step 7 needs a session with Studio running on a network that carries multicast**, and nothing more from this repository. That is the whole of what (a) still owes.

### ✅ 2.2c — the fourth step, 2 September: the dial completes

**It owed a session, it got one, and it works.** `make test-device` on an iPhone 16 launches the app fresh, holds a pairing persisted from an earlier session, browses `_ppcp._tcp`, resolves each advertisement's `rid` against every held pairing, and dials:

```
channel bulk    dialled TLS 1.2 · link_bind sent
channel control dialled TLS 1.2 · link_bind sent
DEVICE-RUN reached Mark's Mac mini — TLS 1.2,
           TLS_PSK_WITH_AES_128_GCM_SHA256 — no forward secrecy
```

⛔ **Four hosted rows in one run each did it independently, over Wi-Fi** — `en0[802.11]`, not the cable — with **no code, no credentials on the command line, and nobody touching the phone**. That is requirement (a) end to end, and it is the step this document has named as never having happened since 24 August.

⚠ **Reported honestly: the network is the flaky part, and it always was.** `6c214d8` records two consecutive **4.5-minute sweeps beside an advertising Studio that found nothing**, with a third finding it on sweep four. That is REQ-DISC-3's premise observed rather than assumed. ⛔ And the diagnostics said *nothing at all* for those nine minutes, so *"it never browsed"* and *"it browsed and found nothing"* were the same silence — there is now one line per sweep outcome in the diag log, still never on screen, because 3.6a makes finding nothing not an error.

✅ **[#66](https://github.com/PinPoint-Golf/PinPointCapture/issues/66) closed on this, 2 September.** ⚠ Recorded because it is a judgement rather than a measurement: REQ-DISC-3's *"assume multicast fails"* half was **observed** — two sweeps that found nothing, and a third that took four — and never **driven deliberately** on a network with multicast blocked. The level closes on the dial completing; the deliberate-failure test was not run, and the fallbacks it would have exercised (the code, and now the cable) are both built.

### 2.3 What each repository owes

| Repository | Owes |
|---|---|
| **PinPointCapture** | ✅ §2.2a answered and built; Phase 0 clear; ✅ preview 28 Aug; ✅ **(a), (b) and (c) all watched working on a phone, 2 Sep**. ⛔ Now: **a real strike ([#21](https://github.com/PinPoint-Golf/PinPointCapture/issues/21)), and nothing else on the MVP path.** ⚠ Carried forward outside the levels, all three closed over rather than done: `make conform` on the device, the network-drop run, and the deliberate multicast failure |
| **PinPointStudio** | ✅ Advertising, 24 Aug. ✅ **The preview viewer and its always-on consumer, 28 Aug** (`83e5afd`). ✅ **The cable's host half, 31 Aug** — `Connector::connectAdditional(Channel::Preview)` over a fresh usbmux tunnel. ⚠ Owed: their half of *config from PPS* ([#118](https://github.com/PinPoint-Golf/PinPointCapture/issues/118)), their half of [#113](https://github.com/PinPoint-Golf/PinPointCapture/issues/113)'s two numbers, and ⛔ **a `capture_committed` — no host has ever sent one, so `In Studio` is unreachable** |
| **libppcp** | ⛔ **The MVP now has a floor: `a9785bb` or later.** The transfer-table reclaim ([#107](https://github.com/PinPoint-Golf/PinPointCapture/issues/107)) is load-bearing — below it, preview kills capture in thirteen seconds. ⚠ One MVP-adjacent item still waits on it, [#105](https://github.com/PinPoint-Golf/PinPointCapture/issues/105); [#106](https://github.com/PinPoint-Golf/PinPointCapture/issues/106) closed 2 Sep after the estimate came in at **−1588 ppm / ± 1.29 ms**, against −184515 ppm / ± 36.77 ms when it was raised |

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

⚠ **What that day left behind, and none of it blocked preview:** ✅ [#103](https://github.com/PinPoint-Golf/PinPointCapture/issues/103) minting stopping after ~31 candidates — **closed 27 Aug**; ⛔ [#99](https://github.com/PinPoint-Golf/PinPointCapture/issues/99) the primary button's label and the Session's state decided separately — **still open, and still real** (§7.3); ✅ [#19](https://github.com/PinPoint-Golf/PinPointCapture/issues/19)'s intrinsics overclaim — **fixed and measured 2 Sep** (§3.1a); and ✅ [#17](https://github.com/PinPoint-Golf/PinPointCapture/issues/17)'s last item, the encoded profile/level, **read on 2 Sep and the issue closed**. ⚠ **[#100](https://github.com/PinPoint-Golf/PinPointCapture/issues/100) is half-closed and this document said otherwise.** [#104](https://github.com/PinPoint-Golf/PinPointCapture/issues/104) shipped 26 Aug — a session swipes away and its bundle leaves the disk — but #100's own exit criterion covers **per-shot** deletion, whose manifest-rewrite question is unresolved. It stays open, correctly.

### 3.0a ⚠ What 25 August says about *how* this codebase fails

Three defects landed and were fixed in one day, and they share one shape worth naming before planning the next tranche:

| Defect | Shape |
|---|---|
| *Arm* dead on every launch after the first, on every device | `refreshCapability()` had no caller outside onboarding |
| `endPairing`, `revoke`, `pairings`, `bind` | all written, all correct, **none called** (findings F-D12-1, and #96) |
| B3's full-width button | six titles wired to one behaviour |

⛔ **This target cannot test for a missing call site**, and `RendezvousTeardownTests` says so at length. Worse, the suites *hide* it: every test that touches arming calls `refreshCapability()` in its own setup, doing for the model exactly what the application forgot to do — so a green run said nothing about the app.

⚠ **The practical consequence for planning:** budget a **wiring pass** at the end of each level in (b) and (c) — read the call sites, on a phone — rather than trusting a green suite. And when a guard can refuse, make it say why: *Arm* shipped dead for weeks because `warmUp` returned silently, and became findable within an hour of being given a sentence.

### 3.1 The device session — ✅ done 24 August, ⚠ contradicted 25 August, ✅ **settled 2 September**

✅ **Run on 24 August** (`42e92d0`). E1.1's exit criterion met on an iPhone 16: 239.5 fps realised against a claimed 240, **max inter-arrival 4.18 ms against a 4.17 ms frame period**, zero drops of any kind, 20/20 fragments held, and the REQ-OPT locks holding through the run. A real clip decoded and a thumbnail generated at the impact anchor.

⛔ **The same instrument said something different on 25 August**, on a different phone and a different run: `20/20 · 239 fps · ↕100.2 ms`, with the gap flagged. At 239 fps a frame period is ~4.2 ms, so that is **twenty-four frame periods** — against the 4.18 ms measured on 24 August. Twenty fragments still rolled and the rate was still achieved, so this is not the ring failing; something stalled delivery for a tenth of a second. ⚠ **E1.1's criterion says *at the claimed rate*, and one clean run plus one stalled run is not a pass.** Recorded on [#17](https://github.com/PinPoint-Golf/PinPointCapture/issues/17); it may well be the same cause as [#98](https://github.com/PinPoint-Golf/PinPointCapture/issues/98) and should be looked at together.

⛔ **Three findings came out of the 24 August run.** `warmUp` crashed on its first hardware execution and is fixed. The other two are now closed by the run below.

### ✅ 3.1a — 2 September: [#17](https://github.com/PinPoint-Golf/PinPointCapture/issues/17) and [#18](https://github.com/PinPoint-Golf/PinPointCapture/issues/18) closed, and the contradiction retired

`make test-device` on an iPhone 16 at 1080p240 wide, 50 Mbps provisional:

```
framesAppended            3594          realised rate   239.5 fps (claimed 240.0)
maxInterArrivalNs         4.18 ms       (one frame = 4.17 ms)
drop: encoder busy 0 · drop: not retaining 0 · write failed 0 · non-monotonic 0
frag: written / evicted   30 / 10       held in ring    20/20
encoded profile/level     HEVC Main, High tier, level 5.1
focus / exposure / whiteBalance   locked → locked        thermal  fair
```

⚠ **The 25 August `↕100.2 ms` does not reappear**, and the largest gap in the whole run is one frame period. That retires the contradiction this section was named for: it was the startup transient §3.0 said it was, not a sustained defect.

⛔ **High tier, and that is the answer §7.2 was waiting for.** `RingStats.encodedProfileLevel` parses the `hvcC` box out of the initialisation segment — the encoder's own declaration, not what we asked for — and reads `tier_flag 1`. At level 5.1 the Main-tier cap is 40 Mbit/s and this application asks for 50, so **Main** would have meant a stream exceeding a level a decoder is entitled to believe. It emitted **High**. ⚠ This does not harden the bitrate: 50 Mbps stays provisional and E-M2 still owns it ([#20](https://github.com/PinPoint-Golf/PinPointCapture/issues/20)).

✅ **And a real clip**: 15.0 MB, one video track, **2.500 s**, `hvc1`, 599 frames at 239.49 fps, exposure measured at 4.038 ms rather than the hardcoded zero, a 3.3 KB JPEG thumbnail at the impact anchor. [#18](https://github.com/PinPoint-Golf/PinPointCapture/issues/18)'s criterion — a playable MP4 instead of `absent` — met on a camera rather than on synthetic frames.

✅ **The intrinsics overclaim is settled too**, and it was the second of the 24 August findings. Measured live, format by format: available at 1080p30/60/120, **not at 1080p240**, with stabilisation ruled out as the cause. The declaration no longer claims otherwise — `AVFoundationCaptureDevice` enumerates every mode with `deliversIntrinsics: false` and confirms it in `warmUp`, *"because intrinsics delivery is a property of a live `AVCaptureConnection`, not of a format"*. ✅ **[#19](https://github.com/PinPoint-Golf/PinPointCapture/issues/19) closed with it** — Mark, 2 September: this level's job is that a clip describes itself, and it does. Driving `ppcp-conform` on the device is a **conformance-claim** obligation rather than a capability E1.3 still owes, and it survives as [#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27)'s exit criterion and as `ppcp-conformance.md`'s own `blocked: a phone` row for CT-S7 (4).

### 3.2 ✅ (c) — shots crossing, watched on a phone 2 September

⚠ **Numbered before (b) and now sequenced after it** — the section numbers are historical, the order in §6 is current. See §3.3 for why, and for the one dependency that has since resolved it.

✅ **Sync — done, 26 August** ([#25](https://github.com/PinPoint-Golf/PinPointCapture/issues/25), E3.2). `HostLinkDriver.pump(nowNs:throughputMbitPerSecond:)` is composed into `HostLinkSession`'s tick — the burst, the filtering, the settle to heartbeat cadence, all running. Verified against a real PinPointStudio: the burst converges, offset and rate both measured. Two findings surfaced by that run rather than by testing — `AppModel.hostLink` was never refreshed after the initial connect, so a converged link still read as frozen `Pairing`; and the raw offset between two peers' own since-boot clocks is correct but can print as several million milliseconds, which is meaningless to a golfer. B3 now polls the live link and shows the clock agreement's **uncertainty**, not its magnitude. ⛔ This was required before anything else in (c) — `.connected` was deliberately unreachable without a settled clock estimate — and it now is reachable.

**The fan-out sink.** A small `DetectionSink` wrapping `CaptureSessionRecorder` and `LiveDetectionSink`, so the same records reach the bundle and the wire. **Decided: both**, per §1's note on (d).

**Shots crossing** ([#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27), E3.4). Announce on control immediately; payload queued on bulk behind its own flow control — `CORE` 3.1/T2, so a 25 MB clip cannot head-of-line block the next shot's `candidate`. `HostLinkSession.handle` currently drops every event that is not `connected`/`declared`/`error`, deliberately and with a comment; that switch is where this lands.

⚠ **The hosted-session question is answered.** `HostlessRecordingSession` became `RecordingSession` with a `Control` regime, and the hosted case moves the Mint engine onto the **link** peer — `ppcp_mint_pump` reads `timebase_ref`, the session id and the relation set off the peer it was built with, so a mint on the bundle peer with a host present would ignore `issue_hold_ns`, stamp `t0` in this device's own clock and never see the host's Shots. ⛔ Two peers stay, and not for taste: `SessionBundleWriter` writes with `peer.drain()`, which *consumes* the tx queue, while `PeerLinkPump` writes the socket with `drainPeek`/`drainCommit` over the same queues.

### ✅ 3.2a — what a phone did on 2 September

Against a live PinPointStudio, over Wi-Fi, with the host driving:

```
DEVICE-RUN clock agreement before arming: ± 1.31 ms (gate 5.0 ms)
DEVICE-RUN armed by the host after 0 s (state armed, torch commanded: true)
transfer capture_request received shot 63f2d3ee… pre 2000ms post 1000ms
transfer capture_request t0 converted … via relation offset 112754203.392 ms
  skew 1011.37 ppm (σ 1.317 ms) observed 0.2 s before t0, σ(t0) 1.318 ms
transfer capture_request waiting … +161 ms for the post-roll to reach the ring
transfer announce + payload queued capture cap:d6db3ede… — 25163459 byte(s)
transfer capture_request answered … partial [-2503 … +1497] ms from t0
DEVICE-RUN bundle sess:e6657841-… — 82 MB, 1 shot(s) in the session
```

**7 908 pump passes carrying 247 MB on the bulk channel in that run**, clips of 15.6, 18.8, 21.9 and 25.2 MB were queued, and 81–82 MB bundles were written on the device beside them. Every component of [#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27) that read *"built, uncalled"* is called.

⛔ **What it took was mostly making the path speak, not making it work.** Four things had to be fixed first and every one of them was invisible:

| | |
|---|---|
| `serveCaptureRequest` **extracted on arrival** | The host's request lands ~300 ms after impact and asks for a second *after* it, so the ring could never hold the end of the swing. It now waits for `t0 + post + one fragment interval`, bounded by the ring's depth (`4ba514e`) |
| The drain loop **swallowed every throw** | `(try? …) ?? 0` turned a throw into zero bytes into a 20 ms sleep, for ever — the host read `transfer: pending` and the phone's own row said `sending` ([#110](https://github.com/PinPoint-Golf/PinPointCapture/issues/110), `6a52651`) |
| The phone's log **could not be read** | `os_log` needs `idevicesyslog`, which carries none of it; `devicectl --console` bridges stdout while holding a tunnel that **re-enumerates the device and kills the link under measurement**. Every category now also goes to a bounded file in `Documents`, pulled with `make pull-diags` (`97133f1`) |
| A clip **misdescribed its own frames** | `FragmentRing.extract` clipped the frame list to the request while the payload carried every frame of every overlapping fragment — 838 in the file, 719 listed. A fragment decodes whole and is sent whole (`c848b95`) |

⛔ **Three faults the run surfaced, all new**: 86 × `pump FAILED libppcp: output buffer too small` ([#119](https://github.com/PinPoint-Golf/PinPointCapture/issues/119)) with the bytes going anyway; 16 × `announce WITHOUT payload — nothing will follow it` ([#120](https://github.com/PinPoint-Golf/PinPointCapture/issues/120)); and every `capture_request` answered **`partial`**, never `complete`.

⚠ **And the honest limits of the claim.** The swing was **injected** — `CONF` §2a's method, and the camera is the part that cannot be — so [#21](https://github.com/PinPoint-Golf/PinPointCapture/issues/21) E2.1 is untouched. No `capture_committed` has ever arrived, so `In Studio` is still a state nothing can reach. ⚠ **[#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27) closed on 2 September with its exit criterion — `make conform` on the device, closing CT-S3 — still unrun**, on the same reading that closed [#19](https://github.com/PinPoint-Golf/PinPointCapture/issues/19): a conformance run is the claim's obligation rather than the level's. Recorded here rather than dropped, because the claim still says `blocked: a phone`.

### 3.3 ✅ (b) — preview: DONE 28 August, and it had never once worked

⛔ **Promoted to the next tranche after [#98](https://github.com/PinPoint-Golf/PinPointCapture/issues/98)** — Mark, 25 August: *"preview and config in PPS (from preview stream in PPC) and then actual capture and transmission post shot."* The reason was sound: **preview is the first thing that makes the link visible to a human.**

✅ **It works.** `2f604b1`, against `libppcp@a9785bb` and PinPointStudio `83e5afd`: a picture in **Settings → Cameras** with nothing pressed on the phone, 600+ segments in one run, `tapped == sent`, zero decode failures. [#108](https://github.com/PinPoint-Golf/PinPointCapture/issues/108)'s acceptance test — *"if a picture requires anything to be pressed on the phone first, this is not done"* — passes.

⛔ **And before that, no preview frame had ever left this application.** Not intermittently: `PreviewProducer.deliver` could not succeed as written. Nine defects across three repositories, five stacked on the delivery path, each invisible until the one in front of it was cleared. The full record is [#117](https://github.com/PinPoint-Golf/PinPointCapture/issues/117); §4c has what a reader of *this* document needs.

⚠ **The order question this section raised on 25 August is answered, and the answer was not the one expected.** It asked whether preview needs sync to settle first. It does not — but it turned out to need something this document never considered: **an instrument**. Five defects sat behind one swallowed error each and produced identical silence at both ends. What found them was three counters and a named reason, not reasoning about clauses.

**What is left of (b), and none of it blocks (c):**

| | | Status |
|---|---|---|
| [#109](https://github.com/PinPoint-Golf/PinPointCapture/issues/109) | ✅ **CLOSED 28 Aug.** Three tests in `LiveLinkTests.swift`, and both reverts were run: undoing the `.present` fix fails 3, undoing the chunking fails 1. Suite 308 green | ✅ Done |
| [#110](https://github.com/PinPoint-Golf/PinPointCapture/issues/110) ⛔ | The `try?` audit on the delivery path | ⚠ **Half done.** The drain loop, `serveCaptureRequest`'s five silent guards and the recording-error surface all speak now, and found [#119](https://github.com/PinPoint-Golf/PinPointCapture/issues/119) and [#120](https://github.com/PinPoint-Golf/PinPointCapture/issues/120) within an hour. **27 `try?` remain in `HostLinkSession.swift`**, including `reportResidual` |
| [#111](https://github.com/PinPoint-Golf/PinPointCapture/issues/111) | The `print("[preview] …")` instrumentation, converted keeping its shape (E10) | Todo — ⚠ **the destination now exists** (`PpcpLog` + `PpcpDiagnostics`) and the thirteen preview call sites are still `print`, which on a cabled phone means unreadable |
| [#112](https://github.com/PinPoint-Golf/PinPointCapture/issues/112) | ⚠ **The arm transition — measured 2 Sep, half answered.** Preview survives the arm (554 → 734 segments), costs the ring nothing (↕4 ms) and returns across a re-arm | ⛔ Still open: the `absent`-segment-with-a-reason branch never fired, because the picture was never lost |
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
3. ✅ Sync burst runs. The device reports `.connected` with a real offset and uncertainty on B3 — **not** a fixture. Measured 2 Sep: **± 1.31 ms before arming**, inside 6.1f's 5 ms arbitration gate.
4. ✅ **Preview appears in Studio** — and it does, since 28 Aug ([#108](https://github.com/PinPoint-Golf/PinPointCapture/issues/108)). ⚠ It appears at **step 2**, not here: the picture is live from connect, before any of steps 3–5. Watch it survive step 5's arming — [#112](https://github.com/PinPoint-Golf/PinPointCapture/issues/112).
5. Hit a ball. Within a second: `candidate` on control, then `shot`, then `capture_announce`, then the clip on bulk — and the device's own row turning `In Studio` when the host confirms. ⚠ **Everything but the ball has happened** (§3.2a): the host arbitrates, asks with `capture_request`, and gets 25 MB. ⛔ Two things are still unproven here — a **real** strike ([#21](https://github.com/PinPoint-Golf/PinPointCapture/issues/21)) and `In Studio`, which needs a `capture_committed` no host has ever sent.
6. Five shots, no reconnect.
7. ✅ **Done, 2 Sep.** Close the app and reopen it; the device reconnects **with no pairing step and no code**. All four steps proven on hardware (§2.2c), four times in one run over Wi-Fi. ⚠ Still worth running once with the host's address deliberately changed, since that is the case the mechanism was chosen for — and once with multicast blocked, which [#66](https://github.com/PinPoint-Golf/PinPointCapture/issues/66) closed without doing (§2.2c).

### 4.2 The check that (d) stayed honest

✅ **Checked on 2 September, and it holds.** The device suite's last row reads the library after a hosted session: **81 MB and 82 MB bundles**, each carrying the session's shot and a clip with real bytes, written while the same records went over the wire. ⚠ The assertion is deliberately `byteCount > 1 MB` — a bundle with a thumbnail and no clip is [#98](https://github.com/PinPoint-Golf/PinPointCapture/issues/98)'s shape, and it is the failure this step exists to catch.

⚠ On a real session afterwards: five clips in the library with thumbnails, against five that crossed. If this step fails, "online only" has become "online or nothing", which is a different product.

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

## 4d. What changed 29 August – 2 September: the cable, the rig, and the first clips

Five days, twenty commits, and the shape of the remaining work changed rather than the amount of it shrinking. **§7.2 said, from 28 August, that the critical path was one afternoon with a phone.** That afternoon happened, most of it is now a `make` target, and what it found was not what the list expected.

### ✅ A second transport, which the MVP did not have — [#64](https://github.com/PinPoint-Golf/PinPointCapture/issues/64) E15.1 closed 31 Aug

⛔ **usbmux inverts `RV` 2d: on a cable the *host* dials us.** No USB `PeerTransport` was written and writing one would have been wrong — usbmux presents a plain TCP socket on loopback, so TLS runs over it unchanged and the transport on the cable **is** `PpcpListener`, bound to 127.0.0.1 instead of all interfaces. What the level actually needed was `RV` §3 advertisement semantics delivered over a cable, and a listener lifecycle.

- **The device publishes what it registered** (`adbb70c`). Network.framework's listener registers exactly one `(key, identity)` pair up front and cannot resolve a rotating PSK identity — which is *why* 3.5d puts advertising on the host — so one `PpcpListener` per held pairing, each on its own ephemeral port, and `WiredPresence` lists them. ⛔ Both listeners bind **127.0.0.1** via `requiredLocalEndpoint`: the record is plaintext and names every pairing the device holds, so an all-interfaces bind would turn it into a LAN broadcast of the pairing set. It also keeps the wired path outside the iOS local-network permission entirely.
- **The cable was unreachable unless someone opened a window** (`8201ec8`). The presence listener came up only during the connect flow, so outside it port 50915 was closed and PinPointStudio knocked every two seconds all session. *"Restart the capture app"* was the universal remedy all day, which is what masked it. A 2 s reconcile now holds one rule: a pairing is held, no link is up, the app is active, therefore the listener is up publishing the **current** set.
- **Preview over the cable** (`e2a9f70`). `openPreviewChannel()` answered `false` to anything that could not dial, and over a cable this end never can — so every preview Stream on a cabled link was refused `no_preview_channel`, a black tile with nothing in either log. It now waits for the channel to be bound **inbound**, bounded at five seconds because 2.1d makes the third stream optional. ⚠ The host half is a matching change in PinPointStudio; neither works alone.
- ⛔ **Two receive loops read the cabled preview channel and the link died of it** (`c382888`). `start()` loops over `channels()`, which on a cable already includes preview; `attachPreview()` added a second loop on the same connection, so the byte stream split between two tasks and the TLS state machine was driven from two places. **That is the whole wired/Wi-Fi asymmetry**: over Wi-Fi this end dials preview *after* `start()`, so only one loop ever ran. Measured after the fix: one cabled run of **15m26s carrying 168 MB of preview**, against a pre-fix typical life under two minutes.
- ⚠ **An optional channel failing is no longer the link failing.** `receiveLoop` called `stop()` for any channel's error and `stop()` closes every channel, so one preview blip took control and bulk with it. 5.11i/5.11j put preview first in line to degrade — losing it means "no picture", not "session over".

⛔ **The residual fault is still there and is not ours**: the phone sees all three channels end cleanly in the same millisecond while Studio sees a broken pipe, which is the transport being pulled from under both rather than either end choosing to close.

### ✅ The hardware run became a `make` target

```
make integration-device STUDIO=<binary> [EXPECT_CLIPS=1]
```

It starts PinPointStudio offscreen under its probe, runs the device suite on the phone, pulls the phone's own diagnostics off the device, prints **both** sides' verdicts and leaves a timestamped directory holding host log, device log, phone log and the usbmux stream. `make integration` already did this and ran the **simulator**, which has no camera and can therefore never produce a clip — the one thing the swing leg needs proving.

⚠ **Both halves decide the verdict, and that is not tidiness.** The device half was first written with `|| true`, so a device suite that never ran would report a pass on the host probe alone — *a false green sitting inside the rig that exists to prevent false greens*.

Three faults in the harness had to be cleared before it said anything true:

| | |
|---|---|
| ⛔ **The suite dialled itself four times and refused three** (`c4019c3`) | Four tests dial independently and swift-testing ran them concurrently in one process — and one process has one `PeerIdentity.current`. All four declared the **same peer id**, so PinPointStudio's "one phone, one link" rule kept the incumbent and closed the rest. `.serialized` added. ⛔ The host's rule is correct and was not touched: changing a product to accommodate a test harness would have been the wrong repair |
| ⛔ **It armed before the clocks agreed** (`8185afc`) | It waited twelve seconds, armed, held the link, and passed — while Studio's worst sigma never came below 23 ms, so it never started a capture session and **every arbitrated Shot was dropped**. Green, with the leg it exists to prove unrun. It now polls for 6.1f's 5 ms gate first, up to three minutes, because two sits exactly on the convergence boundary |
| ⛔ **It disarmed before the host asked** (`6c4b3f6`) | `retainedClip` answers instantly once `disarm()` closes the ring, and 8.2h holds a group open before issuing — so disarming on a timer answered *"I have nothing"* to a question that had not been asked yet, which from the host is indistinguishable from a device that never had the footage |

### ✅ And then the first clips, 2 September

The numbers are in §3.1a and §3.2a. What is worth carrying forward is the pattern, because it is the same one 28 August recorded: ⛔ **every one of these was a silence, not a failure.** A torch that went out with nothing in the log; a `capture_request` answered in one millisecond with the wrong word; a drain loop retrying fifty times a second for ever; two Captures a session announced with nothing behind them. **The instrument found all of them and clause-by-clause review had found none of them in three days of trying.**

⚠ One item on the list turned out to be a phone problem rather than a link problem: `18197d1`'s torch died **~1 s after `arm()` returned**, with `torchMode` reset by the platform itself and none of arm's five steps seeing it. A host-commanded torch is now re-asserted at the end of arm, at settled, and from the health tick for five seconds — and the re-light is reported as a 12.2a `actuator_state`.

### Four smaller things, none of them in (a)–(d), all of them things a person saw

- **The phone drew a Wi-Fi symbol while it was on a cable** (`179ab3f`). `CaptureScreenStyle.symbol(for:)` returned `wifi` for every live host state — not merely uninformative but wrong, in the one place a golfer looks to see how the phone is talking to the Studio. Reported by Mark, who looked at the screen.
- **The phone says which way it reached the Studio** (`ac151c8`). B3's connected telemetry grows a *Connection* row reading Cable or Wi-Fi, from the session's **listener flag** — the honest source, because iOS reports `.charging` for a wall socket and this device genuinely cannot see a cable. What it can see is that the host dialled *it*, which only happens over usbmux. ⚠ `nil` renders as a dash and must never default to Wi-Fi.
- **A Studio renamed after pairing kept its old name for ever** (`2460d92`). The pairing code names a host once and a persisted pairing has no expiry (7.4a), so one phone tested against macOS, Linux and Windows listed three machines under one indistinguishable label. `declare` arrives on every connect, so the name is refreshed from the wire — and `rename()` moves the display name and **nothing else**, because rewriting key material on a cosmetic change is a way to lose a pairing.
- ⚠ **A host's disarm now leaves the camera warm** (`18197d1`), so preview and the torch persist between buckets — which is the nearest thing yet to §4a's open question about whether *Disarm* should pause rather than end.

---

## 5. Explicitly out

| Out | Why |
|---|---|
| [#28](https://github.com/PinPoint-Golf/PinPointCapture/issues/28) E3.5 — network recovery ✅ **CLOSED 2 Sep** | A dropped link ends the demo rather than surviving it. ⚠ **Out of date as a statement about the code**: it is built, `03a25a6` gave 4.3b's ordering the test it never had, and `8201ec8` made a link that dies while the app is foregrounded recover on its own. Out of the *demo*, not out of the tree |
| [#26](https://github.com/PinPoint-Golf/PinPointCapture/issues/26) E3.3 — arm from host ✅ **CLOSED 2 Sep** | Nice to have. Arm on the device. ⛔ **This row is now simply wrong and is kept to show it moved**: as of 2 September **the host arms this device and the device test waits for it**, the torch is a CR-02 Actuator answering `actuator_command` with the state the hardware achieved, and a host's disarm leaves the camera warm. Host control is in the product, not in the "out" list |
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
   1    device session    ✅ DONE — #17 CLOSED 2 Sep, last number read, contradiction retired (§3.1a)
        ▼
   2    sync (#25)        ✅ DONE 26 Aug — HostLinkDriver composed, converges live against Studio
        ▼
   3    preview (#108)    ✅ DONE 28 Aug — a picture at connect; and over the CABLE 31 Aug (§4d)
        ▼               ⚠ Studio's viewer landed with it; the CONFIG half is #118 and unscoped
        ▼
   3a   the cable         ✅ #64 E15.1 CLOSED 31 Aug — a second transport the MVP never had (§4d)
        ▼
   3b   THE HARDWARE RUN  ✅ MOSTLY RUN 1–2 Sep, and it is now a make target: integration-device
        ▼               and #17 #18 #19 #26 #27 #28 #66 all CLOSED on it (§7.2)
        ▼
   4    shots crossing    ✅ WATCHED 2 Sep — host arbitrates, asks, gets 25 MB (§3.2a)
        ▼               ⚠ #27 closed with CT-S3 unrun; the run is the CLAIM's debt now
        ▼
   5    a real strike     ⛔ NEXT, AND THE ONLY THING LEFT — #21 E2.1
        ▼
   6    demo — every step but 5 has now been watched working, on a phone
```

⛔ **The critical path is a phone with a mat in front of it, and it is now one item long.** Everything a keyboard can reach is built, green, and — since 2 September — watched running against a real Studio. What is left on the board is **a club hitting a ball** ([#21](https://github.com/PinPoint-Golf/PinPointCapture/issues/21)).

⚠ **Two things were never run and their levels closed anyway** — the conformance driver on the device, and one network cable pulled mid-session. Neither is owned by an open issue any more. That is a deliberate call about what a *level* owes versus what a *claim* owes, and it is recorded in §7.2 and §7.3 so that it stays a decision rather than becoming an assumption.

⚠ **Budget a wiring pass per level** (§3.0a). Three defects on 25 August were all "written, correct, never called", and this target cannot test for that. ⛔ **28 August added the harder version of the same lesson**: five defects were written, called, *and reached* — and still did nothing, because every error on the path was swallowed. A wiring pass is not enough on its own; the path needs an instrument that counts (§4c).

---

## 7. Board coverage — every MVP requirement, and the issue that owns it

⚠ **Why this section exists.** This document and the board drifted: §3.0 claimed [#100](https://github.com/PinPoint-Golf/PinPointCapture/issues/100) closed when only half of it was, §5 listed [#26](https://github.com/PinPoint-Golf/PinPointCapture/issues/26) and [#28](https://github.com/PinPoint-Golf/PinPointCapture/issues/28) as *"out"* long after both were built, and the whole of E2 — without which requirement (c) has no candidate to send — was never sequenced anywhere in §6. **Audited against the board 28 August 2026, and re-audited 2 September** after four days in which the drift ran the other way: the board understated what a phone had proved.

### 7.1 The requirements

| | Requirement | Owned by | Status |
|---|---|---|---|
| **(a)** | Finds Studio and connects, by code once and never again | [#16](https://github.com/PinPoint-Golf/PinPointCapture/issues/16) E16 ✅ ([#66](https://github.com/PinPoint-Golf/PinPointCapture/issues/66), [#67](https://github.com/PinPoint-Golf/PinPointCapture/issues/67), [#68](https://github.com/PinPoint-Golf/PinPointCapture/issues/68)) | ✅ **Done — the whole epic closed 2 Sep.** The dial completes over Wi-Fi with no code (§2.2c). ⚠ Three of its checks were closed without being run: the deliberate multicast failure, a real device restore (RT-15), and a hotspot join |
| | *and over a cable* | [#15](https://github.com/PinPoint-Golf/PinPointCapture/issues/15) E15 ✅ ([#64](https://github.com/PinPoint-Golf/PinPointCapture/issues/64) ✅, [#65](https://github.com/PinPoint-Golf/PinPointCapture/issues/65)) | ✅ **E15.1 closed 31 Aug, the epic 2 Sep** — on the ground that the remainder is rendezvous work, not transport work. ⛔ A *first pairing* over the cable is still not built — `onUseCable: {}` at `RootView.swift:427` — and [#65](https://github.com/PinPoint-Golf/PinPointCapture/issues/65) is the only rendezvous item left open |
| | *first contact without a code at all* | [#94](https://github.com/PinPoint-Golf/PinPointCapture/issues/94) F-MVP-1 | ⛔ **Closed 2 Sep — *"wont do"*.** The change request against `RV` 2c is not being pursued, so **the code stays REQUIRED for a first pairing** and nothing in v1 pairs without one |
| **(b)** | Preview | [#108](https://github.com/PinPoint-Golf/PinPointCapture/issues/108) ✅ · [#107](https://github.com/PinPoint-Golf/PinPointCapture/issues/107) ✅ · [#109](https://github.com/PinPoint-Golf/PinPointCapture/issues/109) ✅ | ✅ **Done 28 Aug**, and over the cable 31 Aug |
| | *preview residue* | [#110](https://github.com/PinPoint-Golf/PinPointCapture/issues/110) [#111](https://github.com/PinPoint-Golf/PinPointCapture/issues/111) [#112](https://github.com/PinPoint-Golf/PinPointCapture/issues/112) [#113](https://github.com/PinPoint-Golf/PinPointCapture/issues/113) [#114](https://github.com/PinPoint-Golf/PinPointCapture/issues/114) [#115](https://github.com/PinPoint-Golf/PinPointCapture/issues/115) [#116](https://github.com/PinPoint-Golf/PinPointCapture/issues/116) | ⚠ #110 half done, #112 half answered on hardware; the rest todo. None blocks (c) |
| | Hi-res capture | [#17](https://github.com/PinPoint-Golf/PinPointCapture/issues/17) E1.1 ✅ · [#18](https://github.com/PinPoint-Golf/PinPointCapture/issues/18) E1.2 ✅ · [#19](https://github.com/PinPoint-Golf/PinPointCapture/issues/19) E1.3 ✅ | ✅ **All three closed 2 Sep** on a real sensor (§3.1a). ⚠ Only E1.4's bitrate is left in E1, and it is out of MVP |
| | *bitrate* | [#20](https://github.com/PinPoint-Golf/PinPointCapture/issues/20) E1.4 | Out of MVP (§5) — the 50 Mbps placeholder holds |
| | *config from Studio* | [#118](https://github.com/PinPoint-Golf/PinPointCapture/issues/118) | ⛔ **Newly filed.** §3.3's other half, unowned since 25 Aug |
| **(c)** | Every **shot** reaches Studio | [#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27) E3.4 ✅ | ✅ **Closed 2 Sep.** It crossed — 25 MB answered to a host's `capture_request` (§3.2a). ⚠ Closed with CT-S3 unrun, deliberately |
| | *the host's half of the loop* | [#26](https://github.com/PinPoint-Golf/PinPointCapture/issues/26) E3.3 ✅ | ✅ **Closed 2 Sep.** The two halves met — the host arms this device and commands its torch, and the ack carries what the hardware did. ⚠ Closed over its criterion's second clause, which cites RT-10 (`session_resume`) and does not read on arming |
| | *faults the crossing surfaced* | [#119](https://github.com/PinPoint-Golf/PinPointCapture/issues/119) [#120](https://github.com/PinPoint-Golf/PinPointCapture/issues/120) | ⛔ **Newly filed, 2 Sep.** 86 failed pump passes and 16 announces with nothing behind them, in one run |
| | Every **candidate** reaches Studio | [#21](https://github.com/PinPoint-Golf/PinPointCapture/issues/21) E2.1 | ⛔ **Unmoved, and now the whole of the critical path.** Every swing so far has been injected; a real strike minting a Shot has never happened |
| | *candidates you can trust* | [#22](https://github.com/PinPoint-Golf/PinPointCapture/issues/22) E2.2 | Out of MVP — (c) says candidates cross, not that they are all real |
| **(d)** | Online only | — | A subtraction. Its check is §4.2, deliberately not an issue |

### 7.2 ✅ The hardware session happened — and most of it is a `make` target now

**Six of the eight tests have run**, on 1–2 September, against a live PinPointStudio with an iPhone 16 on the desk. `make integration-device` drives both products and reads both verdicts (§4d); the device half alone is `make test-device`, **13 rows, all green, 385 s**. [`hardware-run-2026-08-27.md`](hardware-run-2026-08-27.md) remains the script for the parts a person still has to do.

| Test | What it said | Issue |
|---|---|---|
| 1 — a clip exists at all | ✅ **RAN.** 15.0 MB, one video track, 2.500 s, 599 frames at 239.49 fps, thumbnail at the anchor | [#18](https://github.com/PinPoint-Golf/PinPointCapture/issues/18) **closed** |
| 2 — preview across the **arm transition** | ⚠ **RAN, half answered.** 554 → 734 segments across the arm, ↕4 ms on the ring, returns across a re-arm. ⛔ The `absent`-with-a-reason branch never fired, because the picture was never lost | [#112](https://github.com/PinPoint-Golf/PinPointCapture/issues/112) open |
| 3 — a swing crosses | ✅ **RAN, injected.** `capture_request` → converted → waited for the post-roll → 25 MB queued → 82 MB bundle | [#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27) **closed** |
| 4 — host control, the two halves meeting | ✅ **RAN.** `armed by the host after 0 s`; torch commanded, applied, and acked with the state the hardware achieved | [#26](https://github.com/PinPoint-Golf/PinPointCapture/issues/26) **closed** |
| 5 — **the network drops** | ⛔ **NEVER RUN**, and [#28](https://github.com/PinPoint-Golf/PinPointCapture/issues/28) closed anyway on 2 Sep. The code is complete and unit-tested — `session_resume` before the burst before the payload, the gap window, the queue restarting at `ackedIndex + 1` — but no phone has had its Wi-Fi pulled mid-session, so *"capture never stops and six shots queue"* is reasoned, not observed | [#28](https://github.com/PinPoint-Golf/PinPointCapture/issues/28) **closed** |
| 6 — the residual, REQ-SYNC-4 | ⚠ **RAN**, `residual=0.0 ms` at ± 1.29 ms agreement. A weak reading: the host adopted our own injected instant, which is not two detectors agreeing | [#28](https://github.com/PinPoint-Golf/PinPointCapture/issues/28) **closed** |
| 7 — reconnect with no code | ✅ **RAN, four times in one run**, over Wi-Fi, nobody touching the phone (§2.2c) | [#66](https://github.com/PinPoint-Golf/PinPointCapture/issues/66) **closed** |
| 8 — the honesty check | ✅ **RAN.** 81 MB and 82 MB bundles on the device carrying the shot and a clip with real bytes, beside what went over the wire | (d), §4.2 |
| *afterwards* — `make conform` on the device build | ⛔ **UNRUN, and no longer owned by any level** — [#19](https://github.com/PinPoint-Golf/PinPointCapture/issues/19), [#26](https://github.com/PinPoint-Golf/PinPointCapture/issues/26) and [#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27) all closed over it. It lives on only in `ppcp-conformance.md`, where CT-S7 (4), CT-S1 (1–5), CT-I30, IOP-2 and CT-S3 stay `blocked: a phone` | ⚠ **no issue** |
| *a real club strike at a real mat* | ⛔ **UNRUN.** Every swing so far has been injected audio through the real detector | [#21](https://github.com/PinPoint-Golf/PinPointCapture/issues/21) |

⚠ **The rig had to be fixed before it could say anything true**, and all three faults were in this repository: four tests declaring one peer id and being closed by the host's duplicate rule; arming twelve seconds after connect rather than waiting for the 5 ms sigma gate, so every arbitrated Shot was dropped and the row passed anyway; and disarming on a timer before the host had asked for the clip. §4d has them.

✅ **The profile/level question this section asked on 28 August is answered.** At level 5.1 Main tier caps at 40 Mbit/s and this application asks for a provisional 50, so *"nobody knows which yet"* was a real risk. The encoder's own `hvcC` reads **High tier** — the ask is inside the level it declares. E-M2 still owns the bitrate itself ([#20](https://github.com/PinPoint-Golf/PinPointCapture/issues/20)).

⛔ **One item on this list is owned by an open issue, and it is [#21](https://github.com/PinPoint-Golf/PinPointCapture/issues/21)'s real strike.** The other two that were never run — test 5's dropped link, and the conformance driver on the phone — are now behind **closed** levels. That is a deliberate call and not drift; it is written here so that a later reader meeting a green board does not conclude they were run.

### 7.3 What could not be closed, and why — re-audited 2 September

⚠ Audited one by one rather than assumed. **120 issues, all on the project**, and no board status disagrees with its issue state.

✅ **Closed on 2 September, and it is most of the MVP**: [#17](https://github.com/PinPoint-Golf/PinPointCapture/issues/17) E1.1 and [#18](https://github.com/PinPoint-Golf/PinPointCapture/issues/18) E1.2 against their own criteria; [#19](https://github.com/PinPoint-Golf/PinPointCapture/issues/19) E1.3, [#26](https://github.com/PinPoint-Golf/PinPointCapture/issues/26) E3.3 and [#27](https://github.com/PinPoint-Golf/PinPointCapture/issues/27) E3.4 **over** their criteria, all three of which were the same on-device conformance run; [#28](https://github.com/PinPoint-Golf/PinPointCapture/issues/28) E3.5 with its network-drop run never done; [#66](https://github.com/PinPoint-Golf/PinPointCapture/issues/66) E16.1 with the deliberate multicast failure never driven, and with it [#67](https://github.com/PinPoint-Golf/PinPointCapture/issues/67) E16.2 and [#68](https://github.com/PinPoint-Golf/PinPointCapture/issues/68) E16.3, neither exercised on a device; the epics [#3](https://github.com/PinPoint-Golf/PinPointCapture/issues/3) E3 and [#16](https://github.com/PinPoint-Golf/PinPointCapture/issues/16) E16 behind their levels; [#15](https://github.com/PinPoint-Golf/PinPointCapture/issues/15) E15, on the ground that a first pairing over a cable is rendezvous work and not transport work; and [#94](https://github.com/PinPoint-Golf/PinPointCapture/issues/94) F-MVP-1 — *"wont do"*. Earlier: [#64](https://github.com/PinPoint-Golf/PinPointCapture/issues/64) E15.1, 31 August, with its criterion **reworded on closing and recorded as a rewording** (§4d).

⛔ **Eight levels closed over an unrun test, which is a legitimate call and a fragile record.** Each is named above and in §7.2 rather than folded away, because the board now shows green where nobody has watched the thing work. The full list of what was never done: **the conformance driver on the phone** (#19, #26, #27), **a Wi-Fi pull mid-session** (#28), **multicast blocked on purpose** (#66), **a real device restore** (#67), and **a hotspot join** (#68).

| | Why it stays open |
|---|---|
| [#21](https://github.com/PinPoint-Golf/PinPointCapture/issues/21) | ⛔ **The only MVP requirement still open.** A real club strike at a real mat has never happened; every swing has been injected audio through the real detector |
| ⚠ *no issue* | ⛔ **A real device restore (RT-15)**, and **a hotspot join on a device**. [#67](https://github.com/PinPoint-Golf/PinPointCapture/issues/67) and [#68](https://github.com/PinPoint-Golf/PinPointCapture/issues/68) closed on 2 September without either being done. #68 also carried the *Hotspot Configuration on the App ID* entitlement, which [#82](https://github.com/PinPoint-Golf/PinPointCapture/issues/82) E-R2 still lists as a submission requirement |
| ⚠ *no issue* | ⛔ **`make conform` on the device**, and **the network-drop run**. Both were exit criteria until 2 September and both are now behind closed levels. `ppcp-conformance.md` still carries the first as `blocked: a phone`; the second is carried nowhere |
| [#65](https://github.com/PinPoint-Golf/PinPointCapture/issues/65) | ⛔ Explicitly not met, and honestly so: `onUseCable: {}` at `RootView.swift:427`. The machinery exists — `WiredPresence` carries no `rid` so a scanned-but-unconnected code can ride the record — and nothing calls it |
| [#99](https://github.com/PinPoint-Golf/PinPointCapture/issues/99) | ⛔ Still real. `arm()`'s `guard let recording, let mode` still returns after `startRecording()` opened a Session and without unwinding it — checked against the current tree, not the issue text |
| [#100](https://github.com/PinPoint-Golf/PinPointCapture/issues/100) | Half-shipped. [#104](https://github.com/PinPoint-Golf/PinPointCapture/issues/104) delivered whole-session deletion; **per-shot** deletion and the manifest-rewrite question are this issue's actual criterion |
| [#92](https://github.com/PinPoint-Golf/PinPointCapture/issues/92) | An umbrella with no crisp criterion, and deliberately so — it is the "mid-integration" record |
| [#94](https://github.com/PinPoint-Golf/PinPointCapture/issues/94) | ✅ **Closed 2 September — *"wont do"*.** The change request against `RV` 2c is not being pursued. ⛔ **The consequence is a product fact, not a paperwork one: a first pairing always needs the code**, on every transport, in v1. The cable had already answered the *reconnection* half by moving identity resolution to the client |
| [#105](https://github.com/PinPoint-Golf/PinPointCapture/issues/105) | ⛔ Needs `libppcp` — a `shot_disposition` message, so a rejected Shot stops queueing for ever. ⚠ [#106](https://github.com/PinPoint-Golf/PinPointCapture/issues/106) **closed 2 Sep** on the estimate reaching **−1588 ppm at ± 1.29 ms**, against −184515 ppm and ± 36.77 ms when it was raised. It closed without the prober-side twin of `ppcp_peer_sync_reply_stamps`, and 1588 ppm is still an order of magnitude above real crystal skew — usable rather than right |
| [#110](https://github.com/PinPoint-Golf/PinPointCapture/issues/110) [#111](https://github.com/PinPoint-Golf/PinPointCapture/issues/111) [#112](https://github.com/PinPoint-Golf/PinPointCapture/issues/112) | Preview and delivery residue — #110 half done, #112 half answered on hardware, #111 untouched with its destination now built |
| [#113](https://github.com/PinPoint-Golf/PinPointCapture/issues/113) [#116](https://github.com/PinPoint-Golf/PinPointCapture/issues/116) | Joint with PinPointStudio |
| [#115](https://github.com/PinPoint-Golf/PinPointCapture/issues/115) [#118](https://github.com/PinPoint-Golf/PinPointCapture/issues/118) | Decisions, and neither is mine to take |
| [#119](https://github.com/PinPoint-Golf/PinPointCapture/issues/119) [#120](https://github.com/PinPoint-Golf/PinPointCapture/issues/120) | ⛔ **Filed 2 September** from the run that made (c) work — a payload pump that fails 86 times and delivers anyway, and Captures announced with nothing to follow them |

⛔ **The honest summary has changed twice in a week.** On 28 August it was *"the code is not what is holding the MVP — one afternoon with a phone would resolve more of this board than any amount of further building."* That afternoon happened on 1–2 September and it did exactly that. As of the evening of 2 September the board's answer is: **one club, one ball, one mat** ([#21](https://github.com/PinPoint-Golf/PinPointCapture/issues/21)).

⚠ **And the caveat that belongs beside it.** **Five** runs this document listed as the critical path were never done, and their levels closed regardless — the on-device conformance run, the mid-session network drop, the deliberate multicast failure, a real device restore, and a hotspot join. **Nothing on the board will remind anyone of that now**, which is why it is written here in the section whose whole job is to stop this document and the board drifting apart. ⚠ It is also the exact failure mode §7 was created for on 28 August, running in the opposite direction: the board then understated what a phone had proved, and now it overstates it.
