import Foundation
import os

/// D14: how much the correction pass may change. Medium comes later.
public enum CleanupLevel: String, Codable, CaseIterable, Sendable {
    case off, light

    public var label: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        }
    }

    /// Tolerant: an unknown level from a newer build ("medium") falls back to .light.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CleanupLevel(rawValue: raw) ?? .light
    }
}

/// After an HTTP 429 a provider gets 60 s off from cleanup (raw text is pasted meanwhile).
public final class ProviderCooldown: Sendable {
    public static let shared = ProviderCooldown()
    public let seconds: TimeInterval
    private let until = OSAllocatedUnfairLock(initialState: [String: Date]())

    public init(seconds: TimeInterval = 60) { self.seconds = seconds }

    /// One key per provider; a custom server is keyed by its base URL.
    public static func key(_ kind: ProviderKind, customBaseURL: String? = nil) -> String {
        kind == .custom ? "custom:" + (customBaseURL ?? "") : kind.rawValue
    }

    public func note429(_ key: String, now: Date = Date()) {
        let end = now.addingTimeInterval(seconds)
        until.withLock { $0[key] = end }
    }

    public func isCooling(_ key: String, now: Date = Date()) -> Bool {
        until.withLock { until in
            guard let u = until[key] else { return false }
            if now >= u { until[key] = nil; return false }
            return true
        }
    }
}

/// Result of the text stage between STT and paste.
public struct CleanupOutcome: Sendable, Equatable {
    public enum Status: String, Sendable {
        case off                               // cleanup level Off
        case skippedShort = "skipped_short"    // ≤ 4 words, no digits / punctuation words / correction cues
        case skippedCooldown = "skipped_cooldown" // provider had a 429 in the last 60 s
        case ok                                // cleaned text accepted
        case guarded = "guard"                 // cleaned text rejected → raw pasted (see guardReason)
        case error                             // HTTP / decode / key error → raw pasted
    }
    /// What gets pasted: accepted cleaned text, else raw; dictionary applied either way.
    public var text: String
    /// Accepted cleanup output (before the dictionary). nil unless status == .ok.
    public var cleaned: String?
    public var usage: Usage?
    public var status: Status
    public var guardReason: CleanupGuard?
    /// Non-guard failure, for RunRecord.error ("cleanup: …").
    public var error: String?
    public var dictionaryHits = 0
    /// The cleanup output failed the script check once and was re-requested with the "Uzbek in Latin" line.
    public var scriptRetried = false
    /// A rejected cleanup output (runs.jsonl only, for tuning the guards; never app.log).
    public var rejected: String?

    /// Keys merged into RunRecord.providerMeta: `cleanup` = status, `cleanup_guard` = reason,
    /// `cleanup_script_retry` = "1", `dictionary_hits` = N, `cleanup_rejected` = the thrown-away text.
    public var meta: [String: String] {
        var m = ["cleanup": status.rawValue]
        if let g = guardReason { m["cleanup_guard"] = g.rawValue }
        if scriptRetried { m["cleanup_script_retry"] = "1" }
        if dictionaryHits > 0 { m["dictionary_hits"] = "\(dictionaryHits)" }
        if let r = rejected { m["cleanup_rejected"] = r }
        return m
    }
}

/// Raw transcript → (maybe) cleanup → guards → dictionary. Shared by the app pipeline and `soyla replay`.
/// Design rule: cleanup never invents, never translates, never transliterates; on any doubt paste raw.
public enum CleanupFlow {
    public enum Decision: Equatable, Sendable { case off, skipShort, skipCooldown, call }

    /// Whether the model will be called (the pipeline shows "cleaning" only for `.call`).
    public static func decision(raw: String, level: CleanupLevel, cooling: Bool) -> Decision {
        if level == .off { return .off }
        if TextGuards.shouldSkipCleanup(raw) { return .skipShort }
        if cooling { return .skipCooldown }
        return .call
    }

