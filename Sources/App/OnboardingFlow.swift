//  OnboardingFlow.swift
//  Four screens as a linear push stack — A1, A4, B1, A6.
//
//  ⛔ **The order follows where the golfer is standing** (Mark, 25 August 2026):
//  pair at the Mac, then walk over and set the phone down. See `OnboardingStep`
//  for why framing used to be third and why that was wrong.
//
//  ⚠ There is no skip on A4 or A6. Both have a "carry on anyway" out instead: a
//  refused permission and a marginal light reading are decisions, not blocks.
//  B1 does have one, and it means something different — see `PairStepScreen`.

import SwiftUI
import CaptureCore

struct OnboardingFlow: View {
    @Bindable var model: AppModel
    /// Presents B1 modally — still used by A1's *Pair my phone*, which is a
    /// shortcut rather than the sequence.
    let onConnectHost: () -> Void
    /// ⛔ B1a directly, not B1. The pairing STEP already lists the choices, so
    /// routing it through another list would be a screen showing itself.
    let onScanPairingCode: () -> Void
    /// The host, once a link has settled — what the pairing step reports.
    let hostName: String?
    let isPaired: Bool
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

        case .pairing:
            PairStepScreen(
                hostName: hostName,
                isPaired: isPaired,
                onScanPairingCode: onScanPairingCode,
                onContinue: { advance(from: .pairing) },
                onSkip: { advance(from: .pairing) }
            )

        case .framingCheck:
            // ⛔ **The last screen, so this is where onboarding ends.** It used
            // to advance to A7, whose five numbers are a receipt shown on a
            // screen a golfer immediately leaves; they live on the capture
            // screen and in the host panel now, where they can be acted on.
            FramingCheckScreen(
                framing: model.framing,
                onUse120fps: dropTo120,
                onArm: {
                    model.hasCompletedOnboarding = true
                    model.arm()
                    onFinish()
                }
            )
            .task {
                // Warm the session so A6 has something to show and A7's measured
                // row is real rather than empty.
                model.warmUp()
                await model.runSelfTest()
            }

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
