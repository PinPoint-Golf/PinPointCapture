//  OnboardingFlow.swift
//  A1–A7 as a linear push stack.
//
//  ⚠ There is no skip on A4 or A6. Both have a "carry on anyway" out instead: a
//  refused permission and a marginal light reading are decisions, not blocks.

import SwiftUI
import CaptureCore

struct OnboardingFlow: View {
    @Bindable var model: AppModel
    /// Presents B1 modally, per the handoff: B1 is modal from A7.
    let onConnectHost: () -> Void
    /// A8. ⚠ Onboarding runs its own `NavigationStack` over `OnboardingStep`, so
    /// it cannot push an `AppRoute` — the shell presents it instead.
    let onOpenMicToBallDistance: () -> Void
    let onFinish: () -> Void

    @State private var path: [OnboardingStep] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeScreen(
                capability: model.capability,
                onGetStarted: { advance(from: .welcome) },
                onHavePairingCode: onConnectHost
            )
            .navigationDestination(for: OnboardingStep.self, destination: screen(for:))
        }
        .task {
            // A1 is the first thing shown, so capability must be real before it
            // draws. Discovery needs no permission (REQ-FPS-1).
            model.refreshCapability()
        }
    }

    @ViewBuilder
    private func screen(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            WelcomeScreen(capability: model.capability,
                          onGetStarted: { advance(from: .welcome) },
                          onHavePairingCode: onConnectHost)

        case .howItWorks:
            HowItWorksScreen(onContinue: { advance(from: .howItWorks) })

        case .hostOrStandalone:
            HostOrStandaloneScreen(
                selection: model.captureContext,
                onSelect: { model.captureContext = $0 },
                onContinue: { advance(from: .hostOrStandalone) }
            )

        case .permissions:
            PermissionsScreen(
                permissions: model.permissions,
                audioRetention: model.audioRetention,
                onChangeAudioRetention: cycleAudioRetention,
                // ⚠ Local network is requested last, and only by explicit tap.
                // There is no API to read the result back, so a failure surfaces
                // as B6 rather than as a silent denial (REQ-DISC-6).
                onAllowLocalNetwork: { model.noteLocalNetworkRequested() },
                onContinue: { advance(from: .permissions) }
            )
            .task {
                await model.requestCapturePermissions()
            }

        case .placement:
            PlacementGuidanceScreen(onCheckFraming: { advance(from: .placement) })

        case .framingCheck:
            FramingCheckScreen(
                framing: model.framing,
                onUse120fps: dropTo120,
                onArm: { advance(from: .framingCheck) }
            )
            .task {
                // Warm the session so A6 has something to show and A7's measured
                // row is real rather than empty.
                model.warmUp()
                await model.runSelfTest()
            }

        case .ready:
            ReadyToCaptureScreen(
                capability: model.capability,
                storage: model.storage,
                // ⛔ Was a hardcoded `3.0`. The clip window is the detector's,
                // and it is 4.5 s — pre-roll plus post-roll.
                retainedSecondsPerShot: DetectAndMint.Configuration
                    .defaultClipWindowSeconds,
                micToBall: model.micToBallDistance,
                onStartSession: {
                    model.hasCompletedOnboarding = true
                    model.arm()
                    onFinish()
                },
                onConnectHost: onConnectHost,
                onOpenMicToBallDistance: onOpenMicToBallDistance
            )
        }
    }

    private func advance(from step: OnboardingStep) {
        guard let next = step.next else { return }
        path.append(next)
    }

    /// A6's trade: drop the rate to buy a brighter frame.
    ///
    /// ⛔ **It used to fabricate the answer.** The old body multiplied the
    /// exposure by 1.25, kept the ISO, stamped `verdict: .good` and called it a
    /// measurement — so the button always "worked", on every device, in every
    /// room, including a dark one. A6's own doc comment says this path
    /// "re-enumerates and re-runs the check rather than merely relabelling"; now
    /// it does.
    ///
    /// ⚠ It re-measures on a real ≤120 fps mode and lets the result be whatever
    /// it is. If the light is still marginal at 120, the screen says so.
    private func dropTo120() {
        Task { await model.remeasure(atMost: 120) }
    }

    private func cycleAudioRetention() {
        let all = AudioRetention.allCases
        let index = all.firstIndex(of: model.audioRetention) ?? 0
        model.audioRetention = all[(index + 1) % all.count]
    }
}
