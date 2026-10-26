import Foundation
import Testing
@testable import SoylaCore

/// 2026-10-26 perf test follow-ups: scripts outside the allowed set, timestamps glued into words, replies that run
/// away or are cut off by the output cap, and request timeouts sized to the clip. All text here is fake.
@Suite struct SttQualityGuardTests {
    func clip(_ sec: Double) -> EncodedAudio {
        EncodedAudio(data: Data([1]), format: "flac", durationSec: sec, sampleRate: 16000, fileURL: nil)
    }

    func words(_ n: Int) -> String { Array(repeating: "FAKE", count: n).joined(separator: " ") }

    // MARK: script allowlist

    @Test func newScriptsAreForeign() {
        #expect(TextGuards.scriptIssue("Привет руководи Ᏻтелей") == .foreignScript("cherokee"))
        #expect(TextGuards.scriptIssue("Salom ϓ dunyo") == .foreignScript("greek"))
        #expect(TextGuards.scriptIssue("Salom Ελλάδα") == .foreignScript("greek"))
        #expect(TextGuards.scriptIssue("Salom Բարեւ") == .foreignScript("armenian"))
        #expect(TextGuards.scriptIssue("Salom გამარჯობა") == .foreignScript("georgian"))
        #expect(TextGuards.scriptIssue("Salom שלום") == .foreignScript("hebrew"))
        #expect(TextGuards.scriptIssue("Salom नमस्ते") == .foreignScript("other"))
        #expect(ScriptIssue.foreignScript("greek").tag == "foreign:greek")
    }

    @Test func knownScriptsKeepTheirNames() {
        #expect(TextGuards.scriptIssue("안녕하세요") == .foreignScript("hangul"))
        #expect(TextGuards.scriptIssue("Salom مرحبا") == .foreignScript("arabic"))
        #expect(TextGuards.scriptIssue("こんにちは") == .foreignScript("kana"))
        #expect(TextGuards.scriptIssue("你好") == .foreignScript("cjk"))
        #expect(TextGuards.scriptIssue("สวัสดี") == .foreignScript("thai"))
    }

    @Test func allowedTextPasses() {
        #expect(TextGuards.scriptIssue("Café Müller, François, Ñoño, Ça va, Søren") == nil)          // Latin-1 names
        #expect(TextGuards.scriptIssue("O\u{02BB}zbekiston g\u{02BC}alaba, o\u{2018}g\u{2019}il, o`g`il") == nil)
        #expect(TextGuards.scriptIssue("Salom 👋 — 100% ✓ №5 (x) €20 ½ ™ «ok» 3×4") == nil)
        #expect(TextGuards.scriptIssue("Привет, потом напишу. Hello!") == nil)
        #expect(TextGuards.scriptIssue("Cafe\u{0301} ok") == nil)                                      // combining accent
    }

    /// Uzbek Latin uses none of ğ ş ı ł ż ť, but Turkish and Polish names do. One or two such words pass;
    /// three or more read like a transliteration ("Nużno także obnowiť…", pieces replay 2026-10-26).
    @Test func latinExtendedNeedsThreeWords() {
        #expect(TextGuards.scriptIssue("Doğan va Łukasz bilan gaplashdim") == nil)
        #expect(TextGuards.scriptIssue("Nużno także obnowiť dokumenty") == .latinExtended)
        #expect(ScriptIssue.latinExtended.tag == "latin_ext")
        #expect(TextGuards.scriptProfile("Doğan").latin == 5 && TextGuards.scriptProfile("Doğan").foreign == 0)
    }

    @Test func greekOnFirstTryIsRetried() async throws {
        let stt = MockSTT("Salom ϓ dunyo", "Salom dunyo.")
        let r = try await ScriptCheck.transcribe(stt, audio: clip(2), options: TranscribeOptions(model: "m"), timeline: RunTimeline())
        #expect(stt.options.count == 2 && r.text == "Salom dunyo." && r.providerMeta["script_check"] == "retried:foreign:greek")
    }

