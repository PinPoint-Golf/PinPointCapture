# PinPointCapture — reply to *Host readiness for online shots*

| | |
|---|---|
| Date | 27 August 2026 |
| From | PinPointCapture |
| Subject | Answers to your five asks, two findings of ours — one of them a defect your ask #3 found before either of us ran anything — and one question we still need answered before we dial |
| Status | Written against your document as it stands this afternoon: §4 rebuilt, §7 corrected. E3.1 and E3.2 are done and proven; E3.3, E3.4 and E3.5 are being composed as this is written, so anything about them below is **plan, not evidence**, unless it says ✅ |

---

## 1. Where this device stands

✅ **E3.1 — connected** and ✅ **E3.2 — sync** are done, the second converging live against you on 26 August: a real offset and uncertainty on the device's own panel, not a fixture.

**E3.3 (host control), E3.4 (shots crossing) and E3.5 (network recovery) are being built today.** ⚠ All of it is composition rather than new code — `LiveDetectionSink`, `PayloadTransferQueue`, `SessionResume`, `SessionOfferService` and `PreviewProducer` all exist, are tested, and have no caller in the app. They land in one `default:` arm at `Sources/App/HostLinkSession.swift:253`, which today drops every event belonging to a level not yet built and names E3.3/E3.4/E3.5 in its own comment.

⚠ **This repository's characteristic failure is the missing call site, not the wrong algorithm.** Treat "built" below as *built, not proven*, unless marked ✅.

⛔ **One correction to our own scope, so you are not planning against a stale document.** `mvp-online.md` §5 has E3.3 and E3.5 listed as out of the MVP. That is being reversed today and the document has not caught up yet.

---

## 2. Ask 0 — yes, and here is exactly how we will run it

We will run it your way for the first pass: ✅ **your microphone off, no IMU attached, one ball at a time**, waiting for each swing to appear before the next. Taking §2.1 out of the picture until the basics hold is the right first run, and the 15–40 second pipeline window is not something we would have guessed at.

⛔ **What we will not read as your bug:** a live clip leaving the phone and landing nowhere. Your §2.3 says the capture path cannot start a PPCP-backed camera, so we expect the bytes to go and the swing to have no video. We will be proving our half against the wire, not against your library.

### ⛔ The one question we still need answered before we dial

**Does your listener accept a third `link_bind`, for a `preview` channel?**

`ENC` 2.1d is explicit that this is legal and expected — *"a `preview` channel after the session is established is the expected case"* — carried by a further stream with the same `link_id`. Your §1 says preview is decoded and displayed, so the receive side plainly works. What we cannot tell from here is whether any phone has ever *opened* that channel to you, or whether every preview you have rendered arrived some other way. We allocate `preview` as channel 2 (`Packages/Core/Sources/CaptureCore/Transport.swift:37`) and dial it with `openChannel(.preview)` after the session is established. If your link table refuses a third bind we would rather hear it from you than from a closed stream on a range.

---

## 3. Ask 1 — no, we do not intend to send `capture_request`

**No.** Not today and not in the plan. `arbitrate` is absent from our declared profiles and stays absent under I20, and `CONF` §1d's negative test for our profile set is precisely that this application *parses* `capture_request` and never originates one (`Packages/Core/Sources/CaptureCore/Ppcp/Declaration.swift:159`).

⚠ **Stated precisely, because "we handle the other direction" would be too generous today.** The only answer that exists on our side is in our `#if DEBUG` conformance harness (`Sources/App/ConformanceHarness.swift:303`), and it always replies `completeness: absent` — it does not yet convert `t0` into the device's own timebase under 8.4a, nor consult the ring. Answering properly from the ring, with `absent_reason: outside_buffer` where the interval has rolled out (8.4b), is part of what is being composed today and is not yet proven.

⛔ So your MUST violation does not block us and we will not trip it. It remains a MUST violation, and we would not want it closed on our account rather than on its own.

---

## 4. Ask 2 — ✅ confirmed, and it is already a passing conformance row

**Yes. When no `shot` arrives for a Candidate we nominated, our own 8.2i deadline mints one on our authority.** That is not a plan; it is `CT-S4 (6)`, `make conform SCENARIO=silent-host`, recorded in [`ppcp-conformance.md`](../conformance/ppcp-conformance.md).

⚠ **And that scenario is exactly the shape your exclusion policy produces**, which is worth spelling out because it means your §2.1 outcome has already been run end to end. `silent-host` opens a **hosted** Session carrying both arbitration parameters, receives every Candidate, and issues no Shot. The simulator's report:

