# Interop diagnosis — soaking the pairing path

Built on 23 August 2026 to answer "is the intermittent pairing failure PPC's or
PPS's?". Kept because the next such report is an afternoon with these and a week
without.

The Swift tests these drive are in the app target and skip cleanly when no URI is
supplied, so they cost nothing in an ordinary run:

| Test | Suite |
|---|---|
| `E3.1 — the composition root handshakes against a real counterpart` | `ConformanceHarnessTests`, row `e31` |
| `One full pairing against the published host` | `PairingSoakTests` |
| `Three devices hold links to one host at the same time` | `MultiDeviceTests` |

## Build the helpers first

```
cd tools/interop
xcrun swiftc -O qr.swift    -o qrdecode     # decode a QR from an image
xcrun swiftc -O ocr.swift   -o ocrtext      # read a window's text (Vision)
xcrun swiftc -O winid.swift -o winid        # find a window id by owner name
```

They are gitignored — build them, do not commit them.

## The three harnesses

**`./soak.sh [n] [scenario]`** — the app's live-link path against `ppcp-sim`, `n`
times. Needs nothing but a built `ppcp-sim`. This is the **control**: a
counterpart known to be conformant, so a failure here is ours.

**`./pps-soak.sh [n]`** — the shipping rendezvous path against whatever host is
displaying a pairing QR. Captures the QR from the host's window each iteration,
decodes it, dials, and records **both** ends' opinion.

**`./multi.sh`** — UC-6. Pairs three devices at once and re-checks every link
after the last one lands, so a host that silently drops the first when the third
arrives fails the test.

## Three things these got wrong before they got them right

⛔ **Read both ends.** The client's verdict alone is a *one-sided oracle*: it
scores "client believes it settled, host logged a failure" as a pass. `pps-soak.sh`
OCRs the host panel before and after each dial and diffs, so only lines the host
*gained* count — the dialog persists, and a message already on screen is not
evidence about this attempt. The `DISAGREE` verdict is the one worth chasing.

⛔ **Never re-dial a spent code.** Codes are single-use. An early run consumed the
code on iteration 1 and re-presented it three times; the host correctly rejected
each, and all three were recorded as defects. The scripts now fingerprint the URI
and wait for a genuinely new one.

⛔ **Re-resolve the simulator container every poll.** `test-without-building`
reinstalls the app and that changes its container UUID, so a path resolved once
points at the previous install. `multi.sh` hands codes to the test through that
directory; watching a stale one produced a confident and completely false report
that the host had stopped republishing.

Related: the counterpart window must be visible (the capture reads a window by id,
so it may be *behind* others, but the display must be awake and unlocked), and the
scripts run under `caffeinate` to stop the machine sleeping mid-soak.

## Secrets

⛔ `PPCP-RV` 4.4c / 7.2b — a pairing URI carries the PSK. These scripts keep it in
a shell variable and one environment variable for the length of a single
`xcodebuild` invocation. It is never echoed, never written to a results file, and
the screen capture that carried it is deleted immediately after decoding. Keep it
that way.

## What was measured on the day

| | |
|---|---|
| PPC ↔ `ppcp-sim` | 40 / 40 |
| PPC ↔ PinPointStudio | 30 / 30, two-sided |
| Three simultaneous devices | all established, none dropped |

Which is not "it is reliable" — 30 runs bounds a fault at roughly 10%, not 1%.
