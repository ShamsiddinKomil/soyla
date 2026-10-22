import Foundation
import Testing
@testable import SoylaCore

/// History holds transcripts and app.log holds diagnostics: both are private to the user (0600), the data folders
/// 0700 (re-applied at every launch, not only on creation), and app.log does not grow forever.
@Suite struct DataAtRestTests {
    func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("soyla-dar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func mode(_ u: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int) ?? -1 }
    func rec(_ id: String) -> RunRecord {
        RunRecord(runId: id, ts: "2026-10-16T10:00:00.000Z", source: "live", phraseId: nil, model: "fake/model", cleanup: false,
                  cleanupModel: nil, languageHint: nil, prewarm: false,
                  audio: .init(format: "wav", bytes: 10, b64Bytes: 16, durationSec: 1, sampleRate: 16000, file: nil),
                  timelineMs: [:], net: nil, usage: nil, cleanupUsage: nil, rawText: "FAKE words", cleanText: nil, error: nil,
                  providerMeta: nil, status: .ok)
    }

    @Test func historyIsOwnerOnly() throws {
        let log = try tmp().appendingPathComponent("runs.jsonl")
        try RunLog.append(rec("a"), to: log)
        #expect(try mode(log) == 0o600)
        _ = try RunLog.update(runId: "a", in: log) { $0.rawText = "FAKE edited" }
        #expect(try mode(log) == 0o600)   // the rewrite through a temp file keeps it private
    }

    @Test func tightenFixesExistingFolderAndFiles() throws {
        let d = try tmp()
        let f = d.appendingPathComponent("app.log")
        FileManager.default.createFile(atPath: f.path, contents: Data("x".utf8), attributes: [.posixPermissions: 0o644])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d.path)
        SoylaPaths.tighten(dirs: [d], files: [f, d.appendingPathComponent("missing.jsonl")])
        #expect(try mode(d) == 0o700)
        #expect(try mode(f) == 0o600)
    }

    @Test func appLogRotatesPastLimit() throws {
        let d = try tmp()
        let log = d.appendingPathComponent("app.log")
        FileManager.default.createFile(atPath: log.path, contents: Data(repeating: 0x41, count: 2048))
        #expect(SoylaPaths.rotateIfLarge(log, limit: 1024))
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("app.log.1").path))
        FileManager.default.createFile(atPath: log.path, contents: Data("small".utf8))
        #expect(!SoylaPaths.rotateIfLarge(log, limit: 1024))
    }
}
