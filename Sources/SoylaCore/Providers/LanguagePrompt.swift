import Foundation

/// D26(b) · BL-04: the prompt lines for the speaker's language set, shared by the OpenRouter chat route and Google AI
/// Studio (through `OpenRouterSTTProvider.transcriptionPrompt`). No set (CLI, replay, old callers) → no lines.
public enum LanguagePrompt {
    /// Below this, auto-detect guesses wrong most (Korean-for-Uzbek, Russian-for-English on 1–3 s clips).
    public static let shortClipSec = 2.0

    static let names = ["uz": "Uzbek", "ru": "Russian", "en": "English"]

    /// The script rule as native speakers put it, one clause per language in the set (fixed order ru · en · uz).
    static let scriptClauses: [(code: String, text: String)] = [
        ("ru", "Russian in Cyrillic"), ("en", "English words stay in Latin letters"), ("uz", "Uzbek in Latin script"),
    ]

    /// "The speaker may use only these languages: …", the script rule, and for clips under 2 s "If unsure, …".
    public static func lines(languages: [String], durationSec: Double?) -> [String] {
        let set = LanguageSet.all.filter { Set(languages.map { $0.lowercased() }).contains($0) }
        guard !set.isEmpty else { return [] }
        var out = ["The speaker may use only these languages: " + set.compactMap { names[$0] }.joined(separator: ", ") + "."]
        let rule = scriptClauses.filter { set.contains($0.code) }.map(\.text).joined(separator: "; ")
        out.append(rule + ". Never translate, never transliterate.")
        if let d = durationSec, d < shortClipSec { out.append("If unsure, choose among these languages only.") }
        return out
    }

    /// Added to F3's single script retry when the set is not the default: names the set, and forbids Cyrillic when
    /// Russian is not in it.
    public static func retryLine(_ languages: [String]) -> String? {
        guard !languages.isEmpty, !LanguageSet.isDefault(languages) else { return nil }
        let set = LanguageSet.sanitize(languages)
        let line = "The speaker uses only " + set.compactMap { names[$0] }.joined(separator: ", ") + "."
        return set.contains("ru") ? line : line + " Write no Cyrillic letters."
    }
}
