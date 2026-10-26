import Foundation
import Testing
@testable import SoylaCore

// 2026-10-26 (owner chose the recommended approach): a short symbol-only reply ("_", ".") from a short, mostly
// unvoiced clip is not pasted. Digits always paste (review: a dictated number must never be lost). Synthetic audio and made-up text only.

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

@Suite struct ShortJunkTests {
    /// Keyboard bumps in a 6 s hold (the perf test's clip): 420 ms voiced.
    static let bumps = ClipStats(durationS: 6, voicedMs: 420, voicedRms: 0.137, gateVoicedMs: 420)
    /// "Thirty-four" dictated in a 2 s hold.
    static let spokenNumber = ClipStats(durationS: 2, voicedMs: 700, voicedRms: 0.12, gateVoicedMs: 700)

    /// A dictated "5" in a 3 s hold: 300 ms voiced (10 %), inside the mostly-unvoiced zone.
    static let shortNumber = ClipStats(durationS: 3, voicedMs: 300, voicedRms: 0.12, gateVoicedMs: 300)

    @Test func symbolOnlyReplies() {
        for t in ["_", ".", "—", "…", " . ", "? !", "%"] { #expect(HallucinationGuard.isSymbolOnlyJunk(t), "\(t)") }
        for t in ["34", "1", "0", "5", "100%", "3.14", "Alo", "Да", "Xo'sh", "FAKE1234", ". . .", "", "  "] {
            #expect(HallucinationGuard.isSymbolOnlyJunk(t) == false, "\(t)")
        }
    }

    @Test func mostlyUnvoicedShortClips() {
        #expect(HallucinationGuard.isMostlyUnvoicedShortClip(Self.bumps))
        #expect(HallucinationGuard.isMostlyUnvoicedShortClip(ClipStats(durationS: 5, voicedMs: 520, voicedRms: 0.039,
                                                                       gateVoicedMs: 520)))   // breath
        #expect(HallucinationGuard.isMostlyUnvoicedShortClip(Self.spokenNumber) == false)
        // The owner's quietest real short dictation: 17 % voiced (760 ms in 4.5 s).
        #expect(HallucinationGuard.isMostlyUnvoicedShortClip(ClipStats(durationS: 4.5, voicedMs: 760, voicedRms: 0.05,
                                                                       gateVoicedMs: 760)) == false)
        #expect(HallucinationGuard.isMostlyUnvoicedShortClip(ClipStats(durationS: 9, voicedMs: 300, voicedRms: 0.1,
                                                                       gateVoicedMs: 300)) == false)   // over 8 s
        #expect(HallucinationGuard.isMostlyUnvoicedShortClip(ClipStats(durationS: 0, voicedMs: 0, voicedRms: 0)) == false)
    }

    @Test func junkFromNoiseIsDroppedARealNumberIsNot() {
        #expect(HallucinationGuard.drops(".", clip: Self.bumps))
        #expect(HallucinationGuard.drops("_", clip: Self.shortNumber))
        #expect(HallucinationGuard.isMostlyUnvoicedShortClip(Self.shortNumber))
        #expect(HallucinationGuard.drops("5", clip: Self.shortNumber) == false)      // a dictated number always pastes
        #expect(HallucinationGuard.drops("100%", clip: Self.shortNumber) == false)
        #expect(HallucinationGuard.drops("34", clip: Self.bumps) == false)          // digit junk from bumps: accepted
        #expect(HallucinationGuard.drops("34", clip: Self.spokenNumber) == false)
        #expect(HallucinationGuard.drops("Alo", clip: Self.bumps) == false)  // a lone real word can't be told from speech
        #expect(HallucinationGuard.drops("Да", clip: Self.bumps) == false)
        #expect(HallucinationGuard.drops("34", clip: nil) == false)           // History retry: guard off
    }

    @Test func gateVoicedTimeIsMeasuredFromPCM() {
        let c = ClipStats(pcm: quietSpeech())
        #expect(c.voicedMs == 0)                                              // the meaning of voicedMs is unchanged
        #expect(c.gateVoicedMs == CaptureCheck.gateVoicedMs(pcm16: quietSpeech()))
        #expect(ClipStats(durationS: 2, voicedMs: 600, voicedRms: 0.024).gateVoicedMs == 600)   // defaults to voicedMs
    }

    @Test func checkTagsJunkAndThrowsTheCalmCard() throws {
        var meta: [String: String]? = ["paste": "commandV"]
        #expect(throws: ShortJunkDropped.self) { try HallucinationGuard.check("_", clip: Self.bumps, meta: &meta) }
        #expect(meta == ["paste": "commandV", "hallucination_guard": "junk"])
        let f = PillFailure.from(ShortJunkDropped(), stage: "transcribe")
        #expect(f == PillFailure.from(SoylaError.emptyTranscript, stage: "transcribe"))
        #expect(ShortJunkDropped().localizedDescription == "symbol-only reply dropped (hallucination guard)")
    }
}
