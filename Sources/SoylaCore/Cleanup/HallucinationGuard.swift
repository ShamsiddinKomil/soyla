import Foundation

/// Level of a captured clip, measured on the audio after key-down (D26 a).
public struct ClipStats: Equatable, Sendable {
    public var durationS: Double
    /// `Encoder.voicedMs`: 20 ms frames over 0.02 RMS.
    public var voicedMs: Double
    /// Mean RMS of the voiced frames only, 0…1 (0 when none). Silence in the hold can't water it down (review
    /// 2026-10-26: whole-clip RMS made ordinary speech in a long hold look quiet).
    public var voicedRms: Double
    /// `CaptureCheck.gateVoicedMs`: the capture gate's voiced time, which also counts quiet speech (2026-10-26).
    public var gateVoicedMs: Double

    public init(durationS: Double, voicedMs: Double, voicedRms: Double, gateVoicedMs: Double? = nil) {
        self.durationS = durationS; self.voicedMs = voicedMs; self.voicedRms = voicedRms
        self.gateVoicedMs = gateVoicedMs ?? voicedMs
    }

    public init(pcm: Data) {
        let frames = Self.frameRms(pcm).filter { $0 > Self.voicedFrameRms }
        self.init(durationS: Encoder.duration(pcm16: pcm), voicedMs: Double(frames.count) * 20,
                  voicedRms: frames.isEmpty ? 0 : frames.reduce(0, +) / Double(frames.count),
                  gateVoicedMs: CaptureCheck.gateVoicedMs(pcm16: pcm))
    }

    /// The same frames and threshold as `Encoder.voicedMs`: 20 ms, voiced above 0.02 RMS.
    static let voicedFrameRms = 0.02
    static func frameRms(_ pcm16: Data) -> [Double] { Encoder.frameRms(pcm16: pcm16) }

    /// A stored Soyla WAV (pill Retry). Older non-WAV files or a read error: nil, so the guard stays off.
    /// Includes the pre-roll, so it reads slightly longer than the live clip; over 8 s it isn't measured.
    public static func stored(at url: URL) -> ClipStats? {
        guard url.pathExtension.lowercased() == "wav", let pcm = try? WAVFile.readPCM(at: url),
              Encoder.duration(pcm16: pcm) <= HallucinationGuard.maxDurationS else { return nil }
        return ClipStats(pcm: pcm)
    }
}

/// The transcript was a stock invented phrase on a short, quiet clip: nothing is pasted. No text in the description.
public struct StockPhraseDropped: LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "stock phrase dropped (hallucination guard)" }
}

/// A reply of only punctuation or symbols on a short, mostly unvoiced clip: nothing is pasted.
public struct ShortJunkDropped: LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "symbol-only reply dropped (hallucination guard)" }
}

/// D26 (a): speech models answer near-silence with lines from video credits ("Thanks for watching",
/// "Спасибо за просмотр", "Субтитры сделал …"). Pure and conservative: the WHOLE transcript must be listed phrases
/// (credits only as the exact known strings), and the clip must be short and quiet.
public enum HallucinationGuard {
    public static let maxDurationS: Double = 8
    /// Owner decision 2026-10-26 (second review): near-silence alone never reaches the model (the capture gate drops it
    /// first), so the guard looks at clips that are mostly quiet: at most half the hold voiced (breath, room noise)…
    public static let maxVoicedFraction: Double = 0.5
    /// …and the voiced frames' mean RMS under this. Voiced frames start at 0.02; speech measured 0.04–0.25.
    /// 0.03 leaves a soft speaker's onsets and consonants room above it (fourth review 2026-10-26: 0.035 was too close).
    public static let quietVoicedRms: Double = 0.03