    @Test func strayCherokeeInLongTextIsStripped() async throws {
        let ru = String(repeating: "Потом напишу подробно. ", count: 6)
        let stt = MockSTT(ru + "руководи Ᏻтелей", ru + "руководи Ᏻтелей")
        let r = try await ScriptCheck.transcribe(stt, audio: clip(10), options: TranscribeOptions(model: "m"), timeline: RunTimeline())
        #expect(r.providerMeta["script_check"] == "stripped:foreign:cherokee")
        #expect(!r.text.contains("Ᏻ") && r.text.contains("Потом напишу"))
    }

    /// Latin-extended twice never costs the dictation: names would be lost. The try with fewer such words is pasted.
    @Test func latinExtendedTwiceIsKept() async throws {
        let stt = MockSTT("Nużno także obnowiť dokumenty", "Nużno także obnowiť dokumenty")
        let r = try await ScriptCheck.transcribe(stt, audio: clip(4), options: TranscribeOptions(model: "m"), timeline: RunTimeline())
        #expect(stt.options.count == 2 && r.text == "Nużno także obnowiť dokumenty")
        #expect(r.providerMeta["script_check"] == "latin_ext:kept")
    }

    // MARK: glued timestamps

    @Test func gluedTimestampsAreStripped() {
        #expect(TextGuards.stripTimestamps("Bugun uchra 00:04shuv bo'ladi.", durationSec: 10) == ("Bugun uchra shuv bo'ladi.", 1))
        #expect(TextGuards.stripTimestamps("Bugun uchra00:04shuv bo'ladi.", durationSec: 10) == ("Bugun uchrashuv bo'ladi.", 1))
        #expect(TextGuards.stripTimestamps("Narx 00:023:00 bo'ldi.", durationSec: 10) == ("Narx bo'ldi.", 1))
        #expect(TextGuards.stripTimestamps("Salom00:03 dunyo.", durationSec: 10) == ("Salom dunyo.", 1))
    }

    @Test func dictatedTimesStayEvenWhenGlued() {
        for t in ["Soat 5:30 da uchrashamiz.", "Meet at 10:15 please.", "Soat 14:30da keling.", "Soat 5:30da keling.",
                  "Встреча в 09:30, не опаздывай."] {
            #expect(TextGuards.stripTimestamps(t, durationSec: 20) == (t, 0))
        }
        // Zero-padded and glued, but past the end of a 20 s clip: a real time ("07:30da" = at 7:30).
        #expect(TextGuards.stripTimestamps("Ertaga 07:30da turaman.", durationSec: 20).removed == 0)
    }

    @Test func gluedAndSubtitleTimestampsCountTogether() {
        let r = TextGuards.stripTimestamps("00:01 Salom, bugun 00:07 test qila00:09miz.", durationSec: 20)
        #expect(r == ("Salom, bugun test qilamiz.", 3))
    }

    // MARK: salvage and keepBetter ignore Latin-extended names

    @Test func salvageKeepsTextWithNames() async throws {
        let long = "Doğan, Şükrü va Ağaoğlu bilan bugun yangi versiyani test qilamiz, keyin hammasini yozaman va ertaga yana gaplashamiz"
        let stt = MockSTT(long + " مرحبا", long + " مرحبا")
        let r = try await ScriptCheck.transcribe(stt, audio: clip(10), options: TranscribeOptions(model: "m"), timeline: RunTimeline())
        #expect(r.text == long && r.providerMeta["script_check"] == "stripped:foreign:arabic")
    }

    @Test func keepBetterKeepsTextWithNames() async throws {
        let t = "Doğan, Şükrü va Ağaoğlu bilan gaplashdim, потом напишу"
        let stt = MockSTT(t, t)
        let o = TranscribeOptions(model: "m", languages: ["uz", "en"])
        let r = try await ScriptCheck.transcribe(stt, audio: clip(4), options: o, timeline: RunTimeline())
        #expect(r.text == t && r.providerMeta["script_check"] == "outside_set:kept")
    }

