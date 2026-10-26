import Foundation
// SAFETY: AVAudioConverter's input block is annotated @Sendable but runs synchronously inside `convert(to:error:)` on
// the caller's thread; @preconcurrency lets it capture the non-Sendable AVAudioPCMBuffer it refills.
@preconcurrency import AVFoundation
import os
// `soyla replay <file> [--provider openrouter|google|custom|apple] [--models a,b] [--formats wav,flac,m4a,ogg] [--cleanup] [--language uz] [--phrase N] [--no-log] [--prewarm]`
// --provider defaults to Settings.provider; --models then defaults to Settings.sttModel when the provider matches,
// else that provider's default model. Google returns no cost: the usage line shows tokens and cost "-".
// Input is decoded to PCM16 16 kHz mono so re-encoding to each --format is possible.
public enum ReplayCLI {
    struct Args {
        var file = ""
        var provider: ProviderKind?
        var models: [String] = []
        var formats: [AudioFormatChoice] = [.wav]
        var cleanup = false
        var language: String?
        var phrase: Int?
        var noLog = false
        var prewarm = true   // default on: otherwise the first model listed pays the TLS handshake
        var segmented = false   // stream at real-time pace through Segmenter + SegmentedTranscriber
        var context = true
        var segConfig = Segmenter.Config.app
        var liveFast = false   // S6: Live race + decision alongside the pieces
    }

