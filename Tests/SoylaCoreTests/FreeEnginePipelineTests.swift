import Foundation
import Testing
import os
@testable import SoylaCore

/// A provider that always throws (fake reasons only). MockSTT can't throw.
private final class ThrowingSTT: TranscriptionProvider, Sendable {
    let id = "throwing"
    let error: SoylaError
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var calls: Int { count.withLock { $0 } }
    init(_ error: SoylaError) { self.error = error }
    func transcribe(_ audio: EncodedAudio, options: TranscribeOptions, timeline: RunTimeline) async throws -> TranscriptResult {
        count.withLock { $0 += 1 }
        throw error
    }
}

// FE-4: the free engine in the pipeline (S3 effective settings, R1 live gate, D-PUNCT (b), P6 hint, pill cards).
@Suite struct FreeEnginePipelineTests {
    private let audio = EncodedAudio(data: Data([1]), format: "wav", durationSec: 5, sampleRate: 16000, fileURL: nil)

    private func cloud(_ kind: ProviderKind) -> Settings {
        var s = Settings()
        s.provider = kind
        s.cleanupLevel = .light
        s.livePreview = true
        s.audioFormat = .flac
        return s
    }

    // MARK: effectiveSettings (S3)

    @Test func effectiveSettingsTable() {
        var a = cloud(.apple)
        a.cleanupModel = "FAKE-model"
        let e = DictationPipeline.effectiveSettings(a)
        #expect(e.cleanupLevel == .off && e.cleanupEnabled == false)
        #expect(e.livePreview == false)
        #expect(e.audioFormat == .wav && e.uploadFormat == .wav)
        #expect(e.provider == .apple && e.onDeviceLocale == a.onDeviceLocale && e.languageHint == a.languageHint)
        // Idempotent.
        #expect(DictationPipeline.effectiveSettings(e) == e)
        // The input is a value: the caller's (stored) settings are untouched.
        #expect(a.cleanupLevel == .light && a.livePreview && a.audioFormat == .flac)
        for kind in ProviderKind.allCases where kind != .apple {
            let s = cloud(kind)
            #expect(DictationPipeline.effectiveSettings(s) == s, "cloud kind \(kind) must pass through unchanged")
        }
    }

    /// Merge with main's streaming work: pieces and the Live fast path are cloud requests, so the free engine turns
    /// them off and never builds a feeder or a Live race, whatever the stored settings say.
    @MainActor @Test func freeEngineNeverStartsPiecesOrLiveFastPath() {
        var a = cloud(.apple)
        a.streamSegments = true
        a.liveFastPath = true
        let e = DictationPipeline.effectiveSettings(a)
        #expect(e.streamSegments == false && e.liveFastPath == false)
        #expect(DictationPipeline.makeLiveRace(e) == nil)
        #expect(DictationPipeline.segmentFeeder(e, nil) == nil)
        var g = cloud(.google)
        g.streamSegments = true
        g.liveFastPath = true
        let ge = DictationPipeline.effectiveSettings(g)
        #expect(ge.streamSegments && ge.liveFastPath)   // cloud keeps the user's choice
    }

    // MARK: live preview gate (R1)

    @Test func livePreviewNeverStartsForApple() {
        var asked = 0
        let key = { () -> String? in asked += 1; return "FAKE1234" }
        #expect(DictationPipeline.livePreviewKey(cloud(.apple), key: key) == nil)
        #expect(asked == 0)                                   // not even a Keychain read
        #expect(DictationPipeline.livePreviewKey(cloud(.google), key: key) == "FAKE1234")
        #expect(DictationPipeline.livePreviewKey(cloud(.openRouter), key: key) == "FAKE1234")
        var off = cloud(.openRouter); off.livePreview = false
        #expect(DictationPipeline.livePreviewKey(off, key: key) == nil)
        #expect(DictationPipeline.livePreviewKey(cloud(.google), key: { nil }) == nil)
    }

    // MARK: no key needed

