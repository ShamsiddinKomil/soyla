import Foundation

/// Gemini Live (AI Studio key) push-to-talk streaming transcription, used as a LIVE PREVIEW while the user speaks.
/// The pasted text still comes from the batch route: gemini-3.5-transcribe-live decodes each utterance in one language
/// and drops Uzbek↔Russian switches in its final (verified 2026-10-15, PLAN §13), but its interim text appears within
/// ~2–3 s of speaking and keeps updating, which is what the pill needs.
///
/// Protocol (docs: ai.google.dev/gemini-api/docs/live-api/live-transcribe):
///   setup { model, generationConfig{responseModalities:[TEXT]}, inputAudioTranscription{languageCodes, customVocabulary?},
///           realtimeInputConfig{automaticActivityDetection{disabled:true}} }  → setupComplete
///   realtimeInput{activityStart} → realtimeInput{audio{data: base64 pcm16 16k, mimeType}}… → realtimeInput{activityEnd}
///   serverContent.interimInputTranscription.text (speculative, cumulative) / serverContent.inputTranscription.text (final)
///
/// SAFETY (unchecked Sendable): every mutable field is confined to the serial `queue`. Not an actor because the
/// recorder's audio thread calls `feedSync` synchronously (it cannot await).
/// Knobs for `soyla live-test` experiments (2026-10-16: can Live produce the pasted text?). `.app` = what the app uses.
public struct LiveConfig: Sendable {
    public var model = GeminiLiveProvider.model
    /// nil = from the language hint (`languageCodes(_:)`); [] = the model's own auto-detect.
    public var languageCodes: [String]?
    /// false = push-to-talk (activityStart/End, the app); true = server VAD, `audioStreamEnd` at release.
    public var autoVAD = false
    public var silenceMs: Int?
    /// "VERBATIM" | "SMART" (inputAudioTranscription.mode); nil = server default.
    public var mode: String?
    /// For general Live models: a system instruction makes the model's own reply the transcript.
    public var systemInstruction: String?
    public static let app = LiveConfig()
    public init() {}
}