    public static func run(raw: String, level: CleanupLevel, cleaner makeCleaner: @Sendable () throws -> any TextCleaner,
                           model: String, vocabulary: [String], appName: String?, languageHint: String?, languages: [String] = [],
                           dictionary: ReplacementDictionary, cooldownKey: String, cooldown: ProviderCooldown = .shared,
                           timeline: RunTimeline) async -> CleanupOutcome {
        var out = CleanupOutcome(text: raw, status: .ok)
        switch decision(raw: raw, level: level, cooling: cooldown.isCooling(cooldownKey)) {
        case .off: out.status = .off
        case .skipShort: out.status = .skippedShort
        case .skipCooldown: out.status = .skippedCooldown
        case .call:
            do {
                let cleaner = try makeCleaner()
                var r = try await cleaner.clean(raw, model: model, vocabulary: vocabulary, appName: appName,
                                                scriptReminder: false, timeline: timeline)
                var usage = r.usage
                // Script check after cleanup (only blame cleanup if the raw text was fine).
                if TextGuards.scriptIssue(r.text, languageHint: languageHint, languages: languages) != nil,
                   TextGuards.scriptIssue(raw, languageHint: languageHint, languages: languages) == nil {
                    out.scriptRetried = true
                    r = try await cleaner.clean(raw, model: model, vocabulary: vocabulary, appName: appName,
                                                scriptReminder: true, timeline: timeline)
                    usage = Self.sum(usage, r.usage)
                }
                out.usage = usage
                if TextGuards.scriptIssue(r.text, languageHint: languageHint, languages: languages) != nil,
                   TextGuards.scriptIssue(raw, languageHint: languageHint, languages: languages) == nil {
                    out.status = .guarded; out.guardReason = .script; out.rejected = r.text
                } else if let g = TextGuards.checkCleanup(input: raw, output: r.text) {
                    out.status = .guarded; out.guardReason = g; out.rejected = r.text
                } else {
                    out.status = .ok; out.cleaned = r.text; out.text = r.text
                }
            } catch let g as CleanupGuardError {
                out.status = .guarded; out.guardReason = g.reason
            } catch let e as URLError where e.code == .timedOut {
                out.status = .guarded; out.guardReason = .timeout
            } catch SoylaError.http(status: 429, body: _) {
                cooldown.note429(cooldownKey)
                out.status = .guarded; out.guardReason = .rateLimited
            } catch {
                out.status = .error; out.error = "cleanup: \(error.localizedDescription)"
            }
        }
        out.text = Fillers.strip(out.text)
        let d = dictionary.apply(out.text)
        out.text = d.text; out.dictionaryHits = d.hits
        return out
    }

    static func sum(_ a: Usage?, _ b: Usage?) -> Usage? {
        guard let a else { return b }
        guard let b else { return a }
        func s<T: AdditiveArithmetic>(_ x: T?, _ y: T?) -> T? { x == nil && y == nil ? nil : (x ?? .zero) + (y ?? .zero) }
        return Usage(seconds: s(a.seconds, b.seconds), inputTokens: s(a.inputTokens, b.inputTokens), outputTokens: s(a.outputTokens, b.outputTokens),
                     totalTokens: s(a.totalTokens, b.totalTokens), cost: s(a.cost, b.cost))
    }
}

/// The STT result failed the script check twice: nothing is pasted, the card says "Didn't understand that, try again".
public struct ScriptCheckError: Error, LocalizedError, Equatable {
    public var issue: ScriptIssue
    public init(_ issue: ScriptIssue) { self.issue = issue }
    public var errorDescription: String? { "script check failed twice (\(issue.tag))" }
}

/// Script check after STT: a letter outside Latin/Cyrillic (Hangul, Arabic, Greek…) in a uz/ru/en session, or Uzbek in Cyrillic → one retry with
/// `TranscribeOptions.extraInstruction` = the "Uzbek in Latin script" line → still wrong → ScriptCheckError.
public enum ScriptCheck {
    public static let retryInstruction = """
    IMPORTANT: the speech is in Uzbek, Russian and/or English only. Write Uzbek in the Latin script (o', g', sh, ch), never in Cyrillic. Russian stays Cyrillic. Use only Latin and Cyrillic letters: never Korean, Chinese, Japanese, Arabic, Thai, Greek or any other script.
    """

    /// Below this many characters per second of a clip ≥ `shortCheckMinSec`, the text is treated as cut off.
    /// Owner's dictation runs 10–14 chars/s; on 2026-10-16 a 45 s clip came back as 60 and 82 characters.
    static let shortCheckCharsPerSec = 3.0
    static let shortCheckMinSec = 15.0

    static func looksCutOff(_ text: String, durationSec: Double) -> Bool {
        durationSec >= shortCheckMinSec && Double(text.count) < durationSec * shortCheckCharsPerSec
    }

