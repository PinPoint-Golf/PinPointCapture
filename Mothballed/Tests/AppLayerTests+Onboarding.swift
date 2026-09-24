//  AppLayerTests+Onboarding.swift
//  Mothballed with `OnboardingStateStore` (#121). Lifted verbatim out of
//  `Tests/AppLayerTests.swift`'s `AppLayerTests` suite; put it back inside that
//  suite when onboarding returns.

    @Test("Onboarding completion survives a relaunch")
    func onboardingPersists() throws {
        let suite = "ppcp.tests.onboarding"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        #expect(OnboardingStateStore.hasCompleted(in: defaults) == false)
        OnboardingStateStore.setCompleted(true, in: defaults)
        // ⛔ The whole point: a *second* read, as a fresh launch would do.
        #expect(OnboardingStateStore.hasCompleted(in: defaults))
        OnboardingStateStore.reset(in: defaults)
        #expect(OnboardingStateStore.hasCompleted(in: defaults) == false)
    }

