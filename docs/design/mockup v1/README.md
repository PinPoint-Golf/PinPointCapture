# Handoff: PinPointCapture — iOS / iPadOS app

## Overview

PinPointCapture turns an iPhone or iPad into a time-synchronised, high-speed capture source for PinPoint Studio, and works as an autonomous capture device when no host is present. This package covers the first design pass: onboarding (7 screens), host connectivity (6 screens), capture / replay / session library (3 screens), and the iPad two-pane layout (1 screen).

The two areas designed to depth are **onboarding** and **host connectivity**. Capture, replay and the session library are designed to the same visual fidelity but are less resolved in interaction detail (markup tools and two-shot comparison are named, not designed).

Source requirements: `capture-companion-requirements.md`. Where a screen encodes a requirement, this document names it.

## About the design files

`design/PinPointCapture iOS.dc.html` is a **design reference written in HTML** — a prototype of intended look, copy and behaviour. It is not production code and none of it should be ported.

The target is a **native iOS / iPadOS app in Swift (SwiftUI, or UIKit where SwiftUI cannot reach the capture stack)**. The requirement is a 100% native look and feel, so the correct implementation of every screen here is the standard system control, not a recreation of the HTML:

| In the HTML | Build it as |
|---|---|
| Grouped card lists (`#1C1C1E`, 14pt radius, 0.5px separators) | `List` with `.listStyle(.insetGrouped)` |
| 34px bold headings | `.navigationTitle` with `.navigationBarTitleDisplayMode(.large)` |
| 50pt green filled buttons | `Button` + `.buttonStyle(.borderedProminent)`, accent tint |
| 4-way pill switcher on B3 | `Picker` + `.pickerStyle(.segmented)` |
| Bottom rounded panel (B4) | `.sheet` with `.presentationDetents` |
| Fixed 393×852 frame, hand-drawn status bar and home indicator | The real device — no bezel, no status bar, respect safe areas |
| `-apple-system` / `ui-monospace` | `.body`/`.title` Dynamic Type; SF Mono via `.monospaced()` or `.system(.body, design: .monospaced)` |
| Hex colours below | Asset catalogue colours; prefer semantic system colours where noted |

Dynamic Type, VoiceOver labels and Reduce Motion are expected and are not represented in the HTML. Camera-preview and diagram areas are dashed or flat placeholder boxes — they stand for `AVCaptureVideoPreviewLayer` output and for illustrations that do not exist yet.

## Fidelity

**High fidelity** for colour, type hierarchy, spacing, copy and state logic — treat exact copy strings and state semantics as decisions, and reproduce them. Treat pixel geometry as **medium fidelity**: it was authored at iPhone 15 Pro width (393pt) with no Dynamic Type scaling, so layouts must be rebuilt to flow rather than measured off. Placement/framing illustrations are explicit placeholders.

## Design tokens

Dark appearance only, in this pass. Values are the literal ones used in the design.

**Colours**

| Token | Value | Use |
|---|---|---|
| Background | `#000000` | Screen background (`.systemBackground` dark) |
| Grouped background | `#1C1C1E` | Cards and list rows (`.secondarySystemBackground`) |
| Fill | `rgba(120,120,128,0.18–0.32)` | Secondary buttons, inline chips (`.systemFill` family) |
| Separator | `rgba(84,84,88,0.6)` at 0.5px | List separators |
| Label | `#FFFFFF` | Primary text |
| Secondary label | `rgba(235,235,245,0.6)` | Supporting text |
| Tertiary label | `rgba(235,235,245,0.45)` | Footnotes, disabled |
| **Accent / tint** | `#30D158` (system green, dark) | The app tint. Retained, synced, in Studio, primary actions |
| Warning | `#FF9F0A` (system orange) | Degraded but still capturing: weak link, marginal light |
| Error | `#FF453A` (system red) | Host gone, permission blocked, Disarm |
| Progress | `#5AA9FF` (near system blue) | In flight: sending, catching up |
| Accent wash | `rgba(48,209,88,0.10–0.18)` | Selected card fill, accent chip backgrounds |

