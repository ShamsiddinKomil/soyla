import Testing
import Foundation
@testable import SoylaCore

@Suite struct OnboardingFlowTests {
    let granted = PermissionState(mic: .granted, ax: true, inputMonitoring: true)

    @Test func welcomeAlwaysContinues() {
        var f = OnboardingFlow()
        #expect(f.step == .welcome && f.canContinue && !f.canGoBack)
        let moved = f.next()
        #expect(moved)
        #expect(f.step == .microphone)
    }

    @Test func microphoneNeedsGrantAndVoice() {
        var f = OnboardingFlow(); f.next()
        #expect(!f.canContinue)
        f.micHeard = true
        #expect(!f.canContinue)                          // heard but not granted (impossible, but gate on both)
        f.permissions.mic = .granted; f.micHeard = false
        #expect(!f.canContinue && f.blocker == "Say something so the bars move.")
        f.micHeard = true
        #expect(f.canContinue && f.blocker == nil)
        let moved = f.next()
        #expect(moved && f.step == .permissions)
    }

    @Test func nextIsRefusedWhileBlocked() {
        var f = OnboardingFlow(); f.next()
        let moved = f.next()
        #expect(!moved)
        #expect(f.step == .microphone)
    }

    @Test func permissionsNeedBothCards() {
        var f = at(.permissions)
        f.permissions = PermissionState(mic: .granted, ax: true, inputMonitoring: false)
        #expect(!f.canContinue && f.blocker == "Turn Soyla on in Input Monitoring.")
        f.permissions = PermissionState(mic: .granted, ax: false, inputMonitoring: true)
        #expect(!f.canContinue && f.blocker == "Turn Soyla on in Accessibility.")
        f.permissions = granted
        #expect(f.canContinue)
    }

    @Test func deliveredEventOverridesStaleInputMonitoringDenial() {
        var f = at(.permissions)
        f.permissions = PermissionState(mic: .granted, ax: true, inputMonitoring: false, eventsFlowing: true)
        #expect(f.permissions.inputMonitoringOK && f.permissions.allGranted)
        #expect(f.canContinue)
    }

    @Test func hotkeyStepNeedsProofAndHotkeysStayInactiveUntilTryIt() {
        var f = at(.permissions)
        f.permissions = granted
        f.next()
        #expect(f.step == .hotkey && !f.canContinue && !f.hotkeysActive)
        f.hotkeyProven = true
        f.next()
        #expect(f.step == .key && !f.canContinue && !f.hotkeysActive)
        f.keyVerified = true
        f.next()
        #expect(f.step == .tryIt && f.hotkeysActive && f.isLastStep)
    }

    @Test func tryItFinishesOnlyWhenTextChanged() {
        var f = at(.tryIt)
        #expect(!f.canContinue)
        let refused = f.next()
        #expect(!refused && !f.finished)
        f.tryTextChanged = true
        let moved = f.next()
        #expect(moved && f.finished)
    }

    @Test func skipPermissionsJumpsPastHotkeyProof() {
        var f = at(.permissions)
        f.skipPermissions()
        #expect(f.step == .key && f.permissionsSkipped)
        f.back()
        #expect(f.step == .permissions)                  // back skips the hotkey step too
        f.skipPermissions()
        f.keyVerified = true
        f.next()
        #expect(f.step == .tryIt && f.canContinue)       // can finish without dictating; view shows a warning
        let moved = f.next()
        #expect(moved && f.finished)
    }

    @Test func grantingAfterSkipRestoresTheHotkeyStep() {
        var f = at(.permissions)
        f.skipPermissions(); f.back()
        f.permissions = granted
        f.next()
        #expect(f.step == .hotkey && !f.permissionsSkipped)
    }

    @Test func skipOnlyWorksOnPermissionsStep() {
        var f = OnboardingFlow()
        f.skipPermissions()
        #expect(f.step == .welcome && !f.permissionsSkipped)
    }

    @Test func skipMicrophoneAndKeyStepsAllowFinishing() {
        var f = at(.microphone)
        f.skip()
        #expect(f.step == .permissions && f.micSkipped)
        f.permissions = granted
        f.next()
        #expect(f.step == .hotkey && f.micSkipped)   // stays flagged so the last step can warn
        f.hotkeyProven = true
        f.next()
        #expect(f.step == .key)
        f.skip()
        #expect(f.step == .tryIt && f.keySkipped && f.canContinue)
        let moved = f.next()
        #expect(moved && f.finished)
    }

    @Test func skipDoesNothingOnOtherSteps() {
        var f = at(.hotkey)
        f.skip()
        #expect(f.step == .hotkey && !f.anySkipped)
    }

    @Test func restartKeepsPermissionsOnly() {
        var f = at(.tryIt)
        f.tryTextChanged = true
        f.restart()
        #expect(f.step == .welcome && !f.tryTextChanged && !f.micHeard && f.permissions == granted)
    }

