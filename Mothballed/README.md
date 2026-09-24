# Mothballed

Code that is **not in the build**, kept because it will probably be wanted back.

On 24 September 2026 PPC was narrowed to one job. It is a camera on a tripod, connected to PinPoint Studio and left alone, and Studio drives it over PPCP. It has no offline at-range capture and no on-phone video, and its UI shows connection and recording status and nothing else (#121). Offline recording may return. When it does, start here rather than from the design pack.

## How this folder works

- Files keep their original paths under this folder: `Mothballed/Sources/UI/Capture/ArmedScreen.swift` came from `Sources/UI/Capture/ArmedScreen.swift`. They were moved with `git mv`, so `git log --follow` still shows their history.
- Nothing here compiles. `project.yml` globs only `Sources/` and `Tests/`, and the Core package compiles only `Packages/Core/Sources/CaptureCore`. The files are therefore free to rot against the APIs around them. Expect to fix compile errors when reinstating something.
- To reinstate a file, `git mv` it back to its original path and do what its row below says.

## What is here and what reinstating it needs

### Screens (#121)

| File | What it was | To reinstate |
|---|---|---|
| `Sources/UI/Capture/ArmedScreen.swift` | C1: full-bleed live preview, local Arm/Disarm, last-shot thumbnail, *Session · n*, framing, telemetry rail. | Restore the `livePreview` environment injection in `RootView` (it was `LivePreviewProvider { … CameraPreview(device: model.captureDevice, …) }`). `AVFoundationCaptureDevice.attachPreview(to:)` is still in place. Re-add the `hostSearch` mapping, which now lives as `RootView.connectionStatus`. |
| `Sources/UI/Capture/ReplayScreen.swift` | C2: replay and markup. Every callback was still a no-op. | Needs `CapturePlaceholders`. Needs real video: nothing ever played a clip. |
| `Sources/UI/Capture/SessionLibraryScreen.swift` | C3: the on-device library. | `AppModel.bundlesOnDevice()` (was `libraryRows()`) still exists. `deleteRecordedBundle` was removed; recover it from the history of `Sources/App/AppModel.swift`. ⚠ Since #122 bundles are deleted after delivery, so a library would have nothing to list unless retention changes too. |
| `Sources/UI/Capture/CapturePlaceholders.swift` | Preview, replay-frame and thumbnail stand-ins. | Used by C1, C2, C3 and `LivePreviewProvider`. |
| `Sources/UI/Capture/CaptureScreenStyle.swift` | Tone and format helpers for C1–C3. | Only those screens used it. |
| `Sources/UI/Host/ConnectHostView.swift` | B1: discovered host, enter a code, cable, *Capture without a host*. | `HostDisclosureRow` was lifted out of it into `Sources/UI/Host/HostDisclosureRow.swift`, which stays in the build. Remove the standalone row. |
| `Sources/UI/Host/HostPanelView.swift` | B3: host sheet with four link states, telemetry, transfer queue, *Forget*. | Its `primaryHostAction` wiring is in the history of `Sources/App/RootView.swift`. `AppModel.transferQueue` still exists. |
| `Sources/UI/Host/ReconcileSessionView.swift` | B5: merge an offline session into a Studio one (REQ-OFF-12). Nothing ever presented it. | Needs `Packages/Core/Sources/CaptureCore/SessionMatch.swift` (below) and `ChoiceCard`. |
| `Sources/UI/Onboarding/*` (9 files) | A1–A7: welcome, how it works, host vs standalone (`CaptureContext` is defined here), permissions and the audio-retention choice, pair step, placement, framing check, ready to capture. | Needs `Sources/App/OnboardingFlow.swift`, `Sources/Platform/OnboardingStateStore.swift`, and `AppModel.hasCompletedOnboarding` and `captureContext` restored. Permissions are now requested on launch by `RootView`. |
| `Sources/App/OnboardingFlow.swift` | The onboarding push stack. Its last step, A6, armed locally, which was a hostless session. | See above. Do not let it arm without a host again. |
| `Sources/UI/DesignSystem/LivePreviewProvider.swift` | The environment seam that let C1 and A6 show the camera. | Needs `CapturePlaceholders` and `CameraPreview`. |
| `Sources/UI/DesignSystem/ChoiceCard.swift` | A3 and B5's selectable card. | |
| `Sources/Platform/CameraPreview.swift` | The `AVCaptureVideoPreviewLayer` host view. | ⚠ Not the PPCP preview *stream* to Studio, which is `Sources/Platform/Capture/LivePreview.swift` and stays in the build. |
| `Sources/Platform/OnboardingStateStore.swift` | Persisted "onboarding done" flag. | |
| `Packages/Core/Sources/CaptureCore/SessionMatch.swift` | `SessionMatchCandidate`, B5's model. | |
| `Tests/AppLayerTests+Onboarding.swift` | `onboardingPersists`, lifted out of `AppLayerTests`. | Paste it back into that suite. |

### What stayed in the build on purpose

- **The PPCP preview stream to Studio** (`PreviewProducer`, `LivePreview`, `AppModel.openPreview`). Studio's preview tile needs it.
- **`RecordingSession`'s hostless branch** (`Control.hostless`) and `HostlessSessionTests`. The code can still record without a host; only the app no longer offers it.
- **`AnnotationStore` / Markup.** It has no UI, and it is the evidence behind the Markup profile claim, which is under discussion (see `docs/conformance/ppcp-conformance.md` §1).
- **`AppModel.framing`, `runSelfTest`, `remeasure`.** Tests use them, and they cost nothing when unused.
- **`MicToBallDistanceView`, `RememberedStudiosView`, `PairingView`, `ScanPairingCodeView`, `JoinNetworkView`, `LocalNetworkBlockedView`.** All are reachable from the settings sheet or the pairing flow.
