import Foundation

// Google AI Studio direct (Gemini API `generateContent`), same verbatim prompt as the OpenRouter chat route.
// Verified against https://ai.google.dev/api/generate-content (2026-10-16):
// - POST /v1beta/models/{model}:generateContent, auth header `x-goog-api-key` (never `?key=`: URLs end up in logs).
// - Part = {text} | {inlineData: {mimeType, data(base64)}}; response candidates[].content.parts[].text, parts with
//   `thought: true` are reasoning, usageMetadata.{promptTokenCount, candidatesTokenCount, thoughtsTokenCount, totalTokenCount}.
// - generationConfig.thinkingConfig.thinkingLevel (MINIMAL|LOW|MEDIUM|HIGH) is "recommended for Gemini 3 or later";
//   it errors on earlier models. Used instead of thinkingBudget = 0 (the OpenRouter route already showed that
//   switching reasoning off is rejected for 3.5 Flash; "minimal" is the supported equivalent).
// Google returns no cost → Usage.cost stays nil.
// MEASURED 2026-10-16 (A3) on the 41 s Uzbek↔Russian clip: OpenRouter serves google/gemini-3.5-flash from Vertex
// ("upstream=Google") and is stable with minimal reasoning. AI Studio direct with MINIMAL (or LOW, or budget 0/512,
// any temperature, prompt in systemInstruction, audio first) is NOT: ~half the runs add timestamps, write Uzbek in
// Cyrillic, transliterate Russian, or loop. Default thinking / MEDIUM is stable but takes 12–18 s (~3k thought tokens).
// Short uz/en clips match OpenRouter. Kept MINIMAL for latency; see PLAN §13 "A3" before making Google the default.
enum GoogleAIHTTP {
    static let base = "https://generativelanguage.googleapis.com/v1beta"

    /// Accepts "gemini-3.5-flash", "google/gemini-3.5-flash", "chat:google/gemini-3.5-flash", "models/gemini-3.5-flash".
    static func modelId(_ model: String) -> String {
        var m = model
        if m.hasPrefix(OpenRouterSTTProvider.chatPrefix) { m = String(m.dropFirst(OpenRouterSTTProvider.chatPrefix.count)) }
        for p in ["google/", "models/"] where m.hasPrefix(p) { m = String(m.dropFirst(p.count)) }
        return m
    }

    static func url(model: String) -> URL {
        let id = modelId(model).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelId(model)
        return URL(string: "\(base)/models/\(id):generateContent")!
    }

    static func request(url: URL, method: String, apiKey: String, body: Data? = nil, timeout: Double = 60) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
        }
        return r
    }

    /// MINIMAL for Gemini 3+ (pro models only take LOW/HIGH); nil for older models, which reject thinkingLevel.
    static func thinkingConfig(for model: String) -> [String: Any]? {
        let m = modelId(model)
        guard m.hasPrefix("gemini-"),
              let major = Int(m.dropFirst("gemini-".count).prefix { $0.isNumber }), major >= 3 else { return nil }
        return ["thinkingLevel": m.contains("pro") ? "LOW" : "MINIMAL"]
    }

    static func mimeType(for format: String) -> String {
        switch format {
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "m4a": return "audio/m4a"
        case "ogg": return "audio/ogg"
        default: return "audio/" + format
        }
    }

    struct Response: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { var text: String?; var thought: Bool? }
                var parts: [Part]?
            }
            var content: Content?
            var finishReason: String?
        }
        struct UsageMeta: Decodable {
            var promptTokenCount: Int?
            var candidatesTokenCount: Int?
            var thoughtsTokenCount: Int?
            var totalTokenCount: Int?
        }
        struct Feedback: Decodable { var blockReason: String? }
        var candidates: [Candidate]?
        var usageMetadata: UsageMeta?
        var promptFeedback: Feedback?
    }

    /// Text of the first candidate (thought parts skipped, trimmed) + usage. `finishReason`/`blockReason` for diagnostics.
    static func decode(_ data: Data) throws -> (text: String, usage: Usage?, finishReason: String?) {
        let r: Response
        do { r = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw SoylaError.decode("google: \(error.localizedDescription) body: \(OpenRouterHTTP.bodyPrefix(data))") }
        let c = r.candidates?.first
        let text = (c?.content?.parts ?? []).filter { $0.thought != true }.compactMap(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usage = r.usageMetadata.map { u -> Usage in
            // Thought tokens are billed as output.
            let out: Int? = (u.candidatesTokenCount == nil && u.thoughtsTokenCount == nil)
                ? nil : (u.candidatesTokenCount ?? 0) + (u.thoughtsTokenCount ?? 0)
            return Usage(inputTokens: u.promptTokenCount, outputTokens: out, totalTokens: u.totalTokenCount, cost: nil)
        }
        return (text, usage, c?.finishReason ?? r.promptFeedback?.blockReason.map { "BLOCKED_" + $0 })
    }

    /// Google answers a bad key with 400 INVALID_ARGUMENT ("API key not valid", reason API_KEY_INVALID); map it to
    /// 401 so the error card says "API key rejected". Other statuses pass through.
    static func httpError(status: Int, data: Data, apiKey: String = "") -> SoylaError {
        let body = OpenRouterHTTP.bodyPrefix(data, redacting: apiKey)
        if status == 400 {
            let full = String(decoding: data.prefix(4096), as: UTF8.self)
            if full.contains("API key not valid") || full.contains("API_KEY_INVALID") { return .http(status: 401, body: body) }
        }
        return .http(status: status, body: body)
    }
}

