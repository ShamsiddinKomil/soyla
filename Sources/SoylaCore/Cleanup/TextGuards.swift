import Foundation

/// Why a cleanup result was thrown away (the raw transcript is pasted instead). Raw values go to
/// `provider_meta.cleanup_guard`.
public enum CleanupGuard: String, Sendable, Equatable, CaseIterable {
    case empty            // the model returned nothing
    case ratioHigh = "ratio_high"     // output > 1.6× input (inputs ≥ 5 words): it added text
    case ratioLow = "ratio_low"       // output < 0.4× input (inputs ≥ 5 words): it dropped text
    case answer           // it answered / replied to the text instead of cleaning it
    case script           // foreign script or Uzbek in Cyrillic, still wrong after one retry
    case scriptShift = "script_shift" // Latin↔Cyrillic balance moved: translated or transliterated
    case truncated        // finish_reason length / MAX_TOKENS
    case filtered         // finish_reason content_filter / SAFETY / blocked
    case timeout
    case rateLimited = "rate_limited" // HTTP 429 (starts the 60 s provider cooldown)
}

/// A script problem in a transcript (Korean for Uzbek, Uzbek in Cyrillic…).
public enum ScriptIssue: Sendable, Equatable {
    /// Hangul / CJK / kana / Arabic / Thai letters in a uz/ru/en session. Associated value: script name.
    case foreignScript(String)
    /// Uzbek words written in Cyrillic (Uzbek must be Latin).
    case uzbekCyrillic

    /// Short tag for `provider_meta`.
    public var tag: String {
        switch self {
        case .foreignScript(let s): return "foreign:" + s
        case .uzbekCyrillic: return "uzbek_cyrillic"
        }
    }
}

/// Pure text checks used around the STT and cleanup calls. No I/O, no state: everything here is unit-tested.
public enum TextGuards {
    // MARK: normalisation

    /// Every apostrophe-like character Uzbek Latin text shows up with: ʻ (U+02BB, official o'/g'), ʼ (U+02BC),
    /// ' ' (U+2018/2019), ` and ´. Matching always happens on the normalised form.
    public static let apostrophes: Set<Character> = ["'", "\u{02BB}", "\u{02BC}", "\u{2018}", "\u{2019}", "`", "\u{00B4}"]

    /// ʻ ʼ ' ' ` ´ → '
    public static func normalizeApostrophes(_ s: String) -> String {
        String(s.map { apostrophes.contains($0) ? "'" : $0 })
    }

    /// Lower-cased words (letters, digits, inner apostrophes), apostrophes normalised. Punctuation is dropped.
    public static func words(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in normalizeApostrophes(s).lowercased() {
            if ch.isLetter || ch.isNumber || (ch == "'" && !cur.isEmpty) {
                cur.append(ch)
            } else if !cur.isEmpty {
                out.append(trimApostrophes(cur)); cur = ""
            }
        }
        if !cur.isEmpty { out.append(trimApostrophes(cur)) }
        return out.filter { !$0.isEmpty }
    }

    private static func trimApostrophes(_ w: String) -> String {
        var w = w
        while w.hasSuffix("'") { w.removeLast() }
        return w
    }

    public static func wordCount(_ s: String) -> Int { words(s).count }

    // MARK: skip rule

    /// Spoken punctuation / layout words (uz, ru, en). Multi-word ones are matched as phrases.
    public static let punctuationWords: [String] = [
        "nuqta", "vergul", "savol belgisi", "undov belgisi", "yangi qator", "yangi xatboshi", "ikki nuqta",
        "точка", "запятая", "вопросительный знак", "восклицательный знак", "новая строка", "с новой строки", "двоеточие",
        "period", "full stop", "comma", "question mark", "exclamation mark", "new line", "new paragraph", "colon",
    ]

