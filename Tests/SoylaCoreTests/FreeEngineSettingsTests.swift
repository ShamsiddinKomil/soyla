import Foundation
import Testing
@testable import SoylaCore

// FE-1: ProviderKind.apple, onDeviceLocale, fresh-install default (P1/P2/V5/R3/S2).
@Suite struct FreeEngineSettingsTests {
    private func suite() -> (UserDefaults, () -> Void) {
        let name = "ai.soyla.test.fe1.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (d, { dropTestDomain(name) })
    }

    @Test func localeDefaultTable() {
        let f = OnDeviceLocale.default(preferredLanguages:)
        #expect(f(["en-GB", "ru"]) == "en-GB")
        #expect(f(["ru-RU"]) == "en-US")
        #expect(f(["uz"]) == "en-US")
        #expect(f([]) == "en-US")
        #expect(f(["en"]) == "en-US")
        #expect(f(["ru-RU", "en-AU"]) == "en-AU")
        #expect(f(["en-PH"]) == "en-US")          // English, but not in the supported set
        #expect(f(["en-Latn-GB"]) == "en-GB")
    }

    @Test func oldBlobKeepsProviderAndGetsDefaultLocale() {
        let (d, cleanup) = suite(); defer { cleanup() }
        d.set(Data(#"{"provider":"google","sttModel":"gemini-3.5-flash","languageHint":"uz"}"#.utf8), forKey: "settings.v1")
        let s = SettingsStore(defaults: d, freshInstallOnDevice: true).current
        #expect(s.provider == .google && s.languageHint == "uz")
        #expect(s.onDeviceLocale == OnDeviceLocale.default(preferredLanguages: Locale.preferredLanguages))
        // A blob with no provider key still infers it (not the fresh-install default).
        let (d2, c2) = suite(); defer { c2() }
        d2.set(Data(#"{"sttModel":"google/gemini-3.5-flash"}"#.utf8), forKey: "settings.v1")
        #expect(SettingsStore(defaults: d2, freshInstallOnDevice: true).current.provider == .openRouter)
    }

    @Test func freshInstallIsAppleWhenAvailable() {
        let (d, cleanup) = suite(); defer { cleanup() }
        let s = SettingsStore(defaults: d, freshInstallOnDevice: true, preferredLanguages: ["en-GB", "ru"]).current
        #expect(s.provider == .apple && s.onDeviceLocale == "en-GB" && s.languageHint == nil)
        #expect(s.cleanupModel == "")
        #expect(!s.keyMissing(hasKey: { _ in false }))
        // Persisted: a second launch keeps it.
        #expect(SettingsStore(defaults: d).current.provider == .apple)
    }

    @Test func freshInstallIsCloudWhenUnavailable() {
        let (d, cleanup) = suite(); defer { cleanup() }
        #expect(SettingsStore(defaults: d, freshInstallOnDevice: false).current.provider == .openRouter)
        #expect(Settings.freshInstall(onDeviceAvailable: false, preferredLanguages: ["en-GB"]).provider == .openRouter)
    }

    @Test func availabilityAssumption() {
        #expect(OnDeviceLocale.assumedAvailable(osMajorVersion: 14))
        #expect(OnDeviceLocale.assumedAvailable(osMajorVersion: 26))
        #expect(!OnDeviceLocale.assumedAvailable(osMajorVersion: 13))
    }

    @Test func switchingProviderNeverTouchesLanguageHintOrLocale() throws {
        var s = Settings.freshInstall(onDeviceAvailable: true, preferredLanguages: ["en-AU"])
        #expect(s.languageHint == nil)
        s.provider = .openRouter; s.sttModel = ProviderKind.openRouter.defaultSTTModel
        #expect(s.languageHint == nil && s.onDeviceLocale == "en-AU")
        s.languageHint = "uz"
        s.provider = .apple
        s.provider = .openRouter
        #expect(s.languageHint == "uz")
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func noKeyNeededForAppleOrCustom() {
        var s = Settings()
        s.provider = .apple
        #expect(!s.keyMissing(hasKey: { _ in false }))
        s.provider = .custom
        #expect(!s.keyMissing(hasKey: { _ in false }))
        s.provider = .google
        #expect(s.keyMissing(hasKey: { $0 == .openRouter }))
        #expect(!s.keyMissing(hasKey: { $0 == .google }))
        s.provider = .openRouter
        #expect(s.keyMissing(hasKey: { $0 == .google }))
        #expect(ProviderKind.apple.hostedKey == nil)
    }

    @Test func appleProviderHasNoKeyAndNoBackendYet() throws {
        #expect(try ProviderFactory.apiKey(for: .apple) == "")
        #expect(ProviderKind.apple.label == "On this Mac")
        #expect(ProviderKind.apple.defaultCleanupModel == "")
        #expect(ProviderKind.apple.defaultSTTModel == "en-US")
        #expect(throws: SoylaError.self) { try ProviderFactory.transcriber(.apple, apiKey: "") }
        #expect(throws: SoylaError.self) { try ProviderFactory.cleaner(.apple, apiKey: "") }
        #expect(ProviderKind.allCases.contains(.apple))
    }
}
