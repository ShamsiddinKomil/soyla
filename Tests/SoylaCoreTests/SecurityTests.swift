import Testing
import Foundation
import Security
@testable import SoylaCore

/// v0.2 review fixes (R1 security, R3 code). Keys are obviously fake.
@Suite struct SecurityTests {
    let fakeKey = "AIzaFAKE-not-a-real-key-123"

    @Test func liveKeyGoesInHeaderNotURL() {
        let r = GeminiLiveProvider.makeRequest(apiKey: fakeKey)
        #expect(r.url?.absoluteString.contains(fakeKey) == false)
        #expect(r.url?.query == nil)
        #expect(r.value(forHTTPHeaderField: "x-goog-api-key") == fakeKey)
    }

    @Test func badCustomBaseNeverFallsBackToOpenRouter() {
        #expect(throws: SoylaError.self) {
            _ = try OpenRouterHTTP.request("/chat/completions", method: "POST", apiKey: "sk-FAKE", baseURL: "http://local host/v1")
        }
        #expect(throws: SoylaError.self) { _ = try OpenRouterHTTP.request("/models", method: "GET", apiKey: "", baseURL: "not a url") }
    }

    @Test func customBaseRequiresHTTPSExceptLocal() throws {
        #expect(try ProviderFactory.customBase("https://api.example.com/v1") == "https://api.example.com/v1")
        #expect(try ProviderFactory.customBase("http://localhost:8080/v1") == "http://localhost:8080/v1")
        #expect(try ProviderFactory.customBase("http://127.0.0.1:1234/v1") == "http://127.0.0.1:1234/v1")
        #expect(try ProviderFactory.customBase("http://[::1]:8080/v1") == "http://[::1]:8080/v1")
        #expect(try ProviderFactory.customBase("http://studio.local:8080/v1") == "http://studio.local:8080/v1")
        #expect(throws: SoylaError.self) { _ = try ProviderFactory.customBase("http://api.example.com/v1") }
        #expect(throws: SoylaError.self) { _ = try ProviderFactory.customBase("http://localhost.evil.com/v1") }
        #expect(throws: SoylaError.self) { _ = try ProviderFactory.customBase("ftp://localhost/v1") }
        #expect(throws: SoylaError.self) { _ = try ProviderFactory.customBase("https://exa mple.com/v1") }
    }

    @Test func sessionsRefuseRedirects() async {
        let session = OpenRouterHTTP.makeSession()
        #expect(session.delegate is MetricsCollector)
        let task = session.dataTask(with: URL(string: "https://openrouter.ai/api/v1/models")!)
        let resp = HTTPURLResponse(url: URL(string: "https://openrouter.ai/api/v1/models")!, statusCode: 302, httpVersion: nil,
                                   headerFields: ["Location": "https://elsewhere.example/"])!
        var followed: URLRequest? = URLRequest(url: URL(string: "https://placeholder.example/")!)
        MetricsCollector().urlSession(session, task: task, willPerformHTTPRedirection: resp,
                                      newRequest: URLRequest(url: URL(string: "https://elsewhere.example/")!)) { followed = $0 }
        #expect(followed == nil)
        task.cancel()
        session.invalidateAndCancel()
    }

    @Test func errorBodiesDropTheKeyAndLogSafeStripsThem() {
        let body = Data(#"{"error":"bad key \#(fakeKey) for project"}"#.utf8)
        let p = OpenRouterHTTP.bodyPrefix(body, redacting: fakeKey)
        #expect(!p.contains(fakeKey) && p.contains("[key]"))
        // A key straddling the 300-byte cut must not leak a fragment either.
        let long = Data((String(repeating: "x", count: 290) + fakeKey).utf8)
        #expect(!OpenRouterHTTP.bodyPrefix(long, redacting: fakeKey).contains("AIzaFAKE"))
        let e = GoogleAIHTTP.httpError(status: 403, data: body, apiKey: fakeKey)
        #expect(e.localizedDescription.contains("[key]") && !e.localizedDescription.contains(fakeKey))
        #expect(DictationPipeline.logSafe(e.localizedDescription) == "HTTP 403 [body omitted]")
    }

    @Test func keyCacheDoesNotCacheAKeychainError() {
        struct Locked: Error {}
        let c = KeyCache()
        var loads = 0
        #expect(c.value("k", load: { loads += 1; throw Locked() }) == nil)
        #expect(c.value("k", load: { loads += 1; return "sk-FAKE" }) == "sk-FAKE")   // retried once unlocked
        #expect(c.value("k", load: { loads += 1; return "other" }) == "sk-FAKE")     // now cached
        #expect(loads == 2)
        let n = KeyCache()
        #expect(n.value("k", load: { nil }) == nil)
        #expect(n.value("k", load: { "late" }) == nil)   // a real "not found" is cached
    }

    @Test func keyCacheNeverBlocksWhileTheLaunchReadWaits() {
        let c = KeyCache()
        c.begin("k")
        var loads = 0
        #expect(c.state("k") == .loading)
        #expect(c.value("k", load: { loads += 1; return "sk-FAKE" }) == nil)   // no second Keychain read meanwhile
        #expect(loads == 0)
        c.finish("k", load: { "sk-FAKE" })
        #expect(c.state("k") == .ready)
        #expect(c.value("k", load: { "other" }) == "sk-FAKE")
    }

    @Test func keyCacheRemembersDenyButASaveWins() {
        let c = KeyCache()
        c.begin("k")
        c.finish("k", load: { throw KeychainStore.Failure(op: "read", status: errSecUserCanceled) })
        #expect(c.state("k") == .denied)
        var loads = 0
        #expect(c.value("k", load: { loads += 1; return "sk-FAKE" }) == nil)   // Deny is not re-asked on every refresh
        #expect(loads == 0)
        c.set("k", "sk-NEW-FAKE")
        #expect(c.state("k") == .ready && c.value("k", load: { nil }) == "sk-NEW-FAKE")
        // A save during the launch read is not overwritten by the older Keychain value.
        let d = KeyCache()
        d.begin("k"); d.set("k", "sk-SAVED-FAKE")
        d.finish("k", load: { "sk-OLD-FAKE" })
        #expect(d.value("k", load: { nil }) == "sk-SAVED-FAKE")
    }

    @Test func keychainBlockedMapsToAPasswordCardNotKeyMissing() {
        let waiting = PillFailure.from(SoylaError.keychainBlocked(denied: false), stage: "transcribe")
        #expect(waiting.title == "Waiting for your Mac password" && waiting.canRetry && !waiting.openSettings)
        let denied = PillFailure.from(SoylaError.keychainBlocked(denied: true), stage: "transcribe")
        #expect(denied.title == "Soyla can't read your API key" && !denied.canRetry)
    }

    @Test @MainActor func appLogNamesInputKindNotDevice() {
        let inputs = [AudioDevices.Input(id: 1, name: "MacBook Pro Microphone", builtIn: true),
                      AudioDevices.Input(id: 2, name: "Fake Person's AirPods", builtIn: false)]
        #expect(DictationPipeline.logInput("MacBook Pro Microphone", inputs: inputs) == "builtIn")
        #expect(DictationPipeline.logInput("Fake Person's AirPods", inputs: inputs) == "external")
        #expect(DictationPipeline.logInput("Gone device", inputs: inputs) == "unknown")
        #expect(DictationPipeline.logInput(nil, inputs: inputs) == "unknown")
        var r = RunRecord(runId: "r", ts: "t", source: "live", phraseId: nil, model: "m", cleanup: false, cleanupModel: nil,
                          languageHint: nil, prewarm: false,
                          audio: .init(format: "wav", bytes: 0, b64Bytes: 0, durationSec: 1, sampleRate: 16000, file: nil),
                          timelineMs: [:], net: nil, usage: nil, cleanupUsage: nil, rawText: nil, cleanText: nil, error: nil,
                          providerMeta: ["input_device": "Fake Person's AirPods"], status: .ok)
        #expect(DictationPipeline.latencyLine(r).contains("Fake Person's AirPods"))
        #expect(!DictationPipeline.latencyLine(r, forLog: true).contains("AirPods"))
        r.providerMeta = nil
        #expect(DictationPipeline.latencyLine(r, forLog: true) == DictationPipeline.latencyLine(r))
    }

    @Test func unknownEnumValuesKeepTheOtherSettings() throws {
        let blob = #"{"sttModel":"x/y","audioFormat":"opus9","hotkey":"leftPinky","vocabulary":["Soyla"],"warnAtSec":42}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(blob.utf8))
        #expect(s.audioFormat == Settings().audioFormat)
        #expect(s.hotkey == Settings().hotkey)
        #expect(s.sttModel == "x/y" && s.vocabulary == ["Soyla"] && s.warnAtSec == 42)
    }

    @Test func versionIsRelease() { #expect(Soyla.version == "0.2.0") }
}