Colour discipline, and the one rule to keep: **green is the only brand tint; orange, red and blue appear only in their system meanings. Capture status never turns red** — red is reserved for the host and for destructive actions, because capture continuing is the product's core promise.

**Typography** — SF throughout; SF Mono for any number the user could not have guessed (clock offsets, residuals, frame rates, timestamps, byte counts).

| Role | HTML value | iOS equivalent |
|---|---|---|
| Large title | 34/1.1, weight 700, −0.9px tracking | `.largeTitle`, bold |
| Screen heading (sheet) | 26–32, weight 700 | `.title`/`.title2`, bold |
| Card title | 18–22, weight 600–700 | `.title3`, semibold |
| Row label | 16–17, weight 400–600 | `.body` |
| Supporting text | 14–15, weight 400 | `.subheadline` / `.footnote` |
| Telemetry value | 13–15, weight 600, mono | `.body.monospaced()`, semibold |
| Eyebrow / label caps | 11–13, weight 600, mono, 0.6–1.2px tracking | `.caption.monospaced()` |
| Status chip | 12, weight 600 | `.caption`, semibold |

**Metrics** — radius: 8 (timeline, small chips), 10–12 (inline controls), 14 (cards, buttons), 18 (choice cards), 28 (sheet top corners). Padding: 20–24pt screen margins, 14–22pt inside cards, 12–16pt list rows. Gaps: 10–16pt within a group, 20–30pt between groups. Controls: 50pt primary buttons, 44pt minimum for every target (the 48×48 markup tool buttons and 54pt frame-step buttons are sized for gloved hands and should not shrink).

## Screens

### A — Onboarding

Seven screens, roughly ninety seconds, ending with a device that is placed well and knows what it can sustain. Never assumes a host exists.

**A1 Welcome.** Centred: concentric-circle mark, title, one-line description. Below it an accent-washed card headed `THIS DEVICE` stating the measured capability of the phone in hand ("iPhone 15 Pro — 1080p at up to 240 fps, wide and ultra-wide. Good for capture."). Actions: *Get started* (filled), *I have a pairing code* (plain).
Behaviour: the capability card is populated by the format enumeration, never a spec-sheet lookup (REQ-FPS-1, REQ-CAP-1/2). A device that will not clear the ingest gate says so here, in these terms, rather than at arm time.

**A2 How it works.** Four numbered rows (44pt rounded accent-wash number tile + title + one line). Steps: Place the device / Arm it, then hit / Review between shots / Send to Studio when you can. Single *Continue*.
Behaviour: sets the two expectations that otherwise generate support traffic — you never press record, and video can reach Studio long after the shot did.

**A3 Where are you today?** Two selection cards of equal weight. "In a studio, with a host" (selected: 2px accent border, filled check) and "At a range, on my own", each with a description and two chips. Footnote card: a host appearing mid-session is picked up automatically; a host disappearing is not a problem.
Behaviour: this is a routing choice only, and reversible. Standalone gets equal visual weight and equal copy length by design (REQ-STANDALONE-1, UC-1 is the normal case).

**A4 What it needs.** Four permission cards, each: icon, name, right-aligned status (`Allowed` in accent, or `Needed to pair` in tertiary), and a benefit sentence — never an API name.
- Camera — locked focus/exposure/white balance/stabilisation, framed as measurements holding.
- Microphone — impact sound gives every shot an exact time. Contains an inline sub-row: `Audio kept — 0.5 s around impact only` with *Change*.
- Local network — requested **last**, framed as pairing, with its own 44pt *Allow local network* button.
- Motion — tilt and gravity, "improves how views line up".
Footer: "No analytics, ever. Nothing leaves this device unless you send it."
Behaviour: request order matters. Camera and mic first (obvious), local network last and framed as a host choice, so a refusal reads as a decision about hosts rather than a broken app (REQ-DISC-6). Audio retention is surfaced here, not buried in Settings, because a continuously open mic in a lesson deserves an up-front answer (REQ-PRIV-2, OPEN-2 — the "0.5 s around impact" wording is a proposal for confirmation).

