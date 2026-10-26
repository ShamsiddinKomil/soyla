import Foundation

// MARK: - Contract types (Phase 0). Read-only for module agents; report needed changes instead of editing.

/// Audio ready to send to a provider.
public struct EncodedAudio: Sendable {
    public let data: Data
    /// "wav" | "flac" | "m4a" | "ogg" (Opus in Ogg) — the value sent as `input_audio.format`.
    public let format: String
    public let durationSec: Double
    public let sampleRate: Int
    /// Where it was saved on disk, if kept (recordings/<run_id>.<format>).
    public let fileURL: URL?

    public init(data: Data, format: String, durationSec: Double, sampleRate: Int, fileURL: URL?) {
        self.data = data; self.format = format; self.durationSec = durationSec
        self.sampleRate = sampleRate; self.fileURL = fileURL
    }
}

public struct TranscribeOptions: Sendable {
    public var model: String
    /// ISO-639-1 ("uz", "ru", "en") or nil = provider auto-detect.
    public var languageHint: String?
    public var temperature: Double?
    /// Experimental passthrough to OpenRouter `provider.options`. Empty = omit the field.
    public var providerOptions: [String: String]
    /// Per-request network timeout (upstream hard limit is 60 s).
    public var timeoutSec: Double
    /// Names/terms to bias towards. Only the prompted chat route ("chat:" models) can use them.
    public var vocabulary: [String] = []
    /// One more prompt line for the chat routes (F3 script-check retry: "Uzbek in Latin script"). Ignored by
    /// dedicated transcribe models, which take no prompt.
    public var extraInstruction: String? = nil

    /// D26(b): the speaker's language set (`Settings.languages`). Empty = no set lines in the prompt and the old
    /// script check (CLI, replay).
    public var languages: [String] = []

    /// Multiplies the output cap (`TextGuards.sttMaxTokens`). 2 = the resend after a reply was cut off by the cap
    /// (finish reason MAX_TOKENS / length, `ScriptCheck.notRunaway`).
    public var maxTokensScale = 1

    public init(model: String, languageHint: String? = nil, languages: [String] = [], temperature: Double? = nil,
                providerOptions: [String: String] = [:], timeoutSec: Double = 60) {
        self.model = model; self.languageHint = languageHint; self.languages = languages; self.temperature = temperature
        self.providerOptions = providerOptions; self.timeoutSec = timeoutSec
    }
}

/// Mirrors OpenRouter's `usage` object. All optional: providers differ.
public struct Usage: Codable, Sendable, Equatable {
    public var seconds: Double?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?
    public var cost: Double?

    public init(seconds: Double? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil,
                totalTokens: Int? = nil, cost: Double? = nil) {
        self.seconds = seconds; self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.totalTokens = totalTokens; self.cost = cost
    }
}

public struct TranscriptResult: Sendable {
    public var text: String
    public var language: String?
    public var usage: Usage?
    /// e.g. ["generation_id": "...", "provider": "google-ai-studio", "http_status": "200"]
    public var providerMeta: [String: String]

    public init(text: String, language: String? = nil, usage: Usage? = nil, providerMeta: [String: String] = [:]) {
        self.text = text; self.language = language; self.usage = usage; self.providerMeta = providerMeta
    }
}

public enum SoylaError: Error, LocalizedError, Sendable {
    case missingAPIKey(String)
    /// The key is saved but macOS has not handed it over yet (password dialog open) or the user clicked Deny.
    case keychainBlocked(denied: Bool)
    case http(status: Int, body: String)
    case decode(String)
    case audio(String)
    case permission(String)
    case notImplemented(String)
    case tooShort(Double)
    case emptyTranscript
    case cancelled
    /// The on-device engine can't run. `reason` is a short machine code ("model-not-installed", "needs-permission",
    /// "unsupported", "recognizer-failed:<domain>:<code>"), never user text (FE-2).
    case onDeviceUnavailable(reason: String)
    /// A custom server address is plain http but not this Mac (D7).
    case insecureEndpoint

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let p): return "API key not found: \(p)"
        case .keychainBlocked(let denied): return denied ? "macOS refused to move the API key out of the Keychain" : "waiting for macOS to move the API key out of the Keychain"
        case .http(let s, let b): return "HTTP \(s) body: \(b.prefix(300))"   // " body:" lets logSafe strip it
        case .decode(let m): return "decode: \(m)"
        case .audio(let m): return "audio: \(m)"
        case .permission(let m): return "permission: \(m)"
        case .notImplemented(let m): return "not implemented: \(m)"
        case .emptyTranscript: return "the model returned an empty transcript (no speech recognised)"
        case .tooShort(let d): return "recording too short (\(String(format: "%.2f", d)) s)"
        case .cancelled: return "cancelled"
        case .onDeviceUnavailable(let r): return "on-device engine unavailable: \(r)"
        case .insecureEndpoint: return "custom base URL must use https (http is allowed only for localhost)"
        }
    }
}

/// Batch (request/response) speech-to-text: the cloud providers and the on-device engine.
public protocol TranscriptionProvider: Sendable {
    var id: String { get }
    /// Must call `timeline.mark(.requestSent)`, `.firstByte` (if known), `.responseReceived`
    /// and fill `timeline.net` from URLSessionTaskMetrics when available.
    func transcribe(_ audio: EncodedAudio, options: TranscribeOptions, timeline: RunTimeline) async throws -> TranscriptResult
}

/// Streaming push-to-talk speech-to-text: `GeminiLiveProvider`, for the live preview and the experimental Live fast path.
public protocol StreamingTranscriptionProvider: Sendable {
    var id: String { get }
    func startSession(options: TranscribeOptions) async throws
    /// Hotkey down. Maps to Gemini Live `activity_start` (manual VAD).
    func activityStart() async throws
    /// 16 kHz mono Int16 little-endian PCM chunks straight from the Recorder tap.
    func feed(pcm16: Data) async throws
    /// Hotkey up. Maps to `activity_end`.
    func activityEnd() async throws
    /// Interim transcripts for the floating panel.
    var partials: AsyncStream<String> { get }
    func finish() async throws -> TranscriptResult
}
