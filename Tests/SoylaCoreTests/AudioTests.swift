import Testing
import Foundation
import AVFoundation
@testable import SoylaCore

/// Synthetic 16 kHz mono PCM16 LE sine.
private func sine(seconds: Double, hz: Double = 440, amp: Double = 0.5) -> Data {
    let n = Int(seconds * Double(PCMSpec.sampleRate))
    var d = Data(capacity: n * 2)
    for i in 0..<n {
        let v = Int16(amp * 32767 * sin(2 * .pi * hz * Double(i) / Double(PCMSpec.sampleRate)))
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
    return d
}

private func u32(_ d: Data, _ o: Int) -> UInt32 { d.subdata(in: o..<o+4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } }
private func u16(_ d: Data, _ o: Int) -> UInt16 { d.subdata(in: o..<o+2).withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) } }
private func ascii(_ d: Data, _ o: Int) -> String { String(decoding: d.subdata(in: o..<o+4), as: UTF8.self) }

private func decodedFrames(_ enc: EncodedAudio) throws -> (AVAudioFramePosition, Double, AVAudioChannelCount) {
    let r = try decode(enc); return (r.frames, r.sr, r.ch)
}

private func decode(_ enc: EncodedAudio) throws -> (frames: AVAudioFramePosition, sr: Double, ch: AVAudioChannelCount, rms: Double) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("soyla-test-\(UUID().uuidString).\(enc.format)")
    try enc.data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let f = try AVAudioFile(forReading: url)
    // Read it fully to prove it decodes, not just that the header parses.
    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: buf)
    var sum = 0.0
    let n = Int(buf.frameLength)
    if let fl = buf.floatChannelData?[0] { for i in 0..<n { sum += Double(fl[i] * fl[i]) } }
    return (AVAudioFramePosition(n), f.fileFormat.sampleRate, f.fileFormat.channelCount, n > 0 ? (sum / Double(n)).squareRoot() : 0)
}

@Suite struct AudioTests {
    @Test func wavHeaderIsCanonical() throws {
        let pcm = sine(seconds: 1)
        let enc = try Encoder.encode(pcm16: pcm, format: .wav)
        let d = enc.data
        #expect(d.count == 44 + 32_000)
        #expect(ascii(d, 0) == "RIFF")
        #expect(u32(d, 4) == UInt32(36 + 32_000))
        #expect(ascii(d, 8) == "WAVE")
        #expect(ascii(d, 12) == "fmt ")
        #expect(u32(d, 16) == 16)
        #expect(u16(d, 20) == 1)          // PCM
        #expect(u16(d, 22) == 1)          // mono
        #expect(u32(d, 24) == 16_000)     // sample rate
        #expect(u32(d, 28) == 32_000)     // byte rate
        #expect(u16(d, 32) == 2)          // block align
        #expect(u16(d, 34) == 16)         // bits
        #expect(ascii(d, 36) == "data")
        #expect(u32(d, 40) == 32_000)
        #expect(d.subdata(in: 44..<d.count) == pcm)
        #expect(enc.format == "wav" && enc.sampleRate == 16_000 && enc.durationSec == 1.0)
        let (frames, sr, ch) = try decodedFrames(enc)
        #expect(frames == 16_000 && sr == 16_000 && ch == 1)
    }

    @Test func durationFromBytes() {
        #expect(Encoder.duration(pcm16: Data(count: 32_000)) == 1.0)
        #expect(Encoder.duration(pcm16: Data(count: 8_000)) == 0.25)
        #expect(Encoder.duration(pcm16: Data()) == 0)
    }

    @Test(arguments: [AudioFormatChoice.flac, .m4a])
    func roundTripAVAudioFile(format: AudioFormatChoice) throws {
        let pcm = sine(seconds: 2)
        let enc = try Encoder.encode(pcm16: pcm, format: format)
        #expect(enc.format == format.rawValue)
        #expect(enc.data.count > 100 && enc.data.count < pcm.count)
        let (frames, sr, ch, rms) = try decode(enc)
        #expect(sr == 16_000 && ch == 1)
        // 0.5-amplitude sine → RMS ≈ 0.354; a broken chunk-offset patch would decode garbage/silence.
        #expect(abs(rms - 0.354) < 0.05, "\(format) rms \(rms)")
        if format == .m4a {
            #expect(enc.data.range(of: Data("free".utf8)) == nil, "m4a still has a free atom")
            #expect(enc.data.count < 20_000, "m4a 2 s is \(enc.data.count) bytes")
        }
        // AAC adds encoder priming/padding (≤ 1 frame of 1024 + 2112 priming); FLAC is exact.
        let tol: AVAudioFramePosition = format == .flac ? 0 : 3_200
        #expect(abs(frames - 32_000) <= tol, "\(format) decoded \(frames) frames")
    }

