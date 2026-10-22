import Foundation
import AVFoundation
import Speech
import os

// FE-2: the free on-device engine. English only (V5); never Apple's server recognition (V1).
// Availability UI, locale reservation, downloads and permission requests belong to FE-3 (`OnDeviceModels`), not here:
// this file only checks status and throws `SoylaError.onDeviceUnavailable(reason:)` when the model isn't usable.

/// Seam between the provider and Apple's two speech APIs (tests use a fake).
/// Implementations build any `AVAudioPCMBuffer` inside themselves from `pcm16` (16 kHz mono Int16 LE); a buffer
/// never crosses an actor boundary (S6).
public protocol OnDeviceRecognizer: Sendable {
    /// "apple-analyzer" | "apple-legacy" (goes into `providerMeta["engine"]`).
    var engine: String { get }
    /// Cheap status check. Throws `SoylaError.onDeviceUnavailable` when the model or permission is missing.
    func checkReady() async throws
    func recognize(pcm16: Data, contextualStrings: [String]) async throws -> String
}

/// `TranscriptionProvider` for `ProviderKind.apple`. Receives the WAV the pipeline encoded (`Settings.uploadFormat`
/// is always `.wav` for `.apple`, R2) and never reads `EncodedAudio.fileURL`, which may still be streaming.
public actor AppleSpeechProvider: PrewarmableProvider {
    public nonisolated let id = "apple"
    private let recognizer: any OnDeviceRecognizer
    private let localeID: String

    /// `localeID` is `Settings.onDeviceLocale` (e.g. "en-US"); the macOS 26 analyzer is used when available, else
    /// the macOS 14–15 on-device `SFSpeechRecognizer`.
    public init(localeID: String) {
        self.init(recognizer: Self.systemRecognizer(localeID: localeID), localeID: localeID)
    }

    init(recognizer: any OnDeviceRecognizer, localeID: String) {
        self.recognizer = recognizer
        self.localeID = localeID
    }

    static func systemRecognizer(localeID: String) -> any OnDeviceRecognizer {
        if #available(macOS 26.0, *) { return AnalyzerBackend(localeID: localeID) }
        return LegacyBackend(localeID: localeID)
    }

    /// Status check only: no download, no reservation, no permission prompt.
    public func prewarm() async {
        try? await recognizer.checkReady()
    }

    public func transcribe(_ audio: EncodedAudio, options: TranscribeOptions, timeline: RunTimeline) async throws -> TranscriptResult {
        guard audio.format == "wav" else { throw SoylaError.audio("on-device engine needs wav, got \(audio.format)") }
        let pcm = try WAVReader.pcm16(fromWAV: audio.data)
        // Convention: a header-only WAV is "no speech heard" (emptyTranscript), like an empty cloud reply.
        guard !pcm.isEmpty else { throw SoylaError.emptyTranscript }
        if Task.isCancelled { throw SoylaError.cancelled }

        timeline.mark(.requestSent)
        let text: String
        do {
            text = try await recognizer.recognize(pcm16: pcm, contextualStrings: options.vocabulary)
        } catch {
            timeline.mark(.responseReceived)
            let mapped = Self.map(error)
            Log.info("on-device stt failed: \(Self.errorClass(mapped)) engine=\(recognizer.engine)")
            throw mapped
        }
        timeline.mark(.responseReceived)
        // A backend that answered after cancellation must never paste late (S6).
        if Task.isCancelled { throw SoylaError.cancelled }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw SoylaError.emptyTranscript }
        let lang = Locale(identifier: localeID).language.languageCode?.identifier
        return TranscriptResult(text: trimmed, language: lang, usage: Usage(seconds: audio.durationSec, cost: nil),
                                providerMeta: ["provider": "apple", "engine": recognizer.engine])
    }

    /// SoylaError passes through; cancellation → `.cancelled`; anything else → `onDeviceUnavailable` with a
    /// machine code (domain:code). Never the error's localized text, which could carry recognised words.
    static func map(_ error: any Error) -> SoylaError {
        if let s = error as? SoylaError { return s }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        return .onDeviceUnavailable(reason: "recognizer-failed:\(ns.domain):\(ns.code)")
    }

    private static func errorClass(_ e: SoylaError) -> String {
        switch e {
        case .onDeviceUnavailable(let r): return "onDeviceUnavailable(\(r))"
        case .cancelled: return "cancelled"
        case .emptyTranscript: return "emptyTranscript"
        default: return "other"
        }
    }
}

// MARK: - WAV → PCM16

