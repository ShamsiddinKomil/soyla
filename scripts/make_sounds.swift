#!/usr/bin/env swift
// Generates Soyla's UI cue sets procedurally (no external assets): struck notes with natural decay, plus the
// original pure tones as "classic".
// Usage: swift scripts/make_sounds.swift   → Resources/Sounds/{start,done,cancel,warn}.aiff (Soft, the default) and
//        Resources/Sounds/{glass,wood,classic}/{start,done,cancel,warn}.aiff (16-bit mono, 32 kHz)
// `warn` is the 4:45 "nearly at the limit" cue: two quiet equal notes, unlike start (rising) or cancel (falling).
// Tones are rendered straight into AVAudioPCMBuffers and written with AVAudioFile (no audio hardware needed).
import AVFoundation

let rate = 32000.0   // highest partial ~8.8 kHz; keeps the three default cues under the 50 KB budget
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Sounds")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// notes: (frequency Hz, duration s). Each note gets its own 10 ms fade so consecutive notes never click.
func render(_ notes: [(Double, Double)], amplitude: Float = 0.5) -> [Float] {
    var out: [Float] = []
    let fade = Int(0.010 * rate)
    for (freq, dur) in notes {
        let n = Int(dur * rate)
        for i in 0..<n {
            let env = min(1, Float(i) / Float(fade), Float(n - 1 - i) / Float(fade))
            out.append(amplitude * max(0, env) * Float(sin(2 * Double.pi * freq * Double(i) / rate)))
        }
    }
    return out
}

func write(_ name: String, _ samples: [Float]) throws {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    for (i, s) in samples.enumerated() { buf.floatChannelData![0][i] = s }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true,
    ]
    let url = outDir.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buf)
    print("wrote \(url.path) (\(samples.count) frames)")
}

/// A struck note: a 4 ms attack, then each partial decays exponentially (marimba / bell / wood), with a short
/// final fade. `partials`: (frequency multiple, amplitude, decay seconds). `drop`: pitch glide down (wood).
func strike(_ freq: Double, at offset: Double, length: Double, partials: [(Double, Double, Double)], drop: Double = 0) -> [(Int, Float)] {
    let n = Int(length * rate), start = Int(offset * rate)
    var out: [(Int, Float)] = []
    var phase = [Double](repeating: 0, count: partials.count)
    for i in 0..<n {
        let t = Double(i) / rate
        let attack = min(1, t / 0.004), tail = min(1, Double(n - 1 - i) / (0.008 * rate))
        let f = freq * (1 - drop * (1 - exp(-t / 0.02)))
        var v = 0.0
        for (k, p) in partials.enumerated() {
            phase[k] += 2 * Double.pi * f * p.0 / rate
            v += p.1 * exp(-t / p.2) * sin(phase[k])
        }
        out.append((start + i, Float(v * attack * tail)))
    }
    return out
}

/// Mix strikes and normalise the peak (quiet by design: NSSound volume scales it further).
func mix(_ parts: [[(Int, Float)]], peak: Float) -> [Float] {
    let len = parts.flatMap { $0 }.map(\.0).max().map { $0 + 1 } ?? 0
    var buf = [Float](repeating: 0, count: len)
    for p in parts { for (i, v) in p { buf[i] += v } }
    let m = buf.map(abs).max() ?? 1
    return buf.map { $0 / max(m, 1e-6) * peak }
}

let marimba: [(Double, Double, Double)] = [(1, 1, 0.07), (4, 0.12, 0.02), (10, 0.03, 0.008)]
let bell: [(Double, Double, Double)] = [(1, 1, 0.22), (2.01, 0.3, 0.12), (3.02, 0.1, 0.06)]
let wood: [(Double, Double, Double)] = [(1, 1, 0.018), (0.33, 0.6, 0.03)]

// Soft (default "soyla"): warm low-mid marimba, under 0.2 s. Start rises, done is one note, cancel falls.
try write("start.aiff", mix([strike(587.33, at: 0, length: 0.12, partials: marimba),
                             strike(880, at: 0.055, length: 0.12, partials: marimba)], peak: 0.35))
try write("done.aiff", mix([strike(739.99, at: 0, length: 0.15, partials: marimba)], peak: 0.3))
try write("cancel.aiff", mix([strike(440, at: 0, length: 0.11, partials: marimba),
                              strike(349.23, at: 0.06, length: 0.11, partials: marimba)], peak: 0.3))
try write("warn.aiff", mix([strike(659.25, at: 0, length: 0.1, partials: marimba),
                            strike(659.25, at: 0.11, length: 0.1, partials: marimba)], peak: 0.22))

func set(_ name: String, _ cues: [(String, [Float])]) throws {
    let dir = outDir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (cue, samples) in cues { try write("\(name)/\(cue).aiff", samples) }
}

// Glass: a gentle bell with a longer ring.
try set("glass", [
    ("start", mix([strike(783.99, at: 0, length: 0.35, partials: bell), strike(1174.66, at: 0.07, length: 0.35, partials: bell)], peak: 0.22)),
    ("done", mix([strike(1046.5, at: 0, length: 0.4, partials: bell)], peak: 0.2)),
    ("cancel", mix([strike(659.25, at: 0, length: 0.3, partials: bell), strike(523.25, at: 0.08, length: 0.3, partials: bell)], peak: 0.2)),
    ("warn", mix([strike(880, at: 0, length: 0.2, partials: bell), strike(880, at: 0.14, length: 0.3, partials: bell)], peak: 0.16)),
])
// Wood: a short, quiet tick, barely there.
try set("wood", [
    ("start", mix([strike(1100, at: 0, length: 0.07, partials: wood, drop: 0.15)], peak: 0.35)),
    ("done", mix([strike(820, at: 0, length: 0.07, partials: wood, drop: 0.15)], peak: 0.3)),
    ("cancel", mix([strike(520, at: 0, length: 0.06, partials: wood, drop: 0.15), strike(440, at: 0.07, length: 0.06, partials: wood, drop: 0.15)], peak: 0.3)),
    ("warn", mix([strike(700, at: 0, length: 0.06, partials: wood, drop: 0.15), strike(700, at: 0.1, length: 0.06, partials: wood, drop: 0.15)], peak: 0.24)),
])
// Classic: the original pure tones (before 2026-10-19).
try set("classic", [
    ("start", render([(660, 0.040), (880, 0.040)])),
    ("done", render([(660, 0.060)], amplitude: 0.35)),
    ("cancel", render([(330, 0.060)])),
    ("warn", render([(660, 0.040), (0, 0.050), (660, 0.040)], amplitude: 0.25)),
])
