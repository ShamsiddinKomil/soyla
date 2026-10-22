import Testing
import Foundation
@testable import SoylaCore

/// Synthetic audio only: "speech" = a 0.3-amplitude square wave, "pause" = zeros.
private func audio(_ parts: [(speech: Bool, sec: Double)]) -> Data {
    var d = Data()
    for p in parts {
        let n = Int(p.sec * Double(PCMSpec.sampleRate))
        var s = [Int16](repeating: 0, count: n)
        if p.speech { for i in 0..<n { s[i] = (i / 20) % 2 == 0 ? 9830 : -9830 } }
        s.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
    }
    return d
}

private func feed(_ seg: inout Segmenter, _ pcm: Data) -> [Segmenter.Piece] {
    var out: [Segmenter.Piece] = []
    var off = 0
    while off < pcm.count {                                  // 100 ms chunks, like the recorder
        let n = min(3200, pcm.count - off)
        out += seg.append(pcm.subdata(in: off..<(off + n)))
        off += n
    }
    return out
}

private func sec(_ bytes: Int) -> Double { Double(bytes) / Double(PCMSpec.bytesPerSecond) }

@Suite struct SegmenterTests {
    @Test func cutsInTheMiddleOfAPauseAfterMinLength() {
        var seg = Segmenter()
        let pcm = audio([(true, 7), (false, 0.6), (true, 4)])
        let pieces = feed(&seg, pcm)
        #expect(pieces.count == 1)
        let p = pieces[0]
        #expect(p.start == 0 && !p.hardCut)
        #expect(sec(p.end) > 7.1 && sec(p.end) < 7.4)       // inside the 7.0–7.6 s pause, not in speech
        let tail = seg.finish(end: pcm.count)
        #expect(tail?.start == p.end && tail?.end == pcm.count && tail?.index == 1)
    }

    @Test func shortPausesBeforeMinLengthDoNotCut() {
        var seg = Segmenter()
        let pcm = audio([(true, 2), (false, 0.6), (true, 2), (false, 0.6), (true, 1)])
        #expect(feed(&seg, pcm).isEmpty)
        #expect(seg.finish(end: pcm.count) == Segmenter.Piece(index: 0, start: 0, end: pcm.count, hardCut: false))
    }

    @Test func noPauseHardCutsAtMaxWithOverlap() {
        var seg = Segmenter()
        let pcm = audio([(true, 24), (false, 0.1), (true, 8)])   // a 100 ms dip, too short to be a pause
        let pieces = feed(&seg, pcm)
        #expect(pieces.count == 1)
        let p = pieces[0]
        #expect(p.hardCut)
        #expect(sec(p.end) > 23.9 && sec(p.end) < 24.2)      // at the quietest spot of the last 3 s
        let tail = seg.finish(end: pcm.count)
        #expect(tail.map { sec(p.end - $0.start) } ?? 0 >= 0.3)   // next piece re-hears ≥ 300 ms
    }

