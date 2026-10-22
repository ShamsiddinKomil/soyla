import Testing
import Foundation
@testable import SoylaCore

// APP-1 (d): every remaining user-facing string of the main app in English, Uzbek and Russian (AppDStrings, reached
// as AppStrings.d), and the pure functions that now take a language. English output must stay what it was.

@Suite struct AppDStringsTests {
    private static let all: [(UILanguage, AppDStrings)] = UILanguage.allCases.map { ($0, AppStrings.for($0).d) }
    /// Proper names and tech terms that are the same in every language.
    private static let sameEverywhere: Set<String> = ["sSoyla", "ceBase", "upOK"]

    /// Every plain field, as (name, text).
    private func fields(_ d: AppDStrings) -> [(String, String)] {
        var out: [(String, String)] = []
        for child in Mirror(reflecting: d).children {
            guard let name = child.label else { continue }
            switch child.value {
            case let s as String: out.append((name, s))
            case let a as [String]: out += a.enumerated().map { ("\(name)[\($0.offset)]", $0.element) }
            case let m as [PillSpot: String]: out += m.map { ("\(name).\($0.key)", $0.value) }
            default: break
            }
        }
        return out
    }

    /// Every closure-produced string, as (name, text), with fake arguments.
    private func produced(_ d: AppDStrings) -> [(String, String)] {
        var out: [(String, String)] = [
            ("dcLimit", d.dcLimit(3)), ("phInterrupted", d.phInterrupted(1.5)), ("phInterruptedRetry", d.phInterruptedRetry(1.5)),
            ("keyA11y", d.keyA11y("fn")), ("pcIdle", d.pcIdle("fn")), ("pcReady", d.pcReady("fn")),
            ("pcLockedHint", d.pcLockedHint("fn")), ("pcLeft", d.pcLeft(7)), ("pcLocked", d.pcLocked("7 s")),
            ("upAvail", d.upAvail("v9.9.9")), ("upToDateText", d.upToDateText("9.9.9")), ("upButton", d.upButton("9.9.9")),
            ("ucRestart", d.ucRestart("9.9.9")), ("ucDownloading", d.ucDownloading(42)), ("ucA11y", d.ucA11y("9.9.9", "FAKE")),
            ("ceEnv.env", d.ceEnv(true)), ("ceEnv.file", d.ceEnv(false)),
            ("kcAsking", d.kcAsking("fake.example")), ("kcA11y", d.kcA11y("FAKE")), ("kcRefused", d.kcRefused("FAKE")),
            ("ecDownloading", d.ecDownloading(42)), ("atDownloading", d.atDownloading(42)),
        ]
        for c in HotkeyChoice.allCases { out.append(("hotkey.\(c)", d.hotkey(c))) }
        for s in SoundSet.allCases { out.append(("sound.\(s)", d.sound(s))) }
        for s in [RunStatus.pending, .ok, .failed, .cancelled, .interrupted] { out.append(("status.\(s)", d.status(s))) }
        return out
    }

