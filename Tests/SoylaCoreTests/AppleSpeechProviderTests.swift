import Foundation
import Testing
@testable import SoylaCore

// FE-2: AppleSpeechProvider with a fake OnDeviceRecognizer (no Speech framework in unit tests).

/// Records what the provider hands the recognizer; returns a canned outcome.
actor FakeRecognizer: OnDeviceRecognizer {
    nonisolated let engine = "fake-engine"
    enum Mode: Sendable { case text(String), fail(any Error), hangUntilCancelled, ignoreCancel(String) }
    private let mode: Mode
    private(set) var calls: [(bytes: Int, strings: [String])] = []
    private(set) var readyChecks = 0
    init(_ mode: Mode) { self.mode = mode }

    func checkReady() async throws { readyChecks += 1 }

    func recognize(pcm16: Data, contextualStrings: [String]) async throws -> String {
        calls.append((pcm16.count, contextualStrings))
        switch mode {
        case .text(let t): return t
        case .fail(let e): throw e
        case .hangUntilCancelled:
            try await Task.sleep(for: .seconds(30))
            return "TOO LATE FAKE"
        case .ignoreCancel(let t):
            while !Task.isCancelled { await Task.yield() }
            return t   // a backend that answers anyway must still not paste
        }
    }
}

@Suite struct AppleSpeechProviderTests {
    private func wav(samples: Int) -> EncodedAudio {
        let pcm = Data(repeating: 0x01, count: samples * 2)
        return EncodedAudio(data: Encoder.wav(pcm16: pcm), format: "wav", durationSec: Double(samples) / 16_000,
                            sampleRate: 16_000, fileURL: URL(fileURLWithPath: "/nonexistent/never-read.wav"))
    }

    private func opts(_ vocab: [String] = []) -> TranscribeOptions {
        var o = TranscribeOptions(model: "en-US"); o.vocabulary = vocab; return o
    }

    @Test func textPassthroughWithMetaAndTimeline() async throws {
        let fake = FakeRecognizer(.text("  Hello FAKE world.  "))
        let p = AppleSpeechProvider(recognizer: fake, localeID: "en-GB")
        let tl = RunTimeline()
        let r = try await p.transcribe(wav(samples: 1600), options: opts(), timeline: tl)
        #expect(r.text == "Hello FAKE world.")
        #expect(r.language == "en")
        #expect(r.usage?.cost == nil)
        #expect(r.providerMeta["engine"] == "fake-engine")
        #expect(tl.has(.requestSent) && tl.has(.responseReceived))
        #expect(await fake.calls.map(\.bytes) == [3200])
        #expect(p.id == "apple")
    }

    @Test func vocabularyForwardedAsContextualStrings() async throws {
        let fake = FakeRecognizer(.text("ok"))
        let p = AppleSpeechProvider(recognizer: fake, localeID: "en-US")
        _ = try await p.transcribe(wav(samples: 800), options: opts(["Soyla", "FAKE1234"]), timeline: RunTimeline())
        #expect(await fake.calls.first?.strings == ["Soyla", "FAKE1234"])
    }

    @Test func emptyTextIsEmptyTranscript() async {
        let p = AppleSpeechProvider(recognizer: FakeRecognizer(.text(" \n ")), localeID: "en-US")
        let tl = RunTimeline()
        await #expect(throws: SoylaError.self) { _ = try await p.transcribe(wav(samples: 800), options: opts(), timeline: tl) }
        do { _ = try await p.transcribe(wav(samples: 800), options: opts(), timeline: tl); Issue.record("expected throw") }
        catch SoylaError.emptyTranscript {} catch { Issue.record("wrong error \(error)") }
        #expect(tl.has(.responseReceived))
    }