    @Test func longDictationMakesSeveralPieces() {
        var seg = Segmenter()
        var parts: [(speech: Bool, sec: Double)] = []
        for _ in 0..<6 { parts += [(true, 8), (false, 0.5)] }
        let pcm = audio(parts)
        let pieces = feed(&seg, pcm)
        #expect(pieces.count == 6)
        for (a, b) in zip(pieces, pieces.dropFirst()) { #expect(b.start == a.end) }   // no gaps, no overlap
        #expect(seg.finish(end: pcm.count).map { sec($0.end - $0.start) } ?? 99 < 0.5)
    }

    @Test func bytesClampToTheRecording() {
        var seg = Segmenter()
        let pcm = audio([(true, 1)])
        _ = feed(&seg, pcm)
        let p = Segmenter.Piece(index: 0, start: 0, end: pcm.count + 999, hardCut: false)
        #expect(seg.bytes(p).count == pcm.count)
    }

    @Test func joinDropsTheRepeatAfterAHardCut() {
        let t = SegmentJoin.join(["Bugun biz yangi", "yangi versiyani chiqaramiz.", "Потом напишу."],
                                 hardCutBefore: [false, true, false])
        #expect(t == "Bugun biz yangi versiyani chiqaramiz. Потом напишу.")
        // After a pause cut nothing is dropped, even if words repeat (the speaker said them twice).
        #expect(SegmentJoin.join(["ha ha", "ha ha"], hardCutBefore: [false, false]) == "ha ha ha ha")
        #expect(SegmentJoin.join(["Salom.", ""], hardCutBefore: [false, true]) == "Salom.")
    }
}

/// Answers by audio length (WAV = 44 + PCM bytes), so concurrent pieces get stable, distinct fake texts.
private actor LengthSTT: TranscriptionProvider {
    nonisolated let id = "length"
    var replies: [Int: [Result<String, SoylaError>]]           // keyed by PCM seconds × 10
    private(set) var calls: [TranscribeOptions] = []
    init(_ replies: [Int: [Result<String, SoylaError>]]) { self.replies = replies }
    func transcribe(_ audio: EncodedAudio, options: TranscribeOptions, timeline: RunTimeline) async throws -> TranscriptResult {
        calls.append(options)
        let key = Int((Double(audio.data.count - 44) / Double(PCMSpec.bytesPerSecond) * 10).rounded())
        guard var list = replies[key], !list.isEmpty else { return TranscriptResult(text: "?") }
        let r = list.removeFirst(); replies[key] = list
        return TranscriptResult(text: try r.get(), usage: Usage(inputTokens: 10, outputTokens: 2))
    }
}

@Suite struct SegmentedTranscriberTests {
    let tone1 = audio([(true, 1.0)]), tone2 = audio([(true, 2.0)]), tone3 = audio([(true, 3.0)])

    @Test func joinsInOrderAndSumsUsage() async throws {
        let stt = LengthSTT([10: [.success("Bugun biz")], 20: [.success("yangi versiyani")], 30: [.success("chiqaramiz.")]])
        let st = SegmentedTranscriber(provider: stt, options: TranscribeOptions(model: "m"), format: .wav, useContext: false)
        await st.submit(index: 0, pcm: tone3, hardCutBefore: false)    // slowest-looking piece first
        await st.submit(index: 1, pcm: tone2, hardCutBefore: false)
        await st.submit(index: 2, pcm: tone1, hardCutBefore: false)
        let o = try await st.finish()
        #expect(o.result.text == "chiqaramiz. yangi versiyani Bugun biz")   // piece order, not finish order
        #expect(o.pieces == 3 && o.result.providerMeta["segments"] == "3" && o.result.providerMeta["script_check"] == "ok")
        #expect(o.result.usage?.inputTokens == 30)
    }

    @Test func silentPieceIsNotSentAndFailedPieceIsRetriedOnce() async throws {
        let stt = LengthSTT([10: [.failure(.http(status: 503, body: "")), .success("Salom.")]])
        let st = SegmentedTranscriber(provider: stt, options: TranscribeOptions(model: "m"), format: .wav)
        await st.submit(index: 0, pcm: audio([(false, 2.0)]), hardCutBefore: false)
        await st.submit(index: 1, pcm: tone1, hardCutBefore: false)
        let o = try await st.finish()
        #expect(o.result.text == "Salom.")
        #expect(await stt.calls.count == 2)                                 // silence never sent; 503 retried
    }

    @Test func twoFailuresThrowSoTheCallerFallsBack() async {
        let stt = LengthSTT([10: [.failure(.http(status: 503, body: "")), .failure(.http(status: 503, body: ""))]])
        let st = SegmentedTranscriber(provider: stt, options: TranscribeOptions(model: "m"), format: .wav)
        await st.submit(index: 0, pcm: tone1, hardCutBefore: false)
        await #expect(throws: (any Error).self) { try await st.finish() }
    }

