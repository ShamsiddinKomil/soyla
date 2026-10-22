import Foundation
import AVFoundation
import os

// OWNER: Agent A (Audio).
//
// Contract: pure function from PCM16 (16 kHz mono LE) bytes → EncodedAudio in the requested format.
//   wav  : own RIFF writer (no deps)
//   flac : AVAudioFile (kAudioFormatFLAC)
//   m4a  : AVAudioFile (AAC, ~48 kbps mono)
//   ogg  : /opt/homebrew/bin/ffmpeg -f s16le -ar 16000 -ac 1 -i - -c:a libopus -b:a 24k -f ogg -   (throw .audio if ffmpeg missing)
// If `saveTo` is given, also write the encoded bytes there and set fileURL.
public enum Encoder {
    public static func encode(pcm16: Data, format: AudioFormatChoice, saveTo: URL? = nil) throws -> EncodedAudio {
        let bytes: Data
        switch format {
        case .wav: bytes = wav(pcm16: pcm16)
        case .flac: bytes = try viaAVAudioFile(pcm16: pcm16, ext: "flac", settings: [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: Double(PCMSpec.sampleRate),
            AVNumberOfChannelsKey: PCMSpec.channels,
            AVEncoderBitDepthHintKey: PCMSpec.bitsPerSample,
        ])
        case .m4a: bytes = stripMP4FreeAtoms(try viaAVAudioFile(pcm16: pcm16, ext: "m4a", settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(PCMSpec.sampleRate),
            AVNumberOfChannelsKey: PCMSpec.channels,
            AVEncoderBitRateKey: 48_000,
        ]))
        case .ogg: bytes = try oggOpus(pcm16: pcm16)
        }
        var fileURL: URL?
        if let url = saveTo {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try bytes.write(to: url, options: .atomic)
            } catch {
                throw SoylaError.audio("Cannot save \(format.rawValue) to \(url.path): \(error.localizedDescription)")
            }
            fileURL = url
        }
        return EncodedAudio(data: bytes, format: format.rawValue, durationSec: duration(pcm16: pcm16),
                            sampleRate: PCMSpec.sampleRate, fileURL: fileURL)
    }

    public static func duration(pcm16: Data) -> Double { Double(pcm16.count) / Double(PCMSpec.bytesPerSecond) }

    /// Milliseconds of 20 ms frames whose RMS (0…1) exceeds `threshold` — a cheap "was anything said?" check.
    /// Measured on real runs: speech frames sit at 0.04–0.25, accidental taps have ≤ 40 ms above 0.02.
    public static func voicedMs(pcm16: Data, threshold: Double = 0.02) -> Double {
        let frameBytes = PCMSpec.bytesPerSecond / 50
        var voiced = 0
        pcm16.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            let n = frameBytes / 2
            var i = 0
            while i + n <= samples.count {
                var sum = 0.0
                for j in i..<(i + n) { let v = Double(Int16(littleEndian: samples[j])) / 32768; sum += v * v }
                if (sum / Double(n)).squareRoot() > threshold { voiced += 1 }
                i += n
            }
        }
        return Double(voiced * 20)
    }

    // MARK: WAV

    /// Canonical 44-byte RIFF/WAVE header + PCM16 LE data. Odd trailing byte (half sample) is dropped.
    static func wav(pcm16: Data) -> Data {
        let dataLen = UInt32(pcm16.count & ~1)
        let sr = UInt32(PCMSpec.sampleRate), ch = UInt16(PCMSpec.channels), bps = UInt16(PCMSpec.bitsPerSample)
        let blockAlign = ch * bps / 8
        var d = Data(capacity: 44 + Int(dataLen))
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataLen)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                       // PCM
        u16(ch); u32(sr)
        u32(sr * UInt32(blockAlign)) // byte rate
        u16(blockAlign); u16(bps)
        d.append(contentsOf: Array("data".utf8)); u32(dataLen)
        d.append(pcm16.prefix(Int(dataLen)))
        return d
    }

    // MARK: FLAC / M4A via AVAudioFile

    static func pcmBuffer(pcm16: Data) throws -> AVAudioPCMBuffer {
        let frames = pcm16.count / 2
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PCMSpec.sampleRate),
                                      channels: AVAudioChannelCount(PCMSpec.channels), interleaved: true),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(frames, 1))),
              let dst = buf.int16ChannelData?[0] else {
            throw SoylaError.audio("Cannot allocate PCM buffer")
        }
        pcm16.withUnsafeBytes { raw in
            if frames > 0 { memcpy(dst, raw.baseAddress!, frames * 2) }
        }
        buf.frameLength = AVAudioFrameCount(frames)
        return buf
    }

    private static func viaAVAudioFile(pcm16: Data, ext: String, settings: [String: Any]) throws -> Data {
        // Temp file stays inside recordings/.tmp so a crash never leaves audio in $TMPDIR.
        let tmpDir = SoylaPaths.recordings.appendingPathComponent(".tmp")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = tmpDir.appendingPathComponent("soyla-enc-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let buf = try pcmBuffer(pcm16: pcm16)
        do {
            // Scope the file so it is finalised (deinit closes it; close() is macOS 15+).
            try {
                let f = try AVAudioFile(forWriting: tmp, settings: settings,
                                        commonFormat: .pcmFormatInt16, interleaved: true)
                if buf.frameLength > 0 { try f.write(from: buf) }
                if #available(macOS 15.0, *) { f.close() }
            }()
            return try Data(contentsOf: tmp)
        } catch {
            throw SoylaError.audio("\(ext) encode failed: \(error.localizedDescription)")
        }
    }

    // MARK: MP4 `free` atom stripping

    /// AVAudioFile writes a ~23 KB top-level `free` atom between `moov` and `mdat` (room to grow the
    /// moov in place). For a 2 s clip that doubles the upload. Remove top-level `free`/`skip` atoms and
    /// shift `stco`/`co64` chunk offsets by the bytes removed before each chunk. Returns the input
    /// unchanged if anything looks unexpected.
    static func stripMP4FreeAtoms(_ d: Data) -> Data {
        let b = [UInt8](d)
        func be32(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o+1]) << 16 | Int(b[o+2]) << 8 | Int(b[o+3]) }
        func type(_ o: Int) -> String { String(decoding: b[o+4..<o+8], as: UTF8.self) }

        // Top-level atoms: (offset, size, type)
        var atoms: [(Int, Int, String)] = []
        var i = 0
        while i + 8 <= b.count {
            let sz = be32(i)
            guard sz >= 8, i + sz <= b.count else { return d } // 64-bit sizes / size 0: bail out
            atoms.append((i, sz, type(i)))
            i += sz
        }
        guard i == b.count, atoms.contains(where: { $0.2 == "free" || $0.2 == "skip" }) else { return d }
        let removed = atoms.filter { $0.2 == "free" || $0.2 == "skip" }.map { ($0.0, $0.1) }
        func shift(for offset: Int) -> Int { removed.filter { $0.0 < offset }.reduce(0) { $0 + $1.1 } }

        var out = b
        // Patch chunk offset tables inside moov (containers walked recursively).
        let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "mvex"]
        var ok = true
        func walk(_ start: Int, _ end: Int) {
            var p = start
            while p + 8 <= end, ok {
                let sz = be32(p), t = type(p)
                guard sz >= 8, p + sz <= end else { ok = false; return }
                if containers.contains(t) {
                    walk(p + 8, p + sz)
                } else if t == "stco" || t == "co64" {
                    let n = be32(p + 12), w = t == "stco" ? 4 : 8
                    guard p + 16 + n * w <= p + sz else { ok = false; return }
                    for k in 0..<n {
                        let o = p + 16 + k * w
                        var v: UInt64 = 0
                        for j in 0..<w { v = v << 8 | UInt64(b[o + j]) }
                        let nv = v - UInt64(shift(for: Int(v)))
                        for j in 0..<w { out[o + j] = UInt8((nv >> (UInt64(w - 1 - j) * 8)) & 0xff) }
                    }
                }
                p += sz
            }
        }
        for (o, sz, t) in atoms where t == "moov" { walk(o + 8, o + sz) }
        guard ok else { return d }
        var result = Data(capacity: b.count)
        for (o, sz, t) in atoms where t != "free" && t != "skip" { result.append(contentsOf: out[o..<o+sz]) }
        return result
    }

    // MARK: OGG/Opus via ffmpeg

    static let ffmpegCandidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    static var ffmpegPath: String? {
        ffmpegCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func oggOpus(pcm16: Data) throws -> Data {
        guard let ffmpeg = ffmpegPath else {
            throw SoylaError.audio("ogg/opus needs ffmpeg at /opt/homebrew/bin/ffmpeg (brew install ffmpeg); not found.")
        }
        // A dying ffmpeg must not SIGPIPE-kill us; write() then throws EPIPE instead.
        signal(SIGPIPE, SIG_IGN)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.environment = ProcessInfo.processInfo.environment.filter { $0.key != "OPENROUTER_API_KEY" }
        p.arguments = ["-hide_banner", "-loglevel", "error",
            "-f", "s16le", "-ar", "\(PCMSpec.sampleRate)", "-ac", "\(PCMSpec.channels)", "-i", "-",
            "-c:a", "libopus", "-b:a", "24k", "-f", "ogg", "-",
        ]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch { throw SoylaError.audio("ffmpeg failed to launch: \(error.localizedDescription)") }

        // Feed stdin and drain stderr concurrently with reading stdout to avoid pipe-buffer deadlock.
        let group = DispatchGroup()
        let errData = OSAllocatedUnfairLock(initialState: Data())
        group.enter()
        DispatchQueue.global().async {
            try? inPipe.fileHandleForWriting.write(contentsOf: pcm16)
            try? inPipe.fileHandleForWriting.close()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()   // read outside the lock
            errData.withLock { $0 = d }
            group.leave()
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        group.wait()
        guard p.terminationStatus == 0, !out.isEmpty else {
            let msg = String(decoding: errData.withLock { $0 }.suffix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SoylaError.audio("ffmpeg opus encode failed (exit \(p.terminationStatus)): \(msg)")
        }
        return out
    }
}