    /// Whole-utterance phrases, normalised (lower case, ' for apostrophes, no punctuation, е for ё). Only video outros:
    /// lines people dictate alone are left out ("thank you", "спасибо", "rahmat", "bye", "пока", "see you next time",
    /// "до новых встреч", "продолжение следует") and so are channel calls Telegram admins write as posts
    /// ("subscribe…", "подписывайтесь…", "ставьте лайки", "obuna bo'ling") (reviews 2026-10-26).
    static let phrases: [String] = [
        // EN
        "thanks for watching", "thank you for watching", "thank you so much for watching",
        "thanks for watching and see you next time",
        // RU
        "спасибо за просмотр", "спасибо за просмотр и до встречи",
        // UZ (Latin and Cyrillic)
        "tomosha qilganingiz uchun rahmat", "ko'rganingiz uchun rahmat",
        "томоша қилганингиз учун раҳмат",
        // Subtitle credits, only the exact strings the models are known to invent. A prefix plus "a name" matched real
        // sentences ("Субтитры подготовлены заранее", "Subtitrlar muallifi kim?"; reviews 2026-10-26).
        "subtitles by the amara org community", "субтитры подготовлены сообществом amara org",
        "субтитры сделал dimatorzok", "субтитры создавал dimatorzok",
        "редактор субтитров а синецкая корректор а егорова",
    ]

    private static let phraseWords: [[String]] = phrases.map { $0.split(separator: " ").map(String.init) }
        .sorted { $0.count > $1.count }

    static func normalisedWords(_ text: String) -> [String] {
        TextGuards.words(text).map { $0.replacingOccurrences(of: "ё", with: "е") }
    }

    /// The whole transcript is one or more listed phrases back to back.
    public static func isStockPhrase(_ text: String) -> Bool {
        let w = normalisedWords(text)
        guard !w.isEmpty else { return false }
        return chain(w[...])
    }

    private static func chain(_ w: ArraySlice<String>) -> Bool {
        if w.isEmpty { return true }
        for p in phraseWords where w.starts(with: p) && chain(w.dropFirst(p.count)) { return true }
        return false
    }

    /// Short (≤ 8 s) and mostly quiet (at most half voiced, and what is voiced is faint).
    public static func isQuietShortClip(_ c: ClipStats) -> Bool {
        c.durationS > 0 && c.durationS <= maxDurationS && c.voicedMs <= c.durationS * 1000 * maxVoicedFraction
            && c.voicedRms < quietVoicedRms
    }

    /// Perf test 2026-10-26: noise, tones, keyboard bumps and breath come back as "34", "1", "0", "_", ".". A reply
    /// of at most two tokens with no letter and no digit is junk only on a clip at most this much voiced (gate rule):
    /// bumps and breath measured 7–10 %, the owner's quietest real short dictation 17 %. Digits always paste (owner,
    /// review 2026-10-26): a dictated "5" in a 3 s hold is about 10 % voiced, the same as bumps, so "34" from bumps
    /// still pastes.
    public static let junkMaxVoicedFraction: Double = 0.15
    public static let junkMaxTokens = 2

    /// Only punctuation or symbols, 1–2 tokens: "_", ".", "—", "…". Any letter or digit in any script keeps the reply:
    /// numbers can be dictated, and lone real words ("Alo", "Да") can't be told apart from speech.
    public static func isSymbolOnlyJunk(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        return !tokens.isEmpty && tokens.count <= junkMaxTokens && !text.contains { $0.isLetter || $0.isNumber }
    }

    /// Short (≤ 8 s) and at most 15 % voiced by the capture gate's rule.
    public static func isMostlyUnvoicedShortClip(_ c: ClipStats) -> Bool {
        c.durationS > 0 && c.durationS <= maxDurationS && c.gateVoicedMs <= c.durationS * 1000 * junkMaxVoicedFraction
    }

    /// Drop the transcript instead of pasting it. `clip == nil` (History retry): never.
    public static func drops(_ text: String, clip: ClipStats?) -> Bool {
        reason(text, clip: clip) != nil
    }

    private static func reason(_ text: String, clip: ClipStats?) -> String? {
        guard let clip else { return nil }
        if isQuietShortClip(clip) && isStockPhrase(text) { return "dropped" }
        return isMostlyUnvoicedShortClip(clip) && isSymbolOnlyJunk(text) ? "junk" : nil
    }

    /// Pipeline hook: tags `provider_meta.hallucination_guard` ("dropped" for a stock phrase, "junk" for a
    /// symbol-only reply) and throws `StockPhraseDropped` / `ShortJunkDropped`.
    public static func check(_ text: String, clip: ClipStats?, meta: inout [String: String]?) throws {
        guard let why = reason(text, clip: clip) else { return }
        meta = (meta ?? [:]).merging(["hallucination_guard": why]) { _, b in b }
        if why == "junk" { throw ShortJunkDropped() }
        throw StockPhraseDropped()
    }
}
