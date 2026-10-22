import Foundation
import Testing
@testable import SoylaCore

// FE-6: `soyla replay --provider apple`. The on-device engine has no correction pass and no script check.
@Suite struct ReplayAppleTests {
    @Test func parseProviderAcceptsApple() {
        #expect(ReplayCLI.parseProvider("apple") == .apple)
        #expect(ReplayCLI.parseProvider("Apple") == .apple)
        #expect(ReplayCLI.parseProvider("google") == .google)
    }

    @Test func parseKeepsAppleAndLanguage() throws {
        let a = try ReplayCLI.parse(["x.wav", "--provider", "apple", "--language", "en-GB"])
        #expect(a.provider == .apple && a.language == "en-GB" && a.file == "x.wav")
    }

    @Test func languageTable() throws {
        func locale(_ lang: String?) throws -> String {
            try ReplayCLI.enginePlan(kind: .apple, cleanupRequested: false, language: lang, settingsLocale: "en-AU").locale ?? "-"
        }
        #expect(try locale(nil) == "en-AU")        // no flag: the Settings locale
        #expect(try locale("en") == "en-US")
        #expect(try locale("en-GB") == "en-GB")
        #expect(try locale("EN-gb") == "en-GB")
        #expect(try locale("en_IN") == "en-IN")
        for bad in ["ru", "uz", "fr", "en-PH", "en-XX", "", "english"] {
            #expect(throws: SoylaError.self) { try locale(bad) }
        }
    }

    @Test func appleBuildsNoCleanerAndNoScriptCheck() throws {
        let p = try ReplayCLI.enginePlan(kind: .apple, cleanupRequested: true, language: "en-GB", settingsLocale: "en-US")
        #expect(!p.buildsCleaner && !p.runsScriptCheck && !p.cleanup)
        #expect(p.models == ["en-GB"])            // the row's model carries the locale
        #expect(p.meta == ["provider": "apple"])  // so reports can group by engine, even on a failed run
    }

    @Test func cloudPlanIsUnchanged() throws {
        let p = try ReplayCLI.enginePlan(kind: .google, cleanupRequested: true, language: "uz", settingsLocale: "en-US")
        #expect(p.buildsCleaner && p.runsScriptCheck && p.cleanup)
        #expect(p.locale == nil && p.models == nil && p.meta.isEmpty)   // "uz" is not validated for cloud
        let q = try ReplayCLI.enginePlan(kind: .openRouter, cleanupRequested: false, language: nil, settingsLocale: "en-US")
        #expect(q.buildsCleaner && q.runsScriptCheck && !q.cleanup)
    }
}
