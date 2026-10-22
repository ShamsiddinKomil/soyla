import Foundation

public final class OpenRouterSTTProvider: TranscriptionProvider, Sendable {
    public let id: String
    private let apiKey: String
    private let baseURL: String
    private let session: URLSession

    /// `baseURL` nil = OpenRouter. A custom OpenAI-compatible server (`ProviderKind.custom`) passes its base URL
    /// (e.g. "http://localhost:8080/v1"); it gets the same prompted chat route.
    public init(apiKey: String, baseURL: String? = nil) {
        self.apiKey = apiKey
        self.baseURL = baseURL ?? OpenRouterHTTP.base
        self.id = baseURL == nil ? "openrouter" : "custom"
        self.session = OpenRouterHTTP.makeSession()
    }

    /// Tiny GET on the same session so TLS is up before audio is ready. Never throws.
    public func prewarm() async {
        guard let req = try? OpenRouterHTTP.request(id == "openrouter" ? "/auth/key" : "/models", method: "GET", apiKey: apiKey,
                                                    timeout: 10, baseURL: baseURL) else { return }
        _ = try? await session.data(for: req)
    }

    /// JSON body for /audio/transcriptions (exposed for tests).
    static func makeBody(_ audio: EncodedAudio, options: TranscribeOptions) throws -> Data {
        var body: [String: Any] = [
            "model": options.model,
            "input_audio": ["data": audio.data.base64EncodedString(), "format": audio.format],
        ]
        if let l = options.languageHint, !l.isEmpty { body["language"] = l }
        if let t = options.temperature { body["temperature"] = t }
        if !options.providerOptions.isEmpty { body["provider"] = ["options": options.providerOptions] }
        return try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
    }

    struct Response: Decodable {
        struct U: Decodable {
            var seconds: Double?
            var totalTokens: Int?
            var inputTokens: Int?
            var outputTokens: Int?
            var cost: Double?
        }
        var text: String
        var usage: U?
    }

