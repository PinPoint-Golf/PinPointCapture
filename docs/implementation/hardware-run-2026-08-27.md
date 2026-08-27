# The hardware run — what only a phone can prove

| | |
|---|---|
| Date | 27 August 2026 |
| Purpose | The list of things that genuinely need a device, and nothing else on it |
| Status | Not run. Everything below is built and green on the simulator |

**Why this list is short.** Almost everything now runs on this Mac: `make conform` drives the
shipping composition against `ppcp-sim`, and `make interop-app` drives it against a live
PinPointStudio from the simulator. What remains here is what a simulator physically cannot do —
**it enumerates no camera, so it declares no camera Source** — plus the two cases no instrument can
produce.

⛔ **Run them in this order.** Each one's failure would make the ones below it unreadable.

---

## 0. Before you start

| | |
|---|---|
| Deploy | `make deploy` — builds, installs and launches on the connected device |
| Studio | Running, on a network that carries multicast between its clients |
| ⚠ First pass | **PinPointStudio's microphone off and no IMU attached** |
| ⚠ Pace | **One ball at a time.** Wait for each swing to appear before the next |

**Why the microphone off.** Their corroboration rule refuses a Shot when a host detector is
*available* and none fired within 50 ms of `t0`, and the refusal is invisible on the wire. With no
detector available every Shot is accepted unweighed, which takes the rule out of the picture until
the basics hold. Turn it on again for test 6.

**Why one at a time.** Their shot pipeline is unavailable for **15–40 seconds** after each shot and
silently drops what arrives inside that window. Four swings in four seconds measures their backlog,
not our nomination.

---

## 1. A clip exists at all — E1.2 on this device

⛔ **Everything below depends on this and it has never been proven on the current build.**

1. Arm. Wait for the *Capture* pill to settle.
2. Hit one ball.
3. Open the session library.

**Pass:** a shot row with a thumbnail, and a non-zero clip on disk.
**Then:** `make pull-bundles`, and check `clips/` holds an MP4 of a plausible size (a 240 fps clip
is tens of megabytes, not tens of kilobytes).

⚠ If the thumbnail is there and the clip is empty, stop — that is #98's shape and nothing after
this is meaningful.

---

## 2. Preview reaches Studio — MVP (b), and the one thing PPS is waiting on

**Nobody has ever opened a `preview` channel to PinPointStudio.** Their side was broken until this
afternoon and is now fixed; we are its first real test, and our side has never sent a frame.

1. Connect to Studio and arm.
2. On the Mac: **Settings → Cameras**.

**Pass:** a moving picture, roughly ten frames a second.

**If nothing appears, the three failure points are separable and worth telling apart:**

| Where | How to tell |
|---|---|
| The third `link_bind` refused | Studio logs a phone and its channel count; it will say two, not three |
| The Stream refused | Studio shows a `stream_open` refusal with our reason |
| Frames not produced | Channel and Stream both open, no pixels — ours, in `PreviewFrameTap` |

⚠ **Watch the capture side while preview runs.** The tap sits after the ring and drops rather than
queues, but 5.11i's whole point is that preview must never cost a captured frame. Check
`RingStats` — inter-arrival and drops — with preview running and again with Studio's Cameras panel
closed. **A difference is a defect and I want to know about it.**

---

## 3. A swing crosses — MVP (c)

1. Still armed, still connected.
2. Hit one ball. Watch both screens.

**Pass, on the phone:** the shot row appears within a second.
**Pass, on the Mac:** a swing appears in the library.

⛔ **Expect no video on the swing.** Their capture path cannot start a PPCP-backed camera yet, so
the clip leaves this phone correctly and lands nowhere. **That is their §2.3 and not our defect** —
do not spend time on it.

⚠ **`In Studio` will not appear either**, and that is also expected: nothing they run emits
`capture_committed` for a live Capture. The row should reach *Sent, not confirmed*. If it sits at
*On device*, the payload never left and that **is** ours.

Repeat to five or six balls, one at a time.

---

## 4. Host control — #26, and the first time a host has ever armed this device

