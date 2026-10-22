import Testing
import Foundation
@testable import SoylaCore

// FE-5: Engine page / menu bar / History copy and the P5 switch prompt.
@Suite struct EngineCopyTests {
    @Test func statusLineCoversEveryModelState() {
        #expect(EngineCopy.status(nil).text == "Checking…")
        #expect(EngineCopy.status(.ready) == .init(text: "Ready", tone: .ok, action: nil, progress: nil))
        let d = EngineCopy.status(.downloading(0.426))
        #expect(d.text == "Downloading 43%" && d.progress == 0.426 && d.action == nil)
        #expect(EngineCopy.status(.needsDownload).action == .download)
        #expect(EngineCopy.status(.needsDownload, failure: "URLError").action == .retry)
        #expect(EngineCopy.status(.needsPermission).text == "Needs Speech Recognition permission")
        #expect(EngineCopy.status(.needsPermission).action == .allowSpeech)
        for r: OnDeviceUnavailableReason in [.localeUnsupported, .noOnDeviceModel, .restricted, .reservationsFull, .osTooOld] {
            let s = EngineCopy.status(.unavailable(r))
            #expect(s.tone == .warn && (s.text.hasPrefix("Not available") || s.text.hasPrefix("Needs macOS")), "\(r)")
        }
    }

    @Test func freeCardIsEnglishOnlyWithNoLanguagePicker() {
        #expect(EngineCopy.freeSubtitle.contains("English only"))
        #expect(!EngineCopy.freeSubtitle.contains("Russian") && !EngineCopy.freePrivacy.contains("Russian"))
        #expect(EngineCopy.freePrivacy.contains("never leaves this Mac"))
        #expect(EngineCopy.cloudSubtitle.contains("Uzbek") && EngineCopy.cloudSubtitle.contains("Russian"))
    }

    @Test func attentionNeverSaysApiKeyForTheFreeEngine() {
        #expect(EngineCopy.attention(provider: .apple, state: .ready) == nil)
        #expect(EngineCopy.attention(provider: .apple, state: nil) == nil)
        #expect(EngineCopy.attention(provider: .apple, state: .downloading(0.5)) == "English model downloading (50%)")
        let states: [OnDeviceModelState] = [.needsDownload, .needsPermission, .unavailable(.noOnDeviceModel), .downloading(0)]
        for s in states { #expect(!(EngineCopy.attention(provider: .apple, state: s) ?? "").contains("key")) }
        // Cloud engines are not this function's business.
        #expect(EngineCopy.attention(provider: .google, state: .needsDownload) == nil)
    }

    @Test func historyLabelAndLastRequest() {
        #expect(EngineCopy.engineLabel(model: "en-US") == "On this Mac")
        #expect(EngineCopy.engineLabel(model: "en-GB") == "On this Mac")
        #expect(EngineCopy.engineLabel(model: "gemini-3.5-flash") == "Gemini 3.5 Flash")
        #expect(EngineCopy.engineLabel(model: "google/gemini-3.5-flash") == "Gemini 3.5 Flash")
        #expect(EngineCopy.lastRequestNote(model: "en-US") == "Nothing left this Mac")
        #expect(EngineCopy.lastRequestNote(model: "gemini-3.5-flash") == nil)
    }

    @Test func cloudCardPicksTheProviderThatHasAKey() {
        #expect(EngineCopy.cloudTarget(hasKey: { $0 == .openRouter }, developerMode: false) == .openRouter)
        #expect(EngineCopy.cloudTarget(hasKey: { _ in true }, developerMode: false) == .google)
        #expect(EngineCopy.cloudTarget(hasKey: { _ in false }, developerMode: false) == .google)
        #expect(EngineCopy.cloudTarget(hasKey: { $0 == .custom }, developerMode: false) == .google)
        #expect(EngineCopy.cloudTarget(hasKey: { $0 == .custom }, developerMode: true) == .custom)
    }
}

@Suite struct EngineSwitchPromptTests {
    private func decide(_ p: ProviderKind, keys: [KeyProvider], verified: Set<KeyProvider> = [], toCloud: Bool = false,
                        toFree: Bool = false, free: Bool = true) -> EngineSwitchPrompt? {
        EngineSwitchPrompt.decide(provider: p, keyedProviders: keys, verified: verified, asked: .init(toCloud: toCloud, toFree: toFree),
                                  freeAvailable: free)
    }

