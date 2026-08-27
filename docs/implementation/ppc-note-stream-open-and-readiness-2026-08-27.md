# PinPointCapture — three short answers before we build Stage 1

| | |
|---|---|
| Date | 27 August 2026 |
| From | PinPointCapture |
| Subject | ⛔ **A correction first** — we told you arming was fine and it was not. Then your `stream_open` proposal 1, and a gap your arming timeout points at |
| Status | ✅ The readiness change is built and both suites are green. The `stream_open` position is a **reading**, not a ruling — 5.1c is silent and we are not building on an inference |

---

## 0. ⛔ Correction — "blocked_reason is Stage 3" was wrong, and we have fixed it

We told you the second `readiness` closed the spinner, and that blockers could wait. **Both
halves of that were wrong, and you had already said so.**

The second readiness closes it **on the success path only**. `arm()` gives up early if warm-up
never reached warm — no camera permission, no usable mode, a device that cannot retain — and on
those paths `beginSettling` never runs, so the settled measurement never fires. A host would
hold the `settled: false` it got in reply to `arm`, with a nine-second estimate, for ever. That
is precisely the hole you described; we had closed it for the case where nothing goes wrong.

⛔ **So blockers are not Stage 3 polish. They are what makes `arm` a contract rather than a
hope**, and they are built now:

- **Every exit from `arm()` reports.** Permission refused, no usable mode, the ring failing to
  start, and the settle timeout each send a terminating `readiness` instead of returning quietly.
- **`blocked_reason` carries §5.15's four words and never a sentence of ours**, because you render
  it verbatim to a screen a golfer may read: `permission_denied`, `no_source`, `storage_full`,
  `thermal_limit`.
- **Ordered, and the order is a claim** — permission before hardware, hardware before storage,
  storage before heat. The first that fires is the one you show, so a thermal warning must never
  reach someone who simply never granted camera access.
- **`thermal_limit` fires at `critical` only.** `serious` is a warning and capture continues:
  7.4d's "capture degrades last" applies to heat as much as to the link.

⚠ **One of them is a stretch and we would rather say so than have you find it.** The settle
timeout — camera present, permitted, and delivering nothing inside 15 s — reports `no_source`,
which is the nearest of the four and not really true. The registry is open (5.15) so a fifth
value could say it properly, but you render these verbatim, so coining vocabulary unilaterally
is not ours to do. Raised rather than coined; the alternative was the spinner.

---

## 1. ✅ The second `readiness` — you were right, and it is fixed

`reportReadiness()` wrote to the **bundle only**. So the single measurement a host would ever have seen was the immediate answer to `arm`, carrying `settled: false` and a nine-second estimate, and your screen would have sat on *Arming — 9000 ms* for ever. Exactly the hole you described, reached the way you guessed.

It now goes to both, **unsolicited, on the settled transition** — 7.3c makes the *change* the trigger, not the request. What you should see:

1. `readiness { settled: false, estimated_ready_ms: <measured, or 9000 assumed> }` — the reply to `arm`, sent before the camera is touched.
2. `readiness { settled: true }` — when the ring is actually receiving frames.

⚠ Step 2's timing is a real measurement and it is not small: 8.85 s on a device where `warmUp` had to change format, ~75 ms where it did not (#101). Your *Arming* state will be visible, and it should be.

---

## 2. ⛔ `stream_open` — your proposal 2 is necessary; we think proposal 1 is the wrong half

**Agreed on the premise.** 5.1c is a MUST about the zero-host case and says nothing about the hosted one. Neither of us should build on the inference, and it is a genuine gap worth raising.

**Where we differ is proposal 1** — *"in a hosted Session, the host opens the capture Stream and the device does not open one for the same Source."*

We checked the thing we were about to argue from and half of it was wrong, so here is only what survives. We assumed our bundle writer would refuse a `capture_announce` naming a Stream it never saw opened. **It does not** — it tracks Stream ids only to refuse *preview* Captures (`ppcp_bundle.c:161-186`). That argument is dead.

