import Testing
import Foundation
@testable import SoylaCore

// FE-3: on-device model availability reducer, reservation bookkeeping, Speech Recognition row visibility.
@Suite struct OnDeviceAvailabilityTests {
    private func state(os: Int, asset: OnDeviceAssetStatus?, onDevice: Bool = true,
                       auth: SpeechAuthorization = .notDetermined, progress: Double? = nil) -> OnDeviceModelState {
        OnDeviceAvailability.state(osMajor: os, asset: asset, legacyOnDevice: onDevice, legacyAuth: auth, progress: progress)
    }

    @Test func analyzerTable() {
        #expect(state(os: 26, asset: .installed) == .ready)
        #expect(state(os: 26, asset: .supported) == .needsDownload)
        #expect(state(os: 26, asset: .downloading, progress: 0.4) == .downloading(0.4))
        #expect(state(os: 26, asset: .downloading) == .downloading(0))
        #expect(state(os: 26, asset: .unsupported) == .unavailable(.localeUnsupported))
        // Our own download is running but the system still says `supported`: show the progress.
        #expect(state(os: 26, asset: .supported, progress: 0.25) == .downloading(0.25))
        // macOS 26 needs no speech authorization (FE-0), whatever the legacy mirror says.
        #expect(state(os: 26, asset: .installed, onDevice: false, auth: .denied) == .ready)
        #expect(state(os: 27, asset: .installed) == .ready)
    }

    @Test func progressIsClamped() {
        #expect(state(os: 26, asset: .downloading, progress: 1.7) == .downloading(1))
        #expect(state(os: 26, asset: .downloading, progress: -0.2) == .downloading(0))
    }

    @Test func legacyTable() {
        #expect(state(os: 15, asset: nil, onDevice: true, auth: .authorized) == .ready)
        #expect(state(os: 14, asset: nil, onDevice: true, auth: .authorized) == .ready)
        #expect(state(os: 15, asset: nil, onDevice: true, auth: .notDetermined) == .needsPermission)
        #expect(state(os: 15, asset: nil, onDevice: true, auth: .denied) == .needsPermission)
        #expect(state(os: 15, asset: nil, onDevice: false, auth: .denied) == .needsPermission)
        #expect(state(os: 15, asset: nil, onDevice: false, auth: .authorized) == .unavailable(.noOnDeviceModel))
        #expect(state(os: 15, asset: nil, onDevice: true, auth: .restricted) == .unavailable(.restricted))
        // An asset status on 14–15 is impossible; it is ignored rather than trusted.
        #expect(state(os: 15, asset: .installed, onDevice: false, auth: .authorized) == .unavailable(.noOnDeviceModel))
    }

    @Test func tooOldOrNoAnalyzerReading() {
        #expect(state(os: 13, asset: nil, auth: .authorized) == .unavailable(.osTooOld))
        // macOS 26 without an analyzer reading (e.g. a fallback Mac) uses the legacy rules.
        #expect(state(os: 26, asset: nil, onDevice: true, auth: .authorized) == .ready)
    }

    @Test func freshInstallAnswer() {
        #expect(OnDeviceAvailability.freshInstallAvailable(osMajor: 26, legacyOnDevice: { Issue.record("not on 26"); return false }))
        #expect(OnDeviceAvailability.freshInstallAvailable(osMajor: 15, legacyOnDevice: { true }))
        #expect(!OnDeviceAvailability.freshInstallAvailable(osMajor: 15, legacyOnDevice: { false }))
        #expect(!OnDeviceAvailability.freshInstallAvailable(osMajor: 13, legacyOnDevice: { true }))
    }

    @Test func speechRowOnlyOnLegacyWithFreeEngine() {
        for p in ProviderKind.allCases {
            #expect(OnDeviceAvailability.showsSpeechPermissionRow(osMajor: 14, provider: p) == (p == .apple))
            #expect(OnDeviceAvailability.showsSpeechPermissionRow(osMajor: 15, provider: p) == (p == .apple))
            #expect(!OnDeviceAvailability.showsSpeechPermissionRow(osMajor: 26, provider: p))
            #expect(!OnDeviceAvailability.showsSpeechPermissionRow(osMajor: 27, provider: p))
        }
    }

    @Test func permissionStateDefaultsAndAllGrantedIgnoresSpeech() {
        var p = PermissionState(mic: .granted, ax: true, inputMonitoring: true)
        #expect(p.speech == .notDetermined && p.allGranted)
        p.speech = .denied
        #expect(p.allGranted)   // only the free engine on 14–15 needs it; the row handles that
    }
}

@Suite struct OnDeviceReservationTests {
    typealias R = OnDeviceReservations

    @Test func alreadyReservedNeedsNothing() {
        #expect(R.plan(wanted: "en-US", reserved: ["en_US"], owned: [], max: 5) == .alreadyReserved)
    }

    @Test func roomLeftJustReserves() {
        #expect(R.plan(wanted: "en-GB", reserved: ["en-US", "fr-FR"], owned: ["en-US"], max: 5) == .reserve)
        #expect(R.plan(wanted: "en-GB", reserved: [], owned: [], max: 5) == .reserve)
    }

    @Test func fullReleasesOnlyOurOldest() {
        let reserved = ["de-DE", "en-US", "fr-FR", "en-AU", "ja-JP"]
        // owned is oldest first; en-AU is older than en-US here.
        #expect(R.plan(wanted: "en-GB", reserved: reserved, owned: ["en-AU", "en-US"], max: 5) == .releaseThenReserve("en-AU"))
        // An owned locale that is no longer reserved (released elsewhere) is skipped.
        #expect(R.plan(wanted: "en-GB", reserved: reserved, owned: ["en-CA", "en-US"], max: 5) == .releaseThenReserve("en-US"))
    }

    @Test func fullWithNothingOfOursIsFull() {
        let reserved = ["de-DE", "en-US", "fr-FR", "es-ES", "ja-JP"]
        #expect(R.plan(wanted: "en-GB", reserved: reserved, owned: [], max: 5) == .full)
        #expect(R.plan(wanted: "en-GB", reserved: reserved, owned: ["en-GB"], max: 5) == .full)
        #expect(R.plan(wanted: "en-GB", reserved: [], owned: [], max: 0) == .full)
    }

    @Test func bookkeepingAfterReserve() {
        #expect(R.owned(["en-AU", "en-US"], released: "en-AU", reserved: "en-GB") == ["en-US", "en-GB"])
        #expect(R.owned(["en-US"], released: nil, reserved: "en_US") == ["en-US"])
        #expect(R.owned([], released: nil, reserved: "en-GB") == ["en-GB"])
    }

    @Test func storeRoundTrip() throws {
        let name = "test.ondevice.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name)); defer { dropTestDomain(name) }
        #expect(R.load(d).isEmpty)
        R.save(["en-US", "en-GB"], to: d)
        #expect(R.load(d) == ["en-US", "en-GB"])
    }
}