    @Test func nextPieceGetsThePreviousTextAsContext() async throws {
        let stt = LengthSTT([10: [.success("Birinchi qism.")], 20: [.success("Ikkinchi qism.")]])
        let st = SegmentedTranscriber(provider: stt, options: TranscribeOptions(model: "m"), format: .wav)
        await st.submit(index: 0, pcm: tone1, hardCutBefore: false)
        _ = try await st.finish()                                            // piece 0 done before piece 1 starts
        await st.submit(index: 1, pcm: tone2, hardCutBefore: false)
        let o = try await st.finish()
        #expect(o.result.text == "Birinchi qism. Ikkinchi qism.")
        let ctx = await stt.calls.last?.extraInstruction ?? ""
        #expect(ctx.contains("«Birinchi qism.»") && ctx.contains("never repeat"))
    }
}

@Suite struct SegmentFeederTests {
    @Test func chunksInPiecesOutAndTailFromTheWholeRecording() async throws {
        // 7 s speech, 0.6 s pause, 2 s speech → one piece at the pause + the tail.
        let pcm = audio([(true, 7), (false, 0.6), (true, 2)])
        let stt = LengthSTT([:])                                         // every piece → "?"
        let feeder = SegmentFeeder(transcriber: SegmentedTranscriber(provider: stt, options: TranscribeOptions(model: "m"), format: .wav))
        var off = 0
        while off < pcm.count { let n = min(3200, pcm.count - off); feeder.feed(pcm.subdata(in: off..<(off + n))); off += n }
        let o = try await feeder.finish(whole: pcm)
        #expect(o.pieces == 2 && o.result.text == "? ?")
        let secs = await stt.calls.count
        #expect(secs == 2)
    }
}

@Suite struct PipelineSegmentsTests {
    let fakeAudio = EncodedAudio(data: Data(), format: "wav", durationSec: 1, sampleRate: 16000, fileURL: nil)

    @Test func piecesThatFailTwiceFallBackToTheWholeRecording() async throws {
        let pcm = audio([(true, 1.0)])
        let stt = LengthSTT([10: [.failure(.http(status: 503, body: "")), .failure(.http(status: 503, body: "")), .success("Butun yozuv.")]])
        let feeder = SegmentFeeder(transcriber: SegmentedTranscriber(provider: stt, options: TranscribeOptions(model: "m"), format: .wav))
        feeder.feed(pcm)
        let r = try await DictationPipeline.transcript(stt, audio: fakeAudio, options: TranscribeOptions(model: "m"),
                                                       timeline: RunTimeline(), segments: (feeder, pcm))
        #expect(r.text == "Butun yozuv." && r.providerMeta["segments"] == "fallback")
        #expect(await stt.calls.count == 3)
    }

    @Test func piecesWinWhenTheyWork() async throws {
        let pcm = audio([(true, 1.0)])
        let stt = LengthSTT([10: [.success("Bo'lak.")]])
        let feeder = SegmentFeeder(transcriber: SegmentedTranscriber(provider: stt, options: TranscribeOptions(model: "m"), format: .wav))
        feeder.feed(pcm)
        let r = try await DictationPipeline.transcript(stt, audio: fakeAudio, options: TranscribeOptions(model: "m"),
                                                       timeline: RunTimeline(), segments: (feeder, pcm))
        #expect(r.text == "Bo'lak." && r.providerMeta["segments"] == "1" && r.providerMeta["segments_pending_at_release"] != nil)
    }

