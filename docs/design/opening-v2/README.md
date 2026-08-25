# Opening and connect — design pass 2

A rethink of the opening screens and the connect journey, 25 August 2026.
Supersedes the A-series and B1 of [`mockup v1`](../mockup%20v1/README.md); everything
else in that pack stands.

**Published canvas:** <https://claude.ai/code/artifact/982e0850-58a1-493e-9547-ea9c614eb5a7>

## What it proposes

**The sequence follows where the golfer is standing.** Pair at the Mac, then walk
over and set the phone down. The pairing code is on the Studio screen, so scanning
it means carrying the phone there — and framing first meant clamping it to a
tripod, getting the ball in shot, then picking it all up again.

| Page | Holds |
|---|---|
| **The flow** | The argument: seven screens become four, and then none |
| **First run** | Welcome · What it needs · Pair my phone · Now set it down |
| **Every run after** | The opening screen, the host panel, and Connect |
| **As built** | Pairing and Remembered Studios, as they shipped |

Two artboards carry live state, as tweak chips above the frame: the opening
screen steps through the four host states, and Connect switches between its
first-run and returning copy.

## Departures from `mockup v1`, named rather than silently diverged

- **B2 gains a settled state.** The pack gives it none; the handshake completed
  and the screen vanished, so the only confirmation was on the other machine.
- **B3 gains a fourth settings row.** The pack specifies exactly three.
- **The A-series loses three screens** (A2, A3, A5) and A7 becomes a card on the
  capture screen rather than a screen of its own.

## Working with it

Artboards are Design Components — one `.dc.html` per frame, laid out by
`canvas.json`. To rebuild and republish after editing them:

```sh
node "<claude design skill>/seed-canvas.mjs" \
  --template "<claude design skill>/payload.template.html" \
  --out pinpoint-opening-flow.html --title "PinPoint Opening Flow" \
  --artboard Main.dc.html --artboard Flow.dc.html --artboard Welcome.dc.html \
  --artboard Permissions.dc.html --artboard Pair.dc.html --artboard Framing.dc.html \
  --artboard HostPanel.dc.html --artboard Connect.dc.html --artboard Pairing.dc.html \
  --artboard Remembered.dc.html --canvas canvas.json
```

⚠ **`pinpoint-opening-flow.html` is not committed.** It is a 2.2 MB generated
file — the artboard sources with the whole canvas editor baked in — and it is
reproducible from the sources beside it by the command above. The artboards and
`canvas.json` are the design; that file is a build of it.

## What is built and what is not

✅ Built, 25 August 2026: the four-screen sequence (#97), remembering by default
and forgetting as the deliberate act (#96), B2's settled state, Remembered
Studios, and Forget on the host panel's status card.

⛔ Not built: the opening screen's host chip. `AppModel` already publishes
`isSearchingForHost`, `reconnectSilence` and `reconnectDiagnosis`; nothing renders
them, so a reconnection in progress is still invisible on C1.
