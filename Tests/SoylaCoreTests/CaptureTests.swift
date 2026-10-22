import Testing
import Foundation
import AVFoundation
@testable import SoylaCore

// F2: pre-roll, stop grace, capture verdicts, mic-mode settings migration.

private func pcmSine(seconds: Double, amp: Double) -> Data {
    let n = Int(seconds * Double(PCMSpec.sampleRate))
    var d = Data(capacity: n * 2)
    for i in 0..<n {
        let v = Int16(amp * 32767 * sin(2 * .pi * 440 * Double(i) / Double(PCMSpec.sampleRate)))
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
    return d
}

/// 100 ms of 48 kHz mono Float32, like a real tap buffer.
private func tapBuffer(amp: Float) -> AVAudioPCMBuffer {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4800)!
    for i in 0..<4800 { b.floatChannelData![0][i] = amp * sinf(2 * .pi * 440 * Float(i) / 48_000) }
    b.frameLength = 4800
    return b
}

private final class Chunks: @unchecked Sendable {
    private let l = NSLock(); private var sizes: [Int] = []
    func add(_ n: Int) { l.withLock { sizes.append(n) } }
    var all: [Int] { l.withLock { sizes } }
}

@Suite struct PreRollTests {
    @Test func warmPreRollIsPrependedAndDeliveredFirst() async throws {
        let r = Recorder(preRollMs: 300)
        try r._prepareForTesting(inputFormat: tapBuffer(amp: 0.5).format)
        for _ in 0..<5 { r.process(tapBuffer(amp: 0.5)) }              // 500 ms before key-down
        #expect(r._preRollBufferedBytesForTesting >= 9_600)
        let chunks = Chunks()
        try await r.start(onChunk: { chunks.add($0.count) })
        #expect(r.lastPreRollBytes == 9_600)                           // exactly 300 ms of 16 kHz PCM16
        #expect(chunks.all.first == 9_600)                             // live preview gets the pre-roll first
        #expect(r._preRollBufferedBytesForTesting == 0)                // ring consumed
        for _ in 0..<10 { r.process(tapBuffer(amp: 0.5)) }             // 1 s after key-down
        let pcm = try await r.stop()
        // ± resampler latency + flushed tail (≤ ~25 ms = 800 bytes).
        #expect(abs(pcm.count - (32_000 + 9_600)) <= 800, "got \(pcm.count)")
        #expect(r.capturedPeak > 0.4)
    }

    @Test func noPreRollWhenDisabledAndRingClearedOnCancelAndShutdown() async throws {
        let off = Recorder()                                           // default: pre-roll off (tests, cold path)
        try off._prepareForTesting(inputFormat: tapBuffer(amp: 0.5).format)
        for _ in 0..<5 { off.process(tapBuffer(amp: 0.5)) }
        try await off.start()
        #expect(off.lastPreRollBytes == 0)
        off.cancel()

        let r = Recorder(preRollMs: 300)
        try r._prepareForTesting(inputFormat: tapBuffer(amp: 0.5).format)
        for _ in 0..<5 { r.process(tapBuffer(amp: 0.5)) }
        try await r.start(); r.cancel()
        for _ in 0..<2 { r.process(tapBuffer(amp: 0.5)) }
        r.cancel()                                                     // cancel while idle wipes the ring
        #expect(r._preRollBufferedBytesForTesting == 0)
        for _ in 0..<2 { r.process(tapBuffer(amp: 0.5)) }
        r.shutdown()
        #expect(r._preRollBufferedBytesForTesting == 0)
    }

    @Test func ringNeverGrowsPastTwiceTheCap() throws {
        let r = Recorder(preRollMs: 300)
        try r._prepareForTesting(inputFormat: tapBuffer(amp: 0.5).format)
        for _ in 0..<100 { r.process(tapBuffer(amp: 0.5)) }            // 10 s idle
        #expect(r._preRollBufferedBytesForTesting <= 2 * 9_600)
    }

    @Test func digitalSilenceKeepsPeakAtZero() async throws {
        let r = Recorder()
        try r._prepareForTesting(inputFormat: tapBuffer(amp: 0).format)
        try await r.start()
        for _ in 0..<5 { r.process(tapBuffer(amp: 0)) }
        #expect(r.capturedPeak == 0)
        let pcm = try await r.stop()
        #expect(CaptureCheck.isDigitalSilence(pcm))
    }