    /// Self-correction cues (uz, ru, en). In a 2–4 word dictation they still need the model ("dushanba, yo'q, seshanba").
    public static let correctionCues: [String] = [
        "yo'q", "aniqrog'i", "to'g'rirog'i", "yo'q yo'q",
        "нет", "то есть", "вернее", "точнее", "в смысле",
        "no", "scratch that", "i mean", "no wait", "wait no", "sorry",
    ]

    /// True when `phrase` (one or more words) occurs as whole words in `ws`.
    static func containsPhrase(_ ws: [String], _ phrase: String) -> Bool {
        let p = words(phrase)
        guard !p.isEmpty, ws.count >= p.count else { return false }
        for i in 0...(ws.count - p.count) where Array(ws[i..<(i + p.count)]) == p { return true }
        return false
    }

    /// Skip the LLM for ≤ 4 words with no digits, spoken-punctuation words or (for 2+ words) self-correction cues.
    /// Short utterances are where a chat model most often answers instead of cleaning, and the saving is ~1–2 s.
    public static func shouldSkipCleanup(_ text: String) -> Bool {
        let ws = words(text)
        if ws.count > 4 { return false }
        if text.contains(where: { $0.isNumber }) { return false }
        if punctuationWords.contains(where: { containsPhrase(ws, $0) }) { return false }
        if ws.count >= 2, correctionCues.contains(where: { containsPhrase(ws, $0) }) { return false }
        return true
    }

    // MARK: cleanup output guards

