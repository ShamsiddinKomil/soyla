import Testing
import Foundation
@testable import SoylaCore

/// Kept from the retired OnboardingFlowTests (D11): the permission rule itself is live (Setup, Home, the pill).
@Suite struct PermissionStateTests {
    @Test func deliveredEventOverridesStaleInputMonitoringDenial() {
        let p = PermissionState(mic: .granted, ax: true, inputMonitoring: false, eventsFlowing: true)
        #expect(p.inputMonitoringOK && p.allGranted)
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