/// Parses the RIFF/WAVE bytes our `Encoder.wav` writes, defensively: validates RIFF/WAVE, walks chunks (skipping
/// unknown ones and their pad byte), requires `fmt ` = PCM, mono, 16 kHz, 16-bit, and a `data` chunk that fits.
enum WAVReader {
    static func pcm16(fromWAV d: Data) throws -> Data {
        let b = [UInt8](d)
        guard b.count >= 12 else { throw bad("too short for a header") }
        guard tag(b, 0) == "RIFF" else { throw bad("missing RIFF") }
        guard tag(b, 8) == "WAVE" else { throw bad("missing WAVE") }
        var p = 12
        var fmtOK = false
        while p + 8 <= b.count {
            let id = tag(b, p), size = u32(b, p + 4), body = p + 8
            guard size <= b.count - body else { throw bad("chunk \(id) overruns the file") }
            if id == "fmt " {
                try checkFormat(b, body, size)
                fmtOK = true
            } else if id == "data" {
                guard fmtOK else { throw bad("data before fmt") }
                return Data(b[body..<(body + (size & ~1))])   // drop an odd trailing byte (half sample)
            }
            p = body + size + (size & 1)
        }
        throw bad(fmtOK ? "no data chunk" : "no fmt chunk")
    }

    /// PCM, mono, 16 kHz, 16-bit: the only layout `Encoder.pcmBuffer` builds from.
    private static func checkFormat(_ b: [UInt8], _ body: Int, _ size: Int) throws {
        guard size >= 16 else { throw bad("fmt chunk too small") }
        guard u16(b, body) == 1 else { throw bad("not PCM") }
        guard u16(b, body + 2) == PCMSpec.channels else { throw bad("not mono") }
        guard u32(b, body + 4) == PCMSpec.sampleRate else { throw bad("not \(PCMSpec.sampleRate) Hz") }
        guard u16(b, body + 14) == PCMSpec.bitsPerSample else { throw bad("not 16-bit") }
    }

    private static func bad(_ why: String) -> SoylaError { .audio("wav: \(why)") }
    private static func tag(_ b: [UInt8], _ o: Int) -> String { String(bytes: b[o..<(o + 4)], encoding: .ascii) ?? "" }
    private static func u32(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
    private static func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
}

// MARK: - macOS 26: SpeechAnalyzer + DictationTranscriber

@available(macOS 26.0, *)
actor AnalyzerBackend: OnDeviceRecognizer {
    nonisolated let engine = "apple-analyzer"
    private let localeID: String

    init(localeID: String) { self.localeID = localeID }

    /// FE-0: punctuation is sparse with or without `.punctuation`; we ask for it anyway.
    private func makeTranscriber() async throws -> DictationTranscriber {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw SoylaError.onDeviceUnavailable(reason: "unsupported")
        }
        return DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                    reportingOptions: [], attributeOptions: [])
    }

    private func ensureInstalled(_ t: DictationTranscriber) async throws {
        let status = await AssetInventory.status(forModules: [t])
        if status == .installed { return }
        // `.supported` / `.downloading`: FE-3 reserves and downloads; we never do it here.
        throw SoylaError.onDeviceUnavailable(reason: status == .unsupported ? "unsupported" : "model-not-installed")
    }

    func checkReady() async throws {
        try await ensureInstalled(try await makeTranscriber())
    }

    func recognize(pcm16: Data, contextualStrings: [String]) async throws -> String {
        let transcriber = try await makeTranscriber()
        try await ensureInstalled(transcriber)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextualStrings.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = contextualStrings
            try await analyzer.setContext(ctx)
        }
        let input = try await Self.analyzerBuffer(pcm16: pcm16, modules: [transcriber])
        let (stream, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        feed.yield(input)
        feed.finish()

        async let text = Self.collect(transcriber)
        do {
            try await withTaskCancellationHandler {
                if let end = try await analyzer.analyzeSequence(stream) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            await analyzer.cancelAndFinishNow()   // ends `results`, so the `async let` can't hang
            _ = try? await text
            throw error
        }
        let out = try await text
        try Task.checkCancellation()
        return out
    }

    private static func collect(_ t: DictationTranscriber) async throws -> String {
        var parts: [String] = []
        for try await r in t.results {
            let s = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { parts.append(s) }
        }
        return parts.joined(separator: " ")
    }

    /// Builds the 16 kHz Int16 buffer and converts it when the analyzer prefers another format. Runs inside the actor;
    /// the buffer leaves only wrapped in `AnalyzerInput` (Apple's own Sendable box).
    private static func analyzerBuffer(pcm16: Data, modules: [any SpeechModule]) async throws -> AnalyzerInput {
        let src = try Encoder.pcmBuffer(pcm16: pcm16)
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: src.format),
              target != src.format else {
            return AnalyzerInput(buffer: src)
        }
        guard let conv = AVAudioConverter(from: src.format, to: target) else {
            throw SoylaError.audio("no converter to the analyzer's format")
        }
        let ratio = target.sampleRate / src.format.sampleRate
        let capacity = AVAudioFrameCount((Double(src.frameLength) * ratio).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw SoylaError.audio("cannot allocate converted buffer")
        }
        // The input block is @Sendable, so it rebuilds the buffer from the (Sendable) bytes instead of capturing `src`.
        let fed = OSAllocatedUnfairLock(initialState: false)
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, outStatus in
            if fed.withLock({ was in defer { was = true }; return was }) {
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return try? Encoder.pcmBuffer(pcm16: pcm16)
        }
        guard status != .error, err == nil else { throw SoylaError.audio("format conversion failed") }
        return AnalyzerInput(buffer: out)
    }
}

