import Foundation

/// Cuts a live PCM16 stream (16 kHz mono LE) into pieces at natural pauses, so each piece can be transcribed while the
/// user is still speaking. Pure and synchronous: the caller serialises access.
///
/// A piece ends when it is at least `minSec` long and `silenceMs` of quiet follows; the cut lands in the middle of
/// that quiet, so no word is split. With no pause by `maxSec`, it cuts at the quietest 20 ms frame of the last
/// `searchSec` and the next piece starts `overlapMs` earlier (joined later by `SegmentJoin`).
public struct Segmenter {
    public struct Config: Sendable {
        public var minSec = 6.0
        public var silenceMs = 400.0
        public var maxSec = 25.0
        public var searchSec = 3.0
        public var overlapMs = 300.0
        /// Same RMS threshold as `Encoder.voicedMs`.
        public var threshold = 0.02
        public init() {}
        /// What the app uses: 15 s pieces (owner clips, 2026-10-17: closest to the whole-recording text; 6 s pieces
        /// lost more Russian and context).
        public static let app: Config = { var c = Config(); c.minSec = 15; return c }()
    }

    public struct Piece: Sendable, Equatable {
        public let index: Int
        /// Byte range in the whole recording.
        public let start: Int
        public let end: Int
        /// True when cut with no pause (the next piece overlaps this one).
        public let hardCut: Bool
    }

    static let frameBytes = PCMSpec.bytesPerSecond / 50          // 20 ms
    private static let frameMs = 20.0

    public let config: Config
    private(set) var pcm = Data()
    private var frameRMS: [Double] = []                           // one per complete 20 ms frame
    private var pieceStart = 0                                     // byte offset where the open piece starts
    private var quietFrames = 0
    private var nextIndex = 0

    public init(config: Config = Config()) { self.config = config }

    /// Byte offset where the still-open piece starts (the tail begins here at release).
    public var openStart: Int { pieceStart }
    public var piecesCut: Int { nextIndex }

    /// Appends audio; returns the pieces that became complete.
    public mutating func append(_ chunk: Data) -> [Piece] {
        pcm.append(chunk)
        var out: [Piece] = []
        while (frameRMS.count + 1) * Self.frameBytes <= pcm.count {
            let off = frameRMS.count * Self.frameBytes
            let rms = Self.rms(pcm, from: off, count: Self.frameBytes)
            frameRMS.append(rms)
            quietFrames = rms > config.threshold ? 0 : quietFrames + 1
            if let p = cutIfDue() { out.append(p) }
        }
        return out
    }

    /// The tail piece from `openStart` to `end` (the authoritative recording length at release).
    public mutating func finish(end: Int) -> Piece? {
        guard end > pieceStart else { return nil }
        defer { nextIndex += 1 }
        return Piece(index: nextIndex, start: pieceStart, end: end, hardCut: false)
    }

    private mutating func cutIfDue() -> Piece? {
        let pos = frameRMS.count * Self.frameBytes                // end of the frame just analysed
        let lenSec = Double(pos - pieceStart) / Double(PCMSpec.bytesPerSecond)
        let quietMs = Double(quietFrames) * Self.frameMs
        if lenSec >= config.minSec, quietMs >= config.silenceMs {
            let cut = pos - quietFrames / 2 * Self.frameBytes      // middle of the quiet
            return emit(end: cut, nextStart: cut, hard: false)
        }
        guard lenSec >= config.maxSec else { return nil }
        let searchFrames = Int(config.searchSec * 1000 / Self.frameMs)
        let first = max(pieceStart / Self.frameBytes + 1, frameRMS.count - searchFrames)
        var best = frameRMS.count - 1
        for i in first..<frameRMS.count where frameRMS[i] < frameRMS[best] { best = i }
        let cut = best * Self.frameBytes
        let overlap = Int(config.overlapMs / Self.frameMs) * Self.frameBytes
        return emit(end: cut + Self.frameBytes, nextStart: max(pieceStart, cut - overlap), hard: true)
    }

    private mutating func emit(end: Int, nextStart: Int, hard: Bool) -> Piece {
        let p = Piece(index: nextIndex, start: pieceStart, end: end, hardCut: hard)
        nextIndex += 1
        pieceStart = nextStart
        quietFrames = 0
        return p
    }

    /// The bytes of a piece (from the given whole recording, or this segmenter's own buffer).
    public func bytes(_ p: Piece, in whole: Data? = nil) -> Data {
        let src = whole ?? pcm
        let lo = min(p.start, src.count) & ~1, hi = min(p.end, src.count) & ~1
        return src.subdata(in: lo..<max(lo, hi))
    }

    static func rms(_ d: Data, from: Int, count: Int) -> Double {
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Double in
            guard let base = raw.baseAddress, from + count <= raw.count else { return 0 }
            let s = base.advanced(by: from).assumingMemoryBound(to: Int16.self)
            let n = count / 2
            var sum = 0.0
            for j in 0..<n { let v = Double(Int16(littleEndian: s[j])) / 32768; sum += v * v }
            return (sum / Double(n)).squareRoot()
        }
    }
}

/// Joins piece transcripts in order. After a hard cut the next piece re-hears up to `overlapMs` of audio, so its first
/// words may repeat the previous piece's last words: drop the longest such repeat (at most `maxWords`).
public enum SegmentJoin {
    public static func join(_ texts: [String], hardCutBefore: [Bool], maxWords: Int = 4) -> String {
        var out: [String] = []
        for (i, raw) in texts.enumerated() {
            var words = raw.split(whereSeparator: \.isWhitespace).map(String.init)
            if i > 0, hardCutBefore[i] {
                let n = repeatLength(previous: out, next: words, maxWords: maxWords)
                words.removeFirst(n)
            }
            out += words
        }
        return out.joined(separator: " ")
    }

    static func repeatLength(previous: [String], next: [String], maxWords: Int) -> Int {
        func norm(_ w: String) -> String { w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        for n in stride(from: min(maxWords, previous.count, next.count), through: 1, by: -1)
            where previous.suffix(n).map(norm) == next.prefix(n).map(norm) {
            return n
        }
        return 0
    }
}
