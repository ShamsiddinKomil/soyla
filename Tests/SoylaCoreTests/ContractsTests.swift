import Testing
import Foundation
@testable import SoylaCore

@Suite struct ContractsTests {
    @Test func runRecordRoundTripsWithSnakeCaseKeys() throws {
        let (id, ts) = RunRecord.newId()
        let r = RunRecord(runId: id, ts: ts, source: "replay", phraseId: 2, model: "google/gemini-3.5-transcribe",
                          cleanup: false, cleanupModel: nil, languageHint: nil, prewarm: true,
                          audio: .init(format: "wav", bytes: 10, b64Bytes: 16, durationSec: 0.1, sampleRate: 16000, file: nil),
                          timelineMs: ["stt_total": 1.5], net: nil, usage: Usage(cost: 0.001), cleanupUsage: nil,
                          rawText: "salom", cleanText: nil, error: nil, providerMeta: nil)
        let data = try RunRecord.encoder.encode(r)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"run_id\""))
        #expect(json.contains("\"b64_bytes\""))
        #expect(json.contains("\"timeline_ms\""))
        let back = try RunRecord.decoder.decode(RunRecord.self, from: data)
        #expect(back == r)
    }

    @Test func timelineDerivesDurations() {
        let t = RunTimeline()
        t.mark(.keyUp); t.mark(.encodeDone); t.mark(.requestSent); t.mark(.responseReceived); t.mark(.pasted)
        let ms = t.toMillis()
        #expect(ms["release_to_paste"] != nil)
        #expect(ms["cleanup"] == nil)
        #expect(ms["stt_total"]! >= 0)
    }

    @Test func settingsDefaults() {
        let s = Settings()
        #expect(s.hotkey == .fn)
        #expect(s.sttModel == "google/gemini-3.5-flash")
        #expect(s.provider == .openRouter)
        #expect(s.cleanupEnabled == false && s.cleanupLevel == .off)    // owner 2026-10-16: Off by default (was D14 Light)
    }
}

// A6: settings migration (`migrated.v02`) and schema freeze.
@Suite struct SettingsMigrationTests {
    private func suite() -> (UserDefaults, () -> Void) {
        let name = "ai.soyla.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (d, { dropTestDomain(name) })
    }

    @Test func v01BlobMigratesOnce() throws {
        let (d, cleanup) = suite(); defer { cleanup() }
        let v01 = #"{"sttModel":"chat:google/gemini-3.5-transcribe","keepMicWarm":true,"livePreview":true,"minDurationSec":0.3,"hotkey":"rightOption","vocabulary":["Soyla"]}"#
        d.set(Data(v01.utf8), forKey: "settings.v1")
        let s = SettingsStore(defaults: d).current
        // Prefix stripped only; a transcribe model is not silently swapped to Flash.
        #expect(s.sttModel == "google/gemini-3.5-transcribe")
        #expect(s.provider == .openRouter)
        #expect(s.livePreview == false)
        #expect(s.minDurationSec == 0.6)
        #expect(s.micWarmMode == .off)
        #expect(s.hotkey == .rightOption && s.vocabulary == ["Soyla"])   // user values kept
        #expect(d.bool(forKey: "migrated.v02"))
        let saved = try JSONDecoder().decode(Settings.self, from: d.data(forKey: "settings.v1")!)
        #expect(saved == s)
    }