// MARK: - macOS 14–15: SFSpeechRecognizer, on device only

actor LegacyBackend: OnDeviceRecognizer {
    nonisolated let engine = "apple-legacy"
    private let localeID: String
    /// Kept alive while a request runs; cancelled from `cancelCurrent()`.
    private var current: (recognizer: SFSpeechRecognizer, task: SFSpeechRecognitionTask)?

    init(localeID: String) { self.localeID = localeID }

    /// Never requests authorization (FE-3 owns the prompt) and never allows server recognition (V1).
    private func readyRecognizer() throws -> SFSpeechRecognizer {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw SoylaError.onDeviceUnavailable(reason: "needs-permission")
        }
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
            throw SoylaError.onDeviceUnavailable(reason: "unsupported")
        }
        guard r.supportsOnDeviceRecognition else { throw SoylaError.onDeviceUnavailable(reason: "model-not-installed") }
        guard r.isAvailable else { throw SoylaError.onDeviceUnavailable(reason: "recognizer-busy") }
        return r
    }

    func checkReady() async throws { _ = try readyRecognizer() }

    func recognize(pcm16: Data, contextualStrings: [String]) async throws -> String {
        let recognizer = try readyRecognizer()
        recognizer.queue = OperationQueue()   // callbacks off main; the CLI has no main run loop
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.shouldReportPartialResults = false
        request.contextualStrings = contextualStrings
        request.append(try Encoder.pcmBuffer(pcm16: pcm16))
        request.endAudio()

        let once = OnceContinuation()
        let text = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, any Error>) in
                once.install(cont)
                let task = recognizer.recognitionTask(with: request) { @Sendable result, error in
                    if let error {
                        once.resume(throwing: Self.legacyError(error))
                    } else if let result, result.isFinal {
                        once.resume(returning: result.bestTranscription.formattedString)
                    }
                }
                current = (recognizer, task)
            }
        } onCancel: {
            once.resume(throwing: CancellationError())
            Task { await self.cancelCurrent() }
        }
        current = nil
        return text
    }

    private func cancelCurrent() {
        current?.task.cancel()
        current = nil
    }

    /// kAFAssistantErrorDomain 1110 is "No speech detected" (assumption from Apple's on-device recognizer
    /// behaviour; not in the public headers): treat as an empty transcript.
    nonisolated static func legacyError(_ error: any Error) -> any Error {
        let ns = error as NSError
        if ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110 { return SoylaError.emptyTranscript }
        return error
    }
}

/// Resumes a checked continuation exactly once, whichever of the callback or cancellation comes first.
private final class OnceContinuation: Sendable {
    private struct State: Sendable {
        var cont: CheckedContinuation<String, any Error>?
        var early: Result<String, any Error>?   // an outcome that arrived before `install`
        var done = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ c: CheckedContinuation<String, any Error>) {
        let early: Result<String, any Error>? = state.withLock { s in
            if let e = s.early { s.early = nil; s.done = true; return e }
            s.cont = c
            return nil
        }
        if let early { c.resume(with: early) }
    }

    func resume(returning v: String) { finish(.success(v)) }
    func resume(throwing e: any Error) { finish(.failure(e)) }

    private func finish(_ r: Result<String, any Error>) {
        let c: CheckedContinuation<String, any Error>? = state.withLock { s in
            guard !s.done, s.early == nil else { return nil }   // first outcome wins
            guard let c = s.cont else { s.early = r; return nil }
            s.cont = nil; s.done = true
            return c
        }
        c?.resume(with: r)
    }
}