**A5 Set it down.** Heading, one line, then a **placeholder** box (260pt tall, dashed 1.5px, `rgba(235,235,245,0.28)`) for a placement diagram, then four bullet rules: tripod; hip height, landscape, whole swing in view; as much light as possible; leave the lens alone once armed. Action: *Check the framing*.
Behaviour: guidance, not configuration — the app classifies its own viewpoint rather than asking (REQ-SETUP-2). Replace the placeholder with a real drawing of the three positions and most of the body copy can go.

**A6 Framing check.** Top ~470pt is the live preview with an accent-stroked detection box labelled `GOLFER · IN FRAME`. Lower half: heading with `DTL · RIGHT-HANDED` self-classification, then a four-row checklist — in frame at address ✓, club still in frame at the top ✓, device steady ✓, and **light is marginal** in orange with the numbers (`1/1600 s · ISO 2200 · 150 fps`) and the consequence ("The shaft will be noisy near impact. Add light, or drop to 120 fps for a brighter frame."). Two actions: *Use 120 fps* / *Arm anyway*.
Behaviour: the screen that prevents a wasted session (REQ-SETUP-1, REQ-LIGHT-2). Warnings never block arming — they state the consequence and offer the trade. Checklist items update live from body-pose detection, which is framing validation and not analysis (REQ-SETUP-3).

**A7 Ready to capture.** Success glyph, heading, one line, then a five-row summary list: Capture `1080p · 150 fps`; Measured, sustained `149.6 fps · 0 drops`; Lens `Wide · locked`; Kept per shot `3.0 s around impact`; Room for `about 40 sessions`. Grey info card: "Not connected to a host. Everything is kept here until you send it." Actions: *Start a session* / *Connect a host first*.
Behaviour: claimed and measured capability shown together, in the one place a user will read them — also the receipt for the self-test (REQ-CAP-1/2/3). Storage headroom appears here to pre-empt the low-space refusal (REQ-OFF-2).

### B — Host connectivity

**B1 Connect a host.** Camera live behind a 262pt reticle drawn as four accent corner brackets. Nav row: *Cancel* / title. Below: instruction naming the exact Studio path ("Devices — Add a device"), then a three-row list in descending order of reliability — discovered host (`Bay 3 — Mac Studio`, "On this network · paired yesterday", *Connect*), *Enter the six-digit code*, *Use a cable instead* ("Steadier timing, no network at all"). Plain action: *Capture without a host*.
Behaviour: QR **is** the screen, not a fallback — the camera is live on entry (REQ-DISC-2). mDNS results are a convenience row for reconnection only (REQ-DISC-1/3). Every path completes discovery, pairing and authentication in one action (REQ-AUTH-2).

**B2 Pairing.** Accent eyebrow `PAIRING`, host name as the title, version line (`PinPoint Studio 0.9.4 · protocol PPCP 1.0`). Four progress rows, each a plain-language name with mono detail underneath: Private channel open (`TLS-PSK from the code you scanned`) ✓, Capability agreed (`1080p150 accepted · view: DTL`) ✓, Matching clocks (`14 of 20 exchanges · offset −3.184 ms · drift 18 ppm`) in progress, Camera warmed and locked pending. Grey card "Why the wait" explains the twenty round trips and that it is re-checked against every shot. *Cancel*.
Behaviour: sync burst is 10–20 exchanges estimating offset **and** rate (REQ-SYNC-1/2); progress reflects real exchange count. Filtered, never stepped (REQ-SYNC-3).

**B3 Host panel — four states.** *The interactive screen in the prototype.* A sheet with a grabber and a *Done* button, opened from the C1 host chip. Below the nav row sits a 4-way segmented control which in the shipped app is **not present** — it exists only so a reviewer can flip states. One layout carries all four: status card (state dot + title + host name + sub-line + one-sentence explanation), a five-row telemetry list, a three-row settings list (*Send video over*, *Connection log*, *Export a diagnostic bundle*), and a full-width action tinted to the state.