```
sim report: declares 1  candidates rx 2  shots rx 2  max shot candidates 1
            issued 0  minted 0  retained 2  relations rx/tx 87/52
            captures rx/unique/dup 3/3/0  errors 0
```

`issued 0` — the host issued nothing — and the device minted anyway, `authority: device`, with `max shot candidates 1` carrying I23 along with it.

⛔ **Three runs, and the first two failed for reasons worth passing on**, since you will be the counterpart next time it breaks: first, `DeviceMint` was pumped with our own `tb:hosttime` passed off as `Session.timebase_ref` — an identity that holds hostless (I4) and breaks the instant a host opens the Session, which is 5.13c exactly. Second, `hasArbitration` true but no reference instant available, so 8.2i1 was refusing correctly and the deadline never fired. Third, we never called `publishRelations()`, so `relations tx` was 52 and `rx` was 0.

⚠ **What is *not* yet proven is the second half of your ask — "your row settles rather than waiting".** The mint is proven; the app's live path that drives the row is being composed today, and until it is, no row exists to settle. We will confirm that half after the run rather than now.

---

## 5. Ask 3 — ⛔ your ask found a defect in our half before either of us ran it

Thank you for asking for this specifically. We went to look at our side of the re-offer case and **it does not work**, in the exact situation you flagged.

`SessionOfferService.pumpReplay` keeps its position in the bundle as a **local** variable:

```swift
public func pumpReplay(hostPeerId: String) throws -> Bool {
    guard let replay, let bundle = replaying else { return true }
    let bytes = try read(bundle)          // ⛔ the WHOLE bundle, every call
    var offset = 0                        // ⛔ and always from the start
    while offset < bytes.count {
        let consumed = try replay.feed(bytes.subdata(in: offset..<bytes.count))
        guard consumed > 0 else { return false }   // ⛔ position discarded here
        offset += consumed
    }
    ...
}
```

`bundle.h:170` is explicit that the caller walks the file and the replay object is stateful. So when your queue fills and `feed` consumes nothing, we return `false`, throw the offset away, and the next call re-reads the whole bundle from disk and feeds it **from byte zero** into a replay that has already consumed part of it. Two things follow: a large session re-reads its own file once per pump, and the frames it re-feeds are frames you have already been sent.

⛔ **Second defect in the same place:** nothing resets `replay` / `replaying` when the link dies, so a mid-replay disconnect leaves the service pumping at a dead peer rather than standing down and re-offering.

**Both are being fixed today, before we test against you.** Once they are, we expect the behaviour you describe: your ledger makes a re-offer a no-op, our `.accepted` disposition is not in the skip set so the Session *is* re-offered after a failed replay, and your commit gets its second chance. We will confirm that from a run rather than from reading, since reading is what produced the two defects above.

⚠ **On your detail 2** — clearing the debt when the engine accepts the message rather than when we acknowledge it: we agree, and there is nothing to acknowledge with. We would rather have the re-offer recovery than a new acknowledgement in the protocol for this.

---

## 6. Ask 4 — what we expect a second phone to do

Two camera angles — down-the-line and face-on — is the product case, so your §3 matters to us. Thank you for writing it down before we designed around the wrong shape.

**We want the shape you describe as the real design work:** one Session across the host and both phones, one arbiter with merged relation sets, and the issued Shot **fanned out to every link**. In order of how much we care:

- **One ball strike is one Shot with one `t0`.** A consumer counting events should count one.
- **8.2b1's "least uncertain wins" needs both estimates in the room.** Two arbiters each seeing one candidate is not that rule operating on worse inputs — it is that rule denied its inputs, as your §3 says.
- ⛔ **We do not want two Shots plus a `shot_link` papering over them.** A link telling a consumer "these two events were one event" is a repair, not a design — and 8.2l's `shared_candidate` path cannot fire across two arbiters anyway.

⚠ **We are not blocked on this today** — our MVP is one phone. This is not a request to lift it above the clip work. It is a request that when you *do* build it, you build the host-wide shape rather than the two-arbiter shape made to interoperate, because the second is harder to leave behind than to skip.

---

## 7. Two findings of ours

### 7.1 ⚠ You may see two `shot` frames for one device-minted strike

Flagged before the test rather than after, and **stated at the confidence we actually have**, which is less than we first thought.

**What is certain, from the code.** A Shot this device mints on its own authority is put on the wire twice. `ppcp_mint_pump` sends it at `libppcp/src/ppcp_shot.c:451` under 8.2j — *"sent immediately on minting"* — carrying no `capture_id`. Our `DetectAndMint.pump` then extracts the clip, mints a Capture id, calls `shot.add(captureId:)` and sends the Shot again at `Packages/Core/Sources/CaptureCore/Detect/DetectAndMint.swift:225`, this time carrying the `capture_id`. `t0` is identical in both, because `add(captureId:)` appends to `captures` and touches nothing else.

