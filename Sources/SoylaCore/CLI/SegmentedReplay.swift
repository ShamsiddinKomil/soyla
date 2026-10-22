import Foundation

/// `soyla replay <file> --segmented [--no-context]`: plays a recording at real-time pace through `Segmenter` and
/// `SegmentedTranscriber`, as the app would while fn is held, then prints the joined text and the wait after
/// "release". No run log is written.
enum SegmentedReplay {
    static func run(pcm: Data, provider: any TranscriptionProvider, options: TranscribeOptions,
                    format: AudioFormatChoice, context: Bool, config: Segmenter.Config = .init(), liveFast: Bool = false) async throws {
        let codes = liveFast ? LiveFastDecision.sessions(for: options.languageHint) : nil
        let race = try codes.map { LiveRace(apiKey: try Secrets.geminiKey(), codes: $0) }
        await race?.start(vocabulary: options.vocabulary)
        let st = SegmentedTranscriber(provider: provider, options: options, format: format, useContext: context)
        let feeder = SegmentFeeder(transcriber: st, config: config)  // the app's path
        let t0 = Date()
        var off = 0, i = 0
        while off < pcm.count {
            let chunk = pcm.subdata(in: off..<min(off + 3200, pcm.count))
            feeder.feed(chunk)
            race?.feed(chunk)
            off += chunk.count; i += 1
            let wait = t0.addingTimeInterval(Double(i) * 0.1).timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        }
        let release = Date()
        if let race {
            await race.release()
            let outcome = await race.finish()
            let pieces = await st.finishedPrefix()
            let d = LiveFastDecision.decide(strict: race.strict, live: outcome, pieces: pieces,
                                            voicedSec: Encoder.voicedMs(pcm16: pcm) / 1000)
            let liveMs = Date().timeIntervalSince(release) * 1000
            let o = try await feeder.finish(whole: pcm)
            let geminiMs = Date().timeIntervalSince(release) * 1000
            print("gemini_text: \(o.result.text)")
            print("live_text: \(outcome?.text ?? "")")
            print("text: \(d.source == .live ? outcome?.text ?? "" : o.result.text)")
            print(String(format: "live_fast: source %@ · reason %@ · lang %@ · locked %@ · release→text %.0f ms (gemini %.0f ms)",
                         d.source.rawValue, d.reason, outcome?.language ?? "-", outcome?.locked == true ? "yes" : "no",
                         d.source == .live ? liveMs : geminiMs, geminiMs))
            return
        }
        let o = try await feeder.finish(whole: pcm)
        let ms = Date().timeIntervalSince(release) * 1000
        print("text: \(o.result.text)")
        print("meta: \(o.result.providerMeta.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        print(String(format: "segmented: pieces %d · in flight at release %d · release→text %.0f ms", o.pieces, o.pendingAtRelease, ms))
    }
}
