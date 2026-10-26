import Testing
import Foundation
@testable import SoylaCore

// D26(b) · BL-04: "my languages" set, the shared prompt lines, the set-aware script check, the pill chip and
// History → Retry as… All text is fake.

@Suite struct LanguageSetSettingsTests {
    private func decode(_ json: String) throws -> Settings { try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }

    @Test func defaultIsAllThree() {
        #expect(Settings().languages == ["uz", "ru", "en"])
        #expect(Settings().languageHint == nil)
        #expect(LanguageSet.defaultSet == ["uz", "ru", "en"])
    }

    /// An old blob has only `languageHint`: it becomes the primary, the set is the default.
    @Test func oldHintMigrates() throws {
        for hint in ["uz", "ru", "en"] {
            let s = try decode(#"{"sttModel":"google/gemini-3.5-flash","languageHint":"\#(hint)"}"#)
            #expect(s.languages == ["uz", "ru", "en"], "\(hint)")
            #expect(s.languageHint == hint, "\(hint)")
        }
        let auto = try decode(#"{"sttModel":"google/gemini-3.5-flash"}"#)
        #expect(auto.languages == ["uz", "ru", "en"] && auto.languageHint == nil)
        // A hint outside the three stays the primary; the set stays default.
        let ko = try decode(#"{"languageHint":"ko"}"#)
        #expect(ko.languages == ["uz", "ru", "en"] && ko.languageHint == "ko")
    }

    /// The v0.1 fixture (same bytes as ContractsTests/GoogleAITests) still decodes, with the default set.
    @Test func v01FixtureStillDecodes() throws {
        let v01 = #"{"sttModel":"chat:google/gemini-3.5-transcribe","keepMicWarm":true,"livePreview":true,"minDurationSec":0.3,"hotkey":"rightOption","vocabulary":["Soyla"]}"#
        let s = try decode(v01)
        #expect(s.languages == ["uz", "ru", "en"] && s.languageHint == nil)
        #expect(s.vocabulary == ["Soyla"] && s.livePreview)
    }

    @Test func savedSetRoundTripsAndIsTolerant() throws {
        var s = Settings()
        s.languages = ["uz", "en"]; s.languageHint = "uz"
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(try decode(#"{"languages":["EN","xx","uz","en"]}"#).languages == ["uz", "en"])   // canonical order, deduped
        #expect(try decode(#"{"languages":[]}"#).languages == ["uz", "ru", "en"])                // never empty
        #expect(try decode(#"{"languages":"garbage"}"#).languages == ["uz", "ru", "en"])         // tolerant
        #expect(try decode(#"{"languages":["ru"],"cleanupLevel":"light"}"#).cleanupLevel == .light)  // the rest survives
    }

    @Test func sanitize() {
        #expect(LanguageSet.sanitize(nil) == ["uz", "ru", "en"])
        #expect(LanguageSet.sanitize(["en", "ru"]) == ["ru", "en"])
        #expect(LanguageSet.sanitize(["ko"]) == ["uz", "ru", "en"])
        #expect(LanguageSet.isDefault(["en", "uz", "ru"]))
        #expect(!LanguageSet.isDefault(["uz", "en"]))
    }

    @Test func togglingKeepsAtLeastOneAndClearsAStalePrimary() {
        var s = Settings()
        s.languageHint = "ru"
        s.toggleLanguage("ru")
        #expect(s.languages == ["uz", "en"] && s.languageHint == nil)       // the primary went with its language
        s.toggleLanguage("en")
        #expect(s.languages == ["uz"])
        s.toggleLanguage("uz")
        #expect(s.languages == ["uz"])                                      // the last one can't be unticked
        s.toggleLanguage("ru")
        #expect(s.languages == ["uz", "ru"])                                // canonical order
        s.languageHint = "uz"
        s.toggleLanguage("en")
        #expect(s.languageHint == "uz")                                     // other toggles keep it
    }
}

@Suite struct LanguageChipTests {
    @Test func hiddenForTheDefaultSet() {
        #expect(LanguageSet.chip(Settings()) == nil)
    }

    @Test func showsTheSetOtherwise() {
        var s = Settings()
        s.languages = ["ru"]
        #expect(LanguageSet.chip(s) == "RU")
        s.languages = ["uz", "en"]
        #expect(LanguageSet.chip(s) == "UZ·EN")
        s.languages = ["ru", "en"]
        #expect(LanguageSet.chip(s) == "RU·EN")
    }

    @Test func hiddenOnTheFreeEngine() {
        var s = Settings()
        s.provider = .apple; s.languages = ["ru"]
        #expect(LanguageSet.chip(s) == nil)                                  // English only, the set doesn't apply
    }

    @MainActor @Test func resetKeepsTheChipAndTheModelStartsEmpty() {
        let p = PanelModel()
        #expect(p.languageChip == nil)
        p.languageChip = "UZ·EN"
        p.reset()
        #expect(p.languageChip == "UZ·EN")                                  // set at reveal, not a per-run value
    }
}

@Suite struct LanguagePromptTests {
    private let full = "The speaker may use only these languages: Uzbek, Russian, English."
    private let rule = "Russian in Cyrillic; English words stay in Latin letters; Uzbek in Latin script. Never translate, never transliterate."
    private let short = "If unsure, choose among these languages only."

    @Test func noSetNoLines() {
        #expect(LanguagePrompt.lines(languages: [], durationSec: 1).isEmpty)
        #expect(OpenRouterSTTProvider.transcriptionPrompt(TranscribeOptions(model: "m")) ==
                OpenRouterSTTProvider.transcriptionPrompt(TranscribeOptions(model: "m"), durationSec: 1))
    }

    @Test func fullSetLongClip() {
        #expect(LanguagePrompt.lines(languages: ["uz", "ru", "en"], durationSec: 5) == [full, rule])
        #expect(LanguagePrompt.lines(languages: ["uz", "ru", "en"], durationSec: nil) == [full, rule])
    }

    @Test func shortClipLineOnlyUnderTwoSeconds() {
        #expect(LanguagePrompt.lines(languages: ["uz", "ru", "en"], durationSec: 1.9) == [full, rule, short])
        #expect(!LanguagePrompt.lines(languages: ["uz", "ru", "en"], durationSec: 2.0).contains(short))
        #expect(!LanguagePrompt.lines(languages: ["uz", "ru", "en"], durationSec: 0).isEmpty)
    }

    @Test func ruleOnlyNamesTheSet() {
        #expect(LanguagePrompt.lines(languages: ["uz", "en"], durationSec: 3) == [
            "The speaker may use only these languages: Uzbek, English.",
            "English words stay in Latin letters; Uzbek in Latin script. Never translate, never transliterate.",
        ])
        #expect(LanguagePrompt.lines(languages: ["ru"], durationSec: 3) == [
            "The speaker may use only these languages: Russian.",
            "Russian in Cyrillic. Never translate, never transliterate.",
        ])
    }