    /// Owner, 2026-10-17: pieces on by default (was off while experimental); off in Settings → no feeder.
    @MainActor @Test func settingIsOnByDefaultAndOffMeansNoFeeder() {
        #expect(Settings().streamSegments)
        #expect(DictationPipeline.segmentFeeder(Settings(), LengthSTTStub()) != nil)
        var off = Settings(); off.streamSegments = false
        #expect(DictationPipeline.segmentFeeder(off, LengthSTTStub()) == nil)
    }
}

private struct LengthSTTStub: TranscriptionProvider {
    let id = "stub"
    func transcribe(_ audio: EncodedAudio, options: TranscribeOptions, timeline: RunTimeline) async throws -> TranscriptResult {
        TranscriptResult(text: "")
    }
}

/// Owner, 2026-10-17: pieces by default, 15 s pieces, a 5-minute limit, and stray letters never discard a dictation.
@Suite struct PiecesDefaultTests {
    private func suite() -> (UserDefaults, () -> Void) {
        let name = "soyla.test.pieces.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (d, { dropTestDomain(name) })
    }

    @Test func defaults() {
        let s = Settings()
        #expect(s.streamSegments && s.hardStopSec == 300 && s.warnAtSec == 285)
        #expect(Segmenter.Config.app.minSec == 15 && Segmenter.Config().minSec == 6)
    }

    @Test func savedSettingsMoveOnceAndLaterChoicesStay() {
        let (d, cleanup) = suite(); defer { cleanup() }
        d.set(Data(#"{"provider":"google","sttModel":"gemini-3.5-flash","streamSegments":false,"warnAtSec":45,"hardStopSec":55}"#.utf8), forKey: "settings.v1")
        d.set(true, forKey: "migrated.v02")
        let store = SettingsStore(defaults: d)
        #expect(store.current.streamSegments && store.current.hardStopSec == 300 && store.current.warnAtSec == 285)
        store.update { $0.streamSegments = false }
        #expect(!SettingsStore(defaults: d).current.streamSegments)          // a later deliberate "off" is kept
    }

    @Test func customLimitsAreKept() {
        let (d, cleanup) = suite(); defer { cleanup() }
        d.set(Data(#"{"provider":"google","sttModel":"gemini-3.5-flash","warnAtSec":30,"hardStopSec":40}"#.utf8), forKey: "settings.v1")
        d.set(true, forKey: "migrated.v02")
        let s = SettingsStore(defaults: d).current
        #expect(s.hardStopSec == 40 && s.warnAtSec == 30 && s.streamSegments)
    }

    /// Without pieces one request carries the whole clip: keep the old 45/55 s guard (60 s server timeout).
    @MainActor @Test func limitsWithoutPiecesStayShort() {
        var s = Settings()
        #expect(DictationPipeline.recordingLimits(s) == (warn: 285, stop: 300))
        s.streamSegments = false
        #expect(DictationPipeline.recordingLimits(s) == (warn: 45, stop: 55))
        s.hardStopSec = 40; s.warnAtSec = 30
        #expect(DictationPipeline.recordingLimits(s) == (warn: 30, stop: 40))
    }

    /// 2026-10-17 11:21: a 45 s dictation was discarded over a few Arabic letters, twice. Now they are removed.
    @Test func afewStrayForeignLettersAreRemovedNotFatal() async throws {
        let body = "I think we should test the new update with early users and collect their feedback before"
        let stt = MockSTT(body + " مر the public launch.", body + " the public مرحبا launch.")
        let audio = EncodedAudio(data: Data([1]), format: "wav", durationSec: 10, sampleRate: 16000, fileURL: nil)
        let r = try await ScriptCheck.transcribe(stt, audio: audio, options: TranscribeOptions(model: "m"), timeline: RunTimeline())
        #expect(r.text == body + " the public launch.")
        #expect(r.providerMeta["script_check"] == "stripped:foreign:arabic")
    }

    @Test func mostlyForeignTextIsStillACard() async {
        let stt = MockSTT("مرحبا بكم في التطبيق hello", "مرحبا بكم في التطبيق hello")
        let audio = EncodedAudio(data: Data([1]), format: "wav", durationSec: 3, sampleRate: 16000, fileURL: nil)
        await #expect(throws: ScriptCheckError.self) {
            _ = try await ScriptCheck.transcribe(stt, audio: audio, options: TranscribeOptions(model: "m"), timeline: RunTimeline())
        }
    }
}