    @Test func keyAddedWhileFreeOffersCloudOnceItVerifies() {
        #expect(decide(.apple, keys: [.google]) == nil)                                  // saved but not verified yet
        #expect(decide(.apple, keys: [.google], verified: [.google]) == .toCloud(.google))
        #expect(decide(.apple, keys: [.openRouter], verified: [.openRouter]) == .toCloud(.openRouter))
        #expect(decide(.apple, keys: [.custom]) == .toCloud(.custom))                    // no check exists for custom
        #expect(decide(.apple, keys: [.google], verified: [.google], toCloud: true) == nil)   // asked already
        #expect(decide(.apple, keys: []) == nil)
    }

    @Test func keyRemovedWhileCloudOffersFreeOnce() {
        #expect(decide(.google, keys: []) == .toFree)
        #expect(decide(.openRouter, keys: []) == .toFree)
        #expect(decide(.google, keys: [], toFree: true) == nil)
        #expect(decide(.google, keys: [], free: false) == nil)                           // free engine not available here
        #expect(decide(.google, keys: [.google]) == nil)                                 // key still there
        #expect(decide(.google, keys: [.openRouter]) == nil)                             // another key remains: not silent, not asked
        #expect(decide(.custom, keys: []) == nil)                                        // custom may need no key
    }

    @Test func promptCopyAndPersistedFlags() {
        #expect(EngineSwitchPrompt.toCloud(.google).title == "Switch to Cloud?")
        #expect(EngineSwitchPrompt.toCloud(.google).message.contains("Uzbek"))
        let name = "ai.soyla.test.fe5.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { dropTestDomain(name) }
        let flags = EnginePromptFlags(defaults: d)
        #expect(!flags.askedToCloud && !flags.askedToFree)
        flags.markAsked(.toCloud(.google))
        #expect(flags.askedToCloud && !flags.askedToFree)
        flags.markAsked(.toFree)
        #expect(flags.askedToFree)
    }
}

// FE-5: the Home banner for the free engine (never "API key").
@Suite struct EngineBannerTests {
    private let ok = PermissionState(mic: .granted, ax: true, inputMonitoring: true)

    @Test func freeEngineModelNotReadyShowsTheModelNotAKey() {
        let note = EngineCopy.attention(provider: .apple, state: .downloading(0.42))
        let b = SetupBanner(permissions: ok, keyMissing: false, engineNote: note)
        #expect(b.isNeeded && b.text == "English model downloading (42%)" && b.target == .apiKeys)
        #expect(!b.text.contains("key"))
    }

    @Test func permissionsStillComeFirstAndReadyIsQuiet() {
        let missing = PermissionState(mic: .granted, ax: false, inputMonitoring: true)
        let b = SetupBanner(permissions: missing, keyMissing: false, engineNote: "English model needs a download — open Settings")
        #expect(b.text == "Soyla needs 1 permission" && b.target == .permissions)
        #expect(!SetupBanner(permissions: ok, keyMissing: false, engineNote: EngineCopy.attention(provider: .apple, state: .ready)).isNeeded)
    }

    @MainActor @Test func historyMetaLineCarriesTheEngine() {
        var r = RunRecord(runId: "r1", ts: "2026-10-17T10:00:00.000Z", source: "live", phraseId: nil, model: "en-US",
                          cleanup: false, cleanupModel: nil, languageHint: nil, prewarm: false,
                          audio: .init(format: "wav", bytes: 1, b64Bytes: 2, durationSec: 4, sampleRate: 16000, file: nil),
                          timelineMs: [:], net: nil, usage: nil, cleanupUsage: nil, rawText: nil, cleanText: nil, error: nil,
                          providerMeta: nil, status: .ok)
        #expect(NoteMeta.line(r, engine: true).hasSuffix("4 s · On this Mac"))
        #expect(!NoteMeta.line(r).contains("On this Mac"))
        r.model = "gemini-3.5-flash"
        #expect(NoteMeta.line(r, engine: true).hasSuffix("4 s · Gemini 3.5 Flash"))
    }
}