| State | Colour | Title | Action | Rows |
|---|---|---|---|---|
| Connected | `#30D158` | Connected | Disconnect | offset `−3.184 ms ± 0.21`; drift `18 ppm, filtered`; checked on last impact `0.4 ms`; waiting to send `nothing`; temperature `nominal` |
| Weak | `#FF9F0A` | Connected, slowly | Send over a cable instead | offset `−3.20 ms ± 1.9`; last impact `1.9 ms`; waiting `3 shots · 71 MB`; throughput `4.1 Mbit/s`; temperature `fair` |
| Lost | `#FF453A` | Host is gone | Find the host again | **capture `still armed`**; shots since the drop `6`; waiting `6 shots · 118 MB`; retrying `every 2 s`; storage left `38 sessions` |
| Back | `#5AA9FF` | Catching up | Pause sending | offset `−3.191 ms ± 0.24`; sending `shot 3 of 6 · 61%`; gap reported to host `14:38:12 → 14:44:03`; shots in the gap `6, all retained`; temperature `nominal` |

Copy that carries the design (reproduce verbatim):
- Lost — "Capture never stops for this. Keep hitting — the shots are safe here and will go across on their own when the host is back."
- Weak — "Shots are still being correlated the moment you hit them. The video is queueing behind the network."
- Back — "Twenty fresh exchanges before anything is sent, so the shots captured during the gap land on the right timeline."
Behaviour: in Lost, the **first row is capture state**, not the error — the priority rule made visible (§9.2, REQ-RES-1). Weak reflects the split channel: events go immediately, video queues (REQ-SESS-5/6). Back re-syncs before sending and reports the gap explicitly (REQ-SYNC-2, REQ-STATE-5).

**B4 Join the studio network? (sheet)** Bottom sheet, 28pt top corners, grabber, orange Wi-Fi glyph, heading, body naming the SSID, a two-row list (Network `PinPoint-Bay3`, Internet `No — local only`), then *Join network* / *Stay on current Wi-Fi*.
Behaviour: shown when the pairing code carries SSID and passphrase, driving `NEHotspotConfiguration` (REQ-DISC-4) — removing the network problem rather than diagnosing it. Loss of internet is stated because it is what the user notices ten minutes later.

**B5 Studio has part of this session already.** Heading plus "Nothing is merged until you say so." Two candidate cards: the likely one (accent border, `LIKELY` chip, "Studio holds 29 shots from a launch monitor") with its evidence (shot spacing matches `29 of 29`, largest disagreement `41 ms`), and an unlikely one. Orange notice: "Shots 30 to 41 have no launch monitor record. They will arrive as video only." Actions: *Review the 41 shots* / *Send as a new session*.
Behaviour: no auto-merge, ever, and the evidence for each candidate is shown (REQ-OFF-12). Coverage gaps surface here rather than in Studio, so nothing is analysed on absent sensor data (REQ-OFF-13).

**B6 iOS is blocking the local network.** Crossed-out Wi-Fi glyph, heading, and immediately: "It has no effect on capture — you can record all day like this." A "To fix it" card with the exact path (Settings — PinPointCapture — Local Network) and *Open Settings*. Then a section headed `OR CARRY ON WITHOUT IT`: *Connect by cable* ("Does not need this permission") and *Capture on my own* ("Send to Studio later"). Primary: *Try again*.
Behaviour: the failure that otherwise makes the app look permanently broken, and there is no API to read the permission state back — so it is inferred from connection failure and presented as this screen rather than a generic error (REQ-DISC-6). A refusal must cost a golfer a network, not a session.

### C — Capture, replay, session

**C1 Armed.** Full-bleed preview. Top row: accent pill (dot + "Armed") and a host chip ("Bay 3"). Right rail, `rgba(28,28,30,0.72)` card, four mono rows: fps `149.6`, buffer `10.0 s`, sync `0.4 ms` (accent), heat `nominal`. Bottom gradient panel: last-shot thumbnail (74pt), "Shot 41 · 7 iron" / "12 s ago · sent, confirmed", a 48pt play button, then *Session · 41* and *Disarm* (red-tinted).
Behaviour: legible from two metres away on a tripod — one pill, one chip, one thumbnail. The telemetry rail is deliberately small: reassurance for whoever wants it, ignorable otherwise. Arm/disarm is host-controlled when a host is present (REQ-STATE-1); the Disarm button is the local override.

