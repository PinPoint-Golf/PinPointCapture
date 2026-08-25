# Platform — the capture layer, and the only place platform types live

Camera, microphone, encoder, motion, storage and network primitives (REQ-PORT-1,
"Platform capture" row). On this platform that means `AVFoundation`, `VideoToolbox`,
`CoreMedia`/`CoreVideo`, `CoreMotion` and `Network`.

## Contract

- **Platform types stop here.** `CMSampleBuffer`, `AVCaptureDevice`, `CVPixelBuffer`,
  `CMTime`, `NWConnection` and their equivalents must not appear in any type that
  `Core/`, `UI/` or `App/` can name (REQ-PORT-3). Everything leaving this directory is
  a neutral value or a `Core`-declared protocol. If a type from one of the frameworks
  above appears in a public signature, the boundary has already been broken.
- **Abstract base and factory from the start.** Device- and product-specific capture
  code is reached through an abstraction with a factory, matching the standing rule
  applied throughout PinPointStudio (REQ-PORT-4). Not retrofitted later.
- **Implements the port surface — and, for capture, *declares* it.** ⚠ This was
  stated as "the protocols come from `Core/`", and for the transport half that is
  true: `ByteChannel`, `PeerTransport` and the connector/listener pair are all
  declared in `Packages/Core`. **`CaptureDevice` is not** — it is declared here,
  in `CaptureDevice.swift`, because every type in its signature is already a Core
  type and moving the protocol itself would buy nothing. The rule that actually
  holds is the one REQ-PORT-3 states: no *platform* type crosses the boundary.
  Recorded because the previous wording sent a reader looking in `Core/` for a
  file that has never been there (REQ-PORT-2, E14.3).
- **Encode to fragments, not raw frames.** The capture abstraction must survive a
  platform without clean per-frame access — Android's constrained high-speed session
  takes batched request lists over a limited surface set (REQ-PORT-9, REQ-BUF-1/4).
- **Measure the timebase, never assume it.** iOS puts video and audio on
  `CMClockGetHostTimeClock()`; another platform may not. Report a measured offset with
  its uncertainty (REQ-PORT-8).
- **Own the permissions.** Request flow, denial and re-request handling live here and
  are published upward as neutral readiness (REQ-PORT-13).
- **Device characteristics are data.** Rolling-shutter readout, exposure convention and
  measured capability ship as data keyed by device model, not as branching code
  (REQ-PORT-10).

## What is in here

| Area | Files | Port surface it implements |
|---|---|---|
| Capture | `CaptureDevice.swift`, `AVFoundationCaptureDevice.swift`, `CameraPreview.swift` | `CaptureCore.CaptureDevice` |
| Permissions | `PermissionsService.swift` | `CaptureCore.Permissions` |
| Device data | `DeviceProfiles.swift`, `DeviceProfiles.json` | REQ-PORT-10 |
| **PPCP transport** | `Network/PpcpTransport.swift` | `CaptureCore.ByteChannel`, `PeerTransport`, `PeerTransportConnector`, `PeerTransportListener` |
| **Capture path (D4)** | `Capture/RingBufferRecorder.swift`, `Capture/FrameTimeline.swift`, `Capture/MotionMetadataSource.swift`, `Capture/ThermalTimeline.swift`, `Capture/InterruptionMonitor.swift` | fills `CaptureCore.FragmentRing`, `PpcpAchievedSummary`, `StreamCoverage`, `InterruptionRecord` |

⚠ **`Capture/FrameTimeline.swift` is where "what may this device honestly claim?"
is answered, once.** `CORE` 5.8h forbids declaring `exposure_provenance:
per_frame` unless the platform attaches the value to the sample, and the answer —
it does not, for video; it *does* attach the intrinsic matrix — is written down
there with what was checked, so the next person does not re-decide it
optimistically. That file is also the only place the column-major-to-row-major
transpose of the intrinsic matrix happens (`ENC` §4.1).