    /// Order: the base prompt, vocabulary, the primary, the set lines, and the retry line last.
    @Test func promptOrderAndBothRoutes() throws {
        var o = TranscribeOptions(model: "google/gemini-3.5-flash", languageHint: "uz", languages: ["uz", "en"])
        o.vocabulary = ["FAKE1234"]
        o.extraInstruction = ScriptCheck.retryInstruction
        let p = OpenRouterSTTProvider.transcriptionPrompt(o, durationSec: 1.5)
        #expect(p.hasPrefix(OpenRouterSTTProvider.chatPrompt))
        #expect(p.hasSuffix(ScriptCheck.retryInstruction))
        let iMain = try #require(p.range(of: "main language is uz")).lowerBound
        let iSet = try #require(p.range(of: "may use only these languages: Uzbek, English.")).lowerBound
        let iShort = try #require(p.range(of: short)).lowerBound
        #expect(iMain < iSet && iSet < iShort)

        let audio = EncodedAudio(data: Data([1, 2, 3]), format: "wav", durationSec: 1.5, sampleRate: 16000, fileURL: nil)
        let or = try JSONSerialization.jsonObject(with: OpenRouterSTTProvider.makeChatBody(audio, options: o)) as? [String: Any]
        let msg = (or?["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]
        let g = try JSONSerialization.jsonObject(with: GoogleAIProvider.makeBody(audio, options: o)) as? [String: Any]
        let gp = ((g?["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])?.first?["text"] as? String
        #expect(msg?.first?["text"] as? String == p)
        #expect(gp == p)
    }

    @Test func retryLineNamesTheSet() {
        #expect(LanguagePrompt.retryLine([]) == nil)
        #expect(LanguagePrompt.retryLine(["uz", "ru", "en"]) == nil)
        #expect(LanguagePrompt.retryLine(["uz", "en"]) == "The speaker uses only Uzbek, English. Write no Cyrillic letters.")
        #expect(LanguagePrompt.retryLine(["ru"]) == "The speaker uses only Russian.")
    }
}

@Suite struct LanguageGuardTests {
    let audio = EncodedAudio(data: Data([1]), format: "wav", durationSec: 3, sampleRate: 16000, fileURL: nil)

    @Test func cyrillicOutsideTheSet() {
        #expect(TextGuards.scriptIssue("Я завтра приду", languages: ["uz", "en"]) == .outsideSet("cyrillic"))
        #expect(TextGuards.scriptIssue("deploy на staging", languages: ["uz", "ru", "en"]) == nil)
        #expect(TextGuards.scriptIssue("deploy на staging", languages: ["ru"]) == nil)
        #expect(TextGuards.scriptIssue("Bugun deploy qildim, then tests", languages: ["uz", "en"]) == nil)   // Latin is fine
        #expect(TextGuards.scriptIssue("Bugun deploy qildim", languages: ["ru"]) == nil)
        #expect(TextGuards.scriptIssue("Я завтра приду") == nil)            // no set: today's behaviour
        #expect(TextGuards.scriptIssue("Бугун ҳаво яхши", languages: ["uz", "ru", "en"]) == .uzbekCyrillic)
        #expect(TextGuards.scriptIssue("안녕하세요", languages: ["uz", "en"]) == .foreignScript("hangul"))
        #expect(ScriptIssue.outsideSet("cyrillic").tag == "outside_set:cyrillic")
    }

    /// The set [uz, en] + Cyrillic output → F3's single retry, with the set named in the retry line.
    @Test func setUzEnCyrillicRetriesOnce() async throws {
        let stt = MockSTT("Я завтра приду", "Ertaga kelaman")
        let o = TranscribeOptions(model: "m", languages: ["uz", "en"])
        let r = try await ScriptCheck.transcribe(stt, audio: audio, options: o, timeline: RunTimeline())
        #expect(stt.options.count == 2)
        #expect(stt.options[1].extraInstruction?.contains("Latin script") == true)
        #expect(stt.options[1].extraInstruction?.contains("Write no Cyrillic letters.") == true)
        #expect(r.text == "Ertaga kelaman" && r.providerMeta["script_check"] == "retried:outside_set:cyrillic")
    }

    /// Review fix: the set check never costs the dictation. Both tries outside the set → the better one is pasted.
    @Test func setUzEnCyrillicTwiceStillPastes() async throws {
        let stt = MockSTT("Я завтра приду и всё скажу", "Ertaga kelaman, всё скажу")
        let o = TranscribeOptions(model: "m", languages: ["uz", "en"])
        let r = try await ScriptCheck.transcribe(stt, audio: audio, options: o, timeline: RunTimeline())
        #expect(stt.options.count == 2)
        #expect(r.text == "Ertaga kelaman, всё скажу")                       // the lower Cyrillic share wins
        #expect(r.providerMeta["script_check"] == "outside_set:kept")
    }

    /// One look-alike Cyrillic letter in a long Latin text is not "outside the set": no retry.
    @Test func strayCyrillicLetterPasses() async throws {
        let text = "Bugun biz yangi versiyani deploy qildik va hammasi yaxshi ishlayapti, ertaga test qilamiz \u{043E}k"
        #expect(TextGuards.scriptIssue(text, languages: ["uz", "en"]) == nil)
        let stt = MockSTT(text)
        let r = try await ScriptCheck.transcribe(stt, audio: audio, options: TranscribeOptions(model: "m", languages: ["uz", "en"]),
                                                 timeline: RunTimeline())
        #expect(stt.options.count == 1 && r.providerMeta["script_check"] == "ok")
    }

    @Test func outsideSetThresholdIsPinned() {
        #expect(TextGuards.outsideSetCyrillicShare == 0.10)
        // 1 of 10 letters is not over the share; 2 of 10 is.
        #expect(TextGuards.scriptIssue("abcdefghi\u{0430}", languages: ["en"]) == nil)
        #expect(TextGuards.scriptIssue("abcdefgh\u{0430}\u{0431}", languages: ["en"]) == .outsideSet("cyrillic"))
    }

    /// Review fix: salvage (stray foreign letters on both tries) uses the set too, and still never drops the text
    /// for a set issue: the kept try may carry a little Cyrillic.
    @Test func salvageUsesTheSet() async throws {
        let long = "Bugun biz yangi versiyani deploy qildik va hammasi yaxshi ishlayapti ertaga yana test qilamiz"
        let stt = MockSTT(long + " 안", long + " 안")
        let r = try await ScriptCheck.transcribe(stt, audio: audio, options: TranscribeOptions(model: "m", languages: ["uz", "en"]),
                                                 timeline: RunTimeline())
        #expect(r.text == long && r.providerMeta["script_check"] == "stripped:foreign:hangul")
        let a = TranscriptResult(text: long + " 안"), b = TranscriptResult(text: "Я завтра приду и всё скажу 안")
        #expect(ScriptCheck.salvage(a, b, languages: ["uz", "en"])?.text == long)
        #expect(ScriptCheck.salvage(b, b, languages: ["uz", "en"]) == nil)                 // mostly Cyrillic: not a salvage
    }

    @Test func fullSetMixedPasses() async throws {
        let stt = MockSTT("deploy на staging")
        let o = TranscribeOptions(model: "m", languages: ["uz", "ru", "en"])
        let r = try await ScriptCheck.transcribe(stt, audio: audio, options: o, timeline: RunTimeline())
        #expect(stt.options.count == 1 && r.providerMeta["script_check"] == "ok")
    }

    /// Cleanup that adds Cyrillic to a [uz, en] text is retried once with the reminder, then guarded.
    @Test func cleanupRespectsTheSet() async {
        let raw = "ertaga kelaman va hammasini aytaman deploy"
        let c = MockCleaner("Завтра приду и всё скажу deploy", "Завтра приду и всё скажу deploy")
        let o = await CleanupFlow.run(raw: raw, level: .light, cleaner: { c }, model: "m", vocabulary: [], appName: nil,
                                      languageHint: nil, languages: ["uz", "en"], dictionary: ReplacementDictionary([]),
                                      cooldownKey: "fake-\(UUID().uuidString)", timeline: RunTimeline())
        #expect(c.calls.count == 2 && o.scriptRetried)
        #expect(o.status == .guarded && o.guardReason == .script && o.text == raw)
    }
}

/// Review fix: the Live fast path uses the set check too; outside the set → Gemini (which never drops the text).
@Suite struct LiveFastSetTests {
    private func live(_ t: String) -> LiveOutcome { LiveOutcome(text: t, language: "uz-UZ", locked: true, finalArrived: true) }

    @Test func liveOutsideTheSetFallsBackToGemini() {
        let d = LiveFastDecision.decide(strict: true, live: live("Я завтра приду и всё скажу"), pieces: nil, voicedSec: 2,
                                        languages: ["uz", "en"])
        #expect(d.source == .gemini && d.reason == "script")
        let all = LiveFastDecision.decide(strict: true, live: live("Я завтра приду и всё скажу"), pieces: nil, voicedSec: 2,
                                          languages: ["uz", "ru", "en"])
        #expect(all.source == .live)
    }

    @Test func strayLetterKeepsLive() {
        let t = "Bugun biz yangi versiyani deploy qildik va hammasi yaxshi ishlayapti \u{043E}k"
        let d = LiveFastDecision.decide(strict: true, live: live(t), pieces: nil, voicedSec: 2, languages: ["uz", "en"])
        #expect(d.source == .live)
    }
}

@Suite struct RetryAsTests {
    /// Review fix: "Retry as" is hidden on the free engine (it ignores a forced language), the same rule as the chip.
    @Test func retryAsHiddenOnTheFreeEngine() {
        var s = Settings()
        #expect(LanguageSet.applies(s))
        s.provider = .apple
        #expect(!LanguageSet.applies(s))
        #expect(RunsModel.showsRetryAs(s) == false)
        s.provider = .google
        #expect(RunsModel.showsRetryAs(s))
    }

    @Test func forcedLanguage() {
        var s = Settings()
        s.languages = ["uz", "en"]; s.languageHint = "uz"; s.sttModel = "FAKE/model"
        let ru = DictationPipeline.historyRetrySettings(s, model: nil, language: "ru")
        #expect(ru.languages == ["ru"] && ru.languageHint == "ru" && ru.sttModel == "FAKE/model")
        let mine = DictationPipeline.historyRetrySettings(s, model: nil, language: nil)
        #expect(mine == s)                                                  // "My languages" = the saved settings
        let other = DictationPipeline.historyRetrySettings(s, model: "FAKE/other", language: "en")
        #expect(other.sttModel == "FAKE/other" && other.languages == ["en"] && other.languageHint == "en")
        #expect(DictationPipeline.historyRetrySettings(s, model: nil, language: "ko") == s)   // unknown: ignored
        #expect(LanguageSet.chip(ru) == "RU")
    }

    /// F4 rule: History never pastes. The retry builds its settings through `historyRetrySettings` and passes
    /// `copyOnly: true`; the menu offers the three languages and the saved set.
    @Test func historyRetryStaysCopyOnly() throws {
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SoylaCore/App")
        let src = try String(contentsOf: core.appendingPathComponent("DictationPipeline.swift"), encoding: .utf8)
        let start = try #require(src.range(of: "public func retryFromHistory(")).lowerBound
        let end = try #require(src[start...].range(of: "\n    }\n")).lowerBound
        let body = src[start..<end]
        #expect(body.contains("language: String?"))
        #expect(body.contains("historyRetrySettings("))
        #expect(body.contains("copyOnly: true"))
        #expect(!body.contains("copyOnly: false"))
        let runs = try String(contentsOf: core.appendingPathComponent("RunsWindow.swift"), encoding: .utf8)
        #expect(runs.contains("m.retry(r, language: "))
        #expect(!runs.contains("Paster.paste"))
    }
}

@Suite struct LanguageSetStringsTests {
    private func all(_ s: LanguageSetStrings) -> [(String, String)] {
        Mirror(reflecting: s).children.compactMap { c in (c.value as? String).map { (c.label ?? "?", $0) } }
    }

    @Test func everyLanguageHasEveryString() {
        let en = Dictionary(uniqueKeysWithValues: all(.for(.en)))
        #expect(en.count >= 5)
        for l in UILanguage.allCases {
            let s = all(.for(l))
            #expect(s.count == en.count, "\(l)")
            for (n, v) in s {
                #expect(!v.trimmingCharacters(in: .whitespaces).isEmpty, "\(l) \(n)")
                #expect(!v.contains("!"), "\(l) \(n)")
                if l != .en { #expect(en[n] != v, "\(l) \(n) is still English") }
                if l == .uz { #expect(!v.contains("o'") && !v.contains("g'"), "\(n): wrong apostrophe") }
            }
        }
    }
}
