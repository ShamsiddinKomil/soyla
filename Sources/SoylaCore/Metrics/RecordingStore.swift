import Foundation

/// F4: launch-time crash recovery and the retention sweep for `recordings/`.
public enum RecordingStore {
    /// `recordings/.tmp`: never-store recordings and encoder scratch files. Swept at launch and daily.
    public static func tmpDir(_ recordings: URL = SoylaPaths.recordings) -> URL { recordings.appendingPathComponent(".tmp") }

    /// Where a new run's streamed WAV goes.
    public static func url(runId: String, retention: AudioRetention, recordings: URL = SoylaPaths.recordings) -> URL {
        (retention == .neverStore ? tmpDir(recordings) : recordings).appendingPathComponent("\(runId).wav")
    }

    /// Path stored in `RunRecord.audio.file`: relative to `root` when inside it.
    public static func relPath(_ u: URL, root: URL = SoylaPaths.root) -> String {
        let r = root.standardizedFileURL.path + "/"
        let p = u.standardizedFileURL.path
        return p.hasPrefix(r) ? String(p.dropFirst(r.count)) : p
    }

    /// Inverse of `relPath`.
    public static func resolve(_ file: String, root: URL = SoylaPaths.root) -> URL {
        file.hasPrefix("/") ? URL(fileURLWithPath: file) : root.appendingPathComponent(file)
    }

    /// Recordings younger than this are never swept (a dictation is ≤ 55 s; never-store files live minutes at most).
    public static let inFlightGraceSec: TimeInterval = 600

    /// Run once at launch, before anything records:
    /// 1. every `<runId>.wav` (in `recordings/` and `.tmp/`) whose header disagrees with its length was cut off by
    ///    a crash: fix the header; empty → delete; otherwise its row becomes (or is added as) `interrupted`.
    /// 2. every row still `pending` belongs to a run that died during the request → `interrupted`.
    /// Returns the run ids marked interrupted.
    @discardableResult
    public static func repairInterrupted(recordings: URL = SoylaPaths.recordings, runsLog: URL = SoylaPaths.runsLog,
                                         root: URL = SoylaPaths.root, model: String) -> [String] {
        let fm = FileManager.default
        let rows = (try? RunLog.readAll(from: runsLog)) ?? []
        var byId: [String: RunRecord] = [:]
        for r in rows { byId[r.runId] = r }
        var marked: [String] = []
        for dir in [recordings, tmpDir(recordings)] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
            // Header-only (killed before the first buffer) or header disagreeing with the length (killed mid-recording).
            for u in items where u.pathExtension == "wav" && (WAVFile.needsRepair(at: u) || WAVFile.isPlaceholderOnly(at: u)) {
                let runId = u.deletingPathExtension().lastPathComponent
                guard let bytes = try? WAVFile.repairHeader(at: u) else { continue }
                if bytes == 0 {
                    try? fm.removeItem(at: u)
                    Log.info("recovery: removed empty recording \(runId)")
                    continue
                }
                let dur = Double(bytes) / Double(PCMSpec.bytesPerSecond)
                let audio = RunRecord.AudioInfo(format: "wav", bytes: bytes + WAVFile.headerBytes, b64Bytes: 0,
                                                durationSec: dur, sampleRate: PCMSpec.sampleRate, file: relPath(u, root: root))
                if byId[runId] != nil {
                    _ = try? RunLog.update(runId: runId, in: runsLog) { r in
                        r.status = .interrupted; r.error = "interrupted"; r.audio = audio
                    }
                } else {
                    let created = (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let r = RunRecord(runId: runId, ts: iso.string(from: created), source: "live", phraseId: nil, model: model,
                                      cleanup: false, cleanupModel: nil, languageHint: nil, prewarm: false, audio: audio,
                                      timelineMs: [:], net: nil, usage: nil, cleanupUsage: nil, rawText: nil, cleanText: nil,
                                      error: "interrupted", providerMeta: nil, status: .interrupted)
                    try? RunLog.append(r, to: runsLog)
                }
                marked.append(runId)
                Log.info(String(format: "recovery: %@ cut off mid-recording, %.1f s kept, marked interrupted", runId, dur))
            }
        }
        for r in rows where r.status == .pending && !marked.contains(r.runId) {
            _ = try? RunLog.update(runId: r.runId, in: runsLog) { $0.status = .interrupted; $0.error = "interrupted" }
            marked.append(r.runId)
            Log.info("recovery: run \(r.runId) was pending at launch, marked interrupted")
        }
        return marked
    }

    /// Retention sweep (launch + every 24 h). Deletes top-level recordings older than `retention.maxAgeDays`
    /// (never-store: anything older than the in-flight grace) and `.tmp/` files older than the grace. Directories and
    /// files whose base name is in `protect` (the run being recorded / awaiting Retry) are left alone.
    /// Returns the number of files deleted.
    @discardableResult
    public static func sweep(recordings: URL = SoylaPaths.recordings, retention: AudioRetention, now: Date = Date(),
                             protect: Set<String> = []) -> Int {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        var removed = 0
        func sweepDir(_ dir: URL, olderThan cutoff: Date) {
            for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [] {
                let v = try? u.resourceValues(forKeys: Set(keys))
                if v?.isDirectory == true { continue }
                if protect.contains(u.deletingPathExtension().lastPathComponent) { continue }
                if let d = v?.contentModificationDate, d < cutoff, (try? fm.removeItem(at: u)) != nil { removed += 1 }
            }
        }
        if let days = retention.maxAgeDays {
            sweepDir(recordings, olderThan: now.addingTimeInterval(-max(days * 86400, inFlightGraceSec)))
        }
        sweepDir(tmpDir(recordings), olderThan: now.addingTimeInterval(-inFlightGraceSec))
        return removed
    }
}
