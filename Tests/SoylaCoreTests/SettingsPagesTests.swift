import Testing
import Foundation
@testable import SoylaCore

// APP-1 (c): the other Settings pages, History and the pill. Rules: one subtitle
// line of at most 6 words, 2–4-word captions (longer text goes into an ⓘ), setup's status words, failures that name
// their fix and route into setup.

// MARK: - Pill failures: AppStrings copy and setup routes

@Suite struct PillCopyTests {
    private struct Fake: Error {}

    /// Every card the app can show (the catalog), in English as built.
    private static var catalog: [PillFailure] {
        var c: [PillFailure] = [
            .from(ScriptCheckError(.uzbekCyrillic), stage: "transcribe"),
            .from(URLError(.notConnectedToInternet), stage: "transcribe"),
            .from(URLError(.timedOut), stage: "transcribe"),
            .from(URLError(.badServerResponse), stage: "transcribe"),
            .from(SoylaError.missingAPIKey("FAKE"), stage: "transcribe"),
            .from(SoylaError.keychainBlocked(denied: true), stage: "transcribe"),
            .from(SoylaError.keychainBlocked(denied: false), stage: "transcribe"),
            .from(SoylaError.emptyTranscript, stage: "transcribe"),
            .from(SoylaError.decode("FAKE"), stage: "transcribe"),
            .from(SoylaError.permission("FAKE"), stage: "paste"),
            .from(SoylaError.audio("FAKE"), stage: "record"),
            .from(Fake(), stage: "record"),
            .from(Fake(), stage: "transcribe"),
            .onDeviceHint, .onDevice(reason: "model-not-installed"), .onDevice(reason: "needs-permission"), .onDevice(reason: "x"),
            .noSound(device: "FAKE AirPods"),
            .missedSpeech,
        ]
        for code in [401, 402, 429, 503, 418] { c.append(.from(SoylaError.http(status: code, body: "FAKE"), stage: "transcribe")) }
        for r in [PasteBlockReason.noAccessibility, .secureInput, .focusChanged, .postFailed] { c.append(.paste(r)) }
        return c
    }

    @Test func everyCardIsTranslated() {
        for f in Self.catalog {
            for l in [UILanguage.uz, .ru] {
                let t = f.localized(l)
                #expect(t.title != f.title, "\(l): \(f.title)")
                #expect(f.hint.isEmpty ? t.hint.isEmpty : t.hint != f.hint, "\(l): \(f.hint)")
                #expect(t.kind == f.kind && t.canRetry == f.canRetry && t.fix == f.fix)
            }
            #expect(f.localized(.en) == f)
        }
    }

    @Test func dynamicPartsSurvive() {
        let uz = PillFailure.noSound(device: "FAKE AirPods").localized(.uz)
        #expect(uz.title.contains("FAKE AirPods"))
        let ru = PillFailure.from(SoylaError.http(status: 418, body: "FAKE"), stage: "t").localized(.ru)
        #expect(ru.title.contains("418"))
    }

    @Test func noCardPointsAtOldSettingsPages() {
        for f in Self.catalog {
            for l in UILanguage.allCases {
                let t = f.localized(l)
                for s in [t.title, t.hint] {
                    #expect(!s.contains("Settings → Engine") && !s.contains("Settings → Dictation") && !s.contains("in Settings."), "\(s)")
                }
            }
        }
    }

    @Test func fixesRouteIntoSetup() {
        #expect(PillFailure.from(SoylaError.missingAPIKey("FAKE"), stage: "t").fix == .connectKey)
        #expect(PillFailure.from(SoylaError.http(status: 401, body: "FAKE"), stage: "t").fix == .connectKey)
        #expect(PillFailure.from(SoylaError.permission("FAKE"), stage: "t").fix == .setup(.permissions))
        #expect(PillFailure.paste(.noAccessibility).fix == .setup(.permissions))
        #expect(PillFailure.onDeviceHint.fix == .connectKey)
        #expect(PillFailure.onDevice(reason: "model-not-installed").fix == .page(.languages))
        #expect(PillFailure.noSound(device: nil).fix == .page(.privacy))
        #expect(PillFix.connectKey.route(cloudLanguage: true) == .setup(.connect))
        #expect(PillFix.connectKey.route(cloudLanguage: false) == .page(.languages))
        #expect(PillFix.setup(.permissions).route(cloudLanguage: false) == .setup(.permissions))
    }