    @Test func stopGraceIsCadencePlus8Clamped() {
        #expect(Recorder.stopGraceMs(cadenceMs: nil) == 20)
        #expect(Recorder.stopGraceMs(cadenceMs: 1) == 20)
        #expect(Recorder.stopGraceMs(cadenceMs: 42) == 50)
        #expect(Recorder.stopGraceMs(cadenceMs: 100) == 80)             // 100 ms tap buffers → 80 ms cap
        #expect(Recorder.stopGraceMs(cadenceMs: .infinity) == 20)
    }
}

@Suite struct CaptureVerdictTests {
    private func v(_ pcm: Data, held: Double) -> CaptureVerdict {
        CaptureCheck.classify(pcm: pcm, heldMs: held, minDurationSec: 0.6, minVoicedMs: 250)
    }

    @Test func speechIsSent() { #expect(v(pcmSine(seconds: 2, amp: 0.2), held: 2000) == .send) }

    @Test func tapsStaySilentDrops() {
        var tap = pcmSine(seconds: 0.04, amp: 0.3); tap.append(pcmSine(seconds: 0.4, amp: 0.001))
        #expect(v(tap, held: 450) == .dropSilently)                     // the 2026-10-16 gate is unchanged
        #expect(v(Data(count: 16_000), held: 500) == .dropSilently)     // short zeros = tap, not an error
    }

    @Test func emptyOrDigitalSilenceOnADeliberateHoldIsNoAudio() {
        #expect(v(Data(), held: 1500) == .noAudio)
        #expect(v(Data(count: 64_000), held: 2000) == .noAudio)         // AirPods held by the iPhone
    }

    @Test func nearSilenceOnADeliberateHoldIsDidntCatch() {
        #expect(v(pcmSine(seconds: 2, amp: 0.001), held: 2000) == .didntCatch)
        #expect(v(pcmSine(seconds: 6, amp: 0.001), held: 6000) == .missedSpeech)   // FluidVoice check is ≤ 4 s only
        // Both thresholds must hold: peak 0.005 < 0.01 but rms ≈ 0.0035 ≥ 0.002 → not near-silent.
        #expect(CaptureCheck.isNearSilent(pcmSine(seconds: 1, amp: 0.005)) == false)
    }

    /// Owner, 2026-10-19: a deliberate run (locked, or held ≥ 1.5 s) below the voice gate says "Didn't catch that"
    /// instead of vanishing. Taps and short holds stay silent.
    @Test func shortSpeechInADeliberateRunIsMissedNotDropped() {
        var word = pcmSine(seconds: 0.3, amp: 0.2); word.append(pcmSine(seconds: 1.7, amp: 0.003))
        func c(_ held: Double, locked: Bool = false, gate: Double = 250) -> CaptureVerdict {
            CaptureCheck.classify(pcm: word, heldMs: held, locked: locked, minDurationSec: 0.6, minVoicedMs: gate)
        }
        #expect(Encoder.voicedMs(pcm16: word) < 400)
        #expect(c(4000, locked: true, gate: 400) == .missedSpeech)        // the 2026-10-19 log: 380 ms voiced, Strict
        #expect(c(1600, gate: 400) == .missedSpeech)
        #expect(c(1200, gate: 400) == .dropSilently)                      // under 1.5 s: still an accident
        #expect(c(1200, locked: true, gate: 400) == .missedSpeech)        // a lock is deliberate whatever its length
        #expect(c(4000, locked: true, gate: 250) == .send)                // enough speech: unchanged
        var tap = pcmSine(seconds: 0.04, amp: 0.3); tap.append(pcmSine(seconds: 0.4, amp: 0.001))
        #expect(CaptureCheck.classify(pcm: tap, heldMs: 450, minDurationSec: 0.6, minVoicedMs: 250) == .dropSilently)
    }

    @Test func preRollCannotTurnATapIntoADictation() {
        // 300 ms of loud speech just before the press + an accidental tap: the gate looks at post-key audio only.
        var pcm = pcmSine(seconds: 0.3, amp: 0.3)
        let preRoll = pcm.count
        pcm.append(pcmSine(seconds: 0.5, amp: 0.001))
        #expect(Encoder.voicedMs(pcm16: pcm) >= 250)                    // whole buffer would have passed
        #expect(v(pcm.subdata(in: preRoll..<pcm.count), held: 500) == .dropSilently)
    }
}

@Suite struct MicSettingsTests {
    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    @Test func legacyBoolMigrates() throws {
        #expect(try decode(#"{"keepMicWarm": true}"#).micWarmMode == .always)
        #expect(try decode(#"{"keepMicWarm": false}"#).micWarmMode == .off)
        #expect(try decode(#"{}"#).micWarmMode == .off)
        #expect(Settings().micWarmMode == .off)
    }