    // MARK: runaway and cut-off replies

    @Test func runawayTwiceIsTheCard() async {
        let stt = MockSTT(words(300), words(400))
        do {
            _ = try await ScriptCheck.transcribe(stt, audio: clip(2), options: TranscribeOptions(model: "m"), timeline: RunTimeline())
            Issue.record("expected ScriptCheckError")
        } catch {
            #expect(error as? ScriptCheckError == ScriptCheckError(.runaway))
            #expect(ScriptIssue.runaway.tag == "runaway")
            let f = PillFailure.from(error, stage: "transcribe")
            #expect(f.title == "Didn't understand that" && f.canRetry)
        }
        #expect(stt.options.count == 2)
    }

    /// Pieces: a piece that runs away twice must not become "" (its speech silently gone): the whole clip is sent.
    @Test func runawayPieceFallsBackToTheWholeClip() async throws {
        let pcm = loud(1)
        let stt = ScriptedSTT([.text(words(300)), .text(words(300)), .text(words(300)), .text(words(300)), .text("Butun yozuv.")])
        let feeder = SegmentFeeder(transcriber: SegmentedTranscriber(provider: stt, options: TranscribeOptions(model: "m"), format: .wav))
        feeder.feed(pcm)
        let r = try await DictationPipeline.transcript(stt, audio: clip(1), options: TranscribeOptions(model: "m"),
                                                       timeline: RunTimeline(), segments: (feeder, pcm))
        #expect(r.text == "Butun yozuv." && r.providerMeta["segments"] == "fallback")
        #expect(await stt.calls.count == 5)
    }

    /// The script retry runs away: the first reply decides alone (no card for a name-heavy or salvageable text).
    @Test func latinExtendedWithARunawayRetryPastesTheFirst() async throws {
        let first = "Nużno także obnowiť dokumenty"
        let stt = ScriptedSTT([.text(first), .text(words(300))])
        let r = try await ScriptCheck.transcribe(stt, audio: clip(4), options: TranscribeOptions(model: "m"), timeline: RunTimeline())
        #expect(r.text == first && r.providerMeta["script_check"] == "latin_ext:kept" && r.providerMeta["script_retry"] == "bad")
        #expect(await stt.calls.count == 2)
    }

    @Test func foreignScriptWithARunawayRetryIsSalvagedFromTheFirst() async throws {
        let long = String(repeating: "Bugun yangi versiyani test qilamiz, keyin yozaman. ", count: 3) + "Rahmat"
        let stt = ScriptedSTT([.text(long + " مرحبا"), .text(words(300))])
        let r = try await ScriptCheck.transcribe(stt, audio: clip(10), options: TranscribeOptions(model: "m"), timeline: RunTimeline())
        #expect(r.text == long && r.providerMeta["script_check"] == "stripped:foreign:arabic")
        #expect(await stt.calls.count == 2)
    }

