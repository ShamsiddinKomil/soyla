import Testing
import Foundation
@testable import SoylaCore

/// F-01 (flow audit 2026-10-19): a History retry that fails must never wipe a row that already has text.
@Suite("Retry keeps a good History row")
struct RetryMergeTests {
    private func rec(_ status: RunStatus, raw: String? = nil, clean: String? = nil, app: String? = nil, error: String? = nil) -> RunRecord {
        var r = RunRecord(runId: "r1", ts: "2026-10-19T17:04:13.901Z", source: "live", phraseId: nil, model: "fake/model", cleanup: false,
                          cleanupModel: nil, languageHint: nil, prewarm: false,
                          audio: .init(format: "wav", bytes: 10, b64Bytes: 16, durationSec: 60, sampleRate: 16000, file: "rec.wav"),
                          timelineMs: [:], net: nil, usage: nil, cleanupUsage: nil, rawText: raw, cleanText: clean, error: error,
                          providerMeta: nil, status: status)
        r.targetApp = app
        return r
    }

    @Test func failedRetryOfAGoodRowKeepsIt() {
        let old = rec(.ok, raw: "FAKE old words", app: "FakeApp")
        for status in [RunStatus.failed, .cancelled] {
            #expect(RetryMerge.row(existing: old, attempt: rec(status, error: "API key not found")) == nil)
        }
    }

    @Test func failedRetryOfAFailedRowUpdatesTheErrorButKeepsTheApp() {
        let old = rec(.failed, app: "FakeApp", error: "offline")
        let new = RetryMerge.row(existing: old, attempt: rec(.failed, error: "API key not found"))
        #expect(new?.error == "API key not found")
        #expect(new?.targetApp == "FakeApp")
    }

    @Test func successfulRetryReplacesTheTextAndKeepsTheApp() {
        let old = rec(.ok, raw: "FAKE old words", app: "FakeApp")
        let new = RetryMerge.row(existing: old, attempt: rec(.ok, raw: "FAKE new words"))
        #expect(new?.rawText == "FAKE new words")
        #expect(new?.targetApp == "FakeApp")
    }

    @Test func cleanTextAloneCountsAsText() {
        let old = rec(.ok, raw: "", clean: "FAKE cleaned")
        #expect(RetryMerge.row(existing: old, attempt: rec(.failed, error: "x")) == nil)
    }

    @Test func noExistingRowWritesTheAttempt() {
        #expect(RetryMerge.row(existing: nil, attempt: rec(.failed, error: "x"))?.error == "x")
    }

    @Test func failedRetryLeavesTheFileUntouched() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soyla-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("runs.jsonl")
        try RunLog.append(rec(.ok, raw: "FAKE old words", app: "FakeApp"), to: log)
        try RetryMerge.persist(rec(.failed, error: "API key not found"), in: log)
        let rows = try RunLog.readAll(from: log)
        #expect(rows.count == 1)
        #expect(rows.first?.rawText == "FAKE old words")
        #expect(rows.first?.targetApp == "FakeApp")
        #expect(rows.first?.status == .ok)
    }
}
