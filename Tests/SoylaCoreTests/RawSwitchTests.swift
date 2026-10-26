import Testing
import Foundation
@testable import SoylaCore

// D26 (c) / BL-03: Raw one tap away, the fallback record and its once-a-day note, the Raw naming.

private func fakeRecord() -> RunRecord {
    RunRecord(runId: "2026-10-26T10-00-00-000", ts: "2026-10-26T10:00:00.000Z", source: "live", phraseId: nil,
              model: "fake/model", cleanup: true, cleanupModel: "fake/clean", languageHint: nil, prewarm: false,
              audio: .init(format: "flac", bytes: 10, b64Bytes: 14, durationSec: 3, sampleRate: 16000, file: nil),
              timelineMs: [:], net: nil, usage: nil, cleanupUsage: nil, rawText: "FAKE1234 raw", cleanText: nil,
              error: nil, providerMeta: ["provider": "mock"], status: .pending)
}

@Suite struct RunRecordFallbackTests {
    /// A row written before D26 (c): no `cleanup_fallback` key (and none of the newer optional keys either).
    private static let oldRow = """
    {"run_id":"2026-10-15T10-00-00-000","ts":"2026-10-15T10:00:00.000Z","source":"live","model":"fake/model",
     "cleanup":true,"cleanup_model":"fake/clean","prewarm":false,
     "audio":{"format":"wav","bytes":10,"b64_bytes":14,"duration_sec":1.5,"sample_rate":16000},
     "timeline_ms":{"stt_total":120},"raw_text":"FAKE1234 raw","clean_text":"FAKE1234 clean","app_version":"0.2.0"}
    """

    @Test func anOldRowStillDecodes() throws {
        let r = try RunRecord.decoder.decode(RunRecord.self, from: Data(Self.oldRow.utf8))
        #expect(r.cleanupFallback == nil && r.cleanText == "FAKE1234 clean" && r.status == .ok)
    }

    @Test func aFallbackRoundTripsAsSnakeCase() throws {
        var r = fakeRecord()
        r.cleanupFallback = "ratio_low"
        let data = try RunRecord.encoder.encode(r)
        #expect((String(data: data, encoding: .utf8) ?? "").contains("\"cleanup_fallback\":\"ratio_low\""))
        #expect(try RunRecord.decoder.decode(RunRecord.self, from: data).cleanupFallback == "ratio_low")
        let plain = String(data: try RunRecord.encoder.encode(fakeRecord()), encoding: .utf8) ?? ""
        #expect(!plain.contains("cleanup_fallback"))                    // nil is not written
    }
}

@Suite struct RawSwitchTests {
    let tl = RunTimeline()

    private func run(_ raw: String, level: CleanupLevel, cleaner: MockCleaner, dict: [DictionaryEntry] = [],
                     cooldown: ProviderCooldown = ProviderCooldown()) async -> CleanupOutcome {
        await CleanupFlow.run(raw: raw, level: level, cleaner: { cleaner }, model: "m", vocabulary: [], appName: nil,
                              languageHint: nil, dictionary: ReplacementDictionary(dict), cooldownKey: "k", cooldown: cooldown,
                              timeline: tl)
    }

    // MARK: Raw is the provider text plus the dictionary

    @Test func rawOutputEqualsDictionaryOfTheSpeechText() async {
        let dict = [DictionaryEntry(from: "Soila", to: "Soyla"), DictionaryEntry(from: "Шамсиддин", to: "Shamsiddin")]
        let fixtures = [
            "ee men ertaga boraman",                                   // a two-letter filler is not touched
            "ну я думаю что это хорошо",                                // a Russian filler is not touched
            "hello world this is a plain English sentence",
            "Shamsiddin bilan o'zbek tilida gaplashdim, keyin Шамсиддин keldi",
            "ну ee Soila is the app, no punctuation fixes, lower case start",
        ]
        let ref = ReplacementDictionary(dict)
        for raw in fixtures {
            let c = MockCleaner("should not be called")
            let o = await run(raw, level: .off, cleaner: c, dict: dict)
            #expect(o.text == ref.apply(raw).text, "\(raw)")
            #expect(o.status == .off && o.cleaned == nil && o.fallbackReason == nil && c.calls.isEmpty)
        }
    }

