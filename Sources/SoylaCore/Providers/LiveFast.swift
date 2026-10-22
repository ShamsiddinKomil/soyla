import Foundation
import os

/// How much a Live session's text looks like the language that session is locked to.
/// A session locked to the wrong language still produces words, but they fail these checks.
public enum LanguageScore {
    /// Frequent Uzbek words (Latin) that a Russian or English session would not produce.
    static let uzbekWords: Set<String> = [
        "va", "bu", "men", "sen", "biz", "siz", "ular", "uchun", "bilan", "kerak", "emas", "lekin", "juda", "yaxshi",
        "nima", "endi", "bugun", "ertaga", "keyin", "ham", "yo'q", "bor", "qilish", "bo'ladi", "menga", "sizga",
        "qanday", "hozir", "ayting", "qildim", "qilaman", "bizning", "mening", "shu", "mana", "ko'p", "o'zbek", "agar",
        "chunki", "hammasi", "qanaqa", "yana", "faqat", "deb", "edi", "ekan", "bo'lsa", "qiling", "qilamiz", "kecha",
    ]
    /// Uzbek suffixes on Latin words (also on English stems: "tasklarini").
    static let uzbekEndings = ["lar", "larni", "larini", "ni", "ning", "da", "dan", "ga", "imiz", "ingiz", "yapman",
                               "yapmiz", "dim", "dik", "miz", "sizmi", "ishi", "ishni", "moqda", "gan", "adi"]
    static let englishWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "is", "are", "was", "were", "be", "been", "i", "you", "he", "she", "it",
        "we", "they", "this", "that", "these", "those", "to", "of", "in", "on", "for", "with", "as", "at", "by", "from",
        "not", "no", "yes", "do", "does", "did", "have", "has", "had", "will", "would", "can", "could", "should", "my",
        "your", "our", "their", "what", "why", "how", "when", "where", "who", "which", "if", "so", "then", "there",
        "here", "now", "just", "also", "very", "really", "about", "all", "some", "more", "like", "want", "need", "make",
        "get", "go", "see", "know", "think", "use", "new", "first", "last", "one", "two", "it's", "i'm", "don't",
        "let's", "please", "thanks", "okay", "right", "because", "into", "out", "up", "down", "after", "before",
    ]

    static func isUzbekLike(_ w: String) -> Bool {
        w.contains("o'") || w.contains("g'") || uzbekWords.contains(w) || uzbekEndings.contains { w.count > $0.count + 2 && w.hasSuffix($0) }
    }

    /// Weighted count of words that fit `code` ("uz-UZ" | "ru-RU" | "en-US"). Loanwords count a little.
    public static func score(_ text: String, code: String) -> Double {
        let words = TextGuards.words(text)
        var s = 0.0
        for w in words {
            let cyr = w.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) }
            let uzCyr = w.contains { TextGuards.uzbekCyrillicLetters.contains($0) } || TextGuards.uzbekCyrillicWords.contains(w)
            switch code {
            case "ru-RU": if cyr, !uzCyr { s += 1 }
            case "uz-UZ": if !cyr { s += isUzbekLike(w) ? 1 : englishWords.contains(w) ? 0.2 : 0.5 }
            // Only real common English words count: an English session mishearing Uzbek still writes Latin words
            // (2026-10-17: Auto locked onto English on 4 Uzbek clips when every Latin word scored 0.3).
            case "en-US": if !cyr, englishWords.contains(w) { s += 1 }
            default: break
            }
        }
        return s
    }

    /// The language to lock to: a score of at least 3 and at least twice the runner-up's. nil = keep listening.
    public static func leader(_ scores: [String: Double]) -> String? {
        let ranked = scores.sorted { $0.value > $1.value }
        guard let top = ranked.first, top.value >= 3 else { return nil }
        let second = ranked.dropFirst().first?.value ?? 0
        return top.value >= 2 * second ? top.key : nil
    }
}

public struct LiveOutcome: Sendable, Equatable {
    public var text: String
    public var language: String
    /// Auto mode only: the language was locked during the dictation (always true in strict mode).
    public var locked: Bool
    /// False = Live's final didn't come in time (its last interim may be cut short).
    public var finalArrived: Bool
    public init(text: String, language: String, locked: Bool, finalArrived: Bool) {
        self.text = text; self.language = language; self.locked = locked; self.finalArrived = finalArrived
    }
}