    static func decode(_ data: Data) throws -> (text: String, usage: Usage?) {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let r = try d.decode(Response.self, from: data)
            let u = r.usage.map { Usage(seconds: $0.seconds, inputTokens: $0.inputTokens, outputTokens: $0.outputTokens,
                                         totalTokens: $0.totalTokens, cost: $0.cost) }
            return (r.text, u)
        } catch {
            throw SoylaError.decode("\(error.localizedDescription) body: \(OpenRouterHTTP.bodyPrefix(data))")
        }
    }

    // MARK: prompted chat route
    //
    // Gemini's dedicated transcribe models (batch and Live) decode each utterance in ONE language: on Uzbek↔Russian
    // speech they drop the other language or return empty text (verified 2026-10-15). A general Gemini chat model
    // with an explicit instruction keeps both, at similar latency with reasoning effort "minimal".
    // v0.2: the model id is plain ("google/gemini-3.5-flash"); the provider picks the route. The legacy "chat:" prefix
    // is still accepted (and stripped by the settings migration).
    public static let chatPrefix = "chat:"

    /// Dedicated speech-to-text models go to /audio/transcriptions; everything else is a chat model and gets the
    /// verbatim prompt. "chat:" forces the chat route.
    public static func usesChatRoute(_ model: String) -> Bool {
        if model.hasPrefix(chatPrefix) { return true }
        let m = model.lowercased()
        return !(m.contains("transcribe") || m.contains("whisper"))
    }

    /// Model id without the legacy "chat:" prefix.
    public static func plainModel(_ model: String) -> String {
        model.hasPrefix(chatPrefix) ? String(model.dropFirst(chatPrefix.count)) : model
    }

    /// The verbatim prompt + vocabulary + language hint. Shared with GoogleAIProvider so both routes behave the same.
    static func transcriptionPrompt(_ options: TranscribeOptions) -> String {
        var prompt = chatPrompt
        if !options.vocabulary.isEmpty { prompt += "\nPreferred spellings for names and terms: " + options.vocabulary.joined(separator: ", ") }
        if let l = options.languageHint, !l.isEmpty { prompt += "\nThe main language is \(l), but keep every other language exactly as spoken." }
        if let x = options.extraInstruction, !x.isEmpty { prompt += "\n" + x }
        return prompt
    }

    static let chatPrompt = """
    Transcribe the audio verbatim. The speaker mixes Uzbek, Russian and English, often within one sentence.
    Rules:
    - Uzbek MUST be written in the Latin alphabet (o', g', sh, ch, ng), NEVER in Cyrillic, even right after Russian.
    - Russian MUST be written in Cyrillic.
    - Use only Latin and Cyrillic letters. NEVER output Arabic, Persian, Korean, Chinese, Japanese, Thai or any other script;
      if a word is unclear, write the closest Uzbek, Russian or English word.
    - English words stay in English spelling, including when they carry Uzbek suffixes (e.g. tasklarini, deploy qildi).
    - Never translate, never transliterate, never summarise, never skip any language or sentence.
    - Never add timestamps, time codes, speaker labels or notes.
    - Keep the speaker's words and order. Add normal punctuation. Write numbers as digits.
    - Leave out hesitation sounds (a-a, e-e, m-m, э-э, ммм, uh, um); keep every real word.
    - Output ONLY the transcript, nothing else. If there is no speech, output nothing.
    """

    static func makeChatBody(_ audio: EncodedAudio, options: TranscribeOptions) throws -> Data {
        let prompt = transcriptionPrompt(options)
        let body: [String: Any] = [
            "model": plainModel(options.model),
            "temperature": 0,
            "reasoning": ["effort": "minimal"],
            "messages": [["role": "user", "content": [
                ["type": "text", "text": prompt],
                ["type": "input_audio", "input_audio": ["data": audio.data.base64EncodedString(), "format": audio.format]],
            ]]],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
    }

    struct ChatResponse: Decodable {
        struct Choice: Decodable { struct M: Decodable { var content: String? }; var message: M }
        struct U: Decodable { var promptTokens: Int?; var completionTokens: Int?; var totalTokens: Int?; var cost: Double? }
        var choices: [Choice]
        var usage: U?
    }

    static func decodeChat(_ data: Data) throws -> (text: String, usage: Usage?) {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let r = try d.decode(ChatResponse.self, from: data)
            let u = r.usage.map { Usage(inputTokens: $0.promptTokens, outputTokens: $0.completionTokens, totalTokens: $0.totalTokens, cost: $0.cost) }
            return ((r.choices.first?.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines), u)
        } catch {
            throw SoylaError.decode("\(error.localizedDescription) body: \(OpenRouterHTTP.bodyPrefix(data))")
        }
    }

    public func transcribe(_ audio: EncodedAudio, options: TranscribeOptions, timeline: RunTimeline) async throws -> TranscriptResult {
        let chat = Self.usesChatRoute(options.model)
        var plain = options; plain.model = Self.plainModel(options.model)
        let body = chat ? try Self.makeChatBody(audio, options: plain) : try Self.makeBody(audio, options: plain)
        let path = chat ? "/chat/completions" : "/audio/transcriptions"
        let req = try OpenRouterHTTP.request(path, method: "POST", apiKey: apiKey, body: body, timeout: options.timeoutSec, baseURL: baseURL)
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
        timeline.mark(.responseReceived)   // before the metrics wait (≤200 ms) so it never inflates latency
        timeline.net = MetricsCollector.net(from: await collector.waitForMetrics())
        guard let http = resp as? HTTPURLResponse else { throw SoylaError.decode("non-HTTP response") }
        guard http.statusCode == 200 else {
            throw SoylaError.http(status: http.statusCode, body: OpenRouterHTTP.bodyPrefix(data, redacting: apiKey))
        }
        let (text, usage) = chat ? try Self.decodeChat(data) : try Self.decode(data)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw SoylaError.emptyTranscript }
        var meta: [String: String] = ["http_status": "\(http.statusCode)", "provider": id]
        if let g = http.value(forHTTPHeaderField: "X-Generation-Id") { meta["generation_id"] = g }
        // Which upstream served it (OpenRouter's top-level "provider", e.g. "Google AI Studio" vs "Google" = Vertex).
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let up = root["provider"] as? String { meta["upstream"] = up }
        return TranscriptResult(text: text, language: options.languageHint, usage: usage, providerMeta: meta)
    }

    // MARK: models

    private struct Cache: Codable { var fetchedAt: Date; var models: [ModelInfo] }

    static func parseModels(_ data: Data) throws -> [ModelInfo] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["data"] as? [[String: Any]] else { throw SoylaError.decode("models: unexpected shape") }
        return arr.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let p = m["pricing"] as? [String: Any]
            func s(_ v: Any?) -> String? { v.map { "\($0)" } }
            return ModelInfo(id: id, name: m["name"] as? String, promptPrice: s(p?["prompt"]), completionPrice: s(p?["completion"]))
        }
    }

    /// GET /api/v1/models?output_modalities=transcription, cached 24 h at SoylaPaths.modelsCache.
    public static func listTranscriptionModels(apiKey: String, forceRefresh: Bool = false) async throws -> [ModelInfo] {
        let cacheURL = SoylaPaths.modelsCache
        if !forceRefresh, let d = try? Data(contentsOf: cacheURL) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            if let c = try? dec.decode(Cache.self, from: d), Date().timeIntervalSince(c.fetchedAt) < 24 * 3600 {
                return c.models
            }
        }
        let req = try OpenRouterHTTP.request("/models?output_modalities=transcription", method: "GET", apiKey: apiKey, timeout: 20)
        let (data, resp) = try await OpenRouterHTTP.makeSession(timeout: 20).data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SoylaError.decode("non-HTTP response") }
        guard http.statusCode == 200 else { throw SoylaError.http(status: http.statusCode, body: OpenRouterHTTP.bodyPrefix(data, redacting: apiKey)) }
        let models = try parseModels(data)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let out = try? enc.encode(Cache(fetchedAt: Date(), models: models)) {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? out.write(to: cacheURL, options: .atomic)
        }
        return models
    }
}

public struct ModelInfo: Codable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var promptPrice: String?       // per token or per second, as OpenRouter reports
    public var completionPrice: String?
    public init(id: String, name: String? = nil, promptPrice: String? = nil, completionPrice: String? = nil) {
        self.id = id; self.name = name; self.promptPrice = promptPrice; self.completionPrice = completionPrice
    }
}
