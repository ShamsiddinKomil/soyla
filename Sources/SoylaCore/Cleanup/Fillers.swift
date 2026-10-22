import Foundation

/// Deterministic removal of hesitation sounds from the pasted text, cleanup on or off, at no extra latency.
/// Only shapes that are never real words in Uzbek, Russian or English: a vowel or "m" repeated with hyphens
/// ("a-a", "М-м", "э-э-э"), the same letter held 3+ times ("ммм", "eee", "ааа"), and uh/um/hmm/хм.
/// A single "a"/"а"/"э" is a real word (conjunction, interjection) and stays; so do reduplications like
/// "asta-asta" or "tez tez".
public enum Fillers {
    private static let sound = "(?:([aeoumаэеоым])(?:-\\1)+|([aeoumаэеоымн])\\2{2,}|mm|мм|hmm+|хм+|uh+|um+|uhm|эм+)"
    private static let regex = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}'ʻʼ‘’-])\(sound)(?![\\p{L}\\p{N}'ʻʼ‘’-])[,.…]?",
        options: [.caseInsensitive])

    public static func strip(_ text: String) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for m in matches.reversed() {
            // A capitalised filler opened its sentence ("A-a вроде…"): the word after it now opens it.
            let opened = ns.substring(with: NSRange(location: m.range.location, length: 1)).first?.isUppercase == true
            out.replaceCharacters(in: m.range, with: opened ? "\u{1}" : "")
        }
        var r = out as String
        // Tidy what removal leaves: doubled spaces, a space before punctuation, a comma left at a sentence start.
        let tidy: [(String, String)] = [
            ("[ \\t]{2,}", " "), (" +([,.!?;:…])", "$1"), (",\\s*,", ","),
            ("(^|[.!?…]\\s+)(?:\u{1}\\s*,?|,)\\s*\u{1}?", "$1\u{1}"), ("^\\s+|\\s+$", ""),
        ]
        for (p, t) in tidy { r = r.replacingOccurrences(of: p, with: t, options: .regularExpression) }
        // Upper-case the first letter after a marker that sits at a sentence start, then drop the markers.
        var final = "", up = false
        for ch in r {
            if ch == "\u{1}" {
                let last = final.last(where: { !$0.isWhitespace })
                up = last == nil || ".!?…".contains(last!)
                continue
            }
            if up, ch.isLetter { final += String(ch).uppercased(); up = false; continue }
            if up, !ch.isWhitespace { up = false }
            final.append(ch)
        }
        return final.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
