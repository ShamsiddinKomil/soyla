import Foundation

/// Lifecycle of a run in History (F4). A `pending` row is written before the network call and updated in place.
public enum RunStatus: String, Codable, Sendable, CaseIterable {
    case pending, ok, failed, cancelled, interrupted

    /// Tolerant: an unknown value from a newer build reads as `failed` (offers Retry, never claims success).
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RunStatus(rawValue: raw) ?? .failed
    }

    /// Rows written before `status` existed: "cancelled" error → cancelled; any transcript → ok (a cleanup or
    /// paste note in `error` still means the words arrived); other error → failed; else ok.
    public static func inferred(error: String?, rawText: String?) -> RunStatus {
        if error == "cancelled" { return .cancelled }
        if rawText != nil { return .ok }
        return error == nil ? .ok : .failed
    }
}

/// One line of logs/runs.jsonl. Keys are snake_case on disk (see `RunRecord.encoder`).
public struct RunRecord: Codable, Sendable, Equatable {
    public struct AudioInfo: Codable, Sendable, Equatable {
        public var format: String
        public var bytes: Int
        public var b64Bytes: Int
        public var durationSec: Double
        public var sampleRate: Int
        public var file: String?          // relative to project root, nil if auto-deleted
        public init(format: String, bytes: Int, b64Bytes: Int, durationSec: Double, sampleRate: Int, file: String?) {
            self.format = format; self.bytes = bytes; self.b64Bytes = b64Bytes
            self.durationSec = durationSec; self.sampleRate = sampleRate; self.file = file
        }
    }

    public var runId: String              // "2026-10-15T14-02-11-123"
    public var ts: String                 // ISO-8601 wall clock
    public var source: String             // "live" | "replay"
    public var phraseId: Int?             // 1…5, nil = free
    public var model: String
    public var cleanup: Bool
    public var cleanupModel: String?
    public var languageHint: String?
    public var prewarm: Bool
    public var audio: AudioInfo
    public var timelineMs: [String: Double]
    public var net: RunTimeline.Net?
    public var usage: Usage?
    public var cleanupUsage: Usage?
    public var rawText: String?
    public var cleanText: String?
    public var error: String?
    public var providerMeta: [String: String]?
    public var appVersion: String
    /// The app that was frontmost at release (where the text went), shown on the History card. nil on old rows.
    public var targetApp: String?
    /// F4: pending → ok/failed/cancelled, or interrupted (app died). Old rows infer it (`RunStatus.inferred`).
    public var status: RunStatus
    /// D26 (c): why the correction pass was skipped after it was asked for and raw was pasted (a `CleanupGuard` raw value,
    /// or "error"). A class only, never text. nil on old rows and when nothing fell back. Not in the memberwise init.
    public var cleanupFallback: String?

    public init(runId: String, ts: String, source: String, phraseId: Int?, model: String, cleanup: Bool,
                cleanupModel: String?, languageHint: String?, prewarm: Bool, audio: AudioInfo,
                timelineMs: [String: Double], net: RunTimeline.Net?, usage: Usage?, cleanupUsage: Usage?,
                rawText: String?, cleanText: String?, error: String?, providerMeta: [String: String]?,
                appVersion: String = Soyla.version, status: RunStatus? = nil) {
        self.runId = runId; self.ts = ts; self.source = source; self.phraseId = phraseId; self.model = model
        self.cleanup = cleanup; self.cleanupModel = cleanupModel; self.languageHint = languageHint
        self.prewarm = prewarm; self.audio = audio; self.timelineMs = timelineMs; self.net = net
        self.usage = usage; self.cleanupUsage = cleanupUsage; self.rawText = rawText; self.cleanText = cleanText
        self.error = error; self.providerMeta = providerMeta; self.appVersion = appVersion
        self.status = status ?? RunStatus.inferred(error: error, rawText: rawText)
    }

    /// Tolerant decoding: `status` is optional on disk (rows before F4) and an unknown value never drops the row.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decode(String.self, forKey: .runId)
        ts = try c.decode(String.self, forKey: .ts)
        source = try c.decode(String.self, forKey: .source)
        phraseId = try c.decodeIfPresent(Int.self, forKey: .phraseId)
        model = try c.decode(String.self, forKey: .model)
        cleanup = try c.decode(Bool.self, forKey: .cleanup)
        cleanupModel = try c.decodeIfPresent(String.self, forKey: .cleanupModel)
        languageHint = try c.decodeIfPresent(String.self, forKey: .languageHint)
        prewarm = try c.decode(Bool.self, forKey: .prewarm)
        audio = try c.decode(AudioInfo.self, forKey: .audio)
        timelineMs = try c.decodeIfPresent([String: Double].self, forKey: .timelineMs) ?? [:]
        net = try c.decodeIfPresent(RunTimeline.Net.self, forKey: .net)
        usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
        cleanupUsage = try c.decodeIfPresent(Usage.self, forKey: .cleanupUsage)
        rawText = try c.decodeIfPresent(String.self, forKey: .rawText)
        cleanText = try c.decodeIfPresent(String.self, forKey: .cleanText)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        providerMeta = try c.decodeIfPresent([String: String].self, forKey: .providerMeta)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? "?"
        targetApp = try c.decodeIfPresent(String.self, forKey: .targetApp)
        status = ((try? c.decodeIfPresent(RunStatus.self, forKey: .status)) ?? nil)
            ?? RunStatus.inferred(error: error, rawText: rawText)
        cleanupFallback = try c.decodeIfPresent(String.self, forKey: .cleanupFallback)
    }

    /// The text the user got: cleaned if there was a correction pass, else raw.
    public var finalText: String? { cleanText ?? rawText }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Fresh run id + ISO timestamp pair.
    public static func newId(now: Date = Date()) -> (runId: String, ts: String) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now)
        let ms = Int(now.timeIntervalSince1970 * 1000) % 1000   // truncate: rounding could carry past the seconds field
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"; f.locale = Locale(identifier: "en_US_POSIX")
        return ("\(f.string(from: now))-\(String(format: "%03d", ms))", ts)
    }
}