    /// The script-checked transcript. A long clip whose text looks cut off is sent once more and the longer
    /// text wins (`provider_meta.short_retry` = "first" | "second"); a failing second try keeps the first.
    /// At most 2 `checked` calls, so at most 6 provider calls (each may add a hedged backup).
    public static func transcribe(_ provider: any TranscriptionProvider, audio: EncodedAudio, options: TranscribeOptions,
                                  timeline: RunTimeline) async throws -> TranscriptResult {
        let r = try await checked(provider, audio: audio, options: options, timeline: timeline)
        guard looksCutOff(r.text, durationSec: audio.durationSec) else { return r }
        guard let r2 = try? await checked(provider, audio: audio, options: options, timeline: timeline) else {
            var kept = r; kept.providerMeta["short_retry"] = "first"; return kept
        }
        let firstWins = r.text.count >= r2.text.count
        var best = firstWins ? r : r2
        best.usage = CleanupFlow.sum(r.usage, r2.usage)
        best.providerMeta["short_retry"] = firstWins ? "first" : "second"
        return best
    }

    /// `provider_meta.script_check`: "ok", or "retried:<issue tag>" when the retry fixed it. At most 3 provider calls:
    /// the first, one resend if it ran away or was cut off, one script retry (never resent: if it runs away or is cut
    /// off, the first reply is judged alone, `firstAlone`).
    static func checked(_ provider: any TranscriptionProvider, audio: EncodedAudio, options: TranscribeOptions,
                        timeline: RunTimeline) async throws -> TranscriptResult {
        var r = try await notRunaway(provider, try await provider.transcribe(audio, options: options, timeline: timeline),
                                     audio: audio, options: options, timeline: timeline)
        stripTimestamps(&r, audio)
        guard let issue = TextGuards.scriptIssue(r.text, languageHint: options.languageHint, languages: options.languages) else {
            r.providerMeta["script_check"] = "ok"
            return r
        }
        var retry = options
        if r.providerMeta["truncated"] == "retried" { retry.maxTokensScale = options.maxTokensScale * 2 }
        retry.extraInstruction = [options.extraInstruction, retryInstruction, LanguagePrompt.retryLine(options.languages)]
            .compactMap { $0 }.joined(separator: "\n")
        var r2 = try await provider.transcribe(audio, options: retry, timeline: timeline)
        guard !cutOrRunaway(r2, audio) else { return try firstAlone(r, issue: issue, retry: r2, options: options) }
        stripTimestamps(&r2, audio)
        r2.usage = CleanupFlow.sum(r.usage, r2.usage)
        if let issue2 = TextGuards.scriptIssue(r2.text, languageHint: options.languageHint, languages: options.languages) {
            if issue2 == .latinExtended { return keepLatinExtended(r, first: issue, r2) }
            // A few stray foreign letters (2026-10-17: Arabic in a 45 s English dictation) must not cost the whole text.
            // D26(b): the set check never costs the dictation: the try with less Cyrillic is pasted.
            if case .outsideSet = issue2, let kept = keepBetter(r, r2, options: options) {
                var out = kept
                out.usage = r2.usage
                out.providerMeta["script_check"] = "outside_set:kept"
                return out
            }
            guard case .foreignScript = issue2, let kept = salvage(r, r2, languages: options.languages) else { throw ScriptCheckError(issue2) }
            var out = kept
            out.usage = r2.usage
            out.providerMeta["script_check"] = "stripped:" + issue2.tag
            return out
        }
        r2.providerMeta["script_check"] = "retried:" + issue.tag
        return r2
    }

    /// The script retry ran away or was cut off: the first reply decides alone, as the helpers do for two tries.
    /// Latin-extended or outside the set → it is pasted; foreign script → salvaged; anything else → the card.
    /// `provider_meta.script_retry` = "bad".
    static func firstAlone(_ r: TranscriptResult, issue: ScriptIssue, retry r2: TranscriptResult,
                           options: TranscribeOptions) throws -> TranscriptResult {
        var out: TranscriptResult
        switch issue {
        case .latinExtended:
            out = r; out.providerMeta["script_check"] = "latin_ext:kept"
        case .outsideSet:
            guard let kept = keepBetter(r, r, options: options) else { throw ScriptCheckError(issue) }
            out = kept; out.providerMeta["script_check"] = "outside_set:kept"
        case .foreignScript:
            guard let kept = salvage(r, r, languages: options.languages) else { throw ScriptCheckError(issue) }
            out = kept; out.providerMeta["script_check"] = "stripped:" + issue.tag
        default:
            throw ScriptCheckError(issue)
        }
        out.usage = CleanupFlow.sum(r.usage, r2.usage)
        out.providerMeta["script_retry"] = "bad"
        return out
    }

