import Foundation

/// What to do with a finished capture, decided before anything is encoded or sent (F2).
public enum CaptureVerdict: Equatable, Sendable {
    /// Real speech: encode and send.
    case send
    /// Accidental touch (the 2026-10-16 gate): nothing sent, logged as a drop, the pill just disappears.
    case dropSilently
    /// The mic delivered nothing or exact zeros during a deliberate hold: name the device, restart the mic.
    case noAudio
    /// A deliberate hold with only near-silence (FluidVoice thresholds): soft "Didn't catch anything", nothing sent.
    case didntCatch
    /// A deliberate run (locked, or held ≥ 1.5 s) below the voice gate: soft "Didn't catch that", nothing sent.
    /// It used to vanish like a tap, so a short word in a lock was lost without a sign (owner, 2026-10-19).
    case missedSpeech
}

public enum CaptureCheck {
    /// A hold this long is deliberate, not a tap.
    public static let deliberateHoldMs: Double = 1000
    /// A hold this long (or any lock) was meant as a dictation, so dropping it says so instead of vanishing.
    public static let intentionalHoldMs: Double = 1500
    /// FluidVoice's silence check, applied only to short clips.
    public static let quietMaxSec: Double = 4
    public static let quietPeak: Double = 0.01
    public static let quietRms: Double = 0.002

    /// `pcm` must be the audio captured AFTER key-down (pre-roll excluded), so audio from before the press
    /// can never push an accidental touch over the voiced-time gate. The audio itself is never altered
    /// (no normalising, no VAD cutting).
    public static func classify(pcm: Data, heldMs: Double, locked: Bool = false, minDurationSec: Double,
                                minVoicedMs: Double) -> CaptureVerdict {
        let dur = Encoder.duration(pcm16: pcm)
        let deliberate = heldMs > deliberateHoldMs
        if deliberate && (dur < 0.2 || isDigitalSilence(pcm)) { return .noAudio }
        let quiet = dur <= quietMaxSec && isNearSilent(pcm)
        if dur < minDurationSec || gateVoicedMs(pcm16: pcm) < minVoicedMs {
            if deliberate && quiet { return .didntCatch }
            return locked || heldMs >= intentionalHoldMs ? .missedSpeech : .dropSilently
        }
        return quiet ? .didntCatch : .send
    }

    /// A frame quieter than this is never voiced: true silence and a quiet room stay out (they make the model invent
    /// whole paragraphs). Quiet speech at −28 dBFS peak has frames at 0.009–0.014 RMS; the owner's rooms sit at
    /// 0.0004–0.009 (10th percentile of 137 recordings), and pink room noise peaks at about 3x its floor.
    public static let voicedFloorAbs = 0.008
    /// …and it must rise this many times above the clip's own noise floor, so a steady hum is never "speech".
    public static let noiseFloorMultiple = 4.0
    /// The noise floor: this percentile of the clip's 20 ms frame RMS (speech pauses, or the whole clip for a hum).
    public static let noiseFloorPercentile = 0.1
    /// Frames at or under this are digital silence or dropouts, not the room: they never set the floor (review
    /// 2026-10-26: 15 of the owner's 138 recordings have ≥ 10 % such frames, and a floor of 0 let room noise count).
    public static let measurableFrameRms = 0.0005
    /// Fewer measurable frames than this (200 ms): no floor, the old 0.02 rule alone.
    public static let minFloorFrames = 10

    /// The voice gate's voiced time (2026-10-26). A 20 ms frame counts if its RMS is over 0.02 (`Encoder.voicedMs`,
    /// unchanged, so every clip the old gate sent is still sent) OR over max(`voicedFloorAbs`, 4 × the clip's noise
    /// floor), which lets quiet speech through. `Encoder.voicedMs` keeps its meaning for segments and `ClipStats`.
    public static func gateVoicedMs(pcm16: Data) -> Double {
        let frames = Encoder.frameRms(pcm16: pcm16)
        let adaptive = noiseFloor(frames).map { max(voicedFloorAbs, noiseFloorMultiple * $0) } ?? 0.02
        return Double(frames.filter { $0 > 0.02 || $0 > adaptive }.count * 20)
    }

    /// The 10th percentile of the measurable frames (over `measurableFrameRms`); nil when fewer than `minFloorFrames`.
    static func noiseFloor(_ frames: [Double]) -> Double? {
        let sorted = frames.filter { $0 > measurableFrameRms }.sorted()
        guard sorted.count >= minFloorFrames else { return nil }
        return sorted[min(sorted.count - 1, Int(noiseFloorPercentile * Double(sorted.count)))]
    }

    /// Non-empty and every sample exactly zero: a muted/stolen device (AirPods held by an iPhone), not a quiet room.
    public static func isDigitalSilence(_ pcm: Data) -> Bool {
        guard pcm.count >= 2 else { return false }
        return pcm.allSatisfy { $0 == 0 }
    }

    public static func isNearSilent(_ pcm: Data) -> Bool {
        let (pk, r) = peakAndRms(pcm)
        return pk < quietPeak && r < quietRms
    }

    public static func peakAndRms(_ pcm: Data) -> (peak: Double, rms: Double) {
        var pk = 0.0, sum = 0.0, n = 0
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for v in raw.bindMemory(to: Int16.self) {
                let x = Double(Int16(littleEndian: v)) / 32768
                pk = max(pk, abs(x)); sum += x * x; n += 1
            }
        }
        return (pk, n > 0 ? (sum / Double(n)).squareRoot() : 0)
    }
}
