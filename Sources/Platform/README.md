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
- **Implements the port surface, does not define it.** The protocols come from `Core/`;
  this layer supplies conforming implementations (REQ-PORT-2).
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
`PairingSecretStore` (7.2c/7.4 — the Keychain, `ThisDeviceOnly`, opt-in and
revocable), `NetworkJoin` (§6 — `NEHotspotConfiguration` with consent, and 6b's
**second** branch because iOS cannot reassociate a previous network), and
`RendezvousCoordinator` (§4's order: decode, expiry, join, then walk).

⛔ `Capture/RingBufferRecorder.swift` is **written and not connected**. The live
session's `AVCaptureVideoDataOutput` drives only the self-test's probe, so nothing
appends fragments and `CaptureDevice.extractClip` answers `absent` /
`outside_buffer` — which is 8.4b's own answer for a ring that does not hold the
interval, and is the truth here. Recorded in `docs/ppcp-conformance.md` as needing
a phone rather than faked.