    /// An empty reply is "no speech" (`SoylaError.emptyTranscript`) unless the output cap cut it off: then it goes
    /// back to `notRunaway`, which resends it with twice the cap (Google can spend the cap before writing text).
    public static func emptyIsNoSpeech(_ text: String, finishReason: String?) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !["max_tokens", "length"].contains(finishReason?.lowercased() ?? "")
    }

    /// A reply cut off by the output cap: finish reason MAX_TOKENS (Google) or length (OpenRouter chat).
    static func truncated(_ r: TranscriptResult) -> Bool {
        ["max_tokens", "length"].contains(r.providerMeta["finish_reason"]?.lowercased() ?? "")
    }

    static func cutOrRunaway(_ r: TranscriptResult, _ audio: EncodedAudio) -> Bool {
        TextGuards.ranAway(r.text, durationSec: audio.durationSec) || truncated(r)
    }

    /// A reply far longer than the clip (a loop or invented text; perf test 2026-10-26) is sent once more,
    /// `provider_meta.runaway` = "retried". A reply cut off by the cap is sent once more with the cap doubled,
    /// `provider_meta.truncated` = "retried". The resend bad too → `ScriptCheckError(.runaway)`: nothing is pasted,
    /// "Didn't understand that" with Retry, and in pieces mode the whole clip is sent instead.
    static func notRunaway(_ provider: any TranscriptionProvider, _ first: TranscriptResult, audio: EncodedAudio,
                           options: TranscribeOptions, timeline: RunTimeline) async throws -> TranscriptResult {
        guard cutOrRunaway(first, audio) else { return first }
        // A cut-off first reply may be empty (Google MAX_TOKENS spent on thinking); an empty resend is "no speech", as before.
        let cut = !TextGuards.ranAway(first.text, durationSec: audio.durationSec)   // a runaway gets no more room
        var o = options
        if cut { o.maxTokensScale = options.maxTokensScale * 2 }
        var r2 = try await provider.transcribe(audio, options: o, timeline: timeline)
        if r2.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw SoylaError.emptyTranscript }
        guard !cutOrRunaway(r2, audio) else { throw ScriptCheckError(.runaway) }
        r2.usage = CleanupFlow.sum(first.usage, r2.usage)
        r2.providerMeta[cut ? "truncated" : "runaway"] = "retried"
        return r2
    }

    /// Latin-extended letters twice never cost the dictation (Turkish or Polish names, `TextGuards.latinExtWordLimit`):
    /// the try with fewer such words is pasted, `script_check` = "latin_ext:kept".
    static func keepLatinExtended(_ r: TranscriptResult, first: ScriptIssue, _ r2: TranscriptResult) -> TranscriptResult {
        let firstBetter = first == .latinExtended && TextGuards.latinExtWords(r.text) < TextGuards.latinExtWords(r2.text)
        var out = firstBetter ? r : r2
        out.usage = r2.usage
        out.providerMeta["script_check"] = "latin_ext:kept"
        return out
    }

    /// The try with fewer foreign letters, minus its foreign words; nil if that is still wrong (e.g. Uzbek in Cyrillic).
    static func salvage(_ a: TranscriptResult, _ b: TranscriptResult, languages: [String] = []) -> TranscriptResult? {
        let best = TextGuards.scriptProfile(a.text).foreign <= TextGuards.scriptProfile(b.text).foreign ? a : b
        // Latin-extended words (names) are no reason to lose the text here.
        guard let text = TextGuards.stripForeignWords(best.text),
              [nil, .latinExtended].contains(TextGuards.scriptIssue(text, languages: languages)) else { return nil }
        var r = best
        r.text = text
        return r
    }

    /// D26(b): both tries outside the set → the one with the lower Cyrillic share, among tries that pass the checks
    /// without the set (no foreign script, no Uzbek in Cyrillic). nil = neither does: the card, as before.
    static func keepBetter(_ a: TranscriptResult, _ b: TranscriptResult, options: TranscribeOptions) -> TranscriptResult? {
        [a, b].filter { [nil, .latinExtended].contains(TextGuards.scriptIssue($0.text, languageHint: options.languageHint)) }
            .min { TextGuards.scriptProfile($0.text).cyrillicShare < TextGuards.scriptProfile($1.text).cyrillicShare }
    }

    /// `provider_meta.timestamps_stripped` = how many were removed (absent when none).
    static func stripTimestamps(_ r: inout TranscriptResult, _ audio: EncodedAudio) {
        let s = TextGuards.stripTimestamps(r.text, durationSec: audio.durationSec)
        guard s.removed > 0 else { return }
        r.text = s.text
        r.providerMeta["timestamps_stripped"] = String(s.removed)
    }
}
