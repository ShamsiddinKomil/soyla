import Testing
import Foundation
@testable import SoylaCore

@Suite struct GoogleAITests {
    let audio = EncodedAudio(data: Data([1, 2, 3]), format: "wav", durationSec: 1, sampleRate: 16000, fileURL: nil)

    @Test func sttBodyShape() throws {
        var opts = TranscribeOptions(model: "gemini-3.5-flash", languageHint: "uz")
        opts.vocabulary = ["Soyla"]
        let obj = try JSONSerialization.jsonObject(with: GoogleAIProvider.makeBody(audio, options: opts)) as! [String: Any]
        let contents = obj["contents"] as! [[String: Any]]
        #expect(contents.count == 1)
        let parts = contents[0]["parts"] as! [[String: Any]]
        #expect(parts.count == 2)
        let prompt = parts[0]["text"] as! String
        #expect(prompt.hasPrefix(OpenRouterSTTProvider.chatPrompt))       // same verbatim prompt as the OpenRouter route
        #expect(prompt.contains("Soyla") && prompt.contains("main language is uz"))
        let inline = parts[1]["inlineData"] as! [String: String]
        #expect(inline == ["mimeType": "audio/wav", "data": "AQID"])
        let gen = obj["generationConfig"] as! [String: Any]
        #expect(gen["temperature"] as? Int == 0)
        #expect((gen["thinkingConfig"] as! [String: String]) == ["thinkingLevel": "MINIMAL"])
        #expect(obj["model"] == nil)   // model goes in the URL
    }