    @Test func saveToCreatesParentDirs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soyla-test-\(UUID().uuidString)/a/b")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        let url = dir.appendingPathComponent("x.wav")
        let enc = try Encoder.encode(pcm16: sine(seconds: 0.1), format: .wav, saveTo: url)
        #expect(enc.fileURL == url)
        #expect(try Data(contentsOf: url) == enc.data)
    }

    @Test func encodeTenSecondsIsFast() throws {
        let pcm = sine(seconds: 10)
        for fmt in [AudioFormatChoice.wav, .flac, .m4a] {
            _ = try Encoder.encode(pcm16: pcm, format: fmt) // warm-up (codec load)
            let t = Date()
            _ = try Encoder.encode(pcm16: pcm, format: fmt)
            let ms = Date().timeIntervalSince(t) * 1000
            print("encode 10 s \(fmt.rawValue): \(String(format: "%.1f", ms)) ms")
            #expect(ms < 200, "\(fmt) took \(ms) ms")  // target <50 ms; loose bound to avoid CI flake
        }
    }

    @Test(.enabled(if: Encoder.ffmpegPath != nil, "ffmpeg not installed"))
    func oggOpusViaFfmpeg() throws {
        let enc = try Encoder.encode(pcm16: sine(seconds: 2), format: .ogg)
        #expect(enc.format == "ogg")
        #expect(String(decoding: enc.data.prefix(4), as: UTF8.self) == "OggS")
        #expect(enc.data.range(of: Data("OpusHead".utf8)) != nil)
    }
}

/// 100 ms of 48 kHz mono Float32 sine, like a real tap buffer on this Mac.
private func hwBuffer(amp: Float = 0.5, frames: Int = 4800) -> AVAudioPCMBuffer {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
    for i in 0..<frames { b.floatChannelData![0][i] = amp * sinf(2 * .pi * 440 * Float(i) / 48_000) }
    b.frameLength = AVAudioFrameCount(frames)
    return b
}

private final class Counter: @unchecked Sendable {
    private let l = NSLock(); private var n = 0; private var b = 0
    func hit(_ bytes: Int = 0) { l.withLock { n += 1; b += bytes } }
    var count: Int { l.withLock { n } }
    var bytes: Int { l.withLock { b } }
}

@Suite struct RecorderWarmTests {
    @Test func warmArmDisarmCycle() async throws {
        let r = Recorder()
        try r._prepareForTesting(inputFormat: hwBuffer().format)
        let first = Counter(), chunks = Counter()
        r.onFirstBuffer = { first.hit() }

        // Prepared but not armed: buffers discarded, level live, no callbacks.
        for _ in 0..<3 { r.process(hwBuffer()) }
        #expect(r.level > 0.3)
        #expect(first.count == 0)
        #expect(try await r.stop().isEmpty)          // stop without start: nothing captured

        // Arm: very next buffer is the first captured one. Byte counts may exceed input by the resampler
        // latency (measured 7-15 ms = 224-480 bytes): pre-arm audio still in the filter + the flushed tail.
        try await r.start(onChunk: { chunks.hit($0.count) })
        try await r.start(onChunk: { _ in Issue.record("second start must be a no-op") })
        for _ in 0..<10 { r.process(hwBuffer()) }     // 1 s of input
        let pcm = try await r.stop()
        #expect(first.count == 1)
        #expect(chunks.count == 10)
        #expect(abs(pcm.count - 32_000) <= 512, "got \(pcm.count) bytes for 1 s")
        #expect(chunks.bytes <= pcm.count)            // pcm also holds the flushed tail
        #expect(r._isActiveForTesting)                // warm: engine path stays up
        #expect(try await r.stop().isEmpty)           // second stop: nothing armed → no stale audio

        // Disarmed again: discarded, no new chunks.
        r.process(hwBuffer())
        #expect(chunks.count == 10)

        // Second hold: fresh buffer, onFirstBuffer fires again exactly once.
        try await r.start()
        for _ in 0..<5 { r.process(hwBuffer()) }
        let pcm2 = try await r.stop()
        #expect(first.count == 2)
        #expect(abs(pcm2.count - 16_000) <= 512, "pcm2 \(pcm2.count)")

        // Cancel discards but stays warm.
        try await r.start()
        r.process(hwBuffer())
        r.cancel()
        #expect(try await r.stop().isEmpty)
        #expect(r._isActiveForTesting)

        // Shutdown leaves warm mode; buffers are ignored.
        r.shutdown()
        #expect(!r._isActiveForTesting)
        r.process(hwBuffer())
        #expect(r.level == 0)
    }

    @Test func voicedMsSeparatesSpeechFromSilence() {
        #expect(Encoder.voicedMs(pcm16: sine(seconds: 1, amp: 0.001)) == 0)          // room noise
        #expect(Encoder.voicedMs(pcm16: sine(seconds: 1, amp: 0.2)) >= 960)          // speech-level signal
        var tap = sine(seconds: 0.04, amp: 0.3); tap.append(sine(seconds: 0.5, amp: 0.001))
        #expect(Encoder.voicedMs(pcm16: tap) < 250)                                  // click + silence = accidental touch
    }
}

@Suite struct FFmpegEnvironmentTests {
    /// D9: the ffmpeg child gets PATH and HOME only, never keys, Soyla switches or injected libraries.
    @Test func keepsOnlyPathAndHome() {
        let env = ["PATH": "/usr/bin:/bin", "HOME": "/Users/test", "OPENROUTER_API_KEY": "FAKE1234",
                   "GEMINI_API_KEY": "FAKE1234", "SOYLA_HOME": "/tmp/x", "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib"]
        #expect(Encoder.ffmpegEnvironment(from: env) == ["PATH": "/usr/bin:/bin", "HOME": "/Users/test"])
    }

    @Test func missingVariablesStayMissing() {
        #expect(Encoder.ffmpegEnvironment(from: ["PATH": "/bin", "OPENROUTER_API_KEY": "FAKE1234"]) == ["PATH": "/bin"])
        #expect(Encoder.ffmpegEnvironment(from: [:]).isEmpty)
    }
}