    /// Known gap: long filler sounds are removed at every level, because the
    /// free engine relies on it. The Raw caption says so. If Raw becomes fully verbatim, this test changes on purpose.
    @Test func rawStillRemovesLongFillerSounds() async {
        let o = await run("Bu ммм yaxshi", level: .off, cleaner: MockCleaner("x"))
        #expect(o.text == "Bu yaxshi")
    }

    // MARK: fallback reason

    @Test func aRejectedCleanupLeavesAReasonClass() async {
        let raw = "bugun biz yangi versiyani chiqaramiz va test qilamiz"
        let empty = await run(raw, level: .light, cleaner: MockCleaner(""))
        #expect(empty.fallbackReason == "empty" && empty.text == raw)
        let timeout = await run(raw, level: .light, cleaner: MockCleaner([.failure(URLError(.timedOut))]))
        #expect(timeout.fallbackReason == "timeout")
        let limited = await run(raw, level: .light, cleaner: MockCleaner([.failure(SoylaError.http(status: 429, body: ""))]))
        #expect(limited.fallbackReason == "rate_limited")
        let answer = await run("What is the capital of France?", level: .light, cleaner: MockCleaner("The capital of France is Paris."))
        #expect(answer.fallbackReason == "answer")
        let broken = await run(raw, level: .light, cleaner: MockCleaner([.failure(SoylaError.http(status: 500, body: "FAKE1234 words"))]))
        #expect(broken.fallbackReason == "error")
    }

    @Test func noFallbackWhenNothingWasRejected() async {
        let raw = "ee mmm men ertaga soat uchda, yo'q, to'rtda uchrashuvga boraman"
        let ok = await run(raw, level: .light, cleaner: MockCleaner("Men ertaga soat to'rtda uchrashuvga boraman."))
        #expect(ok.status == .ok && ok.fallbackReason == nil)
        let short = await run("Ha, mayli", level: .light, cleaner: MockCleaner("x"))
        #expect(short.status == .skippedShort && short.fallbackReason == nil)
        let cool = ProviderCooldown(); cool.note429("k")
        let cooling = await run(raw, level: .light, cleaner: MockCleaner("x"), cooldown: cool)
        #expect(cooling.status == .skippedCooldown && cooling.fallbackReason == nil)
    }

    @Test func applyWritesTheOutcomeIntoTheRecord() async {
        let o = await run("bugun biz yangi versiyani chiqaramiz va test qilamiz", level: .light, cleaner: MockCleaner(""))
        var r = fakeRecord()
        o.apply(to: &r)
        #expect(r.cleanupFallback == "empty" && r.providerMeta?["cleanup"] == "guard" && r.providerMeta?["provider"] == "mock")
        #expect(r.cleanupUsage == o.usage)
        // The reason is a class, never text.
        #expect(r.cleanupFallback.map { !$0.contains(" ") } == true)
    }

    // MARK: the note, once a day

    private func defaults() throws -> (UserDefaults, String) {
        let name = "ai.soyla.test.rawswitch.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }
    private let noon = Date(timeIntervalSince1970: 1_792_000_000)     // a fixed instant; the calendar below is UTC
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .gmt; return c }

    @Test func theNoteShowsOncePerDay() throws {
        let (d, name) = try defaults(); defer { dropTestDomain(name) }
        #expect(FallbackNotice.card(for: nil, now: noon, defaults: d, calendar: utc) == nil)      // no fallback, no note
        let first = FallbackNotice.card(for: "ratio_low", now: noon, defaults: d, calendar: utc)
        #expect(first?.kind == .info && first?.title == "Pasted as heard (cleanup skipped)")
        #expect(FallbackNotice.card(for: "answer", now: noon.addingTimeInterval(3600), defaults: d, calendar: utc) == nil)
        #expect(FallbackNotice.card(for: "answer", now: noon.addingTimeInterval(86_400), defaults: d, calendar: utc) != nil)
    }

