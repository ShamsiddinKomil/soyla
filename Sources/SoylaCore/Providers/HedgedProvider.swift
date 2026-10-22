import Foundation

/// A second identical request when the first is slow (a hedged request). Gemini usually answers in ~1.8 s, but
/// 2 of 15 runs on 2026-10-17 took 7–8 s with nothing wrong on our side (status 200, no retry); a backup sent at
/// ~3 s usually lands well before the stuck one. Whichever answers first wins, the other is cancelled.
public struct HedgedProvider: TranscriptionProvider {
    public let base: any TranscriptionProvider
    public var id: String { base.id }
    let delay: @Sendable (EncodedAudio) -> Double

    public init(_ base: any TranscriptionProvider,
                delay: @escaping @Sendable (EncodedAudio) -> Double = HedgedProvider.defaultDelay) {
        self.base = base; self.delay = delay
    }

    /// 3 s for short clips, longer for long ones (a 60 s clip legitimately takes longer to transcribe).
    public static func defaultDelay(_ a: EncodedAudio) -> Double { max(3.0, 2.5 + 0.06 * a.durationSec) }

    /// Cloud providers only: on-device has no network tail, and a second run would only double the CPU work.
    public static func wrap(_ p: any TranscriptionProvider) -> any TranscriptionProvider {
        p.id == "apple" || p is HedgedProvider ? p : HedgedProvider(p)
    }

    public func transcribe(_ audio: EncodedAudio, options: TranscribeOptions, timeline: RunTimeline) async throws -> TranscriptResult {
        let wait = delay(audio), base = base
        let clock = ContinuousClock(), started = clock.now
        return try await withThrowingTaskGroup(of: (backup: Bool, r: TranscriptResult?, err: Error?).self) { g in
            g.addTask {
                do { return (false, try await base.transcribe(audio, options: options, timeline: timeline), nil) }
                catch { return (false, nil, error) }
            }
            g.addTask {
                try await Task.sleep(for: .seconds(wait))
                Log.info(String(format: "stt slow: no answer after %.1f s, sending a backup request", wait))
                do { return (true, try await base.transcribe(audio, options: options, timeline: RunTimeline()), nil) }
                catch { return (true, nil, error) }
            }
            var primaryError: Error?
            while let next = try? await g.next() {
                if var r = next.r {
                    g.cancelAll()
                    if next.backup { timeline.mark(.responseReceived); r.providerMeta["hedged"] = "backup" }
                    return r
                }
                if !next.backup {
                    primaryError = next.err
                    // Failed before the backup was due: a real error (key, quota, offline), not a slow answer.
                    if clock.now - started < .seconds(wait) { g.cancelAll(); break }
                }
            }
            try Task.checkCancellation()
            throw primaryError ?? CancellationError()
        }
    }
}
