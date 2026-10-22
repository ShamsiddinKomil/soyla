import Foundation

/// Encodings we can send. Raw value == OpenRouter `input_audio.format` == file extension.
public enum AudioFormatChoice: String, Codable, CaseIterable, Sendable {
    case wav, flac, m4a, ogg
    public var label: String {
        switch self {
        case .wav: return "WAV (PCM16)"
        case .flac: return "FLAC"
        case .m4a: return "M4A (AAC)"
        case .ogg: return "OGG (Opus, via ffmpeg)"
        }
    }
}

/// Target capture format for everything downstream (batch and future streaming).
public enum PCMSpec {
    public static let sampleRate = 16_000
    public static let channels = 1
    public static let bitsPerSample = 16
    public static var bytesPerSecond: Int { sampleRate * channels * bitsPerSample / 8 }
}

/// Called on an audio thread with little-endian Int16 mono 16 kHz bytes.
public typealias PCMChunkHandler = @Sendable (Data) -> Void

public enum RecorderState: Sendable, Equatable {
    case idle, starting, recording(elapsedSec: Double), stopping
}
