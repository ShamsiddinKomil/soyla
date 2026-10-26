import Foundation
import Testing
@testable import SoylaCore

// 2026-10-26 (owner chose the recommended approach): the capture gate also counts quiet speech that stands out from
// the clip's own noise floor. Synthetic audio only.

private func sine(_ seconds: Double, amp: Double, hz: Double = 220) -> Data {
    let n = Int(seconds * Double(PCMSpec.sampleRate))
    var d = Data(capacity: n * 2)
    for i in 0..<n {
        let v = Int16(amp * 32767 * sin(2 * .pi * hz * Double(i) / Double(PCMSpec.sampleRate)))
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
    return d
}

/// Syllables at frame RMS ≈ 0.014 (under the old 0.02 gate) with short pauses at ≈ 0.001 room noise: 2 s of 3 s voiced.
private func quietSpeech() -> Data {
    var d = Data()
    for _ in 0..<10 { d += sine(0.2, amp: 0.02); d += sine(0.1, amp: 0.0014) }
    return d
}

@Suite struct CaptureGateTests {
    @Test func quietSpeechIsSentNow() {
        let pcm = quietSpeech()
        #expect(Encoder.voicedMs(pcm16: pcm) == 0)                           // the old rule refused it
        #expect(CaptureCheck.gateVoicedMs(pcm16: pcm) >= 1800)
        #expect(CaptureCheck.classify(pcm: pcm, heldMs: 3000, minDurationSec: 0.6, minVoicedMs: 250) == .send)
        #expect(CaptureCheck.classify(pcm: pcm, heldMs: 3000, minDurationSec: 0.6, minVoicedMs: 400) == .send)
    }

    /// Review 2026-10-26: startup zeros or dropouts must not drag the noise floor to 0 and let room noise count.
    @Test func zerosDoNotLowerTheNoiseFloor() {
        let room = sine(1.8, amp: 0.01 * 2.0.squareRoot())                    // RMS 0.01: room noise the old gate blocked
        for zeros in [6_400, 12_800, 32_000] {                                // 200, 400, 1000 ms of zeros first
            let pcm = Data(count: zeros) + room
            #expect(CaptureCheck.gateVoicedMs(pcm16: pcm) == 0, "\(zeros)")
            #expect(CaptureCheck.classify(pcm: pcm, heldMs: 2000, minDurationSec: 0.6, minVoicedMs: 250) != .send)
        }
        // Quiet speech after startup zeros still counts.
        #expect(CaptureCheck.gateVoicedMs(pcm16: Data(count: 12_800) + quietSpeech()) >= 1800)
        // Too little non-silent audio to measure a floor: the old 0.02 rule alone.
        let blip = Data(count: 64_000) + sine(0.1, amp: 0.015)
        #expect(CaptureCheck.gateVoicedMs(pcm16: blip) == Encoder.voicedMs(pcm16: blip))
    }

    @Test func silenceAndRoomNoiseStayBlocked() {
        #expect(CaptureCheck.gateVoicedMs(pcm16: Data(count: 96_000)) == 0)
        #expect(CaptureCheck.gateVoicedMs(pcm16: Data()) == 0)
        #expect(CaptureCheck.gateVoicedMs(pcm16: sine(3, amp: 0.008)) == 0)   // RMS ≈ 0.0057, under the 0.008 floor
        #expect(CaptureCheck.classify(pcm: sine(3, amp: 0.008), heldMs: 3000, minDurationSec: 0.6, minVoicedMs: 250)
            == .missedSpeech)
    }

    @Test func aQuietSteadyHumIsNotSpeech() {
        // RMS ≈ 0.0106: over the absolute floor, but it IS the clip's floor, so nothing stands out from it.
        #expect(CaptureCheck.gateVoicedMs(pcm16: sine(3, amp: 0.015)) == 0)
        // Sounds must rise 4x above the floor: 0.014 bursts over a 0.004 hum do not count…
        var hum = Data()
        for _ in 0..<10 { hum += sine(0.1, amp: 0.02); hum += sine(0.2, amp: 0.0057) }
        #expect(CaptureCheck.gateVoicedMs(pcm16: hum) == 0)
        // …the same bursts over a quiet room do.
        #expect(CaptureCheck.gateVoicedMs(pcm16: quietSpeech()) > 0)
    }

    @Test func everythingTheOldRuleCountedStillCounts() {
        // The adaptive rule only adds frames: anything over 0.02 RMS is voiced as before (steady tones included,
        // which `CaptureVerdictTests.speechIsSent` relies on), so no clip the old gate sent is refused now.
        var word = sine(0.3, amp: 0.2); word += sine(1.7, amp: 0.003)
        var loudFloor = Data()                                                // continuous speech, no pauses
        for _ in 0..<10 { loudFloor += sine(0.1, amp: 0.06); loudFloor += sine(0.1, amp: 0.12) }
        for pcm in [sine(2, amp: 0.2), word, loudFloor, sine(1, amp: 0.001), Data(count: 32_000)] {
            #expect(CaptureCheck.gateVoicedMs(pcm16: pcm) >= Encoder.voicedMs(pcm16: pcm))
        }
        #expect(abs(CaptureCheck.gateVoicedMs(pcm16: word) - 300) <= 20)     // the 0.003 tail stays unvoiced
    }

    @Test func noiseFloorIsALowPercentileOfFrameRms() {
        #expect(CaptureCheck.noiseFloor([]) == nil)
        #expect(CaptureCheck.noiseFloor(Array(repeating: 0.5, count: 9)) == nil)   // under 10 measurable frames
        let frames = (1...20).map { Double($0) / 100 }                        // 0.01 … 0.20
        #expect(CaptureCheck.noiseFloor(frames) == 0.03)                      // 10th percentile: index 2 of 20
        #expect(CaptureCheck.noiseFloor(Array(repeating: 0, count: 50) + frames) == 0.03)   // zeros are skipped
        #expect(CaptureCheck.noiseFloor(Array(repeating: 0.0005, count: 50) + frames) == 0.03)
    }

    /// Review 2026-10-26: pieces run without the hallucination guard, so they keep the old 0.02 rule. When no piece
    /// was sent at all, the whole recording goes instead (with the guard), so a quiet speaker's text is not lost.
    @Test func quietPiecesAreNotSentAlone() async throws {
        let stt = CountingSTT()
        let st = SegmentedTranscriber(provider: stt, options: TranscribeOptions(model: "m"), format: .wav)
        await st.submit(index: 0, pcm: quietSpeech(), hardCutBefore: false)
        await st.submit(index: 1, pcm: Data(count: 64_000), hardCutBefore: false)
        await #expect(throws: NoPieceSent.self) { _ = try await st.finish() }
        #expect(await stt.calls == 0)
    }

    @Test func aQuietClipInPiecesModeIsSentWhole() async throws {
        let pcm = quietSpeech()
        let stt = CountingSTT()
        let feeder = SegmentFeeder(transcriber: SegmentedTranscriber(provider: stt, options: TranscribeOptions(model: "m"), format: .wav))
        feeder.feed(pcm)
        let audio = EncodedAudio(data: Data(), format: "wav", durationSec: 3, sampleRate: 16000, fileURL: nil)
        let r = try await DictationPipeline.transcript(stt, audio: audio, options: TranscribeOptions(model: "m"),
                                                       timeline: RunTimeline(), segments: (feeder, pcm))
        #expect(r.text == "Salom." && r.providerMeta["segments"] == "fallback")
        #expect(await stt.calls == 1)
    }

    @Test func aPieceWithSpeechStillMeansNoFallback() async throws {
        let stt = CountingSTT()
        let st = SegmentedTranscriber(provider: stt, options: TranscribeOptions(model: "m"), format: .wav)
        await st.submit(index: 0, pcm: sine(1, amp: 0.2), hardCutBefore: false)
        await st.submit(index: 1, pcm: quietSpeech(), hardCutBefore: false)
        #expect(try await st.finish().result.text == "Salom.")
        #expect(await stt.calls == 1)
    }
}

private actor CountingSTT: TranscriptionProvider {
    nonisolated let id = "counting"
    private(set) var calls = 0
    func transcribe(_ audio: EncodedAudio, options: TranscribeOptions, timeline: RunTimeline) async throws -> TranscriptResult {
        calls += 1
        return TranscriptResult(text: "Salom.")
    }
}