    @Test func theDayIsRecordedOnlyWhenTheCardIsReallySet() throws {
        let (d, name) = try defaults(); defer { dropTestDomain(name) }
        // The run was cancelled or superseded before the card could show: nothing is recorded, so today's note is kept.
        #expect(FallbackNotice.card(for: "answer", live: false, now: noon, defaults: d, calendar: utc) == nil)
        #expect(FallbackNotice.card(for: "answer", live: true, now: noon, defaults: d, calendar: utc) != nil)
        #expect(FallbackNotice.card(for: "answer", live: true, now: noon, defaults: d, calendar: utc) == nil)
    }

    @Test func theNoteWordsFollowTheInterfaceLanguage() {
        let card = FallbackNotice.skippedCard
        #expect(card.localized(.en).title == AppStrings.en.d.rsSkipped)
        #expect(card.localized(.uz).title == AppStrings.uz.d.rsSkipped)
        #expect(card.localized(.ru).title == AppStrings.ru.d.rsSkipped)
        #expect(AppStrings.en.d.rsSkipped == "Pasted as heard (cleanup skipped)")
    }

    @Test func aForcedGuardFailureReachesTheRecordAndTheNoteOnce() async throws {
        let (d, name) = try defaults(); defer { dropTestDomain(name) }
        let raw = "bugun biz yangi versiyani chiqaramiz va test qilamiz"
        let o = await run(raw, level: .light, cleaner: MockCleaner([.failure(CleanupGuardError(.truncated))]))
        var r = fakeRecord()
        o.apply(to: &r)
        #expect(r.cleanupFallback == "truncated" && o.text == raw)
        #expect(FallbackNotice.card(for: r.cleanupFallback, now: noon, defaults: d, calendar: utc) != nil)
        #expect(FallbackNotice.card(for: r.cleanupFallback, now: noon, defaults: d, calendar: utc) == nil)
    }
}

@Suite struct CleanupSwitchTests {
    private func store() throws -> (SettingsStore, UserDefaults, String) {
        let name = "ai.soyla.test.cleanupswitch.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        return (SettingsStore(defaults: d), d, name)
    }

    @Test func theChoiceIsRawOrLightAndPersists() throws {
        let (s, d, name) = try store(); defer { dropTestDomain(name) }
        #expect(CleanupChoice.levels == [.off, .light])
        CleanupChoice.set(.light, in: s)
        #expect(s.current.cleanupLevel == .light && s.current.cleanupEnabled)
        #expect(SettingsStore(defaults: d).current.cleanupLevel == .light)           // survives a relaunch
        CleanupChoice.set(.off, in: s)
        #expect(SettingsStore(defaults: d).current.cleanupLevel == .off)
        // The stored value is still "off": only the word on screen changed.
        let blob = String(data: d.data(forKey: "settings.v1") ?? Data(), encoding: .utf8) ?? ""
        #expect(blob.contains("\"cleanupLevel\":\"off\""))
    }

    @Test func offIsCalledRawInEveryLanguageAndNeverOff() {
        #expect(CleanupChoice.name(.off, .en) == "Raw" && CleanupChoice.name(.light, .en) == "Light")
        #expect(CleanupChoice.name(.off, .uz) == AppStrings.uz.hiRaw && CleanupChoice.name(.off, .ru) == AppStrings.ru.hiRaw)
        for l in UILanguage.allCases {
            let t = AppStrings.for(l)
            #expect(!t.dCleanI.contains("Off") && !t.cleanOff.lowercased().contains("off"))
            #expect(!t.d.rsRawC.isEmpty && !t.d.rsBadgeH.isEmpty)
        }
        #expect(CleanupChoice.menuTitle(.off, .en) == "Correction pass: Raw")
    }

    @Test func rowsMarkTheCurrentLevel() {
        let rows = CleanupChoice.rows(current: .light, .en)
        #expect(rows.map(\.title) == ["Raw", "Light"] && rows.map(\.checked) == [false, true])
        #expect(CleanupChoice.rows(current: .off, .ru).map(\.checked) == [true, false])
    }

    @Test func theFreeEngineHasNoSwitch() {
        #expect(!CleanupChoice.offered(for: .apple))
        for p in ProviderKind.allCases where p != .apple { #expect(CleanupChoice.offered(for: p)) }
    }
}
