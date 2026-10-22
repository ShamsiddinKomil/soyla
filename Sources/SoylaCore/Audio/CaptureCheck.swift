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
        if dur < minDurationSec || Encoder.voicedMs(pcm16: pcm) < minVoicedMs {
            if deliberate && quiet { return .didntCatch }
            return locked || heldMs >= intentionalHoldMs ? .missedSpeech : .dropSilently
        }
        return quiet ? .didntCatch : .send
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
