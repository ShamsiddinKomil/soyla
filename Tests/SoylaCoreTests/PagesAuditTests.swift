import Testing
import Foundation
@testable import SoylaCore

// Audit 2026-10-19 V-15 – V-20, V-37: History, Dictation and Developer copy and rules.
@MainActor @Suite struct PagesAuditTests {
    private func run(_ s: RunStatus) -> RunRecord {
        RunRecord(runId: "r1", ts: "2026-10-17T10:00:00.000Z", source: "live", phraseId: nil, model: "gemini-3.5-flash",
                  cleanup: false, cleanupModel: nil, languageHint: nil, prewarm: false,
                  audio: .init(format: "wav", bytes: 1, b64Bytes: 2, durationSec: 3, sampleRate: 16000, file: nil),
                  timelineMs: [:], net: nil, usage: nil, cleanupUsage: nil, rawText: nil, cleanText: nil, error: nil,
                  providerMeta: nil, status: s)
    }

    @Test func cardBodiesDontRepeatTheirStatus() {
        for l in UILanguage.allCases {
            let t = AppStrings.for(l)
            #expect(RunsView.placeholder(run(.cancelled), t: t) != t.d.stCancelled, "\(l)")
            #expect(RunsView.placeholder(run(.failed), canRetry: false, t: t) != t.d.stFailed, "\(l)")
        }
        #expect(RunsView.placeholder(run(.failed), canRetry: false) == "Nothing was pasted.")
        #expect(RunsView.placeholder(run(.cancelled), t: .uz) == "Yuborishdan oldin bekor qilindi.")
        #expect(RunsView.placeholder(run(.cancelled), t: .ru) == "Отменено до отправки.")
    }

    @Test func shortcutsUseMacOSModifierOrder() {
        for l in UILanguage.allCases {
            let k = AppStrings.for(l).hiKeys
            #expect(k.contains("⌃⌘V") && k.contains("⌃⌘C") && !k.contains("⌘⌃"), "\(l): \(k)")
        }
        #expect(AppStrings.uz.hiRaw == "Asl matn")
    }

    @Test func theEmptyHistorySaysHowToStart() {
        #expect(AppStrings.fill(AppStrings.en.hiEmpty, key: "fn") == "Hold fn in any app. Your words appear here.")
        #expect(AppStrings.fill(AppStrings.uz.hiEmpty, key: "fn") == "Istalgan ilovada fn’ni bosib turing. So‘zlaringiz shu yerda chiqadi.")
        #expect(AppStrings.fill(AppStrings.ru.hiEmpty, key: "fn") == "Зажмите fn в любом приложении. Слова появятся здесь.")
    }

    @Test func theDeveloperPageIsTranslated() {
        #expect(AppStrings.uz.devSub == "Sinov sozlamalari va vaqtlar." && AppStrings.ru.devSub == "Настройки для тестов и замеры.")
        #expect(AppStrings.en.devMode == "Developer mode" && AppStrings.uz.devModeC == "Tarixda vaqtlar" && AppStrings.ru.devModeC == "Замеры в Истории")
    }

    @Test func dictionaryCaptionsAreShort() {
        for l in UILanguage.allCases {
            let t = AppStrings.for(l)
            for c in [t.dReplC, t.dSpellC] { #expect(!c.isEmpty && c.count < 32, "\(l): \(c)") }
        }
        #expect(AppStrings.en.dReplC == "Heard → written" && AppStrings.ru.dReplC == "Услышано → пишется")
    }

    @Test func theModelNameIsADevelopersDetail() {
        let r = run(.ok)
        #expect(!NoteMeta.line(r, engine: false).contains("Gemini"))
        #expect(NoteMeta.line(r, engine: true).contains("Gemini"))
    }
}

// Audit 2026-10-19 V-28, V-38: the sidebar dot in words; Back from the first run's Languages.
@Suite struct KeyboardAuditTests {
    @Test func theAttentionDotHasWords() {
        #expect(AppStrings.en.attention == "Needs attention" && AppStrings.uz.attention == "E’tibor kerak"
                && AppStrings.ru.attention == "Требует внимания")
    }

    @Test func languagesGoesBackToWelcomeOnTheFirstRun() {
        var f = SetupFlow(welcome: true)
        f.next()
        #expect(f.step == .languages && f.showsBack && f.hasWelcome)
        f.back()
        #expect(f.step == .welcome)
        #expect(!SetupFlow(entry: .languages, languages: [.en]).hasWelcome)     // from the app: no Back
    }
}
