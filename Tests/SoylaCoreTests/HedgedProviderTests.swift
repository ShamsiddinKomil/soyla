import Foundation
import os
import Testing
@testable import SoylaCore

/// Answers after `delays[call]` seconds (call 0 = the primary, 1 = the backup); throws when `fail` holds the call.
private final class TimedSTT: TranscriptionProvider, Sendable {
    let id = "fake"
    let delays: [Double], fail: Set<Int>
    private let n = OSAllocatedUnfairLock(initialState: 0)
    var calls: Int { n.withLock { $0 } }
    init(_ delays: [Double], fail: Set<Int> = []) { self.delays = delays; self.fail = fail }
    func transcribe(_ audio: EncodedAudio, options: TranscribeOptions, timeline: RunTimeline) async throws -> TranscriptResult {
        let i = n.withLock { v in defer { v += 1 }; return v }
        try await Task.sleep(for: .seconds(delays[min(i, delays.count - 1)]))
        if fail.contains(i) { throw SoylaError.decode("FAKE failure \(i)") }
        return TranscriptResult(text: "FAKE answer \(i)")
    }
}

@Suite struct HedgedProviderTests {
    let audio = EncodedAudio(data: Data(), format: "flac", durationSec: 5, sampleRate: 16000, fileURL: nil)
    let opts = TranscribeOptions(model: "FAKE-model")

    @Test func fastAnswerSendsNoBackup() async throws {
        let p = TimedSTT([0.01])
        let r = try await HedgedProvider(p, delay: { _ in 0.3 }).transcribe(audio, options: opts, timeline: RunTimeline())
        #expect(r.text == "FAKE answer 0" && r.providerMeta["hedged"] == nil)
        try await Task.sleep(for: .seconds(0.4))
        #expect(p.calls == 1)
    }

    @Test func slowAnswerIsBeatenByTheBackup() async throws {
        let p = TimedSTT([2.0, 0.01])
        let tl = RunTimeline()
        let t0 = Date()
        let r = try await HedgedProvider(p, delay: { _ in 0.05 }).transcribe(audio, options: opts, timeline: tl)
        #expect(r.text == "FAKE answer 1" && r.providerMeta["hedged"] == "backup")
        #expect(Date().timeIntervalSince(t0) < 1.0)          // the stuck primary was cancelled, not awaited
        #expect(tl.has(.responseReceived))
    }

    @Test func earlyRealErrorIsNotRetried() async {
        let p = TimedSTT([0.01], fail: [0])
        await #expect(throws: SoylaError.self) {
            try await HedgedProvider(p, delay: { _ in 0.3 }).transcribe(audio, options: opts, timeline: RunTimeline())
        }
        #expect(p.calls == 1)
    }

    @Test func failedBackupStillWaitsForThePrimary() async throws {
        let p = TimedSTT([0.3, 0.01], fail: [1])
        let r = try await HedgedProvider(p, delay: { _ in 0.05 }).transcribe(audio, options: opts, timeline: RunTimeline())
        #expect(r.text == "FAKE answer 0")
    }

    @Test func onDeviceIsNeverHedgedAndDelayGrowsWithLength() {
        #expect(HedgedProvider.wrap(TimedSTT([0])) is HedgedProvider)
        #expect((HedgedProvider.wrap(HedgedProvider(TimedSTT([0]))) as? HedgedProvider)?.base is TimedSTT)   // no double wrap
        #expect(HedgedProvider.defaultDelay(audio) == 3.0)
        let long = EncodedAudio(data: Data(), format: "flac", durationSec: 60, sampleRate: 16000, fileURL: nil)
        #expect(abs(HedgedProvider.defaultDelay(long) - 6.1) < 0.001)
    }
}

@Suite struct TapPendingPillTests {
    @MainActor @Test func tapPendingClearsOnReset() {
        let m = PanelModel()
        m.phase = .recording
        m.tapPending = true
        m.reset()
        #expect(!m.tapPending)
    }
}
