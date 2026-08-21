# CaptureCore — platform-neutral logic and state

A local Swift package, consumed by the app target via `project.yml`.

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

## Why this is a package

It began as a directory in the app target. Making it a package buys two things and
deliberately does not buy a third:

- **Encapsulation.** Anything the app reaches for has to be `public` on purpose.
  Extracting it immediately surfaced three members that screens had been reaching
  into by accident.
- **Speed.** `swift test` runs the whole suite natively on the host in
  milliseconds — no simulator, no runtime download, no Xcode. CI needs none of
  those either.
- **⚠ NOT the seam.** A package boundary does *not* stop a target importing
  `AVFoundation`: system frameworks come from the SDK, not from declared
  dependencies. This was tested, not assumed. The seam is held by
  `Tests/CaptureCoreTests/LayerPurityTests.swift`, which fails the build on a
  forbidden import — the same way `libwrist` asserts its sans-I/O rule in
  `tests/purity.cmake` rather than trusting a convention.

## Running the tests

```
swift test              # from this directory
make test-core          # from the repo root
```

## Relationship to libppcp

Most of what lives here will eventually be owned by `libppcp`, the MIT C reference
implementation of PPCP. It is Swift for now because the protocol specification is
normative and precedes implementation (§14.2), so the API is not something to
settle as a side effect of app work.

Keeping this package platform-free is what makes that later change a substitution
rather than a rewrite. The layer purity test is what keeps it platform-free.
