import Foundation

/// Transcribes `Segmenter` pieces while the user is still speaking, then joins them at release.
/// Each piece goes through the same `ScriptCheck.transcribe` as a whole recording.
/// A failed piece is sent once more; a second failure throws, and the caller falls back to the whole recording.
public actor SegmentedTranscriber {
    public struct Outcome: Sendable {
        public let result: TranscriptResult
        public let pieces: Int
        /// Pieces still in flight when `finish` was called (1 = only the tail).
        public let pendingAtRelease: Int
    }

    private let provider: any TranscriptionProvider
    private let options: TranscribeOptions
    private let format: AudioFormatChoice
    private let minVoicedMs: Double
    private let useContext: Bool
    private var tasks: [Int: Task<TranscriptResult, Error>] = [:]
    private var hardCutBefore: [Int: Bool] = [:]
    private var texts: [Int: String] = [:]                       // finished pieces, for the next piece's context

    public init(provider: any TranscriptionProvider, options: TranscribeOptions, format: AudioFormatChoice = .flac,
                minVoicedMs: Double = 250, useContext: Bool = true) {
        self.provider = provider; self.options = options; self.format = format
        self.minVoicedMs = minVoicedMs; self.useContext = useContext
    }

    /// Starts transcribing one piece. `hardCut` = the piece before it ended with no pause (its start overlaps).
    public func submit(index: Int, pcm: Data, hardCutBefore hard: Bool) {
        hardCutBefore[index] = hard
        // Silence: nothing to send (and the model would invent text or return empty).
        guard Encoder.voicedMs(pcm16: pcm) >= minVoicedMs else {
            texts[index] = ""
            tasks[index] = Task { TranscriptResult(text: "") }
            return
        }
        var opts = options
        if useContext, let prev = texts[index - 1], !prev.isEmpty {
            let line = Self.contextLine(prev)
            opts.extraInstruction = [options.extraInstruction, line].compactMap { $0 }.joined(separator: "\n")
        }
        let provider = provider, format = format
        tasks[index] = Task { [weak self] in
            let audio = try Encoder.encode(pcm16: pcm, format: format)
            let r = try await Self.once(provider, audio, opts)
            await self?.store(index, r.text)
            return r
        }
    }

    /// Waits for every piece in order and joins them. Throws if a piece failed twice.
    public func finish() async throws -> Outcome {
        let order = tasks.keys.sorted()
        let pending = order.filter { texts[$0] == nil }.count
        var results: [TranscriptResult] = []
        for i in order {
            guard let t = tasks[i] else { continue }
            results.append(try await t.value)
        }
        let text = SegmentJoin.join(results.map(\.text), hardCutBefore: order.map { hardCutBefore[$0] ?? false })
        var meta: [String: String] = ["segments": String(order.count)]
        for r in results {
            for (k, v) in r.providerMeta where k != "script_check" || v != "ok" { meta[k] = v }
        }
        if meta["script_check"] == nil { meta["script_check"] = "ok" }
        let usage = results.map(\.usage).reduce(nil) { CleanupFlow.sum($0, $1) }
        return Outcome(result: TranscriptResult(text: text, usage: usage, providerMeta: meta),
                       pieces: order.count, pendingAtRelease: pending)
    }

    public func cancel() { for t in tasks.values { t.cancel() } }

    /// Text of the pieces finished so far, in order, up to the first unfinished one (the Live referee, S6).
    public func finishedPrefix() -> String {
        var out: [String] = []
        var i = 0
        while let t = texts[i] { if !t.isEmpty { out.append(t) }; i += 1 }
        return out.joined(separator: " ")
    }

    private func store(_ i: Int, _ text: String) { texts[i] = text }

    /// One retry per piece; an empty piece (noise the model heard as nothing) is "".
    static func once(_ p: any TranscriptionProvider, _ audio: EncodedAudio, _ o: TranscribeOptions) async throws -> TranscriptResult {
        do { return try await attempt(p, audio, o) }
        catch is CancellationError { throw CancellationError() }
        catch { return try await attempt(p, audio, o) }
    }

    private static func attempt(_ p: any TranscriptionProvider, _ audio: EncodedAudio, _ o: TranscribeOptions) async throws -> TranscriptResult {
        do { return try await ScriptCheck.transcribe(p, audio: audio, options: o, timeline: RunTimeline()) }
        catch SoylaError.emptyTranscript { return TranscriptResult(text: "") }
    }

    /// The last ~200 characters of the previous piece, so names and the language mix stay consistent.
    static func contextLine(_ previous: String) -> String {
        let tail = previous.count > 200 ? "…" + previous.suffix(200) : previous
        return "This audio continues a dictation that so far reads: «\(tail)». Use it only as context: "
            + "transcribe ONLY the new audio and never repeat that text."
    }
}

/// Bridges the recorder's audio-thread chunks to a `Segmenter` in order (AsyncStream keeps order; a Task per chunk
/// would not) and submits each finished piece. At release, `finish(whole:)` sends the tail from the authoritative
/// recording, so the pieces cover exactly the audio a whole-recording request would.
public final class SegmentFeeder: Sendable {
    private struct State: Sendable { let openStart: Int; let nextIndex: Int; let lastWasHard: Bool }
    private let continuation: AsyncStream<Data>.Continuation
    private let consumer: Task<State, Never>
    public let transcriber: SegmentedTranscriber

    public init(transcriber: SegmentedTranscriber, config: Segmenter.Config = .init()) {
        self.transcriber = transcriber
        let (stream, cont) = AsyncStream.makeStream(of: Data.self)
        continuation = cont
        consumer = Task {
            var seg = Segmenter(config: config)
            var prevHard = false
            for await chunk in stream {
                for p in seg.append(chunk) {
                    await transcriber.submit(index: p.index, pcm: seg.bytes(p), hardCutBefore: prevHard)
                    prevHard = p.hardCut
                }
            }
            return State(openStart: seg.openStart, nextIndex: seg.piecesCut, lastWasHard: prevHard)
        }
    }

    /// Safe from any thread (the recorder's audio callback).
    public func feed(_ chunk: Data) { continuation.yield(chunk) }

    public func finish(whole pcm: Data) async throws -> SegmentedTranscriber.Outcome {
        continuation.finish()
        let s = await consumer.value
        if pcm.count > s.openStart {
            await transcriber.submit(index: s.nextIndex, pcm: pcm.subdata(in: s.openStart..<pcm.count), hardCutBefore: s.lastWasHard)
        }
        return try await transcriber.finish()
    }

    public func cancel() {
        continuation.finish()
        let t = transcriber
        Task { await t.cancel() }
    }
}