public final class GoogleAIProvider: TranscriptionProvider, Sendable {
    public let id = "google"
    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String) {
        self.apiKey = apiKey
        self.session = OpenRouterHTTP.makeSession()   // ephemeral, no URLCache (R3)
    }

    /// Tiny GET on the same session so TLS is up before audio is ready. Never throws.
    public func prewarm() async {
        let req = GoogleAIHTTP.request(url: URL(string: GoogleAIHTTP.base + "/models?pageSize=1")!, method: "GET", apiKey: apiKey, timeout: 10)
        _ = try? await session.data(for: req)
    }

    /// generateContent body (exposed for tests). Prompt identical to the OpenRouter chat route.
    static func makeBody(_ audio: EncodedAudio, options: TranscribeOptions) throws -> Data {
        var gen: [String: Any] = ["temperature": 0, "maxOutputTokens": TextGuards.sttMaxTokens(durationSec: audio.durationSec) * max(1, options.maxTokensScale)]
        if let t = GoogleAIHTTP.thinkingConfig(for: options.model) { gen["thinkingConfig"] = t }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [
                ["text": OpenRouterSTTProvider.transcriptionPrompt(options, durationSec: audio.durationSec)],
                ["inlineData": ["mimeType": GoogleAIHTTP.mimeType(for: audio.format), "data": audio.data.base64EncodedString()]],
            ]]],
            "generationConfig": gen,
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
    }

    /// The generateContent request; its timeout scales with the clip (`TextGuards.sttTimeoutSec`).
    static func makeRequest(_ audio: EncodedAudio, options: TranscribeOptions, apiKey: String) throws -> URLRequest {
        GoogleAIHTTP.request(url: GoogleAIHTTP.url(model: options.model), method: "POST", apiKey: apiKey,
                             body: try makeBody(audio, options: options),
                             timeout: TextGuards.sttTimeoutSec(durationSec: audio.durationSec, cap: options.timeoutSec))
    }

    public func transcribe(_ audio: EncodedAudio, options: TranscribeOptions, timeline: RunTimeline) async throws -> TranscriptResult {
        let req = try Self.makeRequest(audio, options: options, apiKey: apiKey)
        let collector = MetricsCollector()
        timeline.mark(.requestSent)
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req, delegate: collector)
        } catch {
            timeline.mark(.responseReceived)
            timeline.net = MetricsCollector.net(from: await collector.waitForMetrics())
            throw error
        }
        timeline.mark(.responseReceived)
        timeline.net = MetricsCollector.net(from: await collector.waitForMetrics())
        guard let http = resp as? HTTPURLResponse else { throw SoylaError.decode("non-HTTP response") }
        guard http.statusCode == 200 else { throw GoogleAIHTTP.httpError(status: http.statusCode, data: data, apiKey: apiKey) }
        let (text, usage, finish) = try GoogleAIHTTP.decode(data)
        if ScriptCheck.emptyIsNoSpeech(text, finishReason: finish) { throw SoylaError.emptyTranscript }
        var meta: [String: String] = ["http_status": "\(http.statusCode)", "provider": "google-ai-studio"]
        if let finish { meta["finish_reason"] = finish }
        return TranscriptResult(text: text, language: options.languageHint, usage: usage, providerMeta: meta)
    }
}
