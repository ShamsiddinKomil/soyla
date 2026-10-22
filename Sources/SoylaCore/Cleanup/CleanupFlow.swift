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
                           model: String, vocabulary: [String], appName: String?, languageHint: String?,
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
                if TextGuards.scriptIssue(r.text, languageHint: languageHint) != nil,
                   TextGuards.scriptIssue(raw, languageHint: languageHint) == nil {
                    out.scriptRetried = true
                    r = try await cleaner.clean(raw, model: model, vocabulary: vocabulary, appName: appName,
                                                scriptReminder: true, timeline: timeline)
                    usage = Self.sum(usage, r.usage)
                }
                out.usage = usage
                if TextGuards.scriptIssue(r.text, languageHint: languageHint) != nil,
                   TextGuards.scriptIssue(raw, languageHint: languageHint) == nil {
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

/// Script check after STT: Hangul/CJK/Arabic/Thai in a uz/ru/en session, or Uzbek in Cyrillic → one retry with
/// `TranscribeOptions.extraInstruction` = the "Uzbek in Latin script" line → still wrong → ScriptCheckError.
public enum ScriptCheck {
    public static let retryInstruction = """
    IMPORTANT: the speech is in Uzbek, Russian and/or English only. Write Uzbek in the Latin script (o', g', sh, ch), never in Cyrillic. Russian stays Cyrillic. Never output Korean, Chinese, Japanese, Arabic or Thai characters.
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

    /// `provider_meta.script_check`: "ok", or "retried:<issue tag>" when the retry fixed it.
    static func checked(_ provider: any TranscriptionProvider, audio: EncodedAudio, options: TranscribeOptions,
                        timeline: RunTimeline) async throws -> TranscriptResult {
        var r = try await provider.transcribe(audio, options: options, timeline: timeline)
        stripTimestamps(&r, audio)
        guard let issue = TextGuards.scriptIssue(r.text, languageHint: options.languageHint) else {
            r.providerMeta["script_check"] = "ok"
            return r
        }
        var retry = options
        retry.extraInstruction = [options.extraInstruction, retryInstruction].compactMap { $0 }.joined(separator: "\n")
        var r2 = try await provider.transcribe(audio, options: retry, timeline: timeline)
        stripTimestamps(&r2, audio)
        r2.usage = CleanupFlow.sum(r.usage, r2.usage)
        if let issue2 = TextGuards.scriptIssue(r2.text, languageHint: options.languageHint) {
            // A few stray foreign letters (2026-10-17: Arabic in a 45 s English dictation) must not cost the whole text.
            guard case .foreignScript = issue2, let kept = salvage(r, r2) else { throw ScriptCheckError(issue2) }
            var out = kept
            out.usage = r2.usage
            out.providerMeta["script_check"] = "stripped:" + issue2.tag
            return out
        }
        r2.providerMeta["script_check"] = "retried:" + issue.tag
        return r2
    }

    /// The try with fewer foreign letters, minus its foreign words; nil if that is still wrong (e.g. Uzbek in Cyrillic).
    static func salvage(_ a: TranscriptResult, _ b: TranscriptResult) -> TranscriptResult? {
        let best = TextGuards.scriptProfile(a.text).foreign <= TextGuards.scriptProfile(b.text).foreign ? a : b
        guard let text = TextGuards.stripForeignWords(best.text), TextGuards.scriptIssue(text) == nil else { return nil }
        var r = best
        r.text = text
        return r
    }

    /// `provider_meta.timestamps_stripped` = how many were removed (absent when none).
    static func stripTimestamps(_ r: inout TranscriptResult, _ audio: EncodedAudio) {
        let s = TextGuards.stripTimestamps(r.text, durationSec: audio.durationSec)
        guard s.removed > 0 else { return }
        r.text = s.text
        r.providerMeta["timestamps_stripped"] = String(s.removed)
    }
}