    /// Walks a flow with everything satisfied up to `step`.
    private func at(_ step: OnboardingStep) -> OnboardingFlow {
        var f = OnboardingFlow()
        f.permissions = granted; f.micHeard = true; f.hotkeyProven = true; f.keyVerified = true
        while f.step != step { let moved = f.next(); #expect(moved); if !moved { break } }
        f.micHeard = false; f.hotkeyProven = step.rawValue > OnboardingStep.hotkey.rawValue
        f.keyVerified = step.rawValue > OnboardingStep.key.rawValue
        if step == .permissions { f.permissions = PermissionState(mic: .granted) }
        return f
    }
}

@Suite struct HotkeyProbeTests {
    @Test func deliveredHotkeyWinsEvenWithTogglesOff() {
        #expect(HotkeyProbe.verdict(elapsed: 1, hotkeySeen: true, anyEventSeen: false, toggleOn: false) == .proven)
    }
    @Test func noToggleNoTap() {
        #expect(HotkeyProbe.verdict(elapsed: 0, hotkeySeen: false, anyEventSeen: false, toggleOn: false) == .noPermission)
    }
    @Test func waitsFiveSeconds() {
        #expect(HotkeyProbe.verdict(elapsed: 4.9, hotkeySeen: false, anyEventSeen: false, toggleOn: true) == .waiting)
    }
    @Test func toggleOnButNothingDeliveredIsTheTCCTrap() {
        // Silence for 5 s is still "waiting" (the reader may not have pressed yet); 12 s of nothing is the trap.
        #expect(HotkeyProbe.verdict(elapsed: 5, hotkeySeen: false, anyEventSeen: false, toggleOn: true) == .waiting)
        #expect(HotkeyProbe.verdict(elapsed: 11.9, hotkeySeen: false, anyEventSeen: false, toggleOn: true) == .waiting)
        #expect(HotkeyProbe.verdict(elapsed: 12, hotkeySeen: false, anyEventSeen: false, toggleOn: true) == .notDelivered)
    }
    @Test func otherKeysButNoFnMeansNoFnKey() {
        #expect(HotkeyProbe.verdict(elapsed: 6, hotkeySeen: false, anyEventSeen: true, toggleOn: true) == .noHotkeyKey)
    }
}

@Suite struct ConflictingAppsTests {
    @Test func detectsKnownDictationApps() {
        let running = ["com.apple.finder", "com.electron.wispr-flow", "ai.amical.desktop", "com.superduper.superwhisper"]
        #expect(ConflictingApps.detect(running) == ["Wispr Flow", "Amical", "Superwhisper"])
    }
    @Test func wisprNativeIdPrefixAndDedup() {
        #expect(ConflictingApps.detect(["com.wisprflow.mac", "com.electron.wispr-flow"]) == ["Wispr Flow"])
    }
    @Test func nothingWhenClean() {
        #expect(ConflictingApps.detect(["com.apple.Safari", "ai.soyla.app", "com.wispr.other"]).isEmpty)
    }
}

@Suite struct OnboardingSettingsTests {
    @Test func freshInstallIsNotDone() {
        #expect(Settings().onboardingDone == false)
    }
    @Test func preA4BlobCountsAsAlreadySetUp() throws {
        let blob = Data(#"{"sttModel":"google/gemini-3.5-flash","hotkey":"fn"}"#.utf8)
        #expect(try JSONDecoder().decode(Settings.self, from: blob).onboardingDone == true)
    }
    @Test func onboardingDoneRoundTrips() throws {
        var s = Settings(); s.onboardingDone = false
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(back.onboardingDone == false)
        s.onboardingDone = true
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)).onboardingDone)
    }
    @Test func persistsThroughTheStore() {
        let suite = "ai.soyla.tests.onboarding.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { dropTestDomain(suite) }
        let store = SettingsStore(defaults: d)
        #expect(store.current.onboardingDone == false)
        store.update { $0.onboardingDone = true }
        #expect(SettingsStore(defaults: d).current.onboardingDone == true)
    }
}

// FE-5: the key step became "How should Soyla listen?" (free on-device or cloud key).
@Suite struct OnboardingEngineStepTests {
    private func atEngineStep() -> OnboardingFlow {
        var f = OnboardingFlow()
        f.permissions = PermissionState(mic: .granted, ax: true, inputMonitoring: true); f.micHeard = true; f.hotkeyProven = true
        while f.step != .key { let moved = f.next(); #expect(moved); if !moved { break } }
        return f
    }

    @Test func stepIsNamedForTheChoice() {
        #expect(OnboardingStep.key.title == "How should Soyla listen?")
    }

    @Test func cloudStillNeedsAVerifiedKey() {
        var f = atEngineStep()
        #expect(f.engine == .cloud && !f.canContinue && f.blocker == "Save a key and press Test.")
        f.modelState = .ready                       // a ready model does not unlock the cloud path
        #expect(!f.canContinue)
        f.keyVerified = true
        #expect(f.canContinue)
    }

    @Test func freeNeedsAReadyModelNotAKey() {
        var f = atEngineStep()
        f.engine = .free
        #expect(!f.canContinue)
        f.keyVerified = true                        // a verified key does not unlock the free path
        #expect(!f.canContinue)
        f.modelState = .downloading(0.4)
        #expect(!f.canContinue && f.blocker == "Wait for the English model, or skip for now.")
        f.modelState = .ready
        #expect(f.canContinue && f.blocker == nil)
        let moved = f.next()
        #expect(moved && f.step == .tryIt && !f.keySkipped)
    }

    @Test func freeBlockerSaysWhatToDo() {
        var f = atEngineStep()
        f.engine = .free
        f.modelState = .needsPermission
        #expect(f.blocker == "Allow Speech Recognition, or skip for now.")
        f.modelState = .unavailable(.noOnDeviceModel)
        #expect(f.blocker == "The free engine isn't available on this Mac. Choose Cloud, or skip for now.")
        f.modelState = nil
        #expect(f.blocker == "Wait for the English model, or skip for now.")
    }

    @Test func skipForNowWorksOnTheFreePathToo() {
        var f = atEngineStep()
        f.engine = .free
        f.modelState = .downloading(0.1)
        f.skip()
        #expect(f.step == .tryIt && f.keySkipped && f.canContinue)
    }

    @Test func restartResetsTheChoice() {
        var f = atEngineStep()
        f.engine = .free; f.modelState = .ready
        f.restart()
        #expect(f.engine == .cloud && f.modelState == nil)
    }
}