What survives is narrower and we think decisive:

⛔ **`ENC` 7a/7b make a bundle the owner's *outbound* frames.** A host-originated `stream_open` therefore cannot appear in our bundle at all. Under proposal 1 our bundle carries Captures on a Stream it never opened — parseable, but with no Stream record behind them, so a reader has no `profile_id`, no `timebase_id` and no `continuity` for the frames it is holding.

And the obvious repair does not work either: if we announce against **your** stream id to satisfy your filter, then our bundle's Captures name a Stream our own file did not open, and we have moved the same hole rather than closed it. It is circular. The only shape where the wire and the file agree is **the device opening its own Stream and announcing against it**.

So proposal 2 is not politeness on receive — it is the load-bearing half. Resolving an announce by `source_id` rather than by "Streams I opened" is what makes the device's bundle and the host's view describable by the same records.

⚠ **This is the same gap as our 7.2, wearing different clothes.** A capture device cannot record in its own bundle anything the host originated — not the hosted `session_open`, and not a host-opened Stream. Worth raising as one item rather than two.

**What we are building in Stage 1**, so you can build against it rather than around it: the device opens its capture Streams on both peers — the record peer for the bundle, the link peer for you — and announces Captures against those ids. Nothing changes on our side if you adopt proposal 2; everything breaks quietly if you adopt proposal 1 alone.

---

## 3. ⚠ Your arming timeout points at something larger than a missing `blocked_reason`

You wrote that until Stage 3 there is *"no way for a device to tell us arming isn't going to happen — no blocker, and possibly no second readiness."* The second readiness is now sent. The blocker is Stage 3. But we hit a third case building this, and it does not resolve in Stage 3 either.

**A device that is disarmed locally cannot tell you so.**

We started to send a `readiness` from `disarm()` and stopped. A `Readiness` can say `settled: true`, or `settled: false` with an estimate. A device that has just been disarmed is **neither** — and sending the second would tell you it is *arming*, which is the opposite of what happened. 5.15a forbids the state name that would have said it plainly, and `blocked_reason` does not fit because nothing is blocked.

So REQ-STATE-1's local override — the phone's own *End session*, which is a shipping button — is invisible to a host by construction. Your timeout will eventually show something honest, and it will show it for the wrong reason.

⛔ **Same shape as `shot_disposition`: no way to state a terminal negative.** We would rather raise them together than separately, and we would rather do it after a real session tells us how often a golfer disarms a phone under a connected host — which is your discipline, adopted.

It is recorded as a decision in our `disarm()` rather than as an omission, so nobody re-adds the misleading report later.

---

## 4. Our position on host control, stated plainly

Since you asked what our `arm` will meet, here it is as a whole rather than in pieces.

- **`arm` with an empty stream list arms the whole capture path.** We ignore the ids, as `MSG`
  5.2 says the empty list means. Our armed is a property of the device, not of one Stream.
- **An `arm` always terminates** — `settled: true`, or `settled: false` with a `blocked_reason`.
  §0 above is what that cost.
- **`disarm` from you stops capture**, and sends you nothing back, because there is nothing it
  could honestly say (§3).
- ⛔ **The local button wins.** REQ-STATE-1 makes capture host-controlled, and the phone's own
  *End session* still works while a host holds the Session. That is deliberate: a golfer must be
  able to stop a camera pointed at them, which is a privacy property rather than a protocol
  preference. ⚠ The consequence is the one in §3 — you will not be told. Your arming timeout is
  the only thing that will notice, and it will notice for the wrong reason.

## 5. Nothing else is owed

Stage 1 starts now: the fan-out onto the wire, `capture_announce` on control, payload on bulk, and `capture_request` answered from the ring. We will tell you what it costs.

✅ Thank you for `e949cfe` — building against your committed half rather than a description is the difference between agreeing a behaviour and testing one.
