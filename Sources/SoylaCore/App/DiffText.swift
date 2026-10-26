import SwiftUI

/// D26 (c) / BL-03: History's cleaned view with what cleanup changed marked. Removed words are struck through and
/// quiet (`Ink.text3`); added or changed words sit on `Ink.lazurWash`. Words that only changed case, punctuation or
/// apostrophe style are not marked (`WordDiff`).
enum DiffText {
    /// The correction pass really ran and was accepted: the run says `cleanup` = "ok" and nothing fell back. A Raw run
    /// or a fallback run can still have a different `cleanText` (fillers and the dictionary run at every level); that
    /// is not "cleaned". Rows from before the marker existed get no marks.
    static func accepted(_ r: RunRecord) -> Bool {
        r.providerMeta?["cleanup"] == "ok" && r.cleanupFallback == nil
    }

    /// The "Cleaned" tag of a History card.
    static func badge(_ r: RunRecord) -> Bool { accepted(r) && changed(raw: r.rawText, cleaned: r.cleanText) }

    static func styled(_ r: RunRecord) -> AttributedString? { accepted(r) ? styled(raw: r.rawText, cleaned: r.cleanText) : nil }

    /// Both texts present and the cleaned one differs: the row gets the "Cleaned" tag.
    static func changed(raw: String?, cleaned: String?) -> Bool {
        guard let raw, let cleaned, !raw.isEmpty, !cleaned.isEmpty else { return false }
        return raw != cleaned
    }

    /// nil when there is nothing to mark (same text, a text too long to compare, or only formatting changed).
    static func styled(raw: String?, cleaned: String?) -> AttributedString? {
        guard changed(raw: raw, cleaned: cleaned), let raw, let cleaned,
              let spans = WordDiff.spans(raw: raw, cleaned: cleaned), spans.contains(where: { $0.kind != .same }) else { return nil }
        return attributed(spans)
    }

    static func attributed(_ spans: [WordDiff.Span]) -> AttributedString {
        var out = AttributedString()
        for (i, span) in spans.enumerated() {
            out += AttributedString(i == 0 ? "" : span.gap)
            var piece = AttributedString(span.text)
            switch span.kind {
            case .same: break
            case .removed: piece.strikethroughStyle = .single; piece.foregroundColor = Ink.text3
            case .added: piece.backgroundColor = Ink.lazurWash
            }
            out += piece
        }
        return out
    }
}

/// History redraws a card often; the word diff is computed once per run and pair of texts (a changed text recomputes).
/// Past the diff's size cap the answer is nil too, and that is cached as well.
struct DiffCache {
    private var entries: [String: (raw: String, cleaned: String, value: AttributedString?)] = [:]
    /// How many diffs were really computed (a test reads it).
    private(set) var computed = 0

    mutating func styled(_ r: RunRecord) -> AttributedString? {
        guard DiffText.accepted(r), let raw = r.rawText, let cleaned = r.cleanText else { return nil }
        if let e = entries[r.runId], e.raw == raw, e.cleaned == cleaned { return e.value }
        if entries.count > 1000 { entries.removeAll() }
        computed += 1
        let value = DiffText.styled(raw: raw, cleaned: cleaned)
        entries[r.runId] = (raw, cleaned, value)
        return value
    }
}
