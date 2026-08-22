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

## The port surface so far

| Protocol | Implemented by | For |
|---|---|---|
| `CaptureDevice` | `Platform/AVFoundationCaptureDevice.swift` | camera, microphone, locks |
| `ByteChannel`, `PeerTransport` | `Platform/Network/PpcpTransport.swift` | PPCP's two channels (`CORE` T2) |
| `PeerTransportConnector`, `PeerTransportListener` | same | dialling and listening (`RV` §2) |

⚠ `Transport.swift` carries no `Network.framework` type and must not: the
negotiated TLS mode arrives here as a `NegotiatedSecurity` value built from a
version code and a ciphersuite number, which is all the protocol has ever meant
by it (`RV` 5.4k).

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

**The substitution has started.** `Package.swift` depends on `libppcp` as a SwiftPM
package (product `CPPCP`, plan A5). During co-development that is a sibling
`../libppcp` checkout; the git URL is recorded in `Package.swift` for when it is
tagged.

⛔ `import CPPCP` lives in **nine** files and nowhere else, and each is a place
where the library owns a rule this application must not re-decide:

| File | What is the library's |
|---|---|
| `Rendezvous.swift` | `PPCP-RV` §5.1 key derivation, §5.3 PSK identities |
| `Ppcp/LinkBind.swift` | `ENC` §2.1/§3/§5 — framing, the envelope, deterministic CBOR |
| `Ppcp/Declaration.swift` | `CORE` §5.6–5.8 — Source, CaptureProfile, and the I22/I28/I31 constructors |
| `Ppcp/DevicePeer.swift` | `CORE` §5.14 Capture, §5.15 Readiness, the injectable clock of §5.1, and the whole sans-I/O engine of `MSG` §3–§8 |
| `Ppcp/Achieved.swift` | `CORE` §5.8 — `AchievedSummary`, `AchievedFrames`, and `ENC` 4.1c–d's scalar-or-array forms |
| `Capture/FragmentRing.swift` | the `absent_reason` spellings of §5.14 |
| `Capture/StreamCoverage.swift` | the Stream `kind` spellings of §5.11 |
| `Capture/ReadinessMeasurement.swift` | §5.15's two constructors, which are the whole Readiness API |
| `Store/SessionStore.swift` | `ENC` §7 — the container, the writer's ordering refusals, and I34's capture index |

⚠ Four of those nine import the library only for **spellings** — `PPCP_ABSENT_*`,
`PPCP_STREAM_KIND_*`, `ppcp_readiness`. That is the point rather than a
shortcut: a token this application typed out would be a token only this
application understands, and an open registry is exactly where that goes wrong
quietly.

⚠ **Both fences are gone, and they were rewritten rather than switched on.**
`DevicePeer` and `SessionBundleWriter` were written against `planned.h` before L6
and L8 landed, behind `PPCP_L6_PEER_ENGINE` and `PPCP_L8_BUNDLE_WRITER`. The real
signatures differed in three places — `ppcp_peer_feed` gained an `out_consumed`,
`ppcp_peer_config` gained `versions`, `min_version` and `listener`, and
`ingest_policy` gained an `out_reason` — so a fence turned on unread would have
compiled against none of them. Coding ahead of the library is worth doing; trusting
what you wrote ahead of it is not.

⚠ The pattern in every one of them is the same and it is the point of plan A5:
**the invariant is held by the library's constructor, not by this application's
care.** I22 is not "remember to set the offset with `nominal_frame_start`"; it is
that `ppcp_timing_make` *refuses* that convention and the other constructor
*requires* the offset and its provenance. A Swift re-implementation of any of these
rules would agree with itself and meet nobody, which is what `PPCP-CONF` §2c calls
the single-implementation trap.

⛔ `CPPCP` is not a platform framework — it is a sans-I/O C library with no socket,
thread, timer, clock or file in it — and the forbidden list is unchanged. The
layer-purity test names it explicitly and **walks the tree recursively**, which it
did not before `Sources/CaptureCore/Ppcp/` existed: a purity test that quietly
checks less is worse than none, because the green tick is what stops anyone
looking.