Their half was built today; ours was built today; the two have never met.

1. Disarm on the phone.
2. On the Mac, arm from **Settings → Phones**.

**Pass:** the phone starts capturing, and Studio's state goes *Arming* → *Armed*.

**What each failure means:**

| Studio shows | Meaning |
|---|---|
| *Armed* | ✅ both halves work |
| *Arming*, then their **Stalled** timeout | our `readiness` never arrived — ours |
| *Cannot arm — `<reason>`* | ✅ working. The reason is ours and a golfer reads it — **tell me the wording** |

3. Then **disarm from the Mac**. The phone should stop.
4. Then **disarm on the phone** while Studio holds the Session.

⚠ **Step 4 will look broken and is not.** A `Readiness` cannot say "stopped and nothing is wrong",
so Studio will eventually show *Stalled*. That is learnings §1.4 and it needs a protocol change,
not a fix. Confirm it happens; do not report it as a bug.

---

## 5. The network drops — #28

⛔ **No instrument can produce this.** `ppcp-sim` has no scenario that stops heartbeating, so this
is the only way to see 7.4c's three-missed-intervals path at all.

1. Armed, connected, mid-session.
2. **Turn Wi-Fi off on the phone.** Leave it off for about a minute.
3. Hit **three balls** while it is off, one at a time.
4. Turn Wi-Fi back on.

**Pass, during the outage:**
- capture **does not stop** — the pill stays on Capture, shot rows keep appearing
- B3 shows *Host is gone*

**Pass, on reconnect:**
- B3 shows *Catching up*, then a **gap** with the outage window and *3 shots in the gap*
- the queued clips send

⛔ **Studio will drop most of what arrives at once** — three shots inside their 15–40 s window is
exactly their §2.2. Judge this one from the **phone**, not from their library.

⚠ **The order matters and is checkable in their log**: `session_resume` first, then a sync burst,
then relations, and only then payload. Payload before the burst would be a real defect.

---

## 6. The residual — REQ-SYNC-4, the only new arithmetic in E3

**Turn PinPointStudio's microphone back on for this one**, so it arbitrates against its own
detection rather than accepting ours unweighed.

1. Connected, armed, Studio's microphone on.
2. Hit three balls, one at a time.

**Pass:** B3's *Checked on last impact* shows a number in milliseconds. It has rendered `—` on
every device ever built, because nothing computed one.

⚠ **What the number should look like:** small — single-digit milliseconds. It is how far our
acoustic fiducial sat from the instant Studio decided the shot happened.

⛔ **A large one is a finding, not a failure**, and I want the value. Tens of milliseconds would
suggest the mic-to-ball distance setting is wrong (it feeds `tof_correction`); hundreds would
suggest the clocks are being compared in the wrong timebase.

⚠ Some balls may show `not yet` — Studio's corroboration may have excluded our Candidate, in which
case no Shot was arbitrated over it and there is nothing to subtract. That is correct behaviour.

---

## 7. Reconnect with no code — MVP (a)'s last unproven step

1. Close the app completely.
2. Reopen it.

**Pass:** it finds Studio and connects with no pairing step and no code.

⚠ Worth running **once with Studio's address changed** — a different network, or a DHCP renewal.
That is the case discovery was chosen for over a cached endpoint, and it has never been exercised.

---

## 8. The honesty check — MVP (d)

`make pull-bundles`, then confirm the bundle carries **the same records that went over the wire**:
the shots, their Captures, and the clips.

⛔ If this fails, "online only" has quietly become "online or nothing", which is a different
product.

---

## What to write down

For each test: pass or fail, and for anything that failed, **what the phone showed and what Studio
showed** — the two together are usually what identifies which side it is.

Specifically worth capturing whatever happens:

- the **`RingStats`** figures with preview running and with it stopped (test 2)
- the **wording** of any `blocked_reason` Studio displays (test 4)
- the **residual values** (test 6)
- **`make conform`** on the device build afterwards — that is what closes **CT-S3**, which needs a
  real camera declaration and is #27's actual exit criterion
