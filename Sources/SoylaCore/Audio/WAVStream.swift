import Foundation
import os

/// F4: the recording is written to disk *while* it is captured, so a crash or kill mid-dictation leaves a
/// recoverable WAV. Layout: the canonical 44-byte header from `Encoder.wav` with zero sizes (placeholder), then PCM16
/// chunks as they arrive (`append`, any thread). `finish(pcm:)` rewrites the data region with the recorder's
/// authoritative buffer (it also holds the resampler tail, which never goes through `onChunk`) and patches the sizes.
/// After a crash, `WAVFile.repairHeader` fixes the sizes from the file length.
public final class WAVStreamWriter: Sendable {
    public let url: URL
    private struct State {
        var handle: FileHandle?
        var closed = false
        var streamedBytes = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    public var streamedBytes: Int { state.withLock { $0.streamedBytes } }

    public init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard fm.createFile(atPath: url.path, contents: WAVFile.header(dataBytes: 0), attributes: [.posixPermissions: 0o600]) else {
            throw SoylaError.audio("Cannot create \(url.lastPathComponent)")
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        state = OSAllocatedUnfairLock(initialState: State(handle: handle))
    }

    /// Called from the recorder's audio thread. Errors are swallowed: the in-memory buffer is still authoritative.
    public func append(_ chunk: Data) {
        state.withLock { s in
            guard !s.closed, let h = s.handle, !chunk.isEmpty else { return }
            do { try h.write(contentsOf: chunk); s.streamedBytes += chunk.count } catch { }
        }
    }

    /// The mic was swapped mid-run (watchdog): the new recorder's buffer starts from scratch, so must the file.
    public func reset() {
        state.withLock { s in
            guard !s.closed, let h = s.handle else { return }
            try? h.truncate(atOffset: UInt64(WAVFile.headerBytes))
            _ = try? h.seekToEnd()
            s.streamedBytes = 0
        }
    }

    /// Final content = header + `pcm` (odd trailing byte dropped). Late `append`s after this are ignored.
    public func finish(pcm: Data) throws {
        try state.withLock { s in
            guard !s.closed, let h = s.handle else { return }
            s.closed = true
            defer { try? h.close(); s.handle = nil }
            let n = pcm.count & ~1
            try h.seek(toOffset: UInt64(WAVFile.headerBytes))
            try h.write(contentsOf: pcm.prefix(n))
            try h.truncate(atOffset: UInt64(WAVFile.headerBytes + n))
            try h.seek(toOffset: 0)
            try h.write(contentsOf: WAVFile.header(dataBytes: n))
            try h.synchronize()
        }
    }

    /// Keep whatever was streamed (ESC during recording: the recorder's buffer is gone) and fix the header.
    public func finishStreamed() {
        let wasOpen = state.withLock { s -> Bool in
            let wasOpen = !s.closed
            s.closed = true
            try? s.handle?.close(); s.handle = nil
            return wasOpen
        }
        if wasOpen { _ = try? WAVFile.repairHeader(at: url) }
    }

    /// Delete the file (accidental touch, nothing worth keeping).
    public func discard() {
        state.withLock { s in
            s.closed = true
            try? s.handle?.close(); s.handle = nil
        }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Helpers for the 44-byte PCM16 mono 16 kHz WAV files Soyla writes.
public enum WAVFile {
    public static let headerBytes = 44

    /// Same bytes as `Encoder.wav` produces, for a data region of `dataBytes`.
    public static func header(dataBytes: Int) -> Data {
        var h = Encoder.wav(pcm16: Data())
        patch(&h, dataBytes: dataBytes)
        return h
    }

    static func patch(_ h: inout Data, dataBytes: Int) {
        let d = UInt32(clamping: dataBytes)
        withUnsafeBytes(of: (36 &+ d).littleEndian) { h.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: d.littleEndian) { h.replaceSubrange(40..<44, with: $0) }
    }

    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        d.subdata(in: o..<(o + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    /// True for a Soyla-style header ("RIFF"…"WAVE"…"data" at 36).
    static func isSoylaWAV(_ h: Data) -> Bool {
        h.count >= headerBytes && h.prefix(4) == Data("RIFF".utf8) && h.subdata(in: 8..<12) == Data("WAVE".utf8)
            && h.subdata(in: 36..<40) == Data("data".utf8)
    }

    /// The header disagrees with the file length: the writer never finished (crash, kill -9).
    public static func needsRepair(at url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let h = try? fh.read(upToCount: headerBytes), isSoylaWAV(h),
              let size = try? fh.seekToEnd() else { return false }
        let data = (Int(size) - headerBytes) & ~1
        return Int(u32(h, 40)) != data || Int(u32(h, 4)) != 36 + data
    }

    /// Exactly a Soyla header and no audio: a recording that never got its first buffer.
    public static func isPlaceholderOnly(at url: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue == headerBytes, let d = try? Data(contentsOf: url) else { return false }
        return isSoylaWAV(d)
    }

    /// Rewrite the sizes from the file length (odd trailing byte ignored). Returns the PCM byte count.
    @discardableResult
    public static func repairHeader(at url: URL) throws -> Int {
        let fh = try FileHandle(forUpdating: url)
        defer { try? fh.close() }
        guard var h = try fh.read(upToCount: headerBytes), isSoylaWAV(h) else {
            throw SoylaError.audio("\(url.lastPathComponent) is not a Soyla WAV")
        }
        let size = try fh.seekToEnd()
        let data = max(0, (Int(size) - headerBytes) & ~1)
        patch(&h, dataBytes: data)
        try fh.seek(toOffset: 0)
        try fh.write(contentsOf: h)
        try fh.synchronize()
        return data
    }

    /// PCM16 bytes of a Soyla WAV (the header's data size, clamped to what is on disk).
    public static func readPCM(at url: URL) throws -> Data {
        let d = try Data(contentsOf: url)
        guard isSoylaWAV(d) else { throw SoylaError.audio("\(url.lastPathComponent) is not a Soyla WAV") }
        let declared = Int(u32(d, 40))
        let n = min(declared, d.count - headerBytes) & ~1
        return d.subdata(in: headerBytes..<(headerBytes + n))
    }
}