    @Test func appleNeedsNoKeyAndPastes() async throws {
        #expect(try ProviderFactory.apiKey(for: .apple) == "")
        var s = Settings(); s.provider = .apple; s.onDeviceLocale = "en-US"
        let e = DictationPipeline.effectiveSettings(s)
        let p = try ProviderFactory.transcriber(for: e)   // prewarm / run path: no throw without any key
        #expect(p is AppleSpeechProvider)
        let stt = MockSTT("hello from the fake engine")
        let r = try await DictationPipeline.transcribeStage(stt, audio: audio, options: TranscribeOptions(model: e.sttModel),
                                                            settings: e, timeline: RunTimeline())
        let c = await CleanupFlow.run(raw: r.text, level: e.cleanupLevel, cleaner: { throw SoylaError.missingAPIKey("FAKE") },
                                      model: e.cleanupModel, vocabulary: [], appName: nil, languageHint: e.languageHint,
                                      dictionary: ReplacementDictionary([]), cooldownKey: "apple", timeline: RunTimeline())
        #expect(c.text == "Hello from the fake engine.")
    }

    // MARK: model not ready

    @Test func modelNotReadyFailsWithRetryAndKeepsAudio() async {
        var s = Settings(); s.provider = .apple
        let e = DictationPipeline.effectiveSettings(s)
        let stt = ThrowingSTT(SoylaError.onDeviceUnavailable(reason: "model-not-installed"))
        do {
            _ = try await DictationPipeline.transcribeStage(stt, audio: audio, options: TranscribeOptions(model: e.sttModel),
                                                            settings: e, timeline: RunTimeline())
            Issue.record("expected onDeviceUnavailable")
        } catch {
            let f = PillFailure.from(error, stage: "transcribe")
            #expect(f.canRetry)
            #expect(f.kind != .soft)
        }
        #expect(stt.calls == 1)                                 // no script-check retry for .apple
        for r in AudioRetention.allCases { #expect(!DictationPipeline.deletesAudio(r, status: .failed)) }
    }

    // MARK: cleanup forced off

    @Test func cleanupForcedOffForApple() async {
        var s = Settings(); s.provider = .apple; s.cleanupLevel = .light; s.cleanupModel = "FAKE-model"
        let e = DictationPipeline.effectiveSettings(s)
        let rec = DictationPipeline.pendingRecord(audio: audio, runId: "r1", ts: "2026-10-16T00:00:00Z", settings: e)
        #expect(rec.cleanup == false && rec.cleanupModel == nil && rec.status == .pending)
        let cleaner = MockCleaner("should not be called")
        let c = await CleanupFlow.run(raw: "One two three four five six seven.", level: e.cleanupLevel, cleaner: { cleaner },
                                      model: e.cleanupModel, vocabulary: [], appName: nil, languageHint: nil,
                                      dictionary: ReplacementDictionary([]), cooldownKey: "apple", timeline: RunTimeline())
        #expect(c.status == .off && c.error == nil && cleaner.calls.isEmpty)
        // Cloud keeps what the user chose.
        let cloudRec = DictationPipeline.pendingRecord(audio: audio, runId: "r2", ts: "2026-10-16T00:00:00Z", settings: cloud(.google))
        #expect(cloudRec.cleanup == true)
    }

    // MARK: ScriptCheck

    @Test func scriptCheckBypassedForAppleActiveForCloud() async throws {
        let e = DictationPipeline.effectiveSettings({ var s = Settings(); s.provider = .apple; return s }())
        let apple = MockSTT("안녕하세요 첫 번째", "never asked")
        let r = try await DictationPipeline.transcribeStage(apple, audio: audio, options: TranscribeOptions(model: "m"),
                                                            settings: e, timeline: RunTimeline())
        #expect(apple.options.count == 1 && apple.options[0].extraInstruction == nil)
        #expect(r.text == "안녕하세요 첫 번째.")

        let cl = MockSTT("안녕하세요 첫 번째", "Xo'p, birinchi testim.")
        let r2 = try await DictationPipeline.transcribeStage(cl, audio: audio, options: TranscribeOptions(model: "m"),
                                                             settings: cloud(.google), timeline: RunTimeline())
        #expect(cl.options.count == 2)
        #expect(r2.text == "Xo'p, birinchi testim." && r2.providerMeta["script_check"] == "retried:foreign:hangul")
    }

    // MARK: D-PUNCT (b)

    @Test func punctuationTable() {
        let f = OnDevicePunctuation.finish
        #expect(f("") == "")
        #expect(f("   ") == "")
        #expect(f("hello world") == "Hello world.")
        #expect(f("Done?") == "Done?")
        #expect(f("ok 👍") == "Ok 👍")
        #expect(f("wait!") == "Wait!")
        #expect(f("and so…") == "And so…")
        #expect(f("the list:") == "The list:")
        #expect(f("one; two;") == "One; two;")
        #expect(f("It is done.") == "It is done.")
        #expect(f("  padded text  ") == "Padded text.")
        #expect(f("costs 5 $") == "Costs 5 $")              // ends in a symbol
        #expect(f("5 apples") == "5 apples.")
        #expect(f("iPhone is here") == "iPhone is here.")   // camel-case brand keeps its case
    }

    @Test func punctuationOnlyForApple() async throws {
        let raw = "hello world"
        let cl = MockSTT(raw)
        let r = try await DictationPipeline.transcribeStage(cl, audio: audio, options: TranscribeOptions(model: "m"),
                                                            settings: cloud(.openRouter), timeline: RunTimeline())
        #expect(r.text == raw)                                // cloud output untouched
    }

    // MARK: P6 hint card

    @Test func hintCardThresholds() {
        let words8 = "one two three four five six seven eight"
        let words9 = "one two three four five six seven eight nine"
        #expect(OnDeviceHint.shows(provider: .apple, durationSec: 41, text: words8))
        #expect(!OnDeviceHint.shows(provider: .apple, durationSec: 4, text: words9))
        #expect(!OnDeviceHint.shows(provider: .apple, durationSec: 2, text: ""))     // short-utterance path
        #expect(OnDeviceHint.shows(provider: .apple, durationSec: 3, text: ""))      // ≥ 3 s, nothing came back
        #expect(!OnDeviceHint.shows(provider: .google, durationSec: 41, text: words8))
        #expect(OnDeviceHint.minAudioSec == 3 && OnDeviceHint.maxWordsPerSec == 0.5)
        let card = PillFailure.onDeviceHint
        #expect(card.kind == .info && !card.canRetry && card.openSettings && card.settingsPage == .apiKeys)
        #expect(card.title + " " + card.hint == "Speaking Uzbek or Russian? Add a cloud key.")
    }

    // MARK: onDeviceUnavailable → pill card

    @Test func onDeviceUnavailableCards() {
        func card(_ r: String) -> PillFailure { PillFailure.from(SoylaError.onDeviceUnavailable(reason: r), stage: "transcribe") }
        let model = card("model-not-installed")
        #expect(model.title + " — " + model.hint.lowercasedFirst == "English model not ready — open Soyla to finish setup")
        #expect(model.canRetry && model.kind != .soft && model.openSettings && model.settingsPage == .apiKeys)
        let perm = card("needs-permission")
        #expect(perm.title == "Allow Speech Recognition in Settings")
        #expect(perm.canRetry && perm.openSettings && perm.settingsPage == .permissions)
        for r in ["unsupported", "recognizer-busy", "no-locale", "recognizer-failed:FakeDomain:1"] {
            let o = card(r)
            #expect(o.title + " — " + o.hint.lowercasedFirst == "On-device engine unavailable — try again or switch to Cloud", "\(r)")
            #expect(o.canRetry)
        }
    }
}

private extension String {
    /// "Open Soyla to finish setup." → "open Soyla to finish setup" (cards split the owner's one-line copy into title + hint).
    var lowercasedFirst: String {
        var t = self
        if t.hasSuffix(".") { t.removeLast() }
        guard let f = t.first else { return t }
        return f.lowercased() + t.dropFirst()
    }
}
