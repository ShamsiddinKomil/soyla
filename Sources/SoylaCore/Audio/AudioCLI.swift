import Foundation
import AVFoundation
import os

// OWNER: Agent A (Audio).
// `soyla rec-test [seconds] [--warm] [--builtin]` : record N s (default 3) from the default mic, encode in every
// format, print bytes + encode ms per format, save to recordings/rectest-<id>.<fmt>.
// --warm: prepare() the engine (300 ms pre-roll ring, as the app uses), wait 1 s, then start — compares
//         first-buffer latency cold vs warm and shows the pre-roll bytes prepended on start.
// --builtin: prefer the built-in mic (Settings → "Prefer built-in microphone").
// Always prints: input device, first-buffer latency, pre-roll bytes, tap cadence → stop grace, capture verdict.
public enum AudioCLI {
    public static func recTest(args: [String]) async throws {
        let warm = args.contains("--warm")
        let builtin = args.contains("--builtin")
        let seconds = args.first { !$0.hasPrefix("--") }.flatMap(Double.init) ?? 3
        guard seconds > 0, seconds <= 120 else { throw SoylaError.audio("seconds must be in (0, 120]") }

        let rec = Recorder(preRollMs: DictationPipeline.preRollMs, preferBuiltInMic: builtin)
        let pick = AudioDevices.resolve(preferBuiltIn: builtin)
        print("inputs: " + AudioDevices.inputs().map { "\($0.name)\($0.builtIn ? " [built-in]" : "")" }.joined(separator: ", "))
        print("resolved input: \(pick.name)\(pick.pinned ? " (pinned)" : " (system default)")")
        // Written from the audio thread, read here.
        let firstAt = OSAllocatedUnfairLock<Date?>(initialState: nil)
        let chunks = OSAllocatedUnfairLock(initialState: 0)
        rec.onFirstBuffer = { firstAt.withLock { $0 = Date() } }
        defer { rec.shutdown() }
        if warm {
            let tp = Date()
            try await rec.prepare()
            print(String(format: "warm: engine prepared in %.0f ms, waiting 1 s", Date().timeIntervalSince(tp) * 1000))
            try await Task.sleep(nanoseconds: 1_000_000_000)
            print(String(format: "warm: idle level=%.3f (buffers discarded except the pre-roll ring)", rec.level))
        }
        let t0 = Date()
        try await rec.start(onChunk: { _ in chunks.withLock { $0 += 1 } })
        print("device: \(rec.activeInputName ?? "?")")
        print(String(format: "pre-roll: %d bytes = %.0f ms prepended on start", rec.lastPreRollBytes,
                     Encoder.duration(pcm16: Data(count: rec.lastPreRollBytes)) * 1000))
        print("recording \(String(format: "%.1f", seconds)) s (\(warm ? "warm" : "cold")) — speak now")
        let ticks = Int((seconds * 2).rounded())
        for _ in 0..<ticks {
            try await Task.sleep(nanoseconds: 500_000_000)
            print(String(format: ". level=%.3f", rec.level))
            fflush(stdout)
        }
        let cadence = rec.observedCadenceMs
        let preBytes = rec.lastPreRollBytes
        let ts = Date()
        let pcm = try await rec.stop()
        let stopMs = Date().timeIntervalSince(ts) * 1000
        let firstMs = firstAt.withLock { $0 }.map { $0.timeIntervalSince(t0) * 1000 } ?? -1
        print(String(format: "first buffer after %.0f ms (%@ start)", firstMs, warm ? "warm" : "cold"))
        print(String(format: "tap cadence %.0f ms → stop grace %.0f ms (stop() took %.0f ms)", cadence ?? -1,
                     Recorder.stopGraceMs(cadenceMs: cadence), stopMs))
        let post = pcm.subdata(in: min(preBytes, pcm.count)..<pcm.count)
        let (pk, rms) = CaptureCheck.peakAndRms(post)
        let verdict = CaptureCheck.classify(pcm: post, heldMs: seconds * 1000, minDurationSec: 0.6, minVoicedMs: 250)
        print(String(format: "device %@ · pre-roll %d bytes · peak %.4f rms %.4f · voiced %.0f ms · verdict %@",
                     rec.activeInputName ?? "?", preBytes, pk, rms, Encoder.voicedMs(pcm16: post), String(describing: verdict)))
        print(String(format: "captured %d bytes = %.2f s PCM16 16 kHz mono, %d chunks",
                      pcm.count, Encoder.duration(pcm16: pcm), chunks.withLock { $0 }))
        if pcm.isEmpty { throw SoylaError.audio("no audio captured") }
        if pcm.allSatisfy({ $0 == 0 }) { print("warning: all samples are zero (mic muted or access silently blocked?)") }

        let id = RunRecord.newId().runId
        print("format bytes encode_ms")
        var wavURL: URL?
        for fmt in AudioFormatChoice.allCases {
            let url = SoylaPaths.recordings.appendingPathComponent("rectest-\(id).\(fmt.rawValue)")
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                let enc = try Encoder.encode(pcm16: pcm, format: fmt, saveTo: url)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                print(String(format: "%@ %d %.1f", fmt.rawValue, enc.data.count, ms))
                if fmt == .wav { wavURL = enc.fileURL }
            } catch {
                print("\(fmt.rawValue) ERROR \(error.localizedDescription)")
            }
        }

        if let wavURL {
            let f = try AVAudioFile(forReading: wavURL)
            let expected = AVAudioFramePosition(pcm.count / 2)
            let ok = f.length == expected && f.fileFormat.sampleRate == Double(PCMSpec.sampleRate)
                && f.fileFormat.channelCount == 1
            print("wav verify: frames=\(f.length) expected=\(expected) sr=\(Int(f.fileFormat.sampleRate)) ch=\(f.fileFormat.channelCount) → \(ok ? "OK" : "MISMATCH")")
            print("saved to \(SoylaPaths.recordings.path)/rectest-\(id).*")
            if !ok { throw SoylaError.audio("WAV verification failed") }
        }
    }
}