    @Test func noEmptyFieldInAnyLanguage() {
        for (l, d) in Self.all {
            let plain = fields(d), made = produced(d)
            #expect(plain.count > 130, "\(l) \(plain.count)")
            for (n, s) in plain + made { #expect(!s.trimmingCharacters(in: .whitespaces).isEmpty, "\(l) \(n)") }
            #expect(d.months.count == 12 && d.spot.count == PillSpot.allCases.count, "\(l)")
            #expect(Set(d.spot.values).count == 6, "\(l) pill spots must be told apart")
        }
    }

    @Test func uzbekKeepsTechTermsInEnglish() {
        let uz = AppStrings.uz.d
        for (n, s) in fields(uz) + produced(uz) {
            #expect(!s.lowercased().contains("kalit"), "\(n): \(s)")
            #expect(!s.contains("Bulut"), "\(n): \(s)")
            #expect(!s.contains("o'") && !s.contains("g'") && !s.contains("O'") && !s.contains("G'"), "\(n): wrong apostrophe in \(s)")
        }
    }

    @Test func noExclamationMarks() {
        for (l, d) in Self.all {
            for (n, s) in fields(d) + produced(d) { #expect(!s.contains("!"), "\(l) \(n): \(s)") }
        }
    }

    @Test func everyStringDiffersFromEnglishExceptProperNames() {
        let en = Dictionary(uniqueKeysWithValues: fields(AppStrings.en.d) + produced(AppStrings.en.d))
        for (l, d) in Self.all where l != .en {
            for (n, s) in fields(d) + produced(d) {
                let base = n.split(separator: ".").first.map(String.init) ?? n
                guard !Self.sameEverywhere.contains(base) else { continue }
                // Key names, symbols and the "F13" / "fn" keycaps are the same everywhere by design.
                if n.hasPrefix("hotkey."), ["fn", "ctrlShiftSpace", "f13"].contains(String(n.dropFirst(7))) { continue }
                if n == "sound.soyla" { continue }
                #expect(en[n] != s, "\(l) \(n) is still English: \(s)")
            }
        }
    }

    @Test func russianBrandIsFeminine() {
        #expect(AppStrings.ru.d.upNetText.contains("Soyla не смогла"))
    }

    @Test func decimalCommaInUzbekAndRussian() {
        #expect(AppStrings.en.d.phInterrupted(1.5) == "Recording interrupted (1.5 s)")
        #expect(AppStrings.uz.d.phInterrupted(1.5) == "Yozuv to‘xtatildi (1,5 s)")
        #expect(AppStrings.ru.d.phInterrupted(1.5) == "Запись прервана (1,5 с)")
        #expect(AppStrings.uz.d.phInterruptedRetry(0.5).contains("0,5") && AppStrings.ru.d.phInterruptedRetry(0.5).contains("0,5"))
    }

    @Test func updateAlertPointsAtTheSidebarCard() {
        // The card moved to the bottom of the sidebar; the alert still said "top-right corner" (fixed in (d)).
        #expect(!AppStrings.en.d.upAvailText.contains("top-right"))
        #expect(AppStrings.en.d.upAvailText.contains(AppStrings.en.d.ucAvail))
        #expect(AppStrings.uz.d.upAvailText.contains(AppStrings.uz.d.ucAvail))
        #expect(AppStrings.ru.d.upAvailText.contains(AppStrings.ru.d.ucAvail))
    }

    @Test func englishWordsAreWhatTheViewsSaidBefore() {
        let d = AppStrings.en.d
        #expect(d.hotkey(.rightOption) == "Right ⌥" && d.hotkey(.fn) == "fn" && d.sound(.system) == "System")
        #expect(d.spot[.bottomCenter] == "Bottom centre" && d.spot[.topLeft] == "Top left")
        #expect(d.upButton("0.2.1") == "Update to 0.2.1" && d.ucRestart("0.2.1") == "Restart to get 0.2.1")
        #expect(d.dcLimit(50) == "Limit reached (50).")
        #expect(d.status(.failed) == "Failed" && RunStatus.interrupted.label == "Interrupted")
        #expect(d.sfBusy == "Finish your dictation first, then click Update again.")
    }
}

// MARK: - Pure functions that now take a language

@Suite struct AppDStringsWiringTests {
    @Test func freeEngineStatusFollowsTheLanguage() {
        let states: [OnDeviceModelState?] = [nil, .ready, .downloading(0.42), .needsDownload, .needsPermission,
                                             .unavailable(.localeUnsupported), .unavailable(.noOnDeviceModel), .unavailable(.restricted),
                                             .unavailable(.reservationsFull), .unavailable(.osTooOld)]
        for s in states {
            let en = EngineCopy.status(s)
            #expect(en == EngineCopy.status(s, language: .en))
            for l in [UILanguage.uz, .ru] {
                let t = EngineCopy.status(s, language: l)
                #expect(t.text != en.text && t.tone == en.tone && t.action == en.action && t.progress == en.progress, "\(l) \(en.text)")
            }
        }
        #expect(EngineCopy.status(.needsDownload, failure: "FAKE", language: .ru).action == .retry)
        #expect(EngineCopy.status(.downloading(0.42), language: .uz).text.contains("42"))
    }

    @Test func attentionLineFollowsTheLanguage() {
        let states: [OnDeviceModelState] = [.downloading(0.42), .needsDownload, .needsPermission, .unavailable(.restricted)]
        for s in states {
            let en = EngineCopy.attention(provider: .apple, state: s)
            #expect(en != nil)
            for l in [UILanguage.uz, .ru] {
                let t = EngineCopy.attention(provider: .apple, state: s, language: l)
                #expect(t != nil && t != en, "\(l)")
            }
        }
        #expect(EngineCopy.attention(provider: .apple, state: .downloading(0.42), language: .ru)?.contains("42%") == true)
        #expect(EngineCopy.attention(provider: .apple, state: .ready, language: .uz) == nil)
        #expect(EngineCopy.attention(provider: .google, state: .needsDownload, language: .uz) == nil)
    }

    @Test func actionAndSwitchOfferFollowTheLanguage() {
        for a in [EngineCopy.Action.download, .retry, .allowSpeech] {
            #expect(a.title == a.title(.en))
            #expect(a.title(.uz) != a.title && a.title(.ru) != a.title)
        }
        for p in [EngineSwitchPrompt.toCloud(.google), .toFree] {
            #expect(p.title == p.title(.en) && p.message == p.message(.en))
            #expect(p.confirmTitle == p.confirmTitle(.en) && p.declineTitle == p.declineTitle(.en))
            for l in [UILanguage.uz, .ru] {
                #expect(p.title(l) != p.title && p.message(l) != p.message && p.confirmTitle(l) != p.confirmTitle && p.declineTitle(l) != p.declineTitle)
            }
        }
    }

    @MainActor @Test func updateFailuresFollowTheLanguage() {
        let all: [SelfUpdate.Failure] = [.notOffered, .network, .tooBig, .checksum, .unzip, .notSoyla, .wrongVersion, .unsigned,
                                         .untrusted, .notWritable, .install]
        for f in all {
            #expect(f.message == f.message(AppStrings.en.d))
            #expect(f.message(AppStrings.uz.d) != f.message && f.message(AppStrings.ru.d) != f.message, "\(f)")
        }
        #expect(Updater().buttonTitle(.ru) != Updater().buttonTitle && Updater().buttonTitle == "Update to ")
    }

    @MainActor @Test func historyPlaceholdersAndDatesFollowTheLanguage() {
        func run(_ status: RunStatus, dur: Double = 2.5) -> RunRecord {
            RunRecord(runId: "r1", ts: "2026-10-17T10:00:00.000Z", source: "live", phraseId: nil, model: "en-US",
                      cleanup: false, cleanupModel: nil, languageHint: nil, prewarm: false,
                      audio: .init(format: "wav", bytes: 1, b64Bytes: 2, durationSec: dur, sampleRate: 16000, file: nil),
                      timelineMs: [:], net: nil, usage: nil, cleanupUsage: nil, rawText: nil, cleanText: nil, error: nil,
                      providerMeta: nil, status: status)
        }
        for s in [RunStatus.interrupted, .failed, .cancelled, .pending, .ok] {
            for canRetry in [true, false] {
                let en = RunsView.placeholder(run(s), canRetry: canRetry)
                #expect(en == RunsView.placeholder(run(s), canRetry: canRetry, t: .en))
                #expect(RunsView.placeholder(run(s), canRetry: canRetry, t: .uz) != en)
                #expect(RunsView.placeholder(run(s), canRetry: canRetry, t: .ru) != en)
            }
        }
        #expect(RunsView.placeholder(run(.interrupted), canRetry: false) == "Recording interrupted (2.5 s)")
        #expect(RunsView.placeholder(run(.interrupted), canRetry: false, t: .ru) == "Запись прервана (2,5 с)")
        #expect(NoteMeta.line(run(.ok, dur: 4), engine: true, t: .uz).hasSuffix("4 s · Shu Mac’da"))
        #expect(NoteMeta.line(run(.ok, dur: 4), engine: true, t: .ru).hasSuffix("4 с · На этом Mac"))
        #expect(NoteMeta.duration(4, t: .ru) == "4 с" && NoteMeta.duration(4) == "4 s")
        // An old date: "17 окт." style, never today.
        #expect(RunsView.when("2020-10-17T12:00:00.000Z", t: .ru).contains("окт."))
        #expect(RunsView.when("2020-10-17T12:00:00.000Z", t: .uz).contains("okt"))
        #expect(RunsView.when("2020-10-17T12:00:00.000Z").contains("Oct"))
    }

    @MainActor @Test func pillCaptionsFollowTheLanguage() {
        let m = PanelModel()
        let enIdle = m.statusLine
        #expect(enIdle == "Hold fn to dictate")
        m.uiLanguage = .uz
        #expect(m.statusLine == "Gapirish uchun fn’ni bosib turing")
        m.uiLanguage = .ru
        #expect(m.statusLine == "Зажмите fn, чтобы диктовать")
        m.phase = .recording; m.locked = true; m.hardStopSec = 55; m.elapsedSec = 1
        #expect(m.caption == nil)                      // locked: the glyph is the hint (owner, 2026-10-19 merge)
        m.warn = true; m.elapsedSec = 50
        #expect(m.caption == "осталось 5 с")           // the countdown is still translated
        m.uiLanguage = .en
        #expect(m.caption == "5 s left")
        m.phase = .failed
        #expect(m.statusLine == "Failed")
        #expect(PanelModel.announcement(for: .recording, failure: nil) == "Recording")
        #expect(PanelModel.announcement(for: .recording, failure: nil, language: .uz) == "Yozilmoqda")
        #expect(PanelModel.announcement(for: .done, failure: nil, language: .ru) == "Вставлено")
    }

    @Test func keyCardMessagesAreTranslatable() {
        // KeyShape keeps saying it in English; the card swaps these two for the interface language.
        #expect(KeyShape.problem("", for: .custom) == KeyShape.emptyMessage)
        #expect(KeyShape.problem("two words", for: .custom) == KeyShape.spacesMessage)
        #expect(AppStrings.uz.d.kpEmpty != KeyShape.emptyMessage && AppStrings.ru.d.kpSpaces != KeyShape.spacesMessage)
    }

    @Test func pillSpotNamesComeFromTheTable() {
        for s in PillSpot.allCases {
            #expect(AppStrings.en.d.spot[s] == s.label)
            #expect(AppStrings.uz.d.spot[s] != nil && AppStrings.ru.d.spot[s] != nil)
        }
    }

    @MainActor @Test func userLatencyLineUsesTheLanguageUnit() {
        let r = RunRecord(runId: "r1", ts: "2026-10-17T10:00:00.000Z", source: "live", phraseId: nil, model: "en-US",
                          cleanup: false, cleanupModel: nil, languageHint: nil, prewarm: false,
                          audio: .init(format: "wav", bytes: 1, b64Bytes: 2, durationSec: 1, sampleRate: 16000, file: nil),
                          timelineMs: ["release_to_paste": 1500], net: nil, usage: nil, cleanupUsage: nil, rawText: nil, cleanText: nil,
                          error: nil, providerMeta: nil, status: .ok)
        #expect(DictationPipeline.userLatencyLine(r) == "1.5 s")
        #expect(DictationPipeline.userLatencyLine(r, language: .ru) == "1,5 с")
    }
}