    @Test func sameVerbatimPromptBothRoutes() throws {
        var opts = TranscribeOptions(model: "google/gemini-3.5-flash", languageHint: "ru")
        opts.vocabulary = ["X"]
        let or = try JSONSerialization.jsonObject(with: OpenRouterSTTProvider.makeChatBody(audio, options: opts)) as! [String: Any]
        let msg = (or["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        let g = try JSONSerialization.jsonObject(with: GoogleAIProvider.makeBody(audio, options: opts)) as! [String: Any]
        let gp = ((g["contents"] as! [[String: Any]])[0]["parts"] as! [[String: Any]])[0]["text"] as! String
        #expect(msg[0]["text"] as! String == gp)
        #expect(or["model"] as? String == "google/gemini-3.5-flash")
    }

    @Test func urlAndHeaderNeverCarryKeyInURL() {
        let url = GoogleAIHTTP.url(model: "google/gemini-3.5-flash")
        #expect(url.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent")
        let r = GoogleAIHTTP.request(url: url, method: "POST", apiKey: "AIza-FAKE-0000", body: Data("{}".utf8))
        #expect(r.value(forHTTPHeaderField: "x-goog-api-key") == "AIza-FAKE-0000")
        #expect(r.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(!(r.url?.absoluteString.contains("FAKE") ?? true))
        #expect(GoogleAIHTTP.modelId("chat:google/gemini-3.5-flash") == "gemini-3.5-flash")
        #expect(GoogleAIHTTP.modelId("models/gemini-3.5-flash-lite") == "gemini-3.5-flash-lite")
    }

    @Test func thinkingConfigPerModel() {
        #expect(GoogleAIHTTP.thinkingConfig(for: "gemini-3.5-flash-lite")?["thinkingLevel"] as? String == "MINIMAL")
        #expect(GoogleAIHTTP.thinkingConfig(for: "gemini-3-pro-preview")?["thinkingLevel"] as? String == "LOW")
        #expect(GoogleAIHTTP.thinkingConfig(for: "gemini-2.5-flash") == nil)   // thinkingLevel errors on pre-3 models
        #expect(GoogleAIHTTP.thinkingConfig(for: "gemma-3") == nil)
    }

    @Test func responseDecoding() throws {
        let json = #"""
        {"candidates":[{"content":{"role":"model","parts":[{"text":"hidden","thought":true},{"text":" Salom, "},{"text":"как дела?\n"}]},
          "finishReason":"STOP","index":0}],
         "usageMetadata":{"promptTokenCount":120,"candidatesTokenCount":9,"thoughtsTokenCount":3,"totalTokenCount":132},
         "modelVersion":"gemini-3.5-flash"}
        """#
        let (text, usage, finish) = try GoogleAIHTTP.decode(Data(json.utf8))
        #expect(text == "Salom, как дела?")
        #expect(usage == Usage(inputTokens: 120, outputTokens: 12, totalTokens: 132, cost: nil))
        #expect(finish == "STOP")
    }

    @Test func emptyAndBlockedDecodeToEmptyText() throws {
        let empty = #"{"candidates":[{"content":{"parts":[{"text":"  "}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":5,"totalTokenCount":5}}"#
        let e = try GoogleAIHTTP.decode(Data(empty.utf8))
        #expect(e.text.isEmpty)
        #expect(e.usage?.outputTokens == nil)
        let blocked = #"{"promptFeedback":{"blockReason":"SAFETY"}}"#
        let b = try GoogleAIHTTP.decode(Data(blocked.utf8))
        #expect(b.text.isEmpty && b.finishReason == "BLOCKED_SAFETY")
        #expect(throws: SoylaError.self) { try GoogleAIHTTP.decode(Data("[1]".utf8)) }
    }

    @Test func badKeyMapsTo401() {
        let body = #"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#
        if case .http(let s, _) = GoogleAIHTTP.httpError(status: 400, data: Data(body.utf8)) { #expect(s == 401) } else { Issue.record("not http") }
        if case .http(let s, _) = GoogleAIHTTP.httpError(status: 400, data: Data(#"{"error":{"message":"bad audio"}}"#.utf8)) { #expect(s == 400) } else { Issue.record("not http") }
        if case .http(let s, _) = GoogleAIHTTP.httpError(status: 429, data: Data()) { #expect(s == 429) } else { Issue.record("not http") }
    }

    @Test func cleanupGoogleBody() throws {
        let obj = try JSONSerialization.jsonObject(with: CleanupService.makeGoogleBody("salom", model: "gemini-3.5-flash", vocabulary: ["Soyla"])) as! [String: Any]
        let sys = ((obj["systemInstruction"] as! [String: Any])["parts"] as! [[String: String]])[0]["text"]!
        #expect(sys == CleanupService.systemPrompt(vocabulary: ["Soyla"]))
        let parts = (obj["contents"] as! [[String: Any]])[0]["parts"] as! [[String: String]]
        #expect(parts == [["text": #"{"transcript":"salom"}"#]])
        let gen = obj["generationConfig"] as! [String: Any]
        #expect(gen["maxOutputTokens"] as? Int == 64 + CleanupService.reasoningHeadroom)
        #expect((gen["thinkingConfig"] as! [String: String])["thinkingLevel"] == "MINIMAL")
    }

    @Test func openRouterRouteFromPlainId() throws {
        #expect(OpenRouterSTTProvider.usesChatRoute("google/gemini-3.5-flash"))
        #expect(OpenRouterSTTProvider.usesChatRoute("chat:google/gemini-3.5-transcribe"))
        #expect(!OpenRouterSTTProvider.usesChatRoute("google/gemini-3.5-transcribe"))
        #expect(!OpenRouterSTTProvider.usesChatRoute("openai/whisper-large-v3"))
        let r = try OpenRouterHTTP.request("/chat/completions", method: "POST", apiKey: "", baseURL: "http://localhost:8080/v1/")
        #expect(r.url?.absoluteString == "http://localhost:8080/v1/chat/completions")
        #expect(r.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func providerKindDefaultsAndInference() {
        #expect(ProviderKind.openRouter.defaultSTTModel == "google/gemini-3.5-flash")
        #expect(ProviderKind.google.defaultSTTModel == "gemini-3.5-flash")
        #expect(ProviderKind.inferred(fromModel: "chat:google/gemini-3.5-flash") == .openRouter)
        #expect(ProviderKind.inferred(fromModel: "gemini-3.5-flash") == .google)
        #expect(ReplayCLI.parseProvider("google") == .google)
        #expect(ReplayCLI.parseProvider("OpenRouter") == .openRouter)
        #expect(ReplayCLI.parseProvider("nope") == nil)
        #expect(throws: SoylaError.self) { try ProviderFactory.customBase("  ") }
    }

    @Test func v01BlobMigratesChatPrefix() throws {
        let v01 = #"{"sttModel":"chat:google/gemini-3.5-flash","cleanupModel":"google/gemini-3.5-flash","hotkey":"rightOption"}"#
        var s = try JSONDecoder().decode(Settings.self, from: Data(v01.utf8))
        #expect(s.provider == .openRouter)
        #expect(s.customBaseURL == nil)
        #expect(Settings.migrate(&s))
        #expect(s.sttModel == "google/gemini-3.5-flash")
        #expect(s.hotkey == .rightOption)
        #expect(!Settings.migrate(&s))   // idempotent

        let future = #"{"sttModel":"x/y","provider":"somethingNew","customBaseURL":"http://h/v1"}"#
        let f = try JSONDecoder().decode(Settings.self, from: Data(future.utf8))
        #expect(f.provider == .openRouter && f.customBaseURL == "http://h/v1")
        let g = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode({ var t = Settings(); t.provider = .google; return t }()))
        #expect(g.provider == .google)
    }

    @Test func storeMigrationPersists() throws {
        let suite = "ai.soyla.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { dropTestDomain(suite) }
        d.set(Data(#"{"sttModel":"chat:google/gemini-3.5-flash"}"#.utf8), forKey: "settings.v1")
        let store = SettingsStore(defaults: d)
        #expect(store.current.sttModel == "google/gemini-3.5-flash")
        let saved = try JSONDecoder().decode(Settings.self, from: d.data(forKey: "settings.v1")!)
        #expect(saved.sttModel == "google/gemini-3.5-flash")
    }
}
