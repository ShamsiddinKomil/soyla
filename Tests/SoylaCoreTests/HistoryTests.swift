import Testing
import Foundation
import AppKit
@testable import SoylaCore

/// F4: persist-first recording, crash repair, History status, RunLog update-in-place, retention, log hygiene.
@Suite struct HistoryTests {
    private func tmpDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("soyla-f4-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func pcm(_ bytes: Int, seed: UInt8 = 1) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: Int($0) &* 31 &+ Int(seed)) })
    }

    private func rec(_ id: String, status: RunStatus? = nil, raw: String? = "fake words", error: String? = nil, file: String? = nil) -> RunRecord {
        RunRecord(runId: id, ts: "2026-10-16T10:00:00.000Z", source: "live", phraseId: nil, model: "fake/model", cleanup: false,
                  cleanupModel: nil, languageHint: nil, prewarm: false,
                  audio: .init(format: "wav", bytes: 10, b64Bytes: 16, durationSec: 1, sampleRate: 16000, file: file),
                  timelineMs: [:], net: nil, usage: nil, cleanupUsage: nil, rawText: raw, cleanText: nil, error: error,
                  providerMeta: nil, status: status)
    }

    // MARK: WAV streamed while recording

    @Test func streamedWavFinishMatchesEncoder() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("r.wav")
        let w = try WAVStreamWriter(url: url)
        #expect(try Data(contentsOf: url) == WAVFile.header(dataBytes: 0))   // placeholder first
        let all = pcm(32_000 + 640)
        w.append(all.prefix(16_000)); w.append(all.subdata(in: 16_000..<32_000))
        #expect(WAVFile.needsRepair(at: url))                                   // sizes not patched yet
        try w.finish(pcm: all)                                                  // + the resampler tail
        w.append(pcm(100))                                                      // late chunk: ignored
        #expect(try Data(contentsOf: url) == Encoder.wav(pcm16: all))
        #expect(!WAVFile.needsRepair(at: url))
        #expect(try WAVFile.readPCM(at: url) == all)
    }

    @Test func crashedWavIsRepairedFromFileSize() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("r.wav")
        let w = try WAVStreamWriter(url: url)
        let a = pcm(8_000), b = pcm(4_001, seed: 7)                            // odd length: half sample dropped
        w.append(a); w.append(b)
        // "kill -9": no finish. The header still says 0 bytes.
        #expect(WAVFile.needsRepair(at: url))
        let n = try WAVFile.repairHeader(at: url)
        #expect(n == 12_000)
        let fixed = try Data(contentsOf: url)
        #expect(fixed.prefix(44) == Encoder.wav(pcm16: (a + b).prefix(12_000)).prefix(44))
        #expect(try WAVFile.readPCM(at: url) == (a + b).prefix(12_000))
        #expect(!WAVFile.needsRepair(at: url))
    }

    @Test func writerResetAndDiscard() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("r.wav")
        let w = try WAVStreamWriter(url: url)
        w.append(pcm(1000)); w.reset(); w.append(pcm(200, seed: 3))
        w.finishStreamed()
        #expect(try WAVFile.readPCM(at: url) == pcm(200, seed: 3))
        let u2 = dir.appendingPathComponent("d.wav")
        let w2 = try WAVStreamWriter(url: u2)
        w2.append(pcm(10)); w2.discard()
        #expect(!FileManager.default.fileExists(atPath: u2.path))
    }

    // MARK: launch-time repair

    @Test func launchRepairMarksInterrupted() throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(at: root) }
        let recs = root.appendingPathComponent("recordings"), log = root.appendingPathComponent("runs.jsonl")
        // 1: crashed mid-recording, no row yet.  2: crashed mid-request (pending row + finished WAV).
        // 3: crashed right at key-down (empty).  4: a normal finished run.  5: never-store crash in .tmp.
        let w1 = try WAVStreamWriter(url: recs.appendingPathComponent("run-1.wav")); w1.append(pcm(32_000))
        let w2 = try WAVStreamWriter(url: recs.appendingPathComponent("run-2.wav")); try w2.finish(pcm: pcm(6_400))
        _ = try WAVStreamWriter(url: recs.appendingPathComponent("run-3.wav"))
        let w4 = try WAVStreamWriter(url: recs.appendingPathComponent("run-4.wav")); try w4.finish(pcm: pcm(640))
        let w5 = try WAVStreamWriter(url: RecordingStore.url(runId: "run-5", retention: .neverStore, recordings: recs)); w5.append(pcm(3_200))
        try RunLog.append(rec("run-2", status: .pending, raw: nil, file: "recordings/run-2.wav"), to: log)
        try RunLog.append(rec("run-4", status: .ok), to: log)

        let marked = RecordingStore.repairInterrupted(recordings: recs, runsLog: log, root: root, model: "fake/model")
        #expect(Set(marked) == ["run-1", "run-2", "run-5"])
        let rows = try RunLog.readAll(from: log)
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.runId, $0) })
        #expect(byId["run-1"]?.status == .interrupted)
        #expect(byId["run-1"]?.audio.file == "recordings/run-1.wav")
        #expect(abs((byId["run-1"]?.audio.durationSec ?? 0) - 1.0) < 1e-9)
        #expect(byId["run-2"]?.status == .interrupted)
        #expect(byId["run-4"]?.status == .ok)
        #expect(byId["run-5"]?.status == .interrupted)
        #expect(byId["run-3"] == nil)
        #expect(!FileManager.default.fileExists(atPath: recs.appendingPathComponent("run-3.wav").path))
        #expect(!WAVFile.needsRepair(at: recs.appendingPathComponent("run-1.wav")))
        // Idempotent: a second launch changes nothing.
        #expect(RecordingStore.repairInterrupted(recordings: recs, runsLog: log, root: root, model: "fake/model").isEmpty)
        #expect(try RunLog.readAll(from: log).count == 4)
    }

    // MARK: RunLog update in place

    @Test func runLogUpdateInPlace() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("runs.jsonl")
        try RunLog.append(rec("a", status: .ok), to: url)
        try RunLog.append(rec("b", status: .pending, raw: nil), to: url)
        let h = try FileHandle(forWritingTo: url); try h.seekToEnd(); try h.write(contentsOf: Data("{not json\n".utf8)); try h.close()
        try RunLog.append(rec("c", status: .ok), to: url)

        let found = try RunLog.update(runId: "b", in: url) { r in r.status = .ok; r.rawText = "fake new words"; r.runId = "hijack" }
        #expect(found)
        let rows = try RunLog.readAll(from: url)
        #expect(rows.map(\.runId) == ["a", "b", "c"])                          // order kept, id never changes
        #expect(rows[1].status == .ok && rows[1].rawText == "fake new words")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("{not json\n"))                                  // malformed line kept verbatim
        #expect(text.split(separator: "\n").count == 4 && text.hasSuffix("\n"))
        #expect(try RunLog.update(runId: "zzz", in: url) { $0.status = .failed } == false)
        #expect(try RunLog.update(rec("c", status: .cancelled, error: "cancelled"), in: url))
        #expect(try RunLog.readAll(from: url).last?.status == .cancelled)
        // No temp files left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["runs.jsonl"])
        #expect(try RunLog.update(runId: "a", in: dir.appendingPathComponent("missing.jsonl")) { _ in } == false)
    }

    // MARK: status decoding

    @Test func statusDecodingIsTolerant() throws {
        func decode(_ extra: String) throws -> RunRecord {
            let json = #"{"run_id":"x","ts":"t","source":"live","model":"m","cleanup":false,"prewarm":true,"#
                + #""audio":{"format":"wav","bytes":1,"b64_bytes":4,"duration_sec":1,"sample_rate":16000},"timeline_ms":{},"#
                + #""app_version":"0.1.0""# + extra + "}"
            return try RunRecord.decoder.decode(RunRecord.self, from: Data(json.utf8))
        }
        #expect(try decode("").status == .ok)
        #expect(try decode(#","raw_text":"fake""#).status == .ok)
        #expect(try decode(#","error":"cancelled""#).status == .cancelled)
        #expect(try decode(#","error":"HTTP 500: x""#).status == .failed)
        #expect(try decode(#","raw_text":"fake","error":"cleanup: timeout""#).status == .ok)   // words arrived
        #expect(try decode(#","status":"interrupted""#).status == .interrupted)
        #expect(try decode(#","status":"from-the-future""#).status == .failed)
        // Round trip keeps an explicit status; it is written as "status".
        let r = rec("y", status: .pending, raw: nil)
        let data = try RunRecord.encoder.encode(r)
        #expect(String(decoding: data, as: UTF8.self).contains(#""status":"pending""#))
        #expect(try RunRecord.decoder.decode(RunRecord.self, from: data) == r)
    }

    // MARK: retention

    @Test func retentionSettings() throws {
        #expect(Settings().retention == .deleteAfter14Days)
        #expect(Settings().developerMode == false)
        let unknown = try JSONDecoder().decode(Settings.self, from: Data(#"{"retention":"deleteSometimes","developerMode":true}"#.utf8))
        #expect(unknown.retention == .deleteAfter14Days && unknown.developerMode)
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"retention":"keep"}"#.utf8))
        #expect(old.retention == .keep && old.developerMode == false)
        var s = Settings(); s.retention = .neverStore
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)).retention == .neverStore)
        #expect(Set(AudioRetention.allCases.map(\.rawValue)) == ["keep", "deleteAfterRun", "deleteAfter7Days", "deleteAfter14Days", "neverStore"])
        // Per-run deletion: a failed run always keeps its audio for Retry.
        #expect(DictationPipeline.deletesAudio(.neverStore, status: .ok))
        #expect(DictationPipeline.deletesAudio(.neverStore, status: .cancelled))
        #expect(!DictationPipeline.deletesAudio(.neverStore, status: .failed))
        #expect(DictationPipeline.deletesAudio(.deleteAfterRun, status: .ok))
        #expect(!DictationPipeline.deletesAudio(.deleteAfterRun, status: .failed))
        for r in [AudioRetention.keep, .deleteAfter7Days, .deleteAfter14Days] { #expect(!DictationPipeline.deletesAudio(r, status: .ok)) }
        #expect(RecordingStore.url(runId: "r", retention: .neverStore, recordings: URL(fileURLWithPath: "/x/recordings")).path == "/x/recordings/.tmp/r.wav")
        #expect(RecordingStore.url(runId: "r", retention: .keep, recordings: URL(fileURLWithPath: "/x/recordings")).path == "/x/recordings/r.wav")
    }

    @Test func retentionSweep() throws {
        let recs = tmpDir(); defer { try? FileManager.default.removeItem(at: recs) }
        let fm = FileManager.default
        let now = Date()
        func make(_ name: String, ageSec: TimeInterval) throws {
            let u = recs.appendingPathComponent(name)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1, 2]).write(to: u)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-ageSec)], ofItemAtPath: u.path)
        }
        func setup() throws {
            try make("old15d.wav", ageSec: 15 * 86400)
            try make("old8d.wav", ageSec: 8 * 86400)
            try make("fresh.wav", ageSec: 60)
            try make("protected.wav", ageSec: 30 * 86400)
            try make(".tmp/oldtmp.wav", ageSec: 1200)
            try make(".tmp/newtmp.wav", ageSec: 30)
        }
        func left() -> Set<String> {
            Set(((try? fm.contentsOfDirectory(atPath: recs.path)) ?? []).filter { $0 != ".tmp" }
                + ((try? fm.contentsOfDirectory(atPath: recs.appendingPathComponent(".tmp").path)) ?? []).map { ".tmp/" + $0 })
        }
        try setup()
        #expect(RecordingStore.sweep(recordings: recs, retention: .deleteAfter14Days, now: now, protect: ["protected"]) == 2)
        #expect(left() == ["old8d.wav", "fresh.wav", "protected.wav", ".tmp/newtmp.wav"])
        #expect(RecordingStore.sweep(recordings: recs, retention: .deleteAfter7Days, now: now) == 2)
        #expect(left() == ["fresh.wav", ".tmp/newtmp.wav"])
        try setup()
        #expect(RecordingStore.sweep(recordings: recs, retention: .keep, now: now) == 1)            // only stale .tmp
        try setup()
        #expect(RecordingStore.sweep(recordings: recs, retention: .neverStore, now: now) == 4)
        #expect(left() == ["fresh.wav", ".tmp/newtmp.wav"])                                         // in-flight grace
    }

    // MARK: Paste last / Copy last

    @Test func lastDictationPicksLatestOk() {
        var cleaned = rec("3", status: .ok, raw: "fake raw 3"); cleaned.cleanText = "fake clean 3"
        let rows = [rec("1", status: .ok, raw: "fake 1"), cleaned, rec("4", status: .failed, raw: nil, error: "HTTP 500"),
                    rec("5", status: .pending, raw: nil)]
        #expect(LastDictation.text(in: rows) == "fake clean 3")
        #expect(LastDictation.text(in: [rec("x", status: .failed, raw: nil, error: "e")]) == nil)
        var replay = rec("r", status: .ok, raw: "fake replay"); replay.source = "replay"
        #expect(LastDictation.text(in: rows + [replay]) == "fake clean 3")
    }

    @Test func lastDictationKeyMatching() {
        let cc: NSEvent.ModifierFlags = [.command, .control]
        #expect(LastDictation.action(keyCode: 9, chars: "v", flags: cc) == .paste)
        #expect(LastDictation.action(keyCode: 8, chars: "c", flags: cc.union(.capsLock)) == .copy)
        #expect(LastDictation.action(keyCode: 9, chars: "м", flags: cc) == .paste)        // Russian layout, ANSI V position
        #expect(LastDictation.action(keyCode: 47, chars: "v", flags: cc) == .paste)       // Dvorak V
        #expect(LastDictation.action(keyCode: 9, chars: "k", flags: cc) == nil)           // Dvorak: position 9 is not V
        #expect(LastDictation.action(keyCode: 9, chars: "v", flags: [.command]) == nil)
        #expect(LastDictation.action(keyCode: 9, chars: "v", flags: cc.union(.shift)) == nil)
    }

    @MainActor @Test func historySearch() {
        var a = rec("a", raw: "Fake Salom dunyo"); a.cleanText = "Fake salom, dunyo."
        let b = rec("b", raw: "fake привет")
        let c = rec("c", status: .failed, raw: nil, error: "x")
        #expect(RunsModel.filter([a, b, c], query: "").count == 3)
        #expect(RunsModel.filter([a, b, c], query: "SALOM").map(\.runId) == ["a"])
        #expect(RunsModel.filter([a, b, c], query: " привет ").map(\.runId) == ["b"])
    }

    // MARK: app.log never gets dictated text

    @Test func logLinesNeverInterpolateTranscripts() throws {
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SoylaCore")
        var files = ["DictationPipeline.swift", "AppMain.swift", "LastDictation.swift", "RunsWindow.swift"].map { "App/" + $0 }
        // Every file of the layers that see transcripts or keys (R1).
        for dir in ["Paste", "Providers", "Cleanup", "Settings"] {
            let names = try FileManager.default.contentsOfDirectory(atPath: core.appendingPathComponent(dir).path)
            files += names.filter { $0.hasSuffix(".swift") }.sorted().map { dir + "/" + $0 }
        }
        let banned = ["rawText", "cleanText", "finalText", "liveText", "result.text", "c.text", "\\(text)", "\\(t)", "live_text",
                      "rejected", "cleanup_rejected"]
        var calls = 0
        for f in files {
            let src = try String(contentsOf: core.appendingPathComponent(f), encoding: .utf8)
            var rest = Substring(src)
            while let r = rest.range(of: "Log.info(") {
                // Take the balanced argument list of this call.
                var depth = 1, i = r.upperBound
                while i < rest.endIndex, depth > 0 {
                    if rest[i] == "(" { depth += 1 } else if rest[i] == ")" { depth -= 1 }
                    i = rest.index(after: i)
                }
                let call = rest[r.lowerBound..<i]
                calls += 1
                for b in banned { #expect(!call.contains(b), "\(f): \(call) interpolates \(b)") }
                rest = rest[i...]
            }
        }
        #expect(calls > 20)   // the scan really ran over the pipeline's log lines
        #expect(DictationPipeline.logSafe("decode: bad shape body: {\"text\":\"fake words\"}") == "decode: bad shape [body omitted]")
        #expect(DictationPipeline.logSafe(SoylaError.http(status: 429, body: "fake transcript words").localizedDescription)
                == "HTTP 429 [body omitted]")
        #expect(DictationPipeline.logSafe("HTTP 429") == "HTTP 429")
    }
}
