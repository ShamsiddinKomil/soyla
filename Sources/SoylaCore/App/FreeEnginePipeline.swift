import Foundation

// FE-4: the free on-device engine inside the pipeline. Pure, tested pieces that `DictationPipeline` calls; kept out
// of the big orchestrator so its edits stay surgical.

extension DictationPipeline {
    /// S3: the settings a run actually uses. `.apple` has no correction pass (P3), no live stream (R1: the Gemini Live
    /// session must never open, whatever the stored toggle says) and always gets WAV (R2). Cloud kinds pass through.
    /// Pure: the stored settings are never mutated, so switching back to Cloud restores the user's choices.
    nonisolated static func effectiveSettings(_ s: Settings) -> Settings {
        guard s.provider == .apple else { return s }
        var e = s
        e.cleanupLevel = .off          // didSet keeps cleanupEnabled in sync
        e.cleanupEnabled = false
        e.livePreview = false
        e.audioFormat = .wav
        e.streamSegments = false   // pieces are cloud requests
        e.liveFastPath = false     // Live fast path streams to Google
        return e
    }

    /// R1: the Gemini key for a live-preview session, or nil when none may start. Reads the effective settings, so
    /// `.apple` never streams, and the key (a Keychain read) is only asked for when a session would really start.
    nonisolated static func livePreviewKey(_ s: Settings, key: () -> String?) -> String? {
        guard effectiveSettings(s).livePreview else { return nil }
        return key()
    }

    /// Provider call for one run. Cloud: F3 script check (one retry on a wrong script). `.apple`: no script check (a
    /// single-locale engine can't drift script, and a retry would double latency), then D-PUNCT (b).
    /// `settings` is the effective copy.
    nonisolated static func transcribeStage(_ provider: any TranscriptionProvider, audio: EncodedAudio,
                                            options: TranscribeOptions, settings s: Settings,
                                            timeline: RunTimeline) async throws -> TranscriptResult {
        guard s.provider == .apple else {
            return try await ScriptCheck.transcribe(HedgedProvider.wrap(provider), audio: audio, options: options, timeline: timeline)
        }
        var r = try await provider.transcribe(audio, options: options, timeline: timeline)
        r.text = OnDevicePunctuation.finish(r.text)
        return r
    }

    /// The History row written before the network call (F4). Reads the effective settings, so a free run records
    /// cleanup off (S3).
    nonisolated static func pendingRecord(audio: EncodedAudio, runId: String, ts: String, settings s: Settings) -> RunRecord {
        RunRecord(
            runId: runId, ts: ts, source: "live", phraseId: s.phraseId, model: s.sttModel,
            cleanup: s.cleanupEnabled, cleanupModel: s.cleanupEnabled ? s.cleanupModel : nil,
            languageHint: s.languageHint, prewarm: s.prewarmConnection,
            audio: .init(format: audio.format, bytes: audio.data.count,
                         b64Bytes: (audio.data.count + 2) / 3 * 4,
                         durationSec: audio.durationSec, sampleRate: audio.sampleRate,
                         file: audio.fileURL.map { RecordingStore.relPath($0) }),
            timelineMs: [:], net: nil, usage: nil, cleanupUsage: nil,
            rawText: nil, cleanText: nil, error: nil, providerMeta: nil, status: .pending)
    }
}

/// D-PUNCT (b), owner 2026-10-16: Apple's on-device output has sparse punctuation (FE-0: 12 marks / 181 words), so a
/// deterministic rule finishes it. No AI, no network, well under 1 ms. Applied to `.apple` output only, before the
/// fillers and the dictionary.
public enum OnDevicePunctuation {
    static let terminal: Set<Character> = [".", "?", "!", "…", ":", ";"]

    /// Upper-cases the first letter (unless the first word is camel-case, like "iPhone") and appends "." unless the
    /// text already ends in `.?!…:;` or in an emoji/symbol. Empty (or whitespace) gives "".
    public static func finish(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first, let last = t.last else { return "" }
        let second = t.dropFirst().first
        if first.isLowercase, !(second?.isUppercase ?? false) {
            t = first.uppercased() + t.dropFirst()
        }
        if !terminal.contains(last), !endsInSymbol(last) { t += "." }
        return t
    }

    /// 👍, ❤️, $, ©: the speaker's sentence ends with it; a period after it reads wrong. Digits are `isEmoji` (keycap
    /// bases), so only emoji *presentation* and Unicode symbols count.
    static func endsInSymbol(_ c: Character) -> Bool {
        c.isSymbol || c.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            || c.unicodeScalars.contains { $0.value == 0xFE0F }   // text symbol + emoji variation selector
    }
}

/// P6: in free mode a non-English dictation comes back near-empty (FE-0). Fewer than `maxWordsPerSec` words per second
/// on a clip of at least `minAudioSec` → paste what came back and show an info card pointing at the cloud engine.
/// No language detection, no model, no network. Thresholds get tuned from FE-6 data.
public enum OnDeviceHint {
    public static let minAudioSec: Double = 3
    public static let maxWordsPerSec: Double = 0.5

    public static func shows(provider: ProviderKind, durationSec: Double, text: String) -> Bool {
        guard provider == .apple, durationSec >= minAudioSec else { return false }
        return Double(TextGuards.words(text).count) / durationSec < maxWordsPerSec
    }
}

extension PillFailure {
    /// P6 info card (not an error): connects a key (setup's Connect, or the Languages page without a cloud language).
    static let onDeviceHint = PillFailure(kind: .info, title: "Speaking Uzbek or Russian?", hint: "Add a cloud key.",
                                          openSettings: true, settingsPage: .apiKeys, fix: .connectKey)

    /// `SoylaError.onDeviceUnavailable(reason:)` → card. The audio and the History row are kept; Retry works once the
    /// model is ready. Reasons are FE-2's machine codes.
    static func onDevice(reason: String) -> PillFailure {
        switch reason {
        case "model-not-installed":
            return .init(kind: .error, title: "English model not ready", hint: "Open Soyla to finish setup.",
                         canRetry: true, openSettings: true, settingsPage: .apiKeys, fix: .page(.languages))
        case "needs-permission":
            return .init(kind: .error, title: "Allow Speech Recognition in Settings", hint: "Your recording is saved. Retry after allowing it.",
                         canRetry: true, openSettings: true, settingsPage: .permissions, fix: .page(.permissions))
        default:
            return .init(kind: .error, title: "On-device engine unavailable", hint: "Try again or switch to Cloud.",
                         canRetry: true, openSettings: true, settingsPage: .apiKeys, fix: .page(.languages))
        }
    }
}
