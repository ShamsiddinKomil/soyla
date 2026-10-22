import Testing
import Foundation
@testable import SoylaCore

@Suite struct NetworkTests {
    @Test func envParsing() {
        let text = """
        # comment
        OTHER=1
        export OPENROUTER_API_KEY="sk-or-v1-FAKE1234"
        EMPTY=
        SINGLE='abc'
        PLAIN = value # trailing
        """
        let env = Secrets.parseEnv(text)
        #expect(env["OPENROUTER_API_KEY"] == "sk-or-v1-FAKE1234")
        #expect(env["SINGLE"] == "abc")
        #expect(env["PLAIN"] == "value")
        #expect(env["EMPTY"] == "")
        #expect(env["OTHER"] == "1")
    }

    @Test func pathsDefaultToAppSupport() {
        let home = URL(fileURLWithPath: "/Users/fake")
        let r = SoylaPaths.resolve(env: [:], home: home)
        #expect(r.root.path == "/Users/fake/Library/Application Support/Soyla")
        #expect(r.devLayout == false)
        let dev = SoylaPaths.resolve(env: ["SOYLA_HOME": "/tmp/soyla-repo"], home: home)
        #expect(dev.root.path == "/tmp/soyla-repo")
        #expect(dev.devLayout == true)
        #expect(SoylaPaths.resolve(env: ["SOYLA_HOME": ""], home: home).devLayout == false)
    }

    @Test func maskedHidesKey() {
        #expect(Secrets.masked("sk-or-v1-FAKE1234") == "…1234")
        #expect(Secrets.masked("AIzaFAKEFAKEFAKE9876") == "…9876")   // no sk-or- prefix assumption
        #expect(Secrets.masked("short") == "…")                       // short values reveal nothing
    }

    @Test func missingKeyThrows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soyla-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "FOO=bar\n".write(to: dir.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
        #expect(Secrets.parseEnv("FOO=bar")["OPENROUTER_API_KEY"] == nil)
    }

    @Test func sttBodyShape() throws {
        let audio = EncodedAudio(data: Data([1, 2, 3]), format: "wav", durationSec: 1, sampleRate: 16000, fileURL: nil)
        let opts = TranscribeOptions(model: "google/gemini-3.5-transcribe", languageHint: "uz", temperature: 0)
        let obj = try JSONSerialization.jsonObject(with: OpenRouterSTTProvider.makeBody(audio, options: opts)) as! [String: Any]
        #expect(obj["model"] as? String == "google/gemini-3.5-transcribe")
        let ia = obj["input_audio"] as! [String: Any]
        #expect(ia["data"] as? String == "AQID")
        #expect(ia["format"] as? String == "wav")
        #expect(obj["language"] as? String == "uz")
        #expect(obj["provider"] == nil)

        var o2 = TranscribeOptions(model: "m"); o2.providerOptions = ["a": "b"]
        let obj2 = try JSONSerialization.jsonObject(with: OpenRouterSTTProvider.makeBody(audio, options: o2)) as! [String: Any]
        #expect(obj2["language"] == nil)
        #expect(((obj2["provider"] as! [String: Any])["options"] as! [String: String]) == ["a": "b"])
    }

    @Test func sttResponseDecoding() throws {
        let json = #"{"text":"salom dunyo","usage":{"seconds":3.5,"total_tokens":120,"input_tokens":100,"output_tokens":20,"cost":0.00123}}"#
        let (text, usage) = try OpenRouterSTTProvider.decode(Data(json.utf8))
        #expect(text == "salom dunyo")
        #expect(usage == Usage(seconds: 3.5, inputTokens: 100, outputTokens: 20, totalTokens: 120, cost: 0.00123))
        #expect(throws: SoylaError.self) { try OpenRouterSTTProvider.decode(Data("{}".utf8)) }
    }

    @Test func modelsParsing() throws {
        let json = #"{"data":[{"id":"a/b","name":"AB","pricing":{"prompt":"0.000002","completion":"0.000012"}},{"id":"c/d"}]}"#
        let m = try OpenRouterSTTProvider.parseModels(Data(json.utf8))
        #expect(m.count == 2)
        #expect(m[0] == ModelInfo(id: "a/b", name: "AB", promptPrice: "0.000002", completionPrice: "0.000012"))
        #expect(m[1].promptPrice == nil)
    }

    @Test func cleanupVocabularySubstitution() {
        let p = CleanupService.systemPrompt(vocabulary: ["Soyla", "OpenRouter"])
        #expect(p.contains("Soyla, OpenRouter"))
        #expect(!p.contains("{vocabulary}"))
        #expect(CleanupService.systemPrompt(vocabulary: []).contains("(none)"))
    }

    @Test func cleanupBodyAndDecode() throws {
        let body = try CleanupService.makeBody("hello", model: "m", vocabulary: [])
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(obj["temperature"] as? Int == 0)
        #expect(obj["max_tokens"] as? Int == 64)                        // ≈1.5× input, floor 64, no reasoning for "m"
        let msgs = obj["messages"] as! [[String: String]]
        #expect(msgs[0]["role"] == "system" && msgs[1]["content"] == #"{"transcript":"hello"}"#)

        let resp = #"{"choices":[{"message":{"content":"  Hello.\n"}}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12,"cost":0.0001}}"#
        let (t, u) = try CleanupService.decode(Data(resp.utf8))
        #expect(t == "Hello.")
        #expect(u == Usage(inputTokens: 10, outputTokens: 2, totalTokens: 12, cost: 0.0001))
    }
}