public enum PasteSource: String, Sendable { case live, gemini }

/// Whether Live's text may be pasted instead of waiting for Gemini. Any doubt → Gemini.
public enum LiveFastDecision {
    /// Live sessions for a language setting. nil/"auto" → all three (lock in the first words); a single uz/ru/en
    /// setting → only that language (strict); anything else → no fast path.
    public static func sessions(for hint: String?) -> [String]? {
        switch hint?.lowercased() {
        case nil, "", "auto": return ["uz-UZ", "ru-RU", "en-US"]
        case "uz", "uz-uz": return ["uz-UZ"]
        case "ru", "ru-ru": return ["ru-RU"]
        case "en", "en-us": return ["en-US"]
        default: return nil
        }
    }

    public static func decide(strict: Bool, live: LiveOutcome?, pieces: String?, voicedSec: Double)
        -> (source: PasteSource, reason: String) {
        guard let live, live.finalArrived else { return (.gemini, "no_final") }
        let words = TextGuards.words(live.text)
        guard !words.isEmpty else { return (.gemini, "empty") }
        // The owner speaks ~2 words per voiced second; under 0.8 means Live dropped speech.
        if voicedSec > 3, Double(words.count) / voicedSec < 0.8 { return (.gemini, "too_few_words") }
        if TextGuards.scriptIssue(live.text) != nil { return (.gemini, "script") }
        if strict { return (.live, "strict") }
        // Auto: the chosen session's own text must look like its language (a wrong lock writes misheard words).
        let fit = LanguageScore.score(live.text, code: live.language) / Double(words.count)
        if fit < (live.language == "en-US" ? 0.25 : 0.5) { return (.gemini, "implausible") }
        guard let pieces, TextGuards.words(pieces).count >= 3 else {
            return live.locked ? (.live, "locked") : (.gemini, "no_lock")
        }
        let share = TextGuards.scriptProfile(pieces).cyrillicShare
        let consistent = live.language == "ru-RU" ? share >= 0.85 : share <= 0.10
        guard consistent else { return (.gemini, "switching") }
        let p = TextGuards.words(pieces)
        let match = difflibRatio(p, Array(words.prefix(p.count + 2)))
        return match >= 0.75 ? (.live, "pieces_agree") : (.gemini, "pieces_disagree")
    }

    /// Longest-common-subsequence ratio, 2·LCS / (|a| + |b|) — the same idea as Python's difflib ratio.
    static func difflibRatio(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() { cur[j + 1] = x == y ? prev[j] + 1 : max(prev[j + 1], cur[j]) }
            prev = cur
        }
        return 2 * Double(prev[b.count]) / Double(a.count + b.count)
    }
}