    /// Convention: a header-only WAV (0 samples) is `emptyTranscript` (the pipeline's soft "No speech heard"),
    /// not `tooShort`, which nothing in the tree throws. The recognizer is never called.
    @Test func headerOnlyWavIsEmptyTranscriptWithoutCallingRecognizer() async {
        let fake = FakeRecognizer(.text("never"))
        let p = AppleSpeechProvider(recognizer: fake, localeID: "en-US")
        do { _ = try await p.transcribe(wav(samples: 0), options: opts(), timeline: RunTimeline()); Issue.record("expected throw") }
        catch SoylaError.emptyTranscript {} catch { Issue.record("wrong error \(error)") }
        #expect(await fake.calls.isEmpty)
    }

    @Test func errorMapping() async {
        func run(_ e: any Error) async -> (any Error)? {
            let p = AppleSpeechProvider(recognizer: FakeRecognizer(.fail(e)), localeID: "en-US")
            let tl = RunTimeline()
            do { _ = try await p.transcribe(wav(samples: 800), options: opts(), timeline: tl); return nil }
            catch { #expect(tl.has(.requestSent) && tl.has(.responseReceived)); return error }
        }
        // SoylaError passes through untouched.
        if case SoylaError.onDeviceUnavailable(let r)? = await run(SoylaError.onDeviceUnavailable(reason: "model-not-installed")) as? SoylaError {
            #expect(r == "model-not-installed")
        } else { Issue.record("onDeviceUnavailable not passed through") }
        // CancellationError → cancelled.
        if case SoylaError.cancelled? = await run(CancellationError()) as? SoylaError {} else { Issue.record("cancel not mapped") }
        // Anything else → onDeviceUnavailable with a machine code (domain:code), never user text.
        let ns = NSError(domain: "kAFAssistantErrorDomain", code: 1107, userInfo: [NSLocalizedDescriptionKey: "FAKE secret words"])
        if case SoylaError.onDeviceUnavailable(let r)? = await run(ns) as? SoylaError {
            #expect(r == "recognizer-failed:kAFAssistantErrorDomain:1107")
            #expect(!r.contains("FAKE"))
        } else { Issue.record("NSError not mapped") }
    }

    @Test func cancellationThrowsCancelledAndNoText() async {
        for mode: FakeRecognizer.Mode in [.hangUntilCancelled, .ignoreCancel("LATE FAKE")] {
            let p = AppleSpeechProvider(recognizer: FakeRecognizer(mode), localeID: "en-US")
            let audio = wav(samples: 800)
            let task = Task { try await p.transcribe(audio, options: opts(), timeline: RunTimeline()) }
            try? await Task.sleep(for: .milliseconds(50))
            task.cancel()
            switch await task.result {
            case .success(let r): Issue.record("cancelled run returned text (\(r.text.count) chars)")
            case .failure(let e):
                if case SoylaError.cancelled? = e as? SoylaError {} else { Issue.record("expected cancelled, got \(e)") }
            }
        }
    }

    @Test func alreadyCancelledNeverCallsRecognizer() async {
        let fake = FakeRecognizer(.text("x"))
        let p = AppleSpeechProvider(recognizer: fake, localeID: "en-US")
        let audio = wav(samples: 800)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await p.transcribe(audio, options: opts(), timeline: RunTimeline())
        }
        if case .success = await task.result { Issue.record("expected cancelled") }
        #expect(await fake.calls.isEmpty)
    }

    @Test func prewarmIsAStatusCheckOnly() async {
        let fake = FakeRecognizer(.text("x"))
        let p = AppleSpeechProvider(recognizer: fake, localeID: "en-US")
        await p.prewarm()
        #expect(await fake.readyChecks == 1)
        #expect(await fake.calls.isEmpty)
    }

    @Test func nonWavInputIsAudioError() async {
        let p = AppleSpeechProvider(recognizer: FakeRecognizer(.text("x")), localeID: "en-US")
        let flac = EncodedAudio(data: Data("fLaC....".utf8), format: "flac", durationSec: 1, sampleRate: 16_000, fileURL: nil)
        do { _ = try await p.transcribe(flac, options: opts(), timeline: RunTimeline()); Issue.record("expected throw") }
        catch SoylaError.audio {} catch { Issue.record("wrong error \(error)") }
    }
}

