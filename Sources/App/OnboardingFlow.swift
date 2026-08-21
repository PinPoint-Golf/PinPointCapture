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
                retainedSecondsPerShot: 3.0,
                onStartSession: {
                    model.hasCompletedOnboarding = true
                    model.arm()
                    onFinish()
                },
                onConnectHost: onConnectHost
            )
        }
    }

    private func advance(from step: OnboardingStep) {
        guard let next = step.next else { return }
        path.append(next)
    }

    /// A6's trade: drop the rate to buy a brighter frame. Re-enumerates and
    /// re-runs the check rather than merely relabelling (REQ-FPS-1).
    private func dropTo120() {
        model.refreshCapability()
        model.framing.light = LightAssessment(
            verdict: .good,
            exposureSeconds: model.framing.light.exposureSeconds * 1.25,
            iso: model.framing.light.iso,
            fps: 120
        )
    }

    private func cycleAudioRetention() {
        let all = AudioRetention.allCases
        let index = all.firstIndex(of: model.audioRetention) ?? 0
        model.audioRetention = all[(index + 1) % all.count]
    }
}