/// One Live session per candidate language while fn is held. Strict = one session. Auto = three;
/// after `lockAfterSec` the clear leader (`LanguageScore.leader`) is kept and the others close, so the rest of the
/// dictation streams to one language only.
public actor LiveRace {
    public struct Session: Sendable {
        public let code: String
        public let provider: GeminiLiveProvider
    }

    public nonisolated let sessions: [Session]
    public nonisolated let strict: Bool
    private let lockAfterSec: Double
    private var latest: [String: String] = [:]
    private var lockedCode: String?
    private let startedAt = Date()
    private var readers: [Task<Void, Never>] = []
    /// Chunks that arrive before the sessions exist (the recorder starts first, the pre-roll comes at once).
    private nonisolated let early = OSAllocatedUnfairLock(initialState: (started: false, pending: [Data]()))

    public init(apiKey: String, codes: [String], lockAfterSec: Double = 2.5) {
        sessions = codes.map { code in
            var c = LiveConfig()
            c.languageCodes = [code]
            return Session(code: code, provider: GeminiLiveProvider(apiKey: apiKey, config: c))
        }
        strict = codes.count == 1
        lockedCode = strict ? codes.first : nil
        self.lockAfterSec = lockAfterSec
    }

    private var startTask: Task<Void, Never>?

    /// Opens the sessions once, however often it is called. The pipeline calls it when a press turns out to be a
    /// hold or a lock, so a tap never opens a connection; audio fed before that is buffered (`early`).
    public func launch(vocabulary: [String]) {
        guard startTask == nil else { return }
        startTask = Task {
            await self.start(vocabulary: vocabulary)
            if self.releaseRequested { await self.endActivities() }   // key-up arrived before the launch ran
        }
    }
    private var releaseRequested = false, activitiesEnded = false, opened = false

    /// Opens every session (setup is queued; audio fed before setupComplete is buffered by the provider).
    public func start(vocabulary: [String]) async {
        opened = true
        var o = TranscribeOptions(model: GeminiLiveProvider.model)
        o.vocabulary = Array((vocabulary + LiveRace.crossLanguageTerms).prefix(100))
        for s in sessions {
            try? await s.provider.startSession(options: o)
            try? await s.provider.activityStart()
            let code = s.code, stream = s.provider.partials
            readers.append(Task { [weak self] in
                for await t in stream { await self?.update(code, t) }
            })
        }
        let sessions = sessions
        early.withLock { st in
            for d in st.pending { for s in sessions { s.provider.feedSync(d) } }
            st = (true, [])
        }
    }

    /// Words the owner mixes in across languages: Live's only "slight expectation" knob is customVocabulary.
    static let crossLanguageTerms = ["deploy", "task", "update", "release", "feedback", "commit", "test", "Claude",
                                     "GitHub", "API", "app", "потом", "короче", "вообще", "кстати", "ладно"]

    /// Safe from the recorder's audio thread; closed sessions drop the chunk.
    public nonisolated func feed(_ pcm16: Data) {
        let sessions = sessions
        early.withLock { st in
            if st.started { for s in sessions { s.provider.feedSync(pcm16) } } else { st.pending.append(pcm16) }
        }
    }

    public var locked: String? { lockedCode }

    private func update(_ code: String, _ text: String) {
        latest[code] = text
        guard lockedCode == nil, Date().timeIntervalSince(startedAt) >= lockAfterSec else { return }
        var scores: [String: Double] = [:]
        for (c, t) in latest { scores[c] = LanguageScore.score(t, code: c) }
        guard let lead = LanguageScore.leader(scores) else { return }
        lockedCode = lead
        for s in sessions where s.code != lead { s.provider.close() }
        Log.info("live lock: \(lead) after \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms")
    }

    /// Key up from synchronous code (the pipeline's key-up handler).
    public nonisolated func releaseSoon() { Task { await self.release() } }

    /// Key up: end the activity in every open session so their finals start now.
    public func release() async {
        releaseRequested = true
        if let t = startTask { await t.value }    // never overtake activityStart
        else if !opened { return }                 // not launched yet: launch() ends the activities once open
        await endActivities()
    }

    private func endActivities() async {
        guard !activitiesEnded else { return }
        activitiesEnded = true
        for s in open { try? await s.provider.activityEnd() }
    }

    private var open: [Session] { lockedCode.map { c in sessions.filter { $0.code == c } } ?? sessions }

    /// Waits up to `waitMs` for the finals, closes everything and returns the chosen session's text.
    public func finish(waitMs: Int = 1000) async -> LiveOutcome? {
        await startTask?.value
        let candidates = open
        var results: [(code: String, r: TranscriptResult)] = []
        await withTaskGroup(of: (String, TranscriptResult?).self) { g in
            for s in candidates { g.addTask { (s.code, try? await s.provider.finish(waitMs: waitMs)) } }
            for await (c, r) in g { if let r { results.append((c, r)) } }
        }
        for s in sessions { s.provider.close() }
        for t in readers { t.cancel() }
        let pick: (code: String, r: TranscriptResult)?
        if let c = lockedCode { pick = results.first { $0.code == c } }
        else { pick = results.max { LanguageScore.score($0.r.text, code: $0.code) < LanguageScore.score($1.r.text, code: $1.code) } }
        guard let pick else { return nil }
        return LiveOutcome(text: pick.r.text, language: pick.code, locked: lockedCode != nil,
                           finalArrived: pick.r.providerMeta["live_final"] == "1")
    }

    public func cancel() {
        for s in sessions { s.provider.close() }
        for t in readers { t.cancel() }
    }
}
