import Foundation

/// D26 (c) / BL-03: what cleanup changed, word by word, for the History card. Pure; no UI.
///
/// Words are compared by `TextGuards.words` (lower-case, apostrophe styles unified, punctuation dropped), so a capital,
/// a comma or `o'` against `o‘` is formatting, not a change. A changed word comes out as `removed` then `added`.
/// Kept (`same`) words show the cleaned spelling.
public enum WordDiff {
    public enum Kind: Sendable, Equatable { case same, added, removed }

    public struct Span: Sendable, Equatable {
        public var kind: Kind
        /// Words of the span with the whitespace that sat between them (the cleaned text's for kept and added words).
        public var text: String
        /// The whitespace that goes before this span when the spans are laid out again: a line break or paragraph of
        /// the cleaned text is kept. "" for the first span. Not part of equality.
        public var gap: String
        public init(_ kind: Kind, _ text: String, gap: String = " ") { self.kind = kind; self.text = text; self.gap = gap }
        public static func == (a: Span, b: Span) -> Bool { a.kind == b.kind && a.text == b.text }
    }

    /// Above this many table cells (words × words) there is no diff: 500 × 500 words (about 3.5 minutes) is cheap on the main thread; beyond it the card shows no marks.
    static let maxCells = 250_000

    /// Runs of equal kind merged, in reading order. nil when the texts are too long to compare.
    public static func spans(raw: String, cleaned: String) -> [Span]? {
        let a = tokens(raw), b = tokens(cleaned)
        guard a.count * b.count <= maxCells else { return nil }
        let w = b.count + 1
        // lcs[i * w + j] = length of the longest common run of a[i...] and b[j...].
        var lcs = [Int32](repeating: 0, count: (a.count + 1) * w)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i * w + j] = a[i].key == b[j].key ? lcs[(i + 1) * w + j + 1] + 1 : max(lcs[(i + 1) * w + j], lcs[i * w + j + 1])
            }
        }
        var out: [Span] = []
        // `sep` is the whitespace before the word in its own text; a new span starts after the cleaned text's break.
        func add(_ kind: Kind, _ t: Token) {
            if let last = out.last, last.kind == kind { out[out.count - 1].text += t.sep + t.shown; return }
            let gap = out.isEmpty ? "" : (kind == .removed ? " " : t.sep)
            out.append(Span(kind, t.shown, gap: gap))
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i].key == b[j].key {
                add(.same, b[j]); i += 1; j += 1
            } else if j >= b.count || (i < a.count && lcs[(i + 1) * w + j] >= lcs[i * w + j + 1]) {
                add(.removed, a[i]); i += 1
            } else {
                add(.added, b[j]); j += 1
            }
        }
        return out
    }

    private struct Token { var shown: String; var key: String; var sep: String }

    /// Words with the whitespace before each ("" for the first).
    private static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        var word = "", sep = "", pending = ""
        func flush() {
            guard !word.isEmpty else { return }
            let key = TextGuards.words(word).joined()
            out.append(Token(shown: word, key: key.isEmpty ? word : key, sep: out.isEmpty ? "" : sep))
            word = ""
        }
        for ch in s {
            if ch.isWhitespace {
                if !word.isEmpty { flush(); pending = "" }
                pending.append(ch)
            } else {
                if word.isEmpty { sep = pending }
                word.append(ch)
            }
        }
        flush()
        return out
    }
}
