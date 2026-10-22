import Testing
import Foundation
@testable import SoylaCore

@Suite struct RunLogTests {
    private func rec(_ n: Int) -> RunRecord {
        RunRecord(runId: "2026-10-15T10-00-0\(n)-000", ts: "2026-10-15T10:00:0\(n).000Z", source: "live", phraseId: n,
                  model: "fake/model", cleanup: n == 2, cleanupModel: nil, languageHint: nil, prewarm: true,
                  audio: .init(format: "wav", bytes: 10, b64Bytes: 16, durationSec: 0.1, sampleRate: 16000, file: nil),
                  timelineMs: ["stt_total": Double(n) * 100], net: .init(ttfb: 5, reused: true), usage: Usage(cost: 0.001),
                  cleanupUsage: nil, rawText: "fake text \(n)", cleanText: nil, error: nil, providerMeta: nil)
    }

    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("soyla-runlog-\(UUID().uuidString)/sub/runs.jsonl")
    }

    @Test func appendAndReadBack() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        try RunLog.append(rec(1), to: url)
        try RunLog.append(rec(2), to: url)
        let back = try RunLog.readAll(from: url)
        #expect(back == [rec(1), rec(2)])
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
        #expect(text.hasSuffix("\n"))
    }

    @Test func malformedLineSkipped() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        try RunLog.append(rec(1), to: url)
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd(); try h.write(contentsOf: Data("{not json\n".utf8)); try h.close()
        try RunLog.append(rec(3), to: url)
        #expect(try RunLog.readAll(from: url) == [rec(1), rec(3)])
    }

    @Test func missingFileIsEmpty() throws {
        #expect(try RunLog.readAll(from: tmpURL()).isEmpty)
    }
}
