import Foundation
import Testing
@testable import SoylaCore

/// 2026-10-26 perf test: on 2 s clips Gemini Flash sometimes returned 88–756 words and took 3–28 s (4 of 55 calls).
/// The request now caps output by clip length, and a reply far longer than anyone speaks is sent once more.
@Suite struct RunawayGuardTests {
    func clip(_ sec: Double) -> EncodedAudio {
        EncodedAudio(data: Data([1]), format: "flac", durationSec: sec, sampleRate: 16000, fileURL: nil)
    }

    func words(_ n: Int) -> String { Array(repeating: "FAKE", count: n).joined(separator: " ") }

    @Test func tokenCapGrowsWithTheClip() {
        #expect(TextGuards.sttMaxTokens(durationSec: 2) == 256 + 48)
        #expect(TextGuards.sttMaxTokens(durationSec: 60) == 256 + 1440)
        #expect(TextGuards.sttMaxTokens(durationSec: 0) == 256)
        #expect(TextGuards.sttMaxTokens(durationSec: 10000) == 8192)
    }

    @Test func googleBodyCarriesTheCap() throws {
        let body = try GoogleAIProvider.makeBody(clip(2), options: TranscribeOptions(model: "gemini-3.5-flash"))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let gen = try #require(json["generationConfig"] as? [String: Any])
        #expect(gen["maxOutputTokens"] as? Int == TextGuards.sttMaxTokens(durationSec: 2))
    }

    @Test func chatBodyCarriesTheCap() throws {
        let body = try OpenRouterSTTProvider.makeChatBody(clip(60), options: TranscribeOptions(model: "google/gemini-3.5-flash"))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["max_tokens"] as? Int == TextGuards.sttMaxTokens(durationSec: 60))
    }

    @Test func ranAwayOnlyWhenFarLongerThanSpeech() {
        #expect(!TextGuards.ranAway(words(9), durationSec: 2))
        #expect(!TextGuards.ranAway(words(36), durationSec: 2))          // 20 + 8 words a second: still allowed
        #expect(TextGuards.ranAway(words(88), durationSec: 2))
        #expect(!TextGuards.ranAway(words(250), durationSec: 60))        // a fast talker: ~4 words a second
        #expect(TextGuards.ranAway(words(2000), durationSec: 60))        // a loop
        #expect(!TextGuards.ranAway("", durationSec: 2))
    }

    @Test func aRunawayIsSentOnceMore() async throws {
        let stt = MockSTT(words(300), "Salom, bu FAKE test.")
        let r = try await ScriptCheck.transcribe(stt, audio: clip(2), options: TranscribeOptions(model: "m"), timeline: RunTimeline())
        #expect(stt.options.count == 2)
        #expect(r.text == "Salom, bu FAKE test.")
        #expect(r.providerMeta["runaway"] == "retried")
        #expect(r.providerMeta["script_check"] == "ok")
    }

    @Test func twoRunawaysPasteNothing() async {
        let stt = MockSTT(words(300), words(400))
        await #expect(throws: ScriptCheckError(.runaway)) {
            _ = try await ScriptCheck.transcribe(stt, audio: clip(2), options: TranscribeOptions(model: "m"), timeline: RunTimeline())
        }
        #expect(stt.options.count == 2)
    }

    @Test func normalSpeechIsNotRetried() async throws {
        let stt = MockSTT(words(150))
        let r = try await ScriptCheck.transcribe(stt, audio: clip(60), options: TranscribeOptions(model: "m"), timeline: RunTimeline())
        #expect(stt.options.count == 1)
        #expect(r.providerMeta["runaway"] == nil)
    }
}
