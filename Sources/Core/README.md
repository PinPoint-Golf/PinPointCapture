# Core — platform-neutral logic and state

Shared logic and state: capture state machine, ring-buffer policy, shot arbitration
client, transfer queue, session store, sync-state tracking (REQ-PORT-1, "Core logic"
row).

## Contract

- **No platform frameworks.** No `AVFoundation`, `VideoToolbox`, `CoreMotion`,
  `Network`, `UIKit`, `CoreMedia`, `CoreVideo`. `Foundation` and `Observation` only.
  This is the mechanical form of REQ-PORT-3: no platform type may cross an internal
  API boundary, so `CMSampleBuffer`, `AVCaptureDevice`, `CVPixelBuffer` and their
  equivalents cannot appear here — not in a signature, not in a stored property, not
  behind a `#if canImport`.
- **Depends on abstractions, never implementations.** Core declares the protocols that
  `Platform/` implements. Those protocols are the port surface: the enumerated,
  deliberately small set an additional platform must satisfy (REQ-PORT-2). Keep them
  documented and keep them few.
- **Vocabulary is protocol vocabulary.** Capability, viewpoint and format are expressed
  in the terms of PPCP §5.5, never in the terms of `AVCaptureDevice.Format` or
  `StreamConfigurationMap` (REQ-PORT-11).
- **Readiness, not permissions.** Core consumes a neutral readiness state. Permission
  acquisition and its failure handling stay in `Platform/` (REQ-PORT-13).
- **No timebase assumptions.** The mic-to-camera offset is a measured, uncertainty-
  bearing value with a known-equal special case — never a hardcoded zero (REQ-PORT-8,
  REQ-TIME-2).
- **Persisted shapes are neutral.** The session store and clip sidecar schema carry no
  platform-specific concepts; an Android-captured session must be indistinguishable to
  the host (REQ-PORT-12).

## Non-goal

Do not pre-generalise. The obligation is that the seams exist and stay clean, not that
every interface be built against a hypothetical second implementation (REQ-PORT-14).
