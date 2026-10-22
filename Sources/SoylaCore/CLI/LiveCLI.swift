import Foundation

/// `soyla live-test <file.wav> [--language uz] [experiment flags] [--stats]` — streams a 16 kHz mono WAV through
/// GeminiLiveProvider at real-time pace (100 ms chunks), printing interim text with timestamps, then the final and the
/// timings the app logs. Experiment flags (2026-10-16): `--model id`, `--langs ""|uz-UZ,ru-RU` ("" = auto-detect),
/// `--vad auto|manual`, `--silence-ms N`, `--mode VERBATIM|SMART`, `--sys-transcribe` (general model + the batch prompt).
/// `--stats` prints counts only (characters, Cyrillic share, interim updates), never the text.
public enum LiveCLI {
    static func value(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func config(_ args: [String]) -> LiveConfig {
        var c = LiveConfig()
        if let m = value(args, "--model") { c.model = m.hasPrefix("models/") ? m : "models/" + m }
        if let l = value(args, "--langs") { c.languageCodes = l.split(separator: ",").map(String.init) }
        c.autoVAD = value(args, "--vad") == "auto"
        c.silenceMs = value(args, "--silence-ms").flatMap(Int.init)
        c.mode = value(args, "--mode")
        if args.contains("--sys-transcribe") { c.systemInstruction = OpenRouterSTTProvider.chatPrompt }
        return c
    }

    /// Characters and the Cyrillic share of letters, the only things `--stats` prints.
    static func stats(_ t: String) -> String {
        let cyr = t.unicodeScalars.filter { (0x400...0x4FF).contains($0.value) }.count
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return String(format: "chars %d · cyrillic share %.2f", t.count, letters == 0 ? 0 : Double(cyr) / Double(letters))
    }

    public static func run(args: [String]) async throws {
        guard let file = args.first else { throw SoylaError.audio("usage: soyla live-test <file.wav> [--language uz]") }
        let lang = value(args, "--language")
        let statsOnly = args.contains("--stats")
        let wav = try Data(contentsOf: URL(fileURLWithPath: file))
        let pcm = wav.subdata(in: 44..<wav.count)
        let live = GeminiLiveProvider(apiKey: try Secrets.geminiKey(), config: config(args))
        let t0 = Date()
        let printer = Task { () -> Int in
            var last = "", n = 0
            for await t in live.partials where t != last {
                last = t; n += 1
                if !statsOnly { print(String(format: "  [%5.0f ms] %@", Date().timeIntervalSince(t0) * 1000, t)) }
            }
            return n
        }
        try await live.startSession(options: TranscribeOptions(model: GeminiLiveProvider.model, languageHint: lang))
        try await live.activityStart()
        var off = 0, i = 0
        while off < pcm.count {
            live.feedSync(pcm.subdata(in: off..<min(off + 3200, pcm.count)))
            off += 3200; i += 1
            let due = t0.addingTimeInterval(Double(i) * 0.1)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        }
        let tRelease = Date()
        try await live.activityEnd()
        let r = try await live.finish(waitMs: 8000)
        let releaseToDone = Date().timeIntervalSince(tRelease) * 1000
        let kind = r.providerMeta["live_final"] == "1" ? "final" : "last interim"
        if statsOnly {
            let updates = await printer.value
            print("FINAL (\(kind)): \(stats(r.text)) · interim updates \(updates)")
        } else {
            printer.cancel()
            print("FINAL (\(kind)): \(r.text)")
        }
        print(String(format: "setup %.0f ms · first text %.0f ms after connect · release→final %@ · release→done %.0f ms",
                     live.setupMs ?? -1, live.firstInterimMs ?? -1,
                     live.releaseToFinalMs.map { String(format: "%.0f ms", $0) } ?? "–", releaseToDone))
    }
}
