import Foundation

/// One user replacement: every whole-word `from` (case-insensitive, any apostrophe variant) becomes `to`.
/// Use case: Uzbek names with Latin/Cyrillic variants ("Шамсиддин" → "Shamsiddin", "Soila" → "Soyla").
public struct DictionaryEntry: Codable, Sendable, Equatable, Hashable {
    public var from: String
    public var to: String
    public init(from: String, to: String) { self.from = from; self.to = to }
}

/// Deterministic word-boundary replacements, applied to the text that gets pasted whether cleanup is on or off.
/// Not called `Dictionary` (that would shadow Swift.Dictionary inside the module).
///
/// Matching: apostrophes are normalised on both sides (ʻ ʼ ' ' ` ´ all match each other), case-insensitive,
/// whole words only (`(?<!\w)…(?!\w)` where \w includes letters of every script and an apostrophe *inside* a word,
/// so "o" never matches in "o'g'il"). One pass, longest entry first, so A→B, B→C never chains.
public struct ReplacementDictionary: Sendable {
    public static let maxEntries = 50
    public let entries: [DictionaryEntry]
    private let regex: NSRegularExpression?
    private let lookup: [String: String]

    /// Keeps the first `maxEntries` usable entries (non-empty `from`, `from` ≠ `to`); later duplicates are ignored.
    public init(_ raw: [DictionaryEntry]) {
        var seen = Set<String>(), kept: [DictionaryEntry] = []
        for e in raw {
            let f = e.from.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Self.key(f)
            guard !f.isEmpty, f != e.to, !seen.contains(key) else { continue }
            seen.insert(key); kept.append(DictionaryEntry(from: f, to: e.to))
            if kept.count == Self.maxEntries { break }
        }
        entries = kept
        lookup = Dictionary(kept.map { (Self.key($0.from), $0.to) }, uniquingKeysWith: { a, _ in a })
        guard !kept.isEmpty else { regex = nil; return }
        let alts = kept.map(\.from).sorted { $0.count > $1.count }.map(Self.pattern).joined(separator: "|")
        let ap = Self.apostropheClass
        let pattern = "(?<![\\p{L}\\p{N}\\p{M}_])(?<!\\p{L}\(ap))(?:\(alts))(?![\\p{L}\\p{N}\\p{M}_])(?!\(ap)\\p{L})"
        regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static let apostropheClass = "['\u{02BB}\u{02BC}\u{2018}\u{2019}`\u{00B4}]"

    /// Lookup key: apostrophes normalised, lower-cased, whitespace runs collapsed.
    static func key(_ s: String) -> String {
        TextGuards.normalizeApostrophes(s).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Regex for one `from`: literal, but any apostrophe matches any apostrophe and runs of spaces match \s+.
    static func pattern(_ from: String) -> String {
        var out = ""
        var lastWasSpace = false
        for ch in from {
            if TextGuards.apostrophes.contains(ch) { out += apostropheClass; lastWasSpace = false }
            else if ch.isWhitespace { if !lastWasSpace { out += "\\s+" }; lastWasSpace = true }
            else { out += NSRegularExpression.escapedPattern(for: String(ch)); lastWasSpace = false }
        }
        return out
    }

    /// Replaced text and how many replacements were made.
    public func apply(_ text: String) -> (text: String, hits: Int) {
        guard let regex, !text.isEmpty else { return (text, 0) }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (text, 0) }
        var out = "", last = 0, hits = 0
        for m in matches {
            guard let to = lookup[Self.key(ns.substring(with: m.range))] else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + to
            last = m.range.location + m.range.length
            hits += 1
        }
        out += ns.substring(from: last)
        return (out, hits)
    }
}