@Suite struct WAVReaderTests {
    @Test func validHeaderGivesPCM() throws {
        let pcm = Data((0..<4000).map { UInt8($0 & 0xff) })   // 2000 samples
        let out = try WAVReader.pcm16(fromWAV: Encoder.wav(pcm16: pcm))
        #expect(out == pcm)
        #expect(out.count / 2 == 2000)
    }

    @Test func headerOnlyGivesZeroSamples() throws {
        #expect(try WAVReader.pcm16(fromWAV: Encoder.wav(pcm16: Data())).isEmpty)
    }

    @Test func extraChunkBeforeDataIsSkipped() throws {
        let pcm = Data(repeating: 7, count: 64)
        var w = Encoder.wav(pcm16: pcm)
        // Insert an odd-sized LIST chunk (3 bytes + 1 pad) between fmt and data.
        let list = Data("LIST".utf8) + Data([3, 0, 0, 0]) + Data([1, 2, 3, 0])
        w.insert(contentsOf: list, at: 36)
        #expect(try WAVReader.pcm16(fromWAV: w) == pcm)
    }

    @Test func malformedHeadersAreAudioErrors() {
        let good = Encoder.wav(pcm16: Data(repeating: 1, count: 32))
        func mutate(_ at: Int, _ bytes: [UInt8]) -> Data { var d = good; d.replaceSubrange(at..<(at + bytes.count), with: bytes); return d }
        let cases: [(String, Data)] = [
            ("empty", Data()),
            ("short", good.prefix(20)),
            ("no RIFF", mutate(0, Array("RIFX".utf8))),
            ("no WAVE", mutate(8, Array("AVI ".utf8))),
            ("no fmt", mutate(12, Array("junk".utf8))),
            ("not PCM", mutate(20, [3, 0])),               // float
            ("stereo", mutate(22, [2, 0])),
            ("44.1k", mutate(24, [0x44, 0xAC, 0, 0])),
            ("8-bit", mutate(34, [8, 0])),
            ("data overruns", mutate(40, [0xFF, 0xFF, 0, 0])),
            ("no data", good.prefix(36)),
        ]
        for (name, d) in cases {
            do { _ = try WAVReader.pcm16(fromWAV: d); Issue.record("\(name): expected throw") }
            catch SoylaError.audio {} catch { Issue.record("\(name): wrong error \(error)") }
        }
    }
}

@Suite struct AppleUploadFormatTests {
    @Test func appleAlwaysUploadsWav() {
        var s = Settings()
        s.provider = .apple
        for f in AudioFormatChoice.allCases {
            s.audioFormat = f
            #expect(s.uploadFormat == .wav, "\(f)")
        }
    }

    @Test func cloudUploadFormatUnchanged() {
        for kind in [ProviderKind.openRouter, .google] {
            var s = Settings(); s.provider = kind
            for f in AudioFormatChoice.allCases { s.audioFormat = f; #expect(s.uploadFormat == f) }
        }
        var c = Settings(); c.provider = .custom
        c.audioFormat = .flac; #expect(c.uploadFormat == .wav)
        c.audioFormat = .ogg; #expect(c.uploadFormat == .ogg)
    }

    @Test func factoryBuildsAppleProviderWithLocale() throws {
        var s = Settings(); s.provider = .apple; s.onDeviceLocale = "en-AU"
        let p = try ProviderFactory.transcriber(for: s)
        #expect(p.id == "apple")
        #expect(try ProviderFactory.apiKey(for: .apple) == "")
        #expect(try ProviderFactory.transcriber(.apple, apiKey: "", onDeviceLocale: "en-US").id == "apple")
    }
}
