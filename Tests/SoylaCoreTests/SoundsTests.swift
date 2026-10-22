import Testing
import Foundation
import AVFoundation
@testable import SoylaCore

@Suite struct SoundsTests {
    private static var dir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Sounds")
    }

    @Test func threeCuesExistDecodeAndStayUnder50KB() throws {
        var total = 0
        for name in ["start", "done", "cancel"] {
            let url = Self.dir.appendingPathComponent("\(name).aiff")
            let file = try AVAudioFile(forReading: url)
            #expect(file.length > 0)
            #expect(Double(file.length) / file.fileFormat.sampleRate < 0.2)   // short cues
            total += (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        }
        #expect(total <= 50_000)
    }

    @Test func soundSetMigratesFromLegacyBool() throws {
        func decode(_ json: String) throws -> Settings { try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }
        #expect(try decode(#"{"sounds":false}"#).soundSet == .off)
        #expect(try decode(#"{"sounds":true}"#).soundSet == .soyla)
        #expect(try decode("{}").soundSet == .soyla)
        #expect(try decode(#"{"soundSet":"system","sounds":false}"#).soundSet == .system)
        #expect(try decode(#"{"soundSet":"bogus"}"#).soundSet == .soyla)
        var s = Settings(); s.soundSet = .system
        #expect(s.sounds)
        s.sounds = false
        #expect(s.soundSet == .off)
        let round = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(round.soundSet == .off)
    }

    /// Every bundled set has all three cues, short and quiet (peak well under full scale: no piercing cues).
    @Test func everyBundledSetHasThreeShortQuietCues() throws {
        for set in SoundSet.allCases where set != .system && set != .off {
            let d = set.folder.map { Self.dir.appendingPathComponent($0) } ?? Self.dir
            for cue in ["start", "done", "cancel"] {
                let file = try AVAudioFile(forReading: d.appendingPathComponent("\(cue).aiff"))
                #expect(Double(file.length) / file.fileFormat.sampleRate < 0.5, "\(set) \(cue)")
                let buf = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
                try file.read(into: buf)
                let peak = (0..<Int(buf.frameLength)).map { abs(buf.floatChannelData![0][$0]) }.max() ?? 0
                #expect(peak > 0.05 && peak <= 0.5, "\(set) \(cue) peak \(peak)")
            }
        }
    }

    /// The recording-limit warning (4:45, or 0:45 without segment streaming) is a soft cue from the chosen set, silent when Sounds = Off; never the system alert beep,
    /// which ignored the setting (owner, 2026-10-19). Quieter than the other cues: it plays mid-dictation.
    @Test @MainActor func warningIsASoftCueFromTheChosenSet() throws {
        #expect(Sounds.Cue.allCases.contains(.warn) && Sounds.Cue.warn.volume <= Sounds.Cue.done.volume)
        for set in SoundSet.allCases where set != .system && set != .off {
            let d = set.folder.map { Self.dir.appendingPathComponent($0) } ?? Self.dir
            let file = try AVAudioFile(forReading: d.appendingPathComponent("warn.aiff"))
            #expect(Double(file.length) / file.fileFormat.sampleRate < 0.5, "\(set) warn")
            let buf = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buf)
            let peak = (0..<Int(buf.frameLength)).map { abs(buf.floatChannelData![0][$0]) }.max() ?? 0
            #expect(peak > 0.05 && peak <= 0.3, "\(set) warn peak \(peak)")
        }
        let src = try String(contentsOf: Self.dir.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SoylaCore/App/DictationPipeline.swift"), encoding: .utf8)
        #expect(!src.contains("NSSound.beep()") && src.contains("Sounds.play(.warn)"))
    }

    @Test func soundVolumeDefaultsAndClamps() throws {
        func decode(_ json: String) throws -> Settings { try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }
        #expect(try decode("{}").soundVolume == 0.6)
        #expect(try decode(#"{"soundVolume":3}"#).soundVolume == 1)
        #expect(try decode(#"{"soundVolume":0.3,"soundSet":"wood"}"#).soundSet == .wood)
        #expect(SoundSet.soyla.label == "Soft" && SoundSet.soyla.folder == nil && SoundSet.glass.folder == "glass")
    }
}