    // Owner decision 2026-10-16: new installs prefer the built-in mic (headsets held by an iPhone gave "no sound");
    // a saved settings file without the field keeps the old behaviour, so nobody is switched silently.
    @Test func builtInMicIsTheNewDefaultButNotForExistingSettings() throws {
        #expect(Settings().preferBuiltInMic == true)
        #expect(try decode(#"{}"#).preferBuiltInMic == false)
        #expect(try decode(#"{"preferBuiltInMic": false}"#).preferBuiltInMic == false)
    }

    @Test func newFieldWinsAndUnknownIsOff() throws {
        #expect(try decode(#"{"keepMicWarm": true, "micWarmMode": "idleClose30s"}"#).micWarmMode == .idleClose30s)
        #expect(try decode(#"{"micWarmMode": "sometimes"}"#).micWarmMode == .off)
        #expect(try decode(#"{"micWarmMode": 3, "sttModel": "x"}"#).sttModel == "x")   // a bad type doesn't reset the rest
        #expect(try decode(#"{"preferBuiltInMic": true}"#).preferBuiltInMic)
    }

    @Test func roundTripDropsTheLegacyKey() throws {
        var s = Settings(); s.micWarmMode = .idleClose30s; s.preferBuiltInMic = true
        let data = try JSONEncoder().encode(s)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("keepMicWarm"))
        let back = try JSONDecoder().decode(Settings.self, from: data)
        #expect(back.micWarmMode == .idleClose30s && back.preferBuiltInMic)
    }
}

/// Owner, 2026-10-19: a dead external mic (AirPods gone mid-hold) shows the quiet "Didn't catch that" card instead of
/// vanishing; still no error card for external inputs. The built-in mic keeps its "No sound from" card.
@Suite struct NoAudioCardTests {
    @Test func externalOrGoneInputGetsTheQuietCard() {
        #expect(PillFailure.forEmptyCapture(device: "Fake Person's AirPods", input: "external", kind: .bluetooth) == .missedSpeech)
        #expect(PillFailure.forEmptyCapture(device: "Gone device", input: "unknown", kind: .unknown) == .missedSpeech)   // unplugged
        #expect(PillFailure.missedSpeech.kind == .soft && !PillFailure.missedSpeech.canRetry)
    }

    @Test func builtInOrUnnamedKeepsTheNoSoundCard() {
        #expect(PillFailure.forEmptyCapture(device: "MacBook Pro Microphone", input: "builtIn", kind: .builtIn)
                == .noSound(device: "MacBook Pro Microphone", input: .builtIn, lidClosed: false))
        #expect(PillFailure.forEmptyCapture(device: nil, input: "unknown", kind: .unknown) == .noSound(device: nil, input: .unknown, lidClosed: false))
    }

    @Test func builtInCardKeepsTheInputHints() {   // merge with main's F-05 card (2026-10-20)
        let lid = PillFailure.forEmptyCapture(device: "MacBook Pro Microphone", input: "builtIn", kind: .builtIn, lidClosed: true)
        #expect(lid.hint == PillFailure.lidClosedHint)
        #expect(PillFailure.forEmptyCapture(device: nil, input: "unknown", kind: .unknown).hint == PillFailure.checkMicHint)
        #expect(PillFailure.forEmptyCapture(device: "Fake AirPods", input: "external", kind: .bluetooth, lidClosed: true) == .missedSpeech)
    }
}