    @Test func plainTranscribeModelStaysAndGoogleIsInferred() {
        let (d, cleanup) = suite(); defer { cleanup() }
        d.set(Data(#"{"sttModel":"google/gemini-3.5-transcribe"}"#.utf8), forKey: "settings.v1")
        let s = SettingsStore(defaults: d).current
        #expect(s.sttModel == "google/gemini-3.5-transcribe" && s.provider == .openRouter)

        let (d2, cleanup2) = suite(); defer { cleanup2() }
        d2.set(Data(#"{"sttModel":"gemini-3.5-flash"}"#.utf8), forKey: "settings.v1")
        #expect(SettingsStore(defaults: d2).current.provider == .google)
    }

    @Test func oldFlagsSkipOneOffsAndAreDeleted() {
        let (d, cleanup) = suite(); defer { cleanup() }
        d.set(Data(#"{"sttModel":"google/gemini-3.5-flash","livePreview":true,"micWarmMode":"always","minDurationSec":0.4}"#.utf8), forKey: "settings.v1")
        for k in SettingsStore.legacyFlags { d.set(true, forKey: k) }
        let s = SettingsStore(defaults: d).current
        #expect(s.livePreview && s.micWarmMode == .always && s.minDurationSec == 0.4)   // owner changed them after the one-offs ran
        for k in SettingsStore.legacyFlags { #expect(d.object(forKey: k) == nil) }
    }

    // Latency step 2 (owner, 2026-10-16): FLAC upload is ~0.3–0.8 s faster than WAV and lossless.
    @Test func flacIsTheDefaultUpload() {
        #expect(Settings().audioFormat == .flac)
    }

    @Test func savedWavMovesToFlacOnceForGoogleAndOpenRouter() {
        for provider in ["openRouter", "google"] {
            let (d, cleanup) = suite(); defer { cleanup() }
            d.set(Data(#"{"provider":"\#(provider)","sttModel":"google/gemini-3.5-flash","audioFormat":"wav"}"#.utf8), forKey: "settings.v1")
            d.set(true, forKey: "migrated.v02")
            let store = SettingsStore(defaults: d)
            #expect(store.current.audioFormat == .flac)
            #expect(d.bool(forKey: SettingsStore.flacMigrationKey))
            // A later, deliberate WAV choice is kept.
            store.update { $0.audioFormat = .wav }
            #expect(SettingsStore(defaults: d).current.audioFormat == .wav)
        }
    }

    @Test func flacMigrationKeepsCustomProviderAndOtherFormats() {
        let (d, cleanup) = suite(); defer { cleanup() }
        d.set(Data(#"{"provider":"custom","customBaseURL":"http://localhost:8080/v1","sttModel":"x/y","audioFormat":"wav"}"#.utf8), forKey: "settings.v1")
        d.set(true, forKey: "migrated.v02")
        #expect(SettingsStore(defaults: d).current.audioFormat == .wav)

        let (d2, cleanup2) = suite(); defer { cleanup2() }
        d2.set(Data(#"{"provider":"openRouter","sttModel":"google/gemini-3.5-flash","audioFormat":"m4a"}"#.utf8), forKey: "settings.v1")
        d2.set(true, forKey: "migrated.v02")
        #expect(SettingsStore(defaults: d2).current.audioFormat == .m4a)
    }

    // Reviewer 2026-10-16: a new install that switches to a custom endpoint must not upload FLAC by default.
    @Test func customProviderUploadsWavInsteadOfFlac() {
        var s = Settings()
        #expect(s.uploadFormat == .flac)
        s.provider = .custom
        #expect(s.uploadFormat == .wav)
        s.audioFormat = .m4a
        #expect(s.uploadFormat == .m4a)   // any other explicit choice is respected
    }

    @Test func freshInstallGetsDefaults() {
        let (d, cleanup) = suite(); defer { cleanup() }
        #expect(SettingsStore(defaults: d).current == Settings())
    }

    @Test func v02BlobRoundTripsUnchanged() throws {
        let (d, cleanup) = suite(); defer { cleanup() }
        var s = Settings()
        s.provider = .custom; s.customBaseURL = "http://localhost:8080/v1"
        s.sttModel = "vendor/some-model"; s.audioFormat = .flac; s.languageHint = "uz"
        s.cleanupEnabled = true; s.cleanupModel = "vendor/cleanup"; s.vocabulary = ["a", "b"]
        s.hotkey = .f13; s.prewarmConnection = false; s.retention = .deleteAfter7Days; s.phraseId = 3
        s.warnAtSec = 30; s.hardStopSec = 40; s.minDurationSec = 0.2; s.minVoicedMs = 400
        s.pasteEnabled = false; s.micWarmMode = .idleClose30s; s.preferBuiltInMic = true; s.sounds = false
        s.livePreview = true; s.showDetails = true; s.autoUpdateCheck = false
        s.lastUpdateCheck = Date(timeIntervalSince1970: 1_800_000_000)
        s.pillPosition = .custom; s.pillAnchor = PillAnchor(fx: 0.25, fy: 0.75); s.pillSnoozedUntil = 1_800_000_500
        d.set(try JSONEncoder().encode(s), forKey: "settings.v1")
        d.set(true, forKey: "migrated.v02")
        #expect(SettingsStore(defaults: d).current == s)
    }
}

/// Capture mode: `SOYLA_SETTINGS_SUITE` points the app at a separate settings store for screenshots and demos,
/// and such a run must never import the developer's real (legacy) settings.
@Suite struct SettingsSuiteTests {
    @Test func defaultSuiteWithoutOverride() {
        #expect(Soyla.settingsSuite(env: [:]) == "ai.soyla.settings")
        #expect(Soyla.legacyImportSuite(env: [:]) == "ai.ovoz.settings")
    }

    @Test func overrideIsHermetic() {
        let env = ["SOYLA_SETTINGS_SUITE": "ai.soyla.capture"]
        #expect(Soyla.settingsSuite(env: env) == "ai.soyla.capture")
        #expect(Soyla.legacyImportSuite(env: env) == nil)
    }

    @Test func emptyOverrideIsIgnored() {
        #expect(Soyla.settingsSuite(env: ["SOYLA_SETTINGS_SUITE": ""]) == "ai.soyla.settings")
    }
}
