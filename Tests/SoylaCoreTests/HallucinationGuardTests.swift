import Foundation
import Testing
@testable import SoylaCore

/// D26 (a). Made-up text only; the stock phrases are the public model artefacts, not anyone's dictation.
@Suite struct HallucinationGuardTests {
    static let quiet = ClipStats(durationS: 2, voicedMs: 600, voicedRms: 0.024)   // breath / room noise

    // MARK: phrase matching

    @Test func stockPhrasesMatchInEachLanguage() {
        for t in ["Thanks for watching!", "thank you for watching.", "  THANK YOU FOR WATCHING  ", "Thanks for watching and see you next time",
                  "Спасибо за просмотр!", "спасибо за просмотр", "Ko'rganingiz uchun rahmat",
                  "Tomosha qilganingiz uchun rahmat!", "Томоша қилганингиз учун раҳмат"] {
            #expect(HallucinationGuard.isStockPhrase(t), "\(t)")
        }
    }

    @Test func normalisesCasePunctuationApostrophesAndYo() {
        #expect(HallucinationGuard.isStockPhrase("Ko’rganingiz uchun rahmat!!!"))
        #expect(HallucinationGuard.isStockPhrase("Koʻrganingiz uchun rahmat"))
        #expect(HallucinationGuard.isStockPhrase("thanks,   for\nwatching"))
        #expect(HallucinationGuard.isStockPhrase("СПАСИБО ЗА ПРОСМОТР"))
        #expect(HallucinationGuard.isStockPhrase("СУБТИТРЫ СДЕЛАЛ DimaTorzok."))
    }

    @Test func repeatsAndChainsMatch() {
        #expect(HallucinationGuard.isStockPhrase("Thanks for watching! Thanks for watching!"))
        #expect(HallucinationGuard.isStockPhrase("Thank you for watching. Thanks for watching."))
        #expect(HallucinationGuard.isStockPhrase("Спасибо за просмотр. Спасибо за просмотр!"))
    }

    @Test func onlyKnownCreditStringsMatch() {
        #expect(HallucinationGuard.isStockPhrase("Subtitles by the Amara.org community"))
        #expect(HallucinationGuard.isStockPhrase("Субтитры подготовлены сообществом Amara.org"))
        #expect(HallucinationGuard.isStockPhrase("Субтитры сделал DimaTorzok"))
        #expect(HallucinationGuard.isStockPhrase("Редактор субтитров А.Синецкая Корректор А.Егорова"))
        // fourth review 2026-10-26: a credit-shaped start plus other words is a real sentence
        for t in ["Субтитры сделал А. Фейков", "Субтитры подготовлены заранее", "Субтитры подготовлены не до конца",
                  "Субтитры подготовил мой коллега", "Subtitrlar tayyorladi kim", "Subtitles by the Amara team, please"] {
            #expect(HallucinationGuard.isStockPhrase(t) == false, "\(t)")
        }
    }

    @Test func realSentencesAreNeverStock() {
        for t in ["Thanks for watching my kid yesterday", "I said thanks for watching to everyone",
                  "thank you", "Thank you!", "спасибо", "Спасибо за внимание", "rahmat", "Пока", "bye",
                  "Bugun kanalga obuna bo'ling deb yozing", "Спасибо за просмотр документа FAKE1234", "", "   ", "...",
                  // review 2026-10-26: lines people dictate alone
                  "Всем пока", "See you next time", "До новых встреч", "Продолжение следует", "Please subscribe",
                  "Obuna bo'ling", "Translated by Google", "Captions by Friday", "Subtitles by tomorrow please",
                  "Корректор, исправь опечатку",
                  // second review 2026-10-26: channel calls Telegram admins write as posts
                  "Kanalimizga obuna bo'ling", "Каналга обуна бўлинг", "Подписывайтесь на наш канал", "Ставьте лайки",
                  "Like and subscribe", "Subscribe to my channel",
                  // third review 2026-10-26: credit-shaped sentences and creator captions
                  "Subtitrlar muallifi kim?", "Редактор субтитров нужен срочно", "Субтитры делал я сам", "Редактор субтитров",
                  "Субтитры сделал", "See you in the next video", "Keyingi videoda ko'rishguncha"] {
            #expect(HallucinationGuard.isStockPhrase(t) == false, "\(t)")
        }
    }

    // MARK: clip thresholds

    @Test func onlyShortQuietClipsQualify() {
        #expect(HallucinationGuard.isQuietShortClip(Self.quiet))
        #expect(HallucinationGuard.isQuietShortClip(ClipStats(durationS: 8, voicedMs: 4000, voicedRms: 0.0299)))
        #expect(HallucinationGuard.isQuietShortClip(ClipStats(durationS: 8.01, voicedMs: 100, voicedRms: 0.025)) == false)
        #expect(HallucinationGuard.isQuietShortClip(ClipStats(durationS: 2, voicedMs: 1020, voicedRms: 0.025)) == false)
        #expect(HallucinationGuard.isQuietShortClip(ClipStats(durationS: 2, voicedMs: 100, voicedRms: 0.03)) == false)
        #expect(HallucinationGuard.isQuietShortClip(ClipStats(durationS: 0, voicedMs: 0, voicedRms: 0)) == false)
        // The capture gate already sent this clip (≥ 250 ms voiced, the default): the guard must still be able to act.
        #expect(HallucinationGuard.isQuietShortClip(ClipStats(durationS: 3, voicedMs: 260, voicedRms: 0.026)))
        // review 2026-10-26: 1 s of ordinary speech in an 8 s hold is not quiet, however much silence surrounds it
        #expect(HallucinationGuard.isQuietShortClip(ClipStats(durationS: 8, voicedMs: 1000, voicedRms: 0.08)) == false)
    }

