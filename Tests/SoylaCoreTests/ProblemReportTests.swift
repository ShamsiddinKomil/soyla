import Testing
import Foundation
@testable import SoylaCore

@Suite struct ProblemReportTests {
    private let home = "/Users/fakeuser1234"

    private func run(raw: String? = "FAKE1234 dictated words", clean: String? = "FAKE1234 clean words") -> RunRecord {
        var r = RunRecord(runId: "2026-10-15T10-00-01-000", ts: "2026-10-15T10:00:01.000Z", source: "live", phraseId: nil,
                  model: "fake/model", cleanup: false, cleanupModel: nil, languageHint: nil, prewarm: true,
                  audio: .init(format: "flac", bytes: 10, b64Bytes: 16, durationSec: 3.25, sampleRate: 16000, file: "recordings/x.flac"),
                  timelineMs: ["stt_total": 812, "release_to_paste": 1034, "encode": 41], net: nil, usage: nil, cleanupUsage: nil,
                  rawText: raw, cleanText: clean, error: "failed near FAKE1234 dictated words in \(home)/x", providerMeta: ["k": "FAKE1234"],
                  status: .failed)
        r.targetApp = "Notes"
        return r
    }

    private func facts(lastRun: RunRecord? = nil, provider: String = "OpenRouter") -> ProblemReport.Facts {
        .init(appVersion: "0.3.0", macOS: "26.0", keyboardLayout: "com.apple.keylayout.US", hotkey: "fn (🌐)",
              inputDevice: "FAKE Mic", provider: provider, model: "google/gemini-3.5-flash",
              accessibility: true, inputMonitoring: false, microphone: "granted", secureInput: true, lastRun: lastRun)
    }

    @Test func containsTheListedFacts() {
        let out = ProblemReport.build(facts(lastRun: run()), home: home)
        for needle in ["Soyla version: 0.3.0", "macOS: 26.0", "com.apple.keylayout.US", "Hotkey: fn", "FAKE Mic",
                       "Provider: OpenRouter", "Model: google/gemini-3.5-flash", "Accessibility on",
                       "Input Monitoring off", "Microphone granted", "Secure Input: on",
                       "Last run: failed, target app: Notes", "audio 3.2 s", "speech to text 812 ms",
                       "release to paste 1034 ms", "encode 41 ms"] {
            #expect(out.contains(needle), "missing \(needle)")
        }
    }

    @Test func providerFieldIsGeneric() {
        #expect(ProblemReport.build(facts(provider: "Some Future Engine"), home: home).contains("Provider: Some Future Engine"))
    }

    @Test func noLastRunSaysSo() {
        #expect(ProblemReport.build(facts(), home: home).contains("Last run: none yet"))
    }

    @Test func neverContainsTranscriptEvenWhenHistoryHasOne() {
        let out = ProblemReport.build(facts(lastRun: run()), home: home)
        #expect(!out.contains("FAKE1234"))
        #expect(!out.contains("dictated words"))
        #expect(!out.contains("clean words"))
        #expect(!out.contains("recordings/"))
        #expect(!out.contains("failed near"))
    }

    @Test func redactsHomePathKeysAndForbiddenStrings() {
        var f = facts(lastRun: run())
        f.inputDevice = "\(home)/Library/Mic sk-FAKE1234abcd AIzaFAKE1234abcdefgh"
        f.model = "model-" + String(repeating: "A1b2", count: 10)
        let out = ProblemReport.build(f, home: home)
        #expect(!out.contains(home))
        #expect(!out.contains("/Users/"))
        #expect(out.contains("~/Library/Mic"))
        for bad in ["sk-", "AIza", String(repeating: "A1b2", count: 10)] { #expect(!out.contains(bad), "leaked \(bad)") }
    }

    @Test func redactMasksEditedText() {
        let r = ProblemReport.redact("path /Users/fakeother/x key sk-FAKE1234 and \(home)/y", home: home)
        #expect(r == "path ~/x key [redacted] and ~/y")
    }

    @Test func issueURLPrefillsAndStaysUnderLimit() throws {
        let big = String(repeating: "line of facts here\n", count: 2000)
        let url = try #require(ProblemReport.issueURL(body: big, facts: facts()))
        #expect(url.absoluteString.count <= 7500)
        #expect(url.absoluteString.hasPrefix("https://github.com/\(ProblemReport.repo)/issues/new?template=bug.yml"))
        #expect(url.absoluteString.contains("[truncated]".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!) )
        let small = try #require(ProblemReport.issueURL(body: "Soyla version: 0.3.0\nA&B=C+D", facts: facts()))
        let items = URLComponents(url: small, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "body" }?.value == "Soyla version: 0.3.0\nA&B=C+D")
        #expect(items.first { $0.name == "version" }?.value == "0.3.0")
    }

    @Test func issueURLRedactsEditedBody() throws {
        let url = try #require(ProblemReport.issueURL(body: "key sk-FAKE1234 here", facts: facts()))
        #expect(!url.absoluteString.contains("sk-"))
    }
}
