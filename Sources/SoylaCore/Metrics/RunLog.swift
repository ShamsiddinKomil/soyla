import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// JSONL run log. One line per run, appended with O_APPEND so concurrent writers never interleave.
public enum RunLog {
    public static func append(_ record: RunRecord, to url: URL = SoylaPaths.runsLog) throws {
        lock.lock(); defer { lock.unlock() }
        var data = try RunRecord.encoder.encode(record)
        // Defensive: JSONEncoder never emits raw newlines, but guarantee one line anyway.
        data = Data(data.filter { $0 != 0x0A && $0 != 0x0D })
        data.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)   // transcripts: owner only
        guard fd >= 0 else { throw SoylaError.decode("RunLog open failed: errno \(errno)") }
        defer { close(fd) }
        // Single write(2) of the whole line.
        let n = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard n == data.count else { throw SoylaError.decode("RunLog write failed: wrote \(n) of \(data.count)") }
        notifyChanged()
    }

    /// Posted on the main queue after every append/update (History reloads on it).
    public static let didChange = Notification.Name("ai.soyla.runLogDidChange")
    private static func notifyChanged() {
        Task { @MainActor in NotificationCenter.default.post(name: didChange, object: nil) }
    }

    /// In-process guard: `update` rewrites the file, so an `append` must not land on the old inode mid-rewrite.
    private static let lock = NSLock()

    /// Replace the row with `runId` in place (F4: pending → ok/failed/…). Rewrites the JSONL to a temp file in the
    /// same directory and renames it over the original (atomic on APFS); malformed and other rows are kept byte for
    /// byte. If several rows share the id the last one is changed. Returns false (file untouched) when not found.
    @discardableResult
    public static func update(runId: String, in url: URL = SoylaPaths.runsLog, _ change: (inout RunRecord) -> Void) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let data = try Data(contentsOf: url)
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).map { Data($0) }
        if lines.last?.isEmpty == true { lines.removeLast() }
        var hit: (Int, RunRecord)?
        let needle = Data("\"\(runId)\"".utf8)
        for (i, line) in lines.enumerated().reversed() where line.range(of: needle) != nil {
            if let r = try? RunRecord.decoder.decode(RunRecord.self, from: line), r.runId == runId { hit = (i, r); break }
        }
        guard let (idx, found) = hit else { return false }
        var rec = found
        change(&rec)
        rec.runId = runId                                   // the key never changes
        var enc = try RunRecord.encoder.encode(rec)
        enc = Data(enc.filter { $0 != 0x0A && $0 != 0x0D })
        lines[idx] = enc
        var out = Data(capacity: data.count + 256)
        for l in lines { out.append(l); out.append(0x0A) }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: out, attributes: [.posixPermissions: 0o600]) else {
            throw SoylaError.decode("RunLog update: cannot write temp file")
        }
        guard rename(tmp.path, url.path) == 0 else {
            let e = errno
            try? FileManager.default.removeItem(at: tmp)
            throw SoylaError.decode("RunLog update: rename failed: errno \(e)")
        }
        notifyChanged()
        return true
    }

    /// Replace the whole row (same `runId`).
    @discardableResult
    public static func update(_ record: RunRecord, in url: URL = SoylaPaths.runsLog) throws -> Bool {
        try update(runId: record.runId, in: url) { $0 = record }
    }

    public static func readAll(from url: URL = SoylaPaths.runsLog) throws -> [RunRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        var out: [RunRecord] = []
        var bad = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { continue }
            if let r = try? RunRecord.decoder.decode(RunRecord.self, from: Data(line)) { out.append(r) } else { bad += 1 }
        }
        if bad > 0 {
            FileHandle.standardError.write(Data("RunLog: skipped \(bad) malformed line(s) in \(url.lastPathComponent)\n".utf8))
        }
        return out
    }
}

/// A retry (History Retry, Retry with another model, the pill's Retry) writes over its run's row only when the attempt
/// is at least as good as what is there. F-01 (flow audit 2026-10-19): a retry with no key wiped a good row's text and
/// app name. A failed or cancelled attempt never replaces a row that has text; any write keeps the original app.
public enum RetryMerge {
    /// The row to write, or nil to leave the existing row as it is.
    public static func row(existing: RunRecord?, attempt: RunRecord) -> RunRecord? {
        guard let old = existing else { return attempt }
        let hasText = [old.rawText, old.cleanText].contains { !($0 ?? "").isEmpty }
        if attempt.status != .ok && hasText { return nil }
        var r = attempt
        if r.targetApp == nil { r.targetApp = old.targetApp }
        return r
    }

    /// Applies `row` to the run's line in `url`; appends when the run has no row yet.
    public static func persist(_ attempt: RunRecord, in url: URL = SoylaPaths.runsLog) throws {
        let found = try RunLog.update(runId: attempt.runId, in: url) { cur in
            if let r = row(existing: cur, attempt: attempt) { cur = r }
        }
        if !found { try RunLog.append(attempt, to: url) }
    }
}

extension RunLog {
    /// The pipeline's two writes for one run: `final: false` before the network call (F4: never lose the words),
    /// `final: true` at the end. A retry skips the first and merges the second (`RetryMerge`, F-01).
    static func persistRun(_ r: RunRecord, retry: Bool, final: Bool) {
        do {
            if retry { if final { try RetryMerge.persist(r) }; return }
            if final, try update(r) { return }
            try append(r)
        } catch {
            Log.info("runlog: \(error.localizedDescription)")
        }
    }
}