    @Test func dropsNeedsBothTheTextAndTheClip() {
        #expect(HallucinationGuard.drops("Thanks for watching!", clip: Self.quiet))
        #expect(HallucinationGuard.drops("Thanks for watching!", clip: ClipStats(durationS: 2, voicedMs: 1400, voicedRms: 0.08)) == false)
        #expect(HallucinationGuard.drops("Send the FAKE1234 report", clip: Self.quiet) == false)
        #expect(HallucinationGuard.drops("Thanks for watching!", clip: nil) == false)   // History retry: guard off
    }

    @Test func clipStatsFromPCM() {
        func pcm(seconds: Double, amplitude: Double) -> Data {
            let n = Int(seconds * 16000)
            var d = Data(capacity: n * 2)
            for i in 0..<n {
                let v = Int16(amplitude * 32767 * sin(Double(i) * 2 * .pi * 220 / 16000))
                withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
            }
            return d
        }
        let silent = ClipStats(pcm: Data(count: 32000))
        #expect(silent.durationS == 1)
        #expect(silent.voicedMs == 0)
        #expect(silent.voicedRms == 0)
        let loud = ClipStats(pcm: pcm(seconds: 2, amplitude: 0.3))
        #expect(abs(loud.durationS - 2) < 0.001)
        #expect(loud.voicedMs >= 1900)
        #expect(loud.voicedRms > 0.2)
        #expect(HallucinationGuard.isQuietShortClip(loud) == false)
        let faint = ClipStats(pcm: pcm(seconds: 2, amplitude: 0.01))
        #expect(faint.voicedMs == 0)
        #expect(HallucinationGuard.isQuietShortClip(faint))
        // review 2026-10-26: 1 s of ordinary speech (frame RMS ≈ 0.05) then 7 s of silence: whole-clip RMS would be
        // under 0.03, the voiced frames are not.
        let held = ClipStats(pcm: pcm(seconds: 1, amplitude: 0.07) + Data(count: 7 * 32000))
        #expect(held.voicedMs == Encoder.voicedMs(pcm16: pcm(seconds: 1, amplitude: 0.07) + Data(count: 7 * 32000)))
        #expect(held.voicedRms > 0.045)
        #expect(HallucinationGuard.isQuietShortClip(held) == false)
    }

    @Test func checkTagsTheRunAndThrowsOnlyOnADrop() throws {
        var meta: [String: String]? = ["paste": "commandV"]
        try HallucinationGuard.check("Send the FAKE1234 report", clip: Self.quiet, meta: &meta)
        #expect(meta == ["paste": "commandV"])
        #expect(throws: StockPhraseDropped.self) {
            try HallucinationGuard.check("Thanks for watching!", clip: Self.quiet, meta: &meta)
        }
        #expect(meta?["hallucination_guard"] == "dropped")
        #expect(meta?["paste"] == "commandV")
        var none: [String: String]?
        #expect(throws: StockPhraseDropped.self) { try HallucinationGuard.check("Спасибо за просмотр", clip: Self.quiet, meta: &none) }
        #expect(none == ["hallucination_guard": "dropped"])
    }

    @Test func storedClipReadsWavOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soyla-d26a-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("FAKE1234.wav")
        _ = try Encoder.encode(pcm16: Data(count: 32000), format: .wav, saveTo: wav)
        let c = try #require(ClipStats.stored(at: wav))
        #expect(abs(c.durationS - 1) < 0.01)
        #expect(c.voicedMs == 0)
        #expect(ClipStats.stored(at: dir.appendingPathComponent("FAKE1234.m4a")) == nil)
        #expect(ClipStats.stored(at: dir.appendingPathComponent("missing.wav")) == nil)
    }

    // MARK: what the user and the log see

    @Test func droppedPhraseIsTheCalmNoSpeechCard() {
        let f = PillFailure.from(StockPhraseDropped(), stage: "transcribe")
        #expect(f == PillFailure.from(SoylaError.emptyTranscript, stage: "transcribe"))
        #expect(f.title == "No speech heard")
        #expect(f.kind == .soft)
        #expect(f.canRetry == false)
    }

    @Test func errorDescriptionCarriesNoText() {
        let d = StockPhraseDropped().localizedDescription
        #expect(d == "stock phrase dropped (hallucination guard)")
        #expect(d.lowercased().contains("watching") == false)
    }
}