    /// Strips a JSON envelope (`{"transcript": "…"}`), code fences or wrapping quotes the model may echo back.
    public static func unwrapEnvelope(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if t.hasPrefix("{"), t.hasSuffix("}"),
           let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any] {
            for k in ["transcript", "text", "cleaned", "output"] {
                if let v = obj[k] as? String { return v.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        return t
    }

    /// Length guard on characters (trimmed). Only for inputs of 5+ words: short ones legitimately shrink a lot.
    public static func lengthGuard(input: String, output: String) -> CleanupGuard? {
        guard wordCount(input) >= 5 else { return nil }
        let i = Double(input.trimmingCharacters(in: .whitespacesAndNewlines).count)
        let o = Double(output.trimmingCharacters(in: .whitespacesAndNewlines).count)
        guard i > 0 else { return nil }
        if o / i > 1.6 { return .ratioHigh }
        if o / i < 0.4 { return .ratioLow }
        return nil
    }

    /// Chat-assistant openers. Only counted when the input did not start the same way.
    public static let answerPreambles: [String] = [
        "sure", "certainly", "of course", "here is", "here's", "here are", "i'm sorry", "i am sorry", "as an ai",
        "i can't", "i cannot", "the answer is", "great question",
        "конечно", "вот ", "извините", "к сожалению", "ответ:", "я не могу",
        "albatta", "mana ", "kechirasiz", "javob:",
    ]

    /// Question openers (en/ru/uz). A question that comes back without a "?" was probably answered.
    public static let questionWords: Set<String> = [
        "what", "who", "why", "how", "where", "when", "which", "is", "are", "can", "could", "do", "does", "did", "will", "would", "should",
        "что", "кто", "почему", "зачем", "как", "где", "когда", "какой", "какая", "какие", "сколько", "куда", "откуда", "разве",
        "nima", "kim", "nega", "nimaga", "qachon", "qayer", "qayerda", "qanday", "qaysi", "necha", "qancha", "nimani",
    ]

    /// Heuristics for "the model replied to the text": an assistant preamble, a question returned as a statement
    /// with any new word, a "?" that disappeared, or many words that were never said. Any doubt → paste raw.
    public static func looksLikeAnswer(input: String, output: String) -> Bool {
        let inW = words(input), outW = words(output)
        guard !outW.isEmpty else { return false }
        let inLower = normalizeApostrophes(input).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let outLower = normalizeApostrophes(output).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for p in answerPreambles where outLower.hasPrefix(p) && !inLower.hasPrefix(p) { return true }

        let inSet = Set(inW)
        // Digits are allowed to be new ("uch" → "3"); everything else should have been said.
        let novel = outW.filter { !inSet.contains($0) && !$0.allSatisfy(\.isNumber) }
        let isQuestion = input.contains("?") || input.contains("¿") || (inW.first.map { questionWords.contains($0) } ?? false)
        if isQuestion, !output.contains("?"), !novel.isEmpty { return true }   // "…France" → "…is Paris."
        if input.contains("?"), !output.contains("?") { return true }
        if novel.count >= 3, Double(novel.count) / Double(outW.count) > 0.4 { return true }
        return false
    }

    /// Letter counts per script family.
    public struct ScriptProfile: Equatable, Sendable {
        public var latin = 0, cyrillic = 0, foreign = 0
        public var foreignName: String? = nil
        public var letters: Int { latin + cyrillic + foreign }
        public var cyrillicShare: Double { letters == 0 ? 0 : Double(cyrillic) / Double(letters) }
    }

    static func scriptName(_ v: UInt32) -> String? {
        switch v {
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF: return "hangul"
        case 0x3040...0x30FF, 0x31F0...0x31FF: return "kana"
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return "cjk"
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return "arabic"
        case 0x0E00...0x0E7F: return "thai"
        default: return nil
        }
    }

    public static func scriptProfile(_ s: String) -> ScriptProfile {
        var p = ScriptProfile()
        for u in s.unicodeScalars {
            let v = u.value
            if let name = scriptName(v) {
                p.foreign += 1
                if p.foreignName == nil { p.foreignName = name }
            } else if u.properties.isAlphabetic {
                if (0x0400...0x052F).contains(v) { p.cyrillic += 1 }
                else if v < 0x0250 || (0x1E00...0x1EFF).contains(v) { p.latin += 1 }
            }
        }
        return p
    }

    /// Drops every word that contains a foreign-script letter (Hangul, CJK, Arabic, Thai…). Returns nil when that
    /// would be more than `maxShare` of the letters or leave under 20 letters: then it was not a stray, it was wrong.
    public static func stripForeignWords(_ text: String, maxShare: Double = 0.05) -> String? {
        let p = scriptProfile(text)
        guard p.foreign > 0, Double(p.foreign) <= Double(p.letters) * maxShare, p.latin + p.cyrillic >= 20 else { return nil }
        let kept = text.split(separator: " ", omittingEmptySubsequences: true)
            .filter { w in !w.unicodeScalars.contains { scriptName($0.value) != nil } }
        return kept.joined(separator: " ")
    }

    /// Letters that exist in Uzbek (and Kazakh) Cyrillic but never in Russian.
    static let uzbekCyrillicLetters: Set<Character> = ["ў", "қ", "ғ", "ҳ", "Ў", "Қ", "Ғ", "Ҳ"]
    /// Frequent Uzbek words as they look in Cyrillic, chosen so none is a Russian word.
    static let uzbekCyrillicWords: Set<String> = [
        "ва", "бу", "мен", "сен", "биз", "сиз", "улар", "учун", "билан", "керак", "эмас", "лекин", "жуда", "яхши",
        "нима", "энди", "бугун", "эртага", "кейин", "ҳам", "йўқ", "бор", "қилиш", "бўлади", "менга", "сизга", "қандай",
        "ҳозир", "айтинг", "килдим", "киламан", "булади", "бизнинг", "менинг", "шу", "мана", "кўп", "ўзбек",
    ]

    /// `languageHint` nil/uz/ru/en (also "uz-UZ" etc.) = a uz/ru/en session. Other hints (ko, zh…) skip the
    /// foreign-script check but Uzbek must still be Latin.
    public static func isUzRuEnSession(_ languageHint: String?) -> Bool {
        guard let l = languageHint?.lowercased(), !l.isEmpty, l != "auto" else { return true }
        return ["uz", "ru", "en"].contains(where: { l.hasPrefix($0) })
    }

    /// Script check after STT and after cleanup. `uzbekLatin`: the session's Uzbek is Latin (always, today).
    public static func scriptIssue(_ text: String, languageHint: String? = nil, uzbekLatin: Bool = true) -> ScriptIssue? {
        if isUzRuEnSession(languageHint) {
            let p = scriptProfile(text)
            if p.foreign > 0 { return .foreignScript(p.foreignName ?? "other") }
        }
        guard uzbekLatin else { return nil }
        if text.contains(where: { uzbekCyrillicLetters.contains($0) }) { return .uzbekCyrillic }
        let hits = words(text).filter { uzbekCyrillicWords.contains($0) }.count
        return hits >= 2 ? .uzbekCyrillic : nil
    }

    /// Cleanup moved the Latin/Cyrillic balance by more than 20 points (needs ≥ 10 letters on both sides):
    /// something was translated or transliterated.
    public static func scriptShift(input: String, output: String) -> Bool {
        let a = scriptProfile(input), b = scriptProfile(output)
        guard a.letters >= 10, b.letters >= 10 else { return false }
        return abs(a.cyrillicShare - b.cyrillicShare) > 0.2
    }

    /// All output checks except the script retry, in order. nil = the cleaned text may be pasted.
    public static func checkCleanup(input: String, output: String) -> CleanupGuard? {
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if let g = lengthGuard(input: input, output: output) { return g }
        if looksLikeAnswer(input: input, output: output) { return .answer }
        if scriptShift(input: input, output: output) { return .scriptShift }
        return nil
    }

    // MARK: timestamps

    /// `00:07`, `[0:07]`, `(01:02:03)` plus a trailing dash or colon. Group 1-3 = the numbers.
    private static let timestampPattern = try? NSRegularExpression(
        pattern: #"[\[(]?\b(\d{1,2}):(\d{2})(?::(\d{2}))?\b[\])]?[ \t]*[-–—:]?[ \t]*"#)

    /// Gemini sometimes subtitles long clips ("00:01 salom 00:07 …", 2026-10-16: 26 in one 45 s run).
    /// Removes them only when they look like audio positions, so a dictated "14:30" stays:
    /// two or more, in order, none past the end of the audio; or a single one at the very start.
    /// Returns the cleaned text and how many were removed (0 = text unchanged).
    public static func stripTimestamps(_ text: String, durationSec: Double) -> (text: String, removed: Int) {
        guard let timestampPattern else { return (text, 0) }
        let ns = text as NSString
        let matches = timestampPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (text, 0) }
        func seconds(_ m: NSTextCheckingResult) -> Int? {
            let parts = (1...3).compactMap { i -> Int? in
                let r = m.range(at: i); return r.location == NSNotFound ? nil : Int(ns.substring(with: r))
            }
            guard parts.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
        let secs = matches.compactMap(seconds)
        guard secs.count == matches.count else { return (text, 0) }
        let limit = Int(durationSec.rounded(.up)) + 5
        let inAudio = secs.allSatisfy { $0 <= limit }
        let ordered = zip(secs, secs.dropFirst()).allSatisfy { $0 <= $1 }
        let leadingOnly = matches.count == 1
            && ns.substring(to: matches[0].range.location).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard inAudio, (matches.count >= 2 && ordered) || leadingOnly else { return (text, 0) }
        var out = timestampPattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length),
                                                            withTemplate: " ")
        out = out.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #" +([,.!?;])"#, with: "$1", options: .regularExpression)
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), matches.count)
    }

    // MARK: request sizing

    /// Rough token estimate that over-counts for Latin and fits Cyrillic (~2.5 chars per token).
    public static func estimateTokens(_ s: String) -> Int { max(1, Int((Double(s.count) / 2.5).rounded(.up))) }

    /// `max_tokens` ≈ 1.5× the input, plus headroom when the model spends tokens on (minimal) reasoning.
    /// Floor 64, cap 4096. A response that hits it comes back with finish_reason "length" → guard → raw.
    public static func maxTokens(for input: String, reasoningHeadroom: Int = 0) -> Int {
        min(4096, max(64, Int((Double(estimateTokens(input)) * 1.5).rounded(.up))) + reasoningHeadroom)
    }
}