**C2 Replay and markup.** Nav: *Done* / centre stack "Shot 41 · 7 iron" with **"still armed"** beneath / *Compare*. Frame area labelled `FRAME AT IMPACT − 0.0067 s`. Timeline: 44pt track, accent-wash fill to the impact line (2px accent, at 52%), plus a 1px tertiary line for the top-of-backswing anchor at 24%; labels `TOP` / `IMPACT 0.0000 s` / `+1.2 s`. Transport: −1 frame (54pt), play (64pt), +1 frame (54pt), `¼×` speed (accent). Bottom: three 48pt markup tools (line, circle, freehand) and an accent chip "In Studio".
Behaviour: the timeline is addressed in time, zeroed on impact, never in frame index (REQ-REPLAY-1/2/3). "Still armed" in the title bar is the promise that reviewing costs nothing (REQ-STATE-4, REQ-RES-1/2). *Compare* opens two-shot comparison aligned on impact — **not designed yet** (REQ-REPLAY-4). Markup anchors to shot ID + frame timestamp and round-trips to Studio (REQ-MARK-1/2).

**C3 Session library.** Large title "Wednesday range", sub-line "41 shots · 18:20 to 19:36 · 12 still to send". Accent transfer banner: "Sending to Bay 3" / `shot 30 of 41 · 218 MB left` / *Pause*. Then the shot list — thumbnail, `41 · 7 iron`, mono `19:36:02 · 3.0 s`, and a state chip. Footer button *Export the whole session*.
Chips, three words not icons: `In Studio` (accent), `Sending 61%` (blue), `On device` (grey). Practice swings appear with "no impact" and stay `On device`.
Behaviour: the library is an independent store with per-shot sync state, not a cache (REQ-SESS-3). `In Studio` means **confirmed by the host**, never merely uploaded; nothing unconfirmed is ever evicted (REQ-SESS-4). Transfer is queued, resumable, backpressure-aware (REQ-SESS-6). *Export the whole session* writes the same schema as the wire format (REQ-STANDALONE-2, REQ-OFF-1).

### D — iPad

**D1 Armed and reviewing.** Landscape 1194×834, permanent two-pane, no split-view gymnastics: left (flex 1.35) live capture with the armed pill, a horizontal mono telemetry strip (`149.6 fps | sync 0.4 ms | nominal`), a club chip with *Change*, and *Framing check* / *Disarm*; right (flex 1) review — "Shot 41" + *Compare*, a 270pt frame area, the same impact timeline and transport at slightly reduced sizes, and the shot list with state chips filling the remainder. Top bar carries `ARMED` in accent.
Behaviour: what an iPad earns is capture and review at once (UC-3), so both panes are permanent rather than swapped. Onboarding and pairing are the **same screens** presented as centred sheets — not a redesign. An iPad sits further away, so status type runs larger and across the top.

## Interactions and behaviour

