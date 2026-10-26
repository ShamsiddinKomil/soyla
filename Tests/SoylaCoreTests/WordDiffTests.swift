import Testing
import Foundation
@testable import SoylaCore

// D26 (c) / BL-03: the History diff of what cleanup changed. Word level; case, punctuation and apostrophe style
// are formatting, not changes.

@Suite struct WordDiffTests {
    typealias S = WordDiff.Span
    private func diff(_ raw: String, _ cleaned: String) -> [S] { WordDiff.spans(raw: raw, cleaned: cleaned) ?? [] }

    @Test func insertedWordIsAdded() {
        #expect(diff("I went home", "I went back home")
                == [S(.same, "I went"), S(.added, "back"), S(.same, "home")])
    }

    @Test func deletedWordIsRemoved() {
        #expect(diff("I went really home", "I went home")
                == [S(.same, "I went"), S(.removed, "really"), S(.same, "home")])
    }

    @Test func changedWordIsRemovedThenAdded() {
        #expect(diff("meet at three", "meet at four")
                == [S(.same, "meet at"), S(.removed, "three"), S(.added, "four")])
    }

    @Test func twoEditsAndATrailingDelete() {
        #expect(diff("a b c d", "a x c")
                == [S(.same, "a"), S(.removed, "b"), S(.added, "x"), S(.same, "c"), S(.removed, "d")])
    }

    @Test func cyrillicFillerRemovedAndCapitalised() {
        #expect(diff("ну я пошёл домой", "Я пошёл домой.") == [S(.removed, "ну"), S(.same, "Я пошёл домой.")])
        #expect(diff("в пятницу нет суббота", "Суббота")
                == [S(.removed, "в пятницу нет"), S(.same, "Суббота")])
    }

    @Test func apostropheStyleIsNotAChange() {
        // Latin Uzbek: ASCII ' vs ‘ vs ʻ are the same word. The cleaned spelling is the one shown.
        #expect(diff("o'zbek tilida gapiraman", "o\u{2018}zbek tilida gapiraman")
                == [S(.same, "o\u{2018}zbek tilida gapiraman")])
        #expect(diff("go\u{02BB}zal kun", "go'zal kun") == [S(.same, "go'zal kun")])
    }

    @Test func caseAndPunctuationAreNotChanges() {
        #expect(diff("salom dunyo", "Salom, dunyo.") == [S(.same, "Salom, dunyo.")])
    }

    @Test func identicalAndEmptyInputs() {
        #expect(diff("one two", "one two") == [S(.same, "one two")])
        #expect(diff("", "one two") == [S(.added, "one two")])
        #expect(diff("one two", "") == [S(.removed, "one two")])
        #expect(diff("", "").isEmpty)
        #expect(diff("  \n ", "one") == [S(.added, "one")])
    }

    @Test func keptSpansRebuildTheCleanedText() {
        let pairs = [("ee men ertaga soat uchda yo'q to'rtda boraman", "Men ertaga soat to'rtda boraman."),
                     ("uh I think it works", "I think it works."), ("a b c", "c b a")]
        for (raw, cleaned) in pairs {
            let kept = diff(raw, cleaned).filter { $0.kind != .removed }.map(\.text).joined(separator: " ")
            #expect(kept == cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " "))
            let old = diff(raw, cleaned).filter { $0.kind != .added }.map(\.text).joined(separator: " ")
            #expect(TextGuards.words(old) == TextGuards.words(raw))      // nothing of the original is lost either
        }
    }

    @Test func aHugeTextGivesNoDiffInsteadOfAStall() {
        let a = Array(repeating: "alpha", count: 2100).joined(separator: " ")
        let b = Array(repeating: "beta", count: 2100).joined(separator: " ")
        #expect(WordDiff.spans(raw: a, cleaned: b) == nil)
        // The cap is small enough to be cheap on the main thread (500 × 500 words); a 3-minute dictation still diffs.
        let long = (0..<450).map { "w\($0)" }.joined(separator: " ")
        #expect(WordDiff.spans(raw: long, cleaned: long) == [S(.same, long)])
        let tooLong = (0..<600).map { "w\($0)" }.joined(separator: " ")
        #expect(WordDiff.spans(raw: tooLong, cleaned: tooLong) == nil)
    }

    @Test func historyMarksOnlyRealChanges() {
        #expect(DiffText.styled(raw: "same words", cleaned: "same words") == nil)
        #expect(DiffText.styled(raw: "salom dunyo", cleaned: "Salom, dunyo.") == nil)          // formatting only
        #expect(!DiffText.changed(raw: nil, cleaned: "x") && !DiffText.changed(raw: "x", cleaned: ""))
        #expect(DiffText.changed(raw: "salom dunyo", cleaned: "Salom, dunyo."))                 // the tag still shows
        let marked = DiffText.styled(raw: "I went really home", cleaned: "I went home")
        #expect(marked.map { String($0.characters) } == "I went really home")                  // removed words stay visible
    }

    // MARK: whitespace of the cleaned text survives

    @Test func lineBreaksAndParagraphsStay() {
        let cleaned = "First line.\n\nSecond   line,\nthird."
        let marked = DiffText.styled(raw: "first line uh second line third", cleaned: cleaned)
        // Cleaned text in order, the removed word where it was, every break exactly as in the cleaned text.
        #expect(marked.map { String($0.characters) } == "First line. uh\n\nSecond   line,\nthird.")
        let kept = DiffText.attributed(WordDiff.spans(raw: "a b c", cleaned: "a x\nb\n\nc") ?? [])
        #expect(String(kept.characters) == "a x\nb\n\nc")
    }

    @Test func aMultiLineTextWithNoChangeIsNotMarked() {
        #expect(DiffText.styled(raw: "one two three", cleaned: "One two,\nthree.") == nil)
    }

    // MARK: only an accepted correction is marked

    private func record(raw: String?, clean: String?, cleanup: String?, fallback: String? = nil) -> RunRecord {
        var r = RunRecord(runId: "r1", ts: "2026-10-26T10:00:00.000Z", source: "live", phraseId: nil, model: "fake", cleanup: true,
                          cleanupModel: nil, languageHint: nil, prewarm: false,
                          audio: .init(format: "flac", bytes: 1, b64Bytes: 2, durationSec: 1, sampleRate: 16000, file: nil),
                          timelineMs: [:], net: nil, usage: nil, cleanupUsage: nil, rawText: raw, cleanText: clean, error: nil,
                          providerMeta: cleanup.map { ["cleanup": $0] }, status: .ok)
        r.cleanupFallback = fallback
        return r
    }

    @Test func aRawRunWithADictionaryHitIsNotCleaned() {
        // Raw level: the dictionary rewrote a word, so cleanText differs, but no correction ran.
        let r = record(raw: "send it to Soila now", clean: "send it to Soyla now", cleanup: "off")
        #expect(!DiffText.accepted(r) && DiffText.badge(r) == false && DiffText.styled(r) == nil)
    }

    @Test func aFallbackRunIsNotCleaned() {
        let r = record(raw: "one two um three", clean: "one two three", cleanup: "guard", fallback: "ratio_low")
        #expect(!DiffText.accepted(r) && !DiffText.badge(r) && DiffText.styled(r) == nil)
        let old = record(raw: "one two", clean: "one", cleanup: nil)                          // a row with no marker
        #expect(!DiffText.accepted(old))
    }

    @Test func anAcceptedCorrectionIsMarked() {
        let r = record(raw: "ee I went really home", clean: "I went home.", cleanup: "ok")
        #expect(DiffText.accepted(r) && DiffText.badge(r) && DiffText.styled(r) != nil)
        #expect(!DiffText.badge(record(raw: "same", clean: nil, cleanup: "ok")))              // nothing changed
    }

    // MARK: the cache

    @Test func theDiffIsComputedOncePerRunAndText() {
        var cache = DiffCache()
        let r = record(raw: "ee I went really home", clean: "I went home.", cleanup: "ok")
        #expect(cache.styled(r) != nil && cache.computed == 1)
        _ = cache.styled(r); _ = cache.styled(r)
        #expect(cache.computed == 1)                                                          // redraws reuse it
        var edited = r; edited.cleanText = "I went there."
        #expect(cache.styled(edited) != nil && cache.computed == 2)                           // a changed text recomputes
        #expect(cache.styled(record(raw: "a", clean: "a", cleanup: "off")) == nil && cache.computed == 2)   // not accepted: no work
    }
}
