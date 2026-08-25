# Integration test, 24 August 2026 — **ABORTED**

**First attempt at proving (b): reconnect to a remembered Studio with no code. Real iPhone 16, real PinPointStudio, real network.**

| | |
|---|---|
| Status | ⛔ **Aborted by the product owner.** Not a failure of the protocol or of the reconnection code — **blocked by the pairing UX in this application** |
| Date | 24 August 2026, ~22:30–23:00 |
| Under test | `ReconnectCoordinator` (`a879d27`) against PinPointStudio `14285bc` |
| Verdict | **(b) remains UNPROVEN end to end.** Everything up to the moment of resolution was verified; the last step never became reachable |

---

## 1. What was proven

- ✅ **PinPointCapture deploys, installs and launches on a physical iPhone 16.**
- ✅ **PinPointStudio advertises `role: host` from the real application** once it holds a persisted pairing — observed on the wire as `PPCP-6682D9EB`, `pv = 1.0`, `txtvers = 1`, `rn = 41dfd5dc…`, `rid = d3aeee50…`, well-formed. **This is the first time the advertisement has been seen from the shipping app rather than a test fixture, and the `K_id` behind that `rid` was a real pairing's.**
- ✅ **The host correctly does NOT advertise when it holds no pairings** — *"with nothing to reconnect to there is nothing to be found FOR"*. Confirmed by observing zero instances before the pairing was remembered and one immediately after.
- ✅ **A QR pairing completed** and the device appeared in PinPointStudio.

## 2. Why it stopped

⛔ **The phone never held a persisted pairing, so `ReconnectCoordinator` correctly did nothing.** `identityKeys()` was empty; there was nothing to reconnect *with*. The reconnection code behaved exactly as designed — it was never given the chance to run.

**The cause is that the primary pairing path cannot produce a persisted pairing.** There are two entry points and only one carries the consent:

| Screen | Reached by | Offers "Remember this Studio" |
|---|---|---|
| `ConnectHostView` | the normal connect flow; scans immediately | ❌ **no** — takes `onCode:` with no `persistPairing` binding at all |
| `ScanPairingCodeView` | tapping **"Enter code"** on that screen | ✅ yes — but below the paste box, and it defaults to **off** |

⚠ **And the reason is a real design tension rather than an oversight.** The primary screen pairs the instant the camera sees a code, so at that moment the code has not been read and `mu` is unknown — and [7.4f](../../../libppcp/docs/specification/ppcp-rv.md) forbids offering persistence for a multi-use code because *"the offer itself would be a lie"*. A pre-commitment toggle cannot honestly sit on a screen that pairs on sight.

## 3. The three UX findings — the product owner's words

1. ⛔ **"We don't get a confirmation on the phone that the connection worked."** The pairing succeeds and the phone says nothing. The only way to know is to look at the *other* machine.
2. ⛔ **"Can't set it to be remembered."** On the path a normal user takes, there is no affordance at all — and there is **no way to remember a Studio after the fact**, so missing it costs a full re-pair. Given the phone is meant to be mounted and calibrated on a tripod, that is precisely the cost (b) exists to remove.
3. ⛔ **"If you choose to scan a QR code there is no way out."** The scanner has no escape.

**Together these mean the default path through the shipping app cannot produce a persisted pairing, so (b) is unreachable for a normal user however well the protocol works.**

## 4. Recommended shape

> ✅ **Resolved 25 August 2026 — and not by the shape recommended below.** Mark's decision (issue #96): **the default stance is to remember, and forgetting is the deliberate action.** So the phone is not asked after the pairing either — it is told. B2 gained a settled state that reports what became of the pairing, and a *Remembered Studios* screen under B3 is where a Studio is forgotten. Findings **1** and **2** are closed; finding **3** is not. ⚠ The specification moved with it: erratum E57 made `RV` 7.4b a SHOULD, so declining its opt-in half is the application's decision to take. See [`mvp-online.md` §2.2a](mvp-online.md) and [the conformance document](../conformance/ppcp-conformance.md).
>
> ⛔ **The abort itself is not closed.** The journey below has still never run to completion on a phone; what changed is that it now can.

The shape recommended on the day, kept as the record of what was thought before the decision:

**Ask after the pairing succeeds, not before it starts** — which is what PinPointStudio already does, and it resolves the 7.4f tension because `mu` is known by then. A "Remember this Studio" affordance on the connected-host row, plus a confirmation that the connection worked, plus a way out of the scanner. That also makes the two ends symmetrical, which they currently are not: **the host asks afterwards and keeps the button; the phone asks beforehand and the offer vanishes with the screen.**

## 5. Fixed in passing

✅ **`make deploy` installed to a SIMULATOR while building for the phone** (`1cc5128`). The selector filtered on `tunnelState == "connected"` alone, and a booted simulator reports exactly that; `build-device` filters on `reality == "physical"` through `_udid` and was right. So the build succeeded for iOS-arm64 and only the install failed, complaining the executable *"does not contain code for any platform … runnable on this device"* — which reads like a signing or slice fault and is not one.

## 6. Not this repository's, recorded so they are not rediscovered

- **PinPointStudio's home-screen device list is stale** — a phone that has closed still shows. The resource monitor is truthful; the home list is not. Pre-existing (`DeviceEnumerator` never forgets). ⚠ **It would have made a failed reconnection look like a successful one**, and was noticed before the test rather than during.
- **Consent lives in two different places on the two ends**, with no indication that hitting only one leaves reconnection impossible.