⚠ `alwaysDiscardsLateVideoFrames` is **`false`** on the capture path and `true` in
the self-test. The self-test wants drops visible (REQ-CAP-3); capture wants them
not to happen, because §9.2 makes capture degrade last.

⛔ `Network/PpcpTransport.swift` is the only file in the app that may name a
`sec_protocol_*` symbol, and it contains **no plaintext path** (`RV` 5.2f). Read
the `PpcpTlsProfile` comment block before touching the TLS setup — RT-17 asks for
it to be re-read whenever that path or a platform SDK changes.

⚠ **Three files now name `Network.framework` types, and the split is the point.**

| File | May name | Why it is separate |
|---|---|---|
| `Network/PpcpTransport.swift` | `NWConnection`, `NWListener`, `NWParameters`, `sec_protocol_*` | The **only** TLS path. No plaintext branch, by construction rather than by care. |
| `Network/PpcpDirectTransport.swift` | `NWConnection` | `#if DEBUG` **in its entirety**. `RV` §2's `direct` path for D9's conformance harness — 9a makes a peer handed an established socket fully conformant, and `ppcp-sim` speaks plaintext deliberately. A release build contains none of it. See F-D9-1. |
| `Rendezvous/PpcpAdvertiser.swift` | `NWListener`, `NWBrowser` | `RV` §3 discovery. It advertises and browses; it never carries application bytes, so it has no business in the transport file. |

⛔ **`PpcpByteChannel.open` refuses a ready connection with no TLS metadata, and
that refusal is how 5.2f is held.** The plaintext channel is a *separate type* in
a file that compiles out, rather than a parameter on that one — a plaintext branch
inside the file that must not have one is exactly the erosion the rule exists to
prevent.

⚠ `Rendezvous/` also holds the three things `RV` §5–§7 make the embedding's:
`PairingSecretStore` (7.2c/7.4 — a backup-excluded file, opt-in and revocable;
**the Keychain until erratum E56 made 7.2c a SHOULD**, and `isExcludedFromBackup`
is now what carries 7.4c's *not transferable*), `NetworkJoin` (§6 — `NEHotspotConfiguration` with consent, and 6b's
**second** branch because iOS cannot reassociate a previous network), and
`RendezvousCoordinator` (§4's order: decode, expiry, join, then walk).

✅ `Capture/RingBufferRecorder.swift` is **connected** (E1.1, 24 Aug 2026).
`AVFoundationCaptureDevice` is itself the session's sole
`AVCaptureVideoDataOutputSampleBufferDelegate` and routes each frame by an
explicit state — `warm` (nobody), `retaining` (the ring), `selfTesting` (the rate
probe). ⛔ `alwaysDiscardsLateVideoFrames` is **derived from that state and never
written as a literal**: the self-test needs late frames discarded so REQ-CAP-3 can
see degradation, the ring needs them kept because §9.2 makes capture degrade last,
and deriving it is what stops one requirement quietly overwriting the other.

✅ **The ring's mechanics are proved on a simulator**, by
`Tests/RingBufferRecorderTests.swift` driving synthetic frames through the real
`AVAssetWriter`: fragments land at the 0.5 s cadence, the ring rolls at 20 and
evicted fragments take their files with them, an out-of-window interval answers
`absent`, orphans from a previous run are swept, and — the one E1.2 depends on —
the initialisation segment plus fragments **decodes as one video track, while the
same fragments without it do not open at all**. ⚠ Frames must be paced at
wall-clock rate: `expectsMediaDataInRealTime` throttles, and over-feeding this
path produces silence rather than an error.

⛔ **What still needs a phone is the camera, not the writer**: 1080p at the
claimed rate, the REQ-OPT-1..4 locks holding under load, thermal behaviour, and
whether VideoToolbox emits High tier at 50 Mbps. `RingBufferRecorder.stats`
(`RingStats`) exists so that run reports numbers — inter-arrival maximum,
fragments written and evicted, frames that went nowhere — rather than a directory
listing that looks about right. Adapted from PinPointStudio's
`src/Buffer/source_stats.h`; see `docs/design/capability-spike.md` §4.