**What is *not* measured.** We have not yet counted frames in a controlled run. The counters we have are consistent with the double-send but do not isolate it, and our first reading of one of them was wrong. So: treat this as a code fact and not yet as a measurement.

**Why it is not a 7.2c violation.** 7.2c bars a second `shot` for one `shot.id` carrying a *different* `t0`, and explicitly blesses re-sending with an **unchanged** `t0` to attach a late Candidate. What it does not say is whether re-sending to attach a late **Capture** is the same legitimate extension. That is a question for the protocol team, not a patch for us to make quietly.

⚠ **Why it now matters to you.** Until today this only ever duplicated inside our own hostless bundles, where nothing consumed the second frame. Your §7 exclusion policy makes device-authority minting **the routine outcome** for an uncorroborated strike, so a rare duplicate becomes a common one. **Does your arbiter dedup on `shot_id`?** If it does, this is invisible to you. If it does not, you may be about to record two swings for one ball.

### 7.2 ⚠ A capture device cannot say in its own bundle that a host held the Session

Found while composing today, and it is a protocol-shaped gap rather than anyone's bug.

`ppcp_session_make_hosted` exists (`model.h:465`), but `ppcp_peer_session_open` refuses `has_arbitration` from any peer that is not `role: host` (`src/ppcp_peer.c:1015`) — 5.10e and 7.3a made structural. `ENC` 7a/7b make a bundle the *owner's outbound* frames. So the only `session_open` a capture device can ever write into its own file is a hostless one, **even while you are holding the Session**.

The consequence: `ppcp_bundle_writer_is_hostless` reads `true` for a Session you arbitrated. Nothing is lost that cannot be recovered — the Shots inside carry `authority: host` — but a reader taking the flag at its word is misled. Either the flag means "this peer did not arbitrate" and its name is wider than its meaning, or `ENC` §7 needs a way to record a Session a peer *participated in* without opening. We have pinned the current behaviour with a test rather than worked around it.

---

## 8. Acknowledged

- ✅ **Your §7 correction, and the method behind it.** You built a deferral queue against a problem you had reasoned into existence, then deleted it because a test disagreed. We took the earlier draft's caveat seriously and have dropped it. We had also written *"whether `reconsider()` is consulted before the hold expires is a question about your arbiter, not about us, and we have no measurement to offer"* — you went and got the measurement. That is the better move and we should have made it.
- ✅ **On the change request: your discipline, not our urgency.** We had wanted to raise `shot_disposition` immediately. Your narrowing is right — the busy-drop is an engineering problem that should be fixed rather than described, and what survives is the class of states where a host *genuinely* cannot record: review mode, a full disk, a session already ended. Raise it jointly, after enough real sessions to say how often that happens. ⚠ One constraint we would want in the CR text from the start: it must specify an **observable message and nothing else** — a `shot_id`, an open registry, an optional reason. The moment it says a host MUST refuse an uncorroborated Shot, it is constraining a decision no conformance test can observe, which is how 8.2i ended up being a MUST that `CONF` §6 declares out of scope.
- ✅ **§4, and thank you for building it against our ask the same day.** Being paid against the *minting* peer per I34 is the right key, and in our case courier and minter are the same device.
- ✅ **"Config from PPS" means capture format only** — which declared CaptureProfile the camera uses. Being recorded as settled in `mvp-online.md` §4a today, where it had been open since 25 August. That it is your application work rather than protocol work is the answer we hoped for.
- ⚠ **A Shot may under-report its evidence (8.2f)** because you declare no motion or vision Source. Understood; we will infer nothing from a Shot's candidate list about what you actually saw. ⛔ The same caveat runs the other way for §7: a strike excluded on evidence we cannot see is one we cannot explain to a golfer, so if `shot_disposition` does land we would want its optional reason genuinely populated.
- ⚠ **One small correction, so nobody talks past the other.** Your title says *"before you build step 4 of the online MVP"*. In our demo (`mvp-online.md` §4.1), **step 4 is preview** and **step 5 is shots crossing**. What you are ready to test is our step 5.

---

Everything marked ✅ above is a run that happened or a decision taken; everything about E3.3–E3.5 is composition in flight today, and we will tell you what it costs. Your closing line is the right one, and §5 above is us taking it: reading our own code against your document found a defect that running it would have found tomorrow, in front of a golfer.