    static func parse(_ argv: [String]) throws -> Args {
        var a = Args()
        a.segmented = argv.contains("--segmented")
        a.context = !argv.contains("--no-context")
        a.liveFast = argv.contains("--live-fast")
        if a.liveFast { a.segmented = true }
        var args = argv.filter { $0 != "--segmented" && $0 != "--no-context" && $0 != "--live-fast" }
        for (flag, set) in [("--min-sec", { (v: Double) in a.segConfig.minSec = v }), ("--silence-ms", { a.segConfig.silenceMs = $0 })] {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count, let v = Double(args[i + 1]) else { continue }
            set(v); args.removeSubrange(i...(i + 1))
        }
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw SoylaError.audio("\(flag) needs a value") }
            return args[i]
        }
        while i < args.count {
            let s = args[i]
            switch s {
            case "--models": a.models = try value(s).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            case "--formats":
                a.formats = try value(s).split(separator: ",").map {
                    guard let f = AudioFormatChoice(rawValue: String($0).trimmingCharacters(in: .whitespaces)) else {
                        throw SoylaError.audio("unknown format \($0)")
                    }
                    return f
                }
            case "--provider":
                let v = try value(s)
                guard let k = parseProvider(v) else { throw SoylaError.audio("unknown provider \(v) (openrouter|google|custom|apple)") }
                a.provider = k
            case "--cleanup": a.cleanup = true
            case "--language": a.language = try value(s)
            case "--phrase": a.phrase = Int(try value(s))
            case "--no-log": a.noLog = true
            case "--prewarm": a.prewarm = true
            case "--no-prewarm": a.prewarm = false
            default:
                if s.hasPrefix("--") { throw SoylaError.audio("unknown option \(s)") }
                a.file = s
            }
            i += 1
        }
        guard !a.file.isEmpty else { throw SoylaError.audio("usage: soyla replay <file> [--provider openrouter|google|custom|apple] [--models a,b] [--formats wav,flac] [--cleanup] [--language uz] [--phrase N] [--no-log] [--prewarm]") }
        if a.models.isEmpty {
            let s = SettingsStore.shared.current
            let k = a.provider ?? s.provider
            a.models = [k == s.provider ? s.sttModel : k.defaultSTTModel]
        }
        return a
    }

    /// "openrouter" | "google" | "custom" (also accepts the raw values and "gemini"/"aistudio").
    static func parseProvider(_ v: String) -> ProviderKind? {
        switch v.lowercased() {
        case "openrouter": return .openRouter
        case "google", "gemini", "aistudio", "ai-studio": return .google
        case "custom": return .custom
        case "apple": return .apple
        default: return ProviderKind(rawValue: v)
        }
    }

    /// What a replay run does for a provider. The on-device engine (`.apple`) mirrors the pipeline's effective
    /// settings: cleanup off, no cleaner, no script check (FE-4 owns the pipeline side; this is Replay-local).
    struct EnginePlan: Equatable {
        var buildsCleaner: Bool
        var runsScriptCheck: Bool
        var cleanup: Bool
        var locale: String?        // .apple only
        var models: [String]?      // .apple only: [locale], overrides --models
        var meta: [String: String] // merged into providerMeta so reports can group by engine
    }

    static func enginePlan(kind: ProviderKind, cleanupRequested: Bool, language: String?, settingsLocale: String) throws -> EnginePlan {
        guard kind == .apple else {
            return EnginePlan(buildsCleaner: true, runsScriptCheck: true, cleanup: cleanupRequested, locale: nil, models: nil, meta: [:])
        }
        let locale = try appleLocale(language: language, settingsLocale: settingsLocale)
        return EnginePlan(buildsCleaner: false, runsScriptCheck: false, cleanup: false, locale: locale, models: [locale],
                          meta: ["provider": "apple"])
    }

    /// `--language en` → en-US; `en-GB` etc. must be one of `OnDeviceLocale.supported` (English only, V5).
    static func appleLocale(language: String?, settingsLocale: String) throws -> String {
        guard let language else { return settingsLocale }
        let norm = language.replacingOccurrences(of: "_", with: "-").lowercased()
        if norm == "en" { return OnDeviceLocale.fallback }
        if let hit = OnDeviceLocale.supported.first(where: { $0.lowercased() == norm }) { return hit }
        throw SoylaError.audio("the on-device engine is English only (V5): --language \"\(language)\" is not supported. Use en or one of \(OnDeviceLocale.supported.joined(separator: ", ")).")
    }

    /// The app reserves the model when the engine is chosen; a CLI run reserves it too (same bundle id, same slot),
    /// so `replay --provider apple` works on a Mac where the app never switched engines. Prints the state only.
    @MainActor static func prepareOnDevice(locale: String) async -> String {
        let models = OnDeviceModels()
        await models.ensureReady(locale: locale)
        return models.state.map { "\($0)" } ?? "unknown"
    }

    public static func run(args: [String]) async throws {
        let a = try parse(args)
        let settings = SettingsStore.shared.current
        let kind = a.provider ?? settings.provider
        let key = try ProviderFactory.apiKey(for: kind)
        let plan = try enginePlan(kind: kind, cleanupRequested: a.cleanup, language: a.language, settingsLocale: settings.onDeviceLocale)
        let url = URL(fileURLWithPath: (a.file as NSString).expandingTildeInPath)
        let pcm = try decodePCM16(url: url)
        let dur = Encoder.duration(pcm16: pcm)
        print("input: \(url.lastPathComponent)  \(String(format: "%.2f", dur)) s  pcm16 \(pcm.count) bytes")

        if kind == .apple, let locale = plan.locale { print("on-device model: \(await prepareOnDevice(locale: locale))") }
        let provider = try ProviderFactory.transcriber(kind, apiKey: key, customBaseURL: settings.customBaseURL, onDeviceLocale: plan.locale ?? settings.onDeviceLocale)
        let cleaner = plan.buildsCleaner ? try ProviderFactory.cleaner(kind, apiKey: key, customBaseURL: settings.customBaseURL) : nil
        let dictionary = ReplacementDictionary(settings.dictionary)
        let cleanupModel = kind == settings.provider ? settings.cleanupModel : kind.defaultCleanupModel
        print("provider: \(kind.label)")
        if a.prewarm { await provider.prewarm() }

        if a.segmented, kind != .apple {   // pieces are a cloud mode; the free engine replays whole
            // "--language auto" = the app's Auto setting (no hint), even when Settings has a language.
            var opts = TranscribeOptions(model: a.models[0], languageHint: a.language == "auto" ? nil : a.language ?? settings.languageHint)
            opts.vocabulary = settings.vocabulary
            try await SegmentedReplay.run(pcm: pcm, provider: provider, options: opts, format: a.formats[0], context: a.context,
                                          config: a.segConfig, liveFast: a.liveFast)
            return
        }
        for model in plan.models ?? a.models {
            for fmt in a.formats {
                print("\n== \(model)  [\(fmt.rawValue)]")
                let timeline = RunTimeline()
                var record: RunRecord?
                let (runId, ts) = RunRecord.newId()
                var audioInfo = RunRecord.AudioInfo(format: fmt.rawValue, bytes: 0, b64Bytes: 0, durationSec: dur, sampleRate: PCMSpec.sampleRate, file: nil)
                var raw: String?, clean: String?, usage: Usage?, cuse: Usage?, meta: [String: String]? = plan.meta.isEmpty ? nil : plan.meta, err: String?
                do {
                    timeline.mark(.keyUp)
                    let enc = try encode(pcm, fmt)
                    timeline.mark(.encodeDone)
                    audioInfo.bytes = enc.data.count
                    audioInfo.b64Bytes = (enc.data.count + 2) / 3 * 4
                    print("bytes: \(enc.data.count)")
                    var opts = TranscribeOptions(model: model, languageHint: a.language ?? settings.languageHint)
                    opts.vocabulary = settings.vocabulary
                    // Same text stage as the app (F3): script check + retry, then CleanupFlow (guards, dictionary).
                    let r = plan.runsScriptCheck
                        ? try await ScriptCheck.transcribe(provider, audio: enc, options: opts, timeline: timeline)
                        : try await provider.transcribe(enc, options: opts, timeline: timeline)
                    raw = r.text; usage = r.usage; meta = (meta ?? [:]).merging(r.providerMeta) { _, b in b }
                    print("text: \(r.text)")
                    let c = await CleanupFlow.run(raw: r.text, level: plan.cleanup ? .light : .off, cleaner: { guard let cleaner else { throw SoylaError.notImplemented("no cleaner for this engine") }; return cleaner },
                                                  model: cleanupModel, vocabulary: settings.vocabulary, appName: nil,
                                                  languageHint: opts.languageHint, dictionary: dictionary,
                                                  cooldownKey: ProviderCooldown.key(kind, customBaseURL: settings.customBaseURL), timeline: timeline)
                    meta = (meta ?? [:]).merging(c.meta) { _, b in b }
                    cuse = c.usage
                    if c.text != r.text { clean = c.text }
                    if let e = c.error { err = e; print("cleanup error: \(e)") }
                    if plan.cleanup || c.dictionaryHits > 0 { print("cleaned: \(c.text)") }
                    print("meta: \((meta ?? [:]).filter { $0.key != "cleanup_rejected" }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
                } catch {
                    err = error.localizedDescription
                    print("error: \(error.localizedDescription)")
                }
                let ms = timeline.toMillis()
                print("timeline_ms: \(ms.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
                let n = timeline.net
                print("net_ms: dns=\(fmtD(n.dns)) connect=\(fmtD(n.connect)) tls=\(fmtD(n.tls)) ttfb=\(fmtD(n.ttfb)) reused=\(n.reused.map(String.init) ?? "-")")
                if let u = usage { print("usage: seconds=\(fmtD(u.seconds)) in=\(u.inputTokens.map(String.init) ?? "-") out=\(u.outputTokens.map(String.init) ?? "-") total=\(u.totalTokens.map(String.init) ?? "-") cost=\(u.cost.map { String(format: "$%.6f", $0) } ?? "-")") }
                if let u = cuse { print("cleanup usage: in=\(u.inputTokens.map(String.init) ?? "-") out=\(u.outputTokens.map(String.init) ?? "-") cost=\(u.cost.map { String(format: "$%.6f", $0) } ?? "-")") }

                record = RunRecord(runId: runId, ts: ts, source: "replay", phraseId: a.phrase, model: model, cleanup: plan.cleanup,
                                   cleanupModel: plan.cleanup ? cleanupModel : nil, languageHint: a.language ?? settings.languageHint,
                                   prewarm: a.prewarm, audio: audioInfo, timelineMs: ms, net: timeline.net, usage: usage, cleanupUsage: cuse,
                                   rawText: raw, cleanText: clean, error: err, providerMeta: meta)
                if !a.noLog, let record { log(record) }
            }
        }
    }

    private static func fmtD(_ d: Double?) -> String { d.map { String(format: "%.1f", $0) } ?? "-" }

    private static func log(_ record: RunRecord) {
        do { try RunLog.append(record) } catch SoylaError.notImplemented {
            if let d = try? RunRecord.encoder.encode(record) { print(String(decoding: d, as: UTF8.self)) }
        } catch {
            FileHandle.standardError.write("log error: \(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }

    // MARK: encode
    // The `notImplemented` catches here and in `log` are left from the v0.1 stubs: neither `Encoder.encode` nor
    // `RunLog.append` throws it any more, so those branches never run.

    private static func encode(_ pcm: Data, _ fmt: AudioFormatChoice) throws -> EncodedAudio {
        do { return try Encoder.encode(pcm16: pcm, format: fmt) }
        catch SoylaError.notImplemented where fmt == .wav {
            return EncodedAudio(data: wavData(pcm), format: "wav", durationSec: Encoder.duration(pcm16: pcm),
                                sampleRate: PCMSpec.sampleRate, fileURL: nil)
        }
    }

    private static func wavData(_ pcm: Data) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(PCMSpec.sampleRate)); u32(UInt32(PCMSpec.bytesPerSecond)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }

    // MARK: decode any audio file -> PCM16 16 kHz mono

    static func decodePCM16(url: URL) throws -> Data {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw SoylaError.audio("cannot open \(url.lastPathComponent): \(error.localizedDescription)") }
        let inFmt = file.processingFormat
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PCMSpec.sampleRate), channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw SoylaError.audio("cannot create converter") }
        let inCap: AVAudioFrameCount = 8192
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: inCap) else { throw SoylaError.audio("buffer alloc") }
        let ratio = outFmt.sampleRate / inFmt.sampleRate
        let outCap = AVAudioFrameCount(Double(inCap) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { throw SoylaError.audio("buffer alloc") }

        var out = Data()
        let finished = OSAllocatedUnfairLock(initialState: false)   // set by the input block, read by the next call
        while true {
            outBuf.frameLength = 0
            var convError: NSError?
            let status = conv.convert(to: outBuf, error: &convError) { _, inStatus in
                if finished.withLock({ $0 }) { inStatus.pointee = .endOfStream; return nil }
                do {
                    inBuf.frameLength = 0
                    try file.read(into: inBuf, frameCount: inCap)
                } catch { finished.withLock { $0 = true }; inStatus.pointee = .endOfStream; return nil }
                if inBuf.frameLength == 0 { finished.withLock { $0 = true }; inStatus.pointee = .endOfStream; return nil }
                inStatus.pointee = .haveData
                return inBuf
            }
            if status == .error { throw SoylaError.audio("convert: \(convError?.localizedDescription ?? "unknown")") }
            if outBuf.frameLength > 0, let p = outBuf.int16ChannelData?[0] {
                out.append(UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream { break }
        }
        guard !out.isEmpty else { throw SoylaError.audio("decoded 0 samples") }
        return out
    }
}