- **Navigation.** Onboarding is a linear push stack with no skip on A4 and A6 (both have "continue anyway" style outs instead). B1 is presented modally from A7 or from the host sheet. B4/B6 are sheets. **There is no tab bar.** The capture screen is the app root; the host chip on C1 opens the host sheet (B3), which contains the connection log and diagnostic export, and the *Session · 41* button opens the library (C3). A camera-first app should not carry a tab bar over a full-bleed preview.
- **State machine (REQ-STATE-1..5).** Cold → Warm on host connect (or on entering the session tab standalone) → Armed on host arm command or local Arm. Warm exists so arming costs no AE/AF settling. Keepalive lapse drops Warm → Cold. Platform interruptions (call, audio session interruption, backgrounding) auto-re-arm on return and report the gap explicitly — surfaced with the same treatment as B3 "Back".
- **Connection transitions.** Connected → Weak on sustained throughput drop or residual above threshold; → Lost on keepalive lapse; Lost → Back on reconnect, which runs a fresh sync burst before any bulk transfer resumes. Transitions animate colour and copy only; the layout never reflows, so a glance from the mat does not need re-reading. No transition ever disarms capture.
- **Framing check (A6)** updates continuously while visible: pose box, three boolean checks, and the light row recomputed from achieved exposure/ISO. *Use 120 fps* re-enumerates formats and re-runs the check.
- **Transfer.** Event message (timestamps, confidence, thumbnail) goes immediately on the low-latency channel; video follows on the bulk channel and may lag, queue, resume across app launches, or never finish within the session. Progress is per-shot, and per-session in the C3 banner. *Pause* is user-level, backpressure is automatic.
- **Reconciliation (B5)** requires explicit confirmation. Never auto-merge.
- **Animation.** System defaults throughout — sheet presentation, list insertion for new shots, and a crossfade for connection-state changes. No custom motion in this pass. The armed pill dot may pulse slowly; honour Reduce Motion.
- **Empty and error states not yet designed:** no sessions yet, storage floor reached (refuse to arm, REQ-OFF-2), thermal limit reached, review mode (REQ-STANDALONE-6), diagnostic bundle export (REQ-OBS-1/2).

## State the UI needs

- `deviceCapability` — claimed, measured, achieved triple; drives A1, A7, the C1 rail.
- `captureState` — cold | warm | armed, plus `isReviewing` (independent; armed + reviewing is the normal case).
- `hostLink` — none | pairing | connected | weak | lost | resyncing, with `offset`, `offsetUncertainty`, `driftPpm`, `lastImpactResidual`, `throughput`, `lastSeen`, `gapWindow`.
- `framingStatus` — inFrameAtAddress, inFrameAtTop, isSteady, lightAssessment(exposure, iso, verdict), classifiedViewpoint.
- `session` — id, start, roster, calibration state, club context, shots.
- `shot` — id, t₀, duration, club, thumbnail, detectionConfidence, syncState(onDevice | sending(progress) | inStudio), markup.
- `transferQueue` — ordered, resumable, paused flag, bytes remaining.
- `permissions` — camera, microphone, localNetwork (inferred, not readable), motion.
- `audioRetention` — the user-visible setting from A4.

Per REQ-PORT-13, the UI should consume a platform-neutral readiness state rather than raw permission results; and per REQ-PORT-3, no `AVFoundation` type should reach these view models.

## Assets

None shipped. Every glyph in the prototype is an inline SVG stand-in for **SF Symbols** — use `camera`, `mic`, `wifi`, `wifi.slash`, `checkmark.circle.fill`, `exclamationmark.circle.fill`, `gyroscope`, `qrcode.viewfinder`, `cable.connector`, `arrow.down.circle`, `chevron.right`, `play.fill`, `backward.frame`/`forward.frame`, `line.diagonal`, `circle`, `scribble` and equivalents rather than redrawing them.

Two real gaps: the **placement diagram** (A5) and any illustration on A2/A6 — both are dashed placeholders. Neither was generated; they need a designer or photography. The app mark on A1 is a placeholder concentric-circle target, not a logo.

## Files

- `design/PinPointCapture iOS.dc.html` — the design, all 17 screens. Open it in a browser; `design/support.js` must sit beside it. Pan and zoom to move around the board. On screen B3, the four-state switcher is live.
- `design/support.js` — runtime for the file above. Not part of the design.
- `screens/A-onboarding.png` — A1 to A7, in flow order, wrapping across rows.
- `screens/B-host-connectivity.png` — B1 to B6. B3 is captured in its **Connected** state; the other three states are specified in the table above.
- `screens/C-capture-replay-session.png` — C1 to C3.
- `screens/D-ipad.png` — D1, the iPad two-pane layout.

Each screen in the images carries its id badge (A1, B3, …) and a caption stating the design reasoning, matching the section names in this document. Trust the README values over pixel-measuring the PNGs — the images are 1× captures of a board, not spec drawings.