    @Test func otherIssueWithACutOffRetryIsStillTheCard() async {
        let stt = ScriptedSTT([.text("안녕하세요"), .text("Salom", ["finish_reason": "MAX_TOKENS"])])
        await #expect(throws: ScriptCheckError(.foreignScript("hangul"))) {
            _ = try await ScriptCheck.transcribe(stt, audio: self.clip(2), options: TranscribeOptions(model: "m"), timeline: RunTimeline())
        }
    }

    /// Google can spend the whole cap before writing text: empty + MAX_TOKENS is cut off, not "no speech".
    @Test func emptyCutOffIsResentNotNoSpeech() async throws {
        #expect(!ScriptCheck.emptyIsNoSpeech("", finishReason: "MAX_TOKENS"))
        #expect(!ScriptCheck.emptyIsNoSpeech(" ", finishReason: "length"))
        #expect(ScriptCheck.emptyIsNoSpeech("", finishReason: "STOP"))
        #expect(ScriptCheck.emptyIsNoSpeech("", finishReason: nil))
        #expect(!ScriptCheck.emptyIsNoSpeech("Salom", finishReason: nil))
        let stt = ScriptedSTT([.text("", ["finish_reason": "MAX_TOKENS"]), .text("Salom, FAKE test.", ["finish_reason": "STOP"])])
        let r = try await ScriptCheck.transcribe(stt, audio: clip(4), options: TranscribeOptions(model: "m"), timeline: RunTimeline())
        #expect(r.text == "Salom, FAKE test." && r.providerMeta["truncated"] == "retried")
        #expect(await stt.calls.last?.maxTokensScale == 2)
    }

    @Test func emptyCutOffTwiceIsNoSpeech() async {
        let stt = ScriptedSTT([.text("", ["finish_reason": "MAX_TOKENS"]), .text("", ["finish_reason": "MAX_TOKENS"])])
        do {
            _ = try await ScriptCheck.transcribe(stt, audio: clip(4), options: TranscribeOptions(model: "m"), timeline: RunTimeline())
            Issue.record("expected emptyTranscript")
        } catch SoylaError.emptyTranscript {
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func cutOffReplyIsResentWithTwiceTheCap() async throws {
        for finish in ["MAX_TOKENS", "length"] {
            let stt = ScriptedSTT([.text("Salom, bu FAKE", ["finish_reason": finish]), .text("Salom, bu FAKE test.", ["finish_reason": "stop"])])
            let r = try await ScriptCheck.transcribe(stt, audio: clip(4), options: TranscribeOptions(model: "m"), timeline: RunTimeline())
            let calls = await stt.calls
            #expect(calls.count == 2 && calls[0].maxTokensScale == 1 && calls[1].maxTokensScale == 2)
            #expect(r.text == "Salom, bu FAKE test." && r.providerMeta["truncated"] == "retried")
        }
    }

    @Test func cutOffTwiceIsTheCard() async {
        let stt = ScriptedSTT([.text("Salom", ["finish_reason": "MAX_TOKENS"]), .text("Salom", ["finish_reason": "MAX_TOKENS"])])
        await #expect(throws: ScriptCheckError(.runaway)) {
            _ = try await ScriptCheck.transcribe(stt, audio: self.clip(4), options: TranscribeOptions(model: "m"), timeline: RunTimeline())
        }
    }

    /// The script retry is checked too, but never resent: `checked` makes at most 3 calls. A bad retry leaves
    /// the first reply to decide alone; Hangul cannot be salvaged, so it is the card, as before.
    @Test func scriptRetryThatRunsAwayIsTheCard() async {
        let stt = MockSTT("안녕하세요", words(300))
        await #expect(throws: ScriptCheckError(.foreignScript("hangul"))) {
            _ = try await ScriptCheck.transcribe(stt, audio: self.clip(2), options: TranscribeOptions(model: "m"), timeline: RunTimeline())
        }
        #expect(stt.options.count == 2)
        let worst = ScriptedSTT([.text(words(300)), .text("안녕하세요"), .text("Salom", ["finish_reason": "length"])])
        await #expect(throws: ScriptCheckError(.foreignScript("hangul"))) {
            _ = try await ScriptCheck.transcribe(worst, audio: self.clip(2), options: TranscribeOptions(model: "m"), timeline: RunTimeline())
        }
        #expect(await worst.calls.count == 3)
    }

    @Test func bothRoutesCarryTheDoubledCap() throws {
        var o = TranscribeOptions(model: "gemini-3.5-flash")
        o.maxTokensScale = 2
        let g = try #require(try JSONSerialization.jsonObject(with: GoogleAIProvider.makeBody(clip(4), options: o)) as? [String: Any])
        #expect((g["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int == 2 * TextGuards.sttMaxTokens(durationSec: 4))
        let c = try #require(try JSONSerialization.jsonObject(with: OpenRouterSTTProvider.makeChatBody(clip(4), options: o)) as? [String: Any])
        #expect(c["max_tokens"] as? Int == 2 * TextGuards.sttMaxTokens(durationSec: 4))
    }

    @Test func chatFinishReasonIsRead() throws {
        let cut = #"{"choices":[{"finish_reason":"length","native_finish_reason":"MAX_TOKENS","message":{"content":"Salom"}}]}"#
        #expect(OpenRouterSTTProvider.chatFinishReason(Data(cut.utf8)) == "length")
        #expect(OpenRouterSTTProvider.chatFinishReason(Data(#"{"choices":[{"message":{"content":"Salom"}}]}"#.utf8)) == nil)
        #expect(try GoogleAIHTTP.decode(Data(#"{"candidates":[{"content":{"parts":[{"text":"Salom"}]},"finishReason":"MAX_TOKENS"}]}"#.utf8)).2 == "MAX_TOKENS")
    }

    // MARK: request timeouts

    @Test func timeoutGrowsWithTheClip() {
        #expect(TextGuards.sttTimeoutSec(durationSec: 5.9, cap: 60) == 15)
        #expect(TextGuards.sttTimeoutSec(durationSec: 20, cap: 60) == 15)
        #expect(TextGuards.sttTimeoutSec(durationSec: 40, cap: 60) == 30)
        #expect(TextGuards.sttTimeoutSec(durationSec: 60, cap: 60) == 45)
        #expect(TextGuards.sttTimeoutSec(durationSec: 300, cap: 60) == 60)
        #expect(TextGuards.sttTimeoutSec(durationSec: 5, cap: 10) == 10)
    }

    @Test func googleRequestUsesTheClipTimeout() throws {
        let req = try GoogleAIProvider.makeRequest(clip(5.9), options: TranscribeOptions(model: "gemini-3.5-flash"), apiKey: "FAKE1234")
        #expect(req.timeoutInterval == 15)
    }

    @Test func openRouterRequestUsesTheClipTimeout() throws {
        let o = TranscribeOptions(model: "chat:google/gemini-3.5-flash")
        let req = try OpenRouterSTTProvider.makeRequest(clip(5.9), options: o, apiKey: "FAKE1234", baseURL: OpenRouterHTTP.base)
        #expect(req.timeoutInterval == 15)
        // A custom (often local) server may be slow on a CPU: it keeps the full timeout.
        let local = try OpenRouterSTTProvider.makeRequest(clip(5.9), options: o, apiKey: "", baseURL: "http://127.0.0.1:8080/v1")
        #expect(local.timeoutInterval == 60)
    }
}

/// Loud square wave: counts as voiced for `Encoder.voicedMs`.
func loud(_ sec: Double) -> Data {
    let n = Int(sec * Double(PCMSpec.sampleRate))
    let s = (0..<n).map { i -> Int16 in (i / 20) % 2 == 0 ? 9830 : -9830 }
    return s.withUnsafeBufferPointer { Data(buffer: $0) }
}

/// Canned replies in order (text + meta, or an error), recording each call's options. Empty when they run out.
actor ScriptedSTT: TranscriptionProvider {
    enum Reply: Sendable {
        case text(String, [String: String] = [:])
        case fail(SoylaError)
    }

    nonisolated let id = "mock"
    private var replies: [Reply]
    private(set) var calls: [TranscribeOptions] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func transcribe(_ audio: EncodedAudio, options: TranscribeOptions, timeline: RunTimeline) async throws -> TranscriptResult {
        calls.append(options)
        guard !replies.isEmpty else { return TranscriptResult(text: "") }
        switch replies.removeFirst() {
        case .text(let t, let meta): return TranscriptResult(text: t, providerMeta: meta)
        case .fail(let e): throw e
        }
    }
}