public final class GeminiLiveProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    public let id = "gemini/gemini-3.5-transcribe-live"
    public static let model = "models/gemini-3.5-transcribe-live"

    private let apiKey: String
    private let config: LiveConfig
    private var modelText = ""                                   // general models: serverContent.modelTurn text
    private var turnComplete = false
    private var lastFinalAt: Date?
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private let queue = DispatchQueue(label: "soyla.live")       // serialises all socket state
    private var ready = false
    private var pending: [String] = []                           // messages queued before setupComplete
    private var finals: [String] = []
    private var closed = false
    private var continuation: AsyncStream<String>.Continuation?
    public let partials: AsyncStream<String>

    /// Timing for the run log (ms since startSession / since activityEnd). Read through `queue` (written on it).
    public var setupMs: Double? { queue.sync { _setupMs } }
    public var firstInterimMs: Double? { queue.sync { _firstInterimMs } }
    public var releaseToFinalMs: Double? { queue.sync { _releaseToFinalMs } }
    private var _setupMs: Double?
    private var _firstInterimMs: Double?
    private var _releaseToFinalMs: Double?
    private var t0 = Date()
    private var tEnd: Date?
    private var lastPartial = ""

    public init(apiKey: String, config: LiveConfig = .app) {
        self.apiKey = apiKey
        self.config = config
        let c = URLSessionConfiguration.ephemeral           // never cache anything carrying the key
        c.urlCache = nil
        // Same redirect refusal as every key-carrying session: a 3xx must never take x-goog-api-key elsewhere.
        self.session = URLSession(configuration: c, delegate: MetricsCollector(), delegateQueue: nil)
        var cont: AsyncStream<String>.Continuation?
        self.partials = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func startSession(options: TranscribeOptions) async throws {
        let request = Self.makeRequest(apiKey: apiKey)
        var transcription: [String: Any] = ["languageCodes": config.languageCodes ?? Self.languageCodes(options.languageHint)]
        if !options.vocabulary.isEmpty { transcription["customVocabulary"] = Array(options.vocabulary.prefix(100)) }
        if let m = config.mode { transcription["mode"] = m }
        var vad: [String: Any] = ["disabled": !config.autoVAD]
        if config.autoVAD, let ms = config.silenceMs { vad["silenceDurationMs"] = ms }
        var body: [String: Any] = [
            "model": config.model,
            "generationConfig": ["responseModalities": ["TEXT"]],
            "inputAudioTranscription": transcription,
            "realtimeInputConfig": ["automaticActivityDetection": vad],
        ]
        if let s = config.systemInstruction { body["systemInstruction"] = ["parts": [["text": s]]] }
        let setup: [String: Any] = ["setup": body]
        let setupJSON = String(decoding: try JSONSerialization.data(withJSONObject: setup), as: UTF8.self)
        queue.sync {
            t0 = Date()
            let t = session.webSocketTask(with: request)
            task = t
            t.resume()
            t.send(.string(setupJSON)) { [weak self] err in if let err { self?.fail("setup send: \(err.localizedDescription)") } }
            receive()
        }
    }

    /// The key travels in the `x-goog-api-key` header (as the official google-genai SDK does for Live), never in the
    /// URL, so no error or log line that prints the URL can leak it (review R1).
    static func makeRequest(apiKey: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!)
        r.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return r
    }

    /// "uz" → ["uz-UZ"]. nil/auto → ["uz-UZ", "ru-RU"]: with no hint the Live model's auto-detect locked onto Czech
    /// on a real Uzbek clip and then stopped emitting text (2026-10-15), so the preview always hints the owner's languages.
    static func languageCodes(_ hint: String?) -> [String] {
        switch hint?.lowercased() {
        case nil, "", "auto": return ["uz-UZ", "ru-RU"]
        case "uz": return ["uz-UZ"]
        case "ru": return ["ru-RU"]
        case "en": return ["en-US"]
        case let h?: return [h]
        }
    }

    public func activityStart() async throws {
        guard !config.autoVAD else { return }                    // the API rejects activity signals under server VAD
        enqueue(["realtimeInput": ["activityStart": [String: Any]()]])
    }

    public func feed(pcm16: Data) async throws { feedSync(pcm16) }

    /// Non-async variant for the recorder's audio-thread callback.
    public func feedSync(_ pcm16: Data) {
        enqueue(["realtimeInput": ["audio": ["data": pcm16.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]])
    }

    public func activityEnd() async throws {
        queue.sync { tEnd = Date() }
        enqueue(["realtimeInput": config.autoVAD ? ["audioStreamEnd": true] : ["activityEnd": [String: Any]()]])
    }

    /// Final text if one arrived (waits up to `waitMs`), else the latest interim. Closes the socket.
    public func finish() async throws -> TranscriptResult { try await finish(waitMs: 800) }

    public func finish(waitMs: Int) async throws -> TranscriptResult {
        let deadline = Date().addingTimeInterval(Double(waitMs) / 1000)
        while Date() < deadline, queue.sync(execute: { !closed && !doneLocked() }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let (text, isFinal) = queue.sync { () -> (String, Bool) in
            if config.systemInstruction != nil, !modelText.isEmpty { return (modelText.trimmingCharacters(in: .whitespacesAndNewlines), turnComplete) }
            return finals.isEmpty ? (lastPartial, false) : (finals.joined(separator: " "), true)
        }
        close()
        return TranscriptResult(text: text, providerMeta: ["live_final": isFinal ? "1" : "0"])
    }

    public func close() {
        queue.sync {
            guard !closed else { return }
            closed = true
            task?.cancel(with: .normalClosure, reason: nil)
            continuation?.finish()
        }
    }

    // MARK: internals (on `queue`)

    /// Push-to-talk: the first final. Server VAD emits several finals, so wait for a 1 s lull after the last one.
    /// A general model is done at turnComplete.
    private func doneLocked() -> Bool {
        if config.systemInstruction != nil { return turnComplete }
        if !config.autoVAD { return !finals.isEmpty }
        guard let last = lastFinalAt, let e = tEnd, last > e || Date().timeIntervalSince(e) > 1 else { return false }
        return Date().timeIntervalSince(last) > 1
    }

    private func enqueue(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let s = String(decoding: data, as: UTF8.self)
        queue.async { [self] in
            guard !closed, let task else { return }
            if ready { sent += 1; task.send(.string(s)) { [weak self] err in if let err { self?.sendErrors += 1; self?.fail("send: \(err.localizedDescription)") } } }
            else { pending.append(s) }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                if Self.debug { Log.info("live rx failure: \((err as NSError).code) closeCode=\(self.task?.closeCode.rawValue ?? -1) reason=\(self.task?.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "-")") }
                self.fail("receive: \(err.localizedDescription)")
            case .success(let msg):
                let data: Data
                switch msg {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: data = Data()
                }
                self.queue.async { self.handle(data); if !self.closed { self.receive() } }
            }
        }
    }

    static let debug = DevOverrides.environment["SOYLA_LIVE_DEBUG"] != nil   // logs server messages: dev only
    private var sent = 0, sendErrors = 0

    private func handle(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if Self.debug { Log.info("live rx non-JSON \(data.count) bytes") }; return
        }
        if Self.debug { Log.info("live rx \(obj.keys.sorted()) sc=\((obj["serverContent"] as? [String: Any])?.keys.sorted() ?? []) sent=\(sent) sendErr=\(sendErrors)") }
        if obj["setupComplete"] != nil {
            ready = true
            _setupMs = Date().timeIntervalSince(t0) * 1000
            for s in pending { task?.send(.string(s)) { _ in } }
            pending.removeAll()
            return
        }
        if let err = obj["error"] { fail("server: \(String(describing: err).prefix(200))"); return }
        guard let sc = obj["serverContent"] as? [String: Any] else { return }
        handleModelTurn(sc)
        if let t = (sc["interimInputTranscription"] as? [String: Any])?["text"] as? String, !t.isEmpty {
            if _firstInterimMs == nil { _firstInterimMs = Date().timeIntervalSince(t0) * 1000 }
            lastPartial = t.trimmingCharacters(in: .whitespaces)
            continuation?.yield(finals.isEmpty ? lastPartial : finals.joined(separator: " ") + " " + lastPartial)
        }
        if let t = (sc["inputTranscription"] as? [String: Any])?["text"] as? String, !t.isEmpty {
            finals.append(t.trimmingCharacters(in: .whitespaces))
            lastFinalAt = Date()
            if let e = tEnd, _releaseToFinalMs == nil { _releaseToFinalMs = Date().timeIntervalSince(e) * 1000 }
            continuation?.yield(finals.joined(separator: " "))
        }
    }

    /// General Live models (`--sys-transcribe`): the reply text is the transcript; turnComplete ends it.
    private func handleModelTurn(_ sc: [String: Any]) {
        if let parts = (sc["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] {
            for p in parts { if let t = p["text"] as? String { modelText += t } }
            if let e = tEnd, _releaseToFinalMs == nil, !modelText.isEmpty { _releaseToFinalMs = Date().timeIntervalSince(e) * 1000 }
        }
        if sc["turnComplete"] as? Bool == true { turnComplete = true }
    }

    private func fail(_ msg: String) {
        queue.async { [self] in
            // A receive/send error after our own close() is the socket going away as asked: not worth a log line
            // (it used to log "Socket is not connected" after every Live run, and "cancelled" after every tap).
            guard !closed else { return }
            Log.info("live: \(msg)")
            closed = true
            continuation?.finish()
        }
    }
}