    @Test func everyFixHasAButton() {
        for f in Self.catalog where f.fix != nil || f.openSettings {
            #expect(f.fix != nil, "\(f.title)")
        }
        let t = AppStrings.en
        #expect(PillFix.connectKey.button(t) == "Connect…" && PillFix.setup(.permissions).button(t) == "Allow…")
        #expect(PillFix.page(.privacy).button(t) == "Open Privacy & data")
    }
}

// MARK: - Permissions page

@Suite struct PermissionsPageTests {
    @Test func inputMonitoringOnlyWhenKeysDoNotFlow() {
        #expect(!PermissionsPage.showsInputMonitoring(PermissionState(mic: .granted, ax: true, inputMonitoring: true)))
        var p = PermissionState(mic: .granted, ax: true, inputMonitoring: false)
        #expect(PermissionsPage.showsInputMonitoring(p))
        p.eventsFlowing = true
        #expect(!PermissionsPage.showsInputMonitoring(p))
        #expect(!PermissionsPage.showsInputMonitoring(PermissionState(mic: .granted, ax: false, inputMonitoring: false)))
    }
}

// MARK: - Copy rules

@Suite struct SettingsCopyRulesTests {
    private func words(_ s: String) -> Int { s.split(whereSeparator: { $0 == " " }).filter { $0 != "·" }.count }

    @Test func subtitlesAreSixWordsOrFewer() {
        for l in UILanguage.allCases {
            let t = AppStrings.for(l)
            // pvSub is the prototype's own line (9 words): Privacy is built exactly as drawn.
            for s in [t.permSub, t.dicSub, t.hkSub, t.plSub, t.abSub, t.devSub, t.hiSub] {
                #expect(words(s) <= 6, "\(l): \(s)")
            }
        }
    }

    @Test func captionsAreFourWordsOrFewer() {
        for l in UILanguage.allCases {
            let t = AppStrings.for(l)
            for s in [t.keepC, t.warmC, t.dLangC, t.dCleanC, t.hkPasteC, t.plLiveC, t.plDetailsC, t.plTouchC, t.abAutoC,
                      t.abSetupC, t.plHiddenC] {
                #expect(words(s) <= 4, "\(l): \(s)")
            }
        }
    }

    @Test func privacyMatchesThePrototype() {
        let t = AppStrings.en
        #expect(t.pvTitle == "Privacy & data" && t.pvSub == "What stays on this Mac and what leaves it.")
        #expect(t.pvWhere == "Where your voice goes" && t.stays == "Stays on this Mac" && t.recs == "Recordings")
        #expect(t.keep == "Keep recordings" && t.keepC == "Text stays in History" && t.finder == "Show in Finder")
        #expect(t.warm == "Keep the microphone on" && t.warmC == "Faster start" && t.builtinNow("FAKE Mic") == "Now: FAKE Mic")
        #expect(t.retNever == "Don’t keep" && t.ret14 == "14 days" && t.retForever == "Forever")
        #expect(t.warmOff == "Off between dictations" && t.warm30 == "For 30 s after a dictation" && t.warmOn == "Always")
        #expect(AppStrings.ru.pvTitle == "Конфиденциальность" && AppStrings.uz.login == "Tizimga kirganda Soyla’ni ochish")
    }

    @Test func dataFolderIsShort() {
        #expect(AppStrings.folderPath(URL(fileURLWithPath: "/Users/FAKE/Library/Application Support/Soyla")) == "Application Support › Soyla")
        #expect(AppStrings.folderPath(URL(fileURLWithPath: "/tmp/FAKE/soyla-home")) == "FAKE › soyla-home")
    }
}
