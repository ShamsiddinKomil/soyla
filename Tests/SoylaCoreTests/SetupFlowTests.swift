import Testing
import Foundation
@testable import SoylaCore

// OB-2: onboarding v2 reducer. Mirrors the v5 prototype's state machine.
@Suite struct SetupFlowStepTests {
    @Test func englishOnlySkipsConnect() {
        let f = SetupFlow()
        #expect(f.languages == [.en])
        #expect(f.steps == [.languages, .permissions, .tryIt, .done])
    }

    @Test func uzbekOrRussianAddsConnect() {
        var f = SetupFlow()
        f.toggle(.uz)
        #expect(f.steps == [.languages, .permissions, .connect, .tryIt, .done])
        f.toggle(.uz); f.toggle(.ru)
        #expect(f.steps.contains(.connect))
        #expect(f.cloudCombo == .ru)
        f.toggle(.uz)
        #expect(f.cloudCombo == .uzru)
    }

    @Test func noLanguageBlocksContinue() {
        var f = SetupFlow()
        f.toggle(.en)
        #expect(f.languages.isEmpty && !f.canContinue)
        let r1 = f.next()
        #expect(!r1 && f.step == .languages)
        f.toggle(.ru)
        #expect(f.canContinue)
    }

    @Test func walkEnglishOnly() {
        var f = SetupFlow()
        let r2 = f.next()
        #expect(r2 && f.step == .permissions)
        #expect(!f.canContinue)
        f.grantAll()
        let r3 = f.next()
        #expect(r3 && f.step == .tryIt)
        #expect(!f.canContinue)
        let r4 = f.recordTry(text: "FAKE text", releasedAt: Date(timeIntervalSince1970: 10), now: Date(timeIntervalSince1970: 10.5), engine: .onDevice)
        #expect(r4)
        let r5 = f.next()
        #expect(r5 && f.step == .done)
        let r6 = f.next()
        #expect(r6 && f.finished)
    }

    @Test func backStopsAtLanguages() {
        var f = SetupFlow()
        f.back()
        #expect(f.step == .languages)
        f.next(); f.back()
        #expect(f.step == .languages)
    }

    @Test func railIndexFollowsTheVisibleSteps() {
        var f = SetupFlow()
        f.toggle(.uz); f.next(); f.grantAll(); f.next()
        #expect(f.step == .connect && f.railIndex == 2 && f.steps.count == 5)
    }

    @Test func hotkeyReachesThePipelineOnlyFromTry() {
        var f = SetupFlow()
        #expect(!f.hotkeysReachPipeline)
        f.next(); #expect(!f.hotkeysReachPipeline)
        f.grantAll(); f.next()
        #expect(f.step == .tryIt && f.hotkeysReachPipeline)
        f.skipTry()
        #expect(f.step == .done && f.hotkeysReachPipeline)
    }

    @Test func windowHeightsPerStep() {
        // Owner 2026-10-17: v5's 960 × 560/580 scaled by one ratio (SetupScale, 1.1) to 1056 × 616/640.
        #expect(SetupFlow.height(.languages) == 616)
        #expect(SetupFlow.height(.permissions) == 616)
        #expect(SetupFlow.height(.connect) == 640)
        #expect(SetupFlow.height(.tryIt) == 640)
        #expect(SetupFlow.height(.done) == 616)
        #expect(SetupFlow.width == 1056 && SetupFlow.stageWidth == 376)
    }

    @Test func restartKeepsLivePermissionsAndUILanguage() {
        var f = SetupFlow()
        f.uiLanguage = .ru
        f.toggle(.uz); f.next(); f.grantAll()
        f.restart()
        #expect(f.step == .languages && f.languages == [.en] && f.ax && f.mic == .granted && f.uiLanguage == .ru)
    }
}

@Suite struct SetupFlowPermissionTests {
    private func atPermissions() -> SetupFlow { var f = SetupFlow(); f.next(); return f }

    @Test func anyOrder() {
        var f = atPermissions()
        #expect(f.firstPending == .mic)
        f.update(PermissionState(mic: .notDetermined, ax: true))
        #expect(f.firstPending == .mic && !f.permissionsDone)
        f.update(PermissionState(mic: .granted, ax: true))
        #expect(f.firstPending == nil && f.permissionsDone && f.canContinue)
    }

    @Test func deniedMicPointsToSettings() {
        var f = atPermissions()
        f.update(PermissionState(mic: .denied, ax: false))
        #expect(f.firstPending == .micSettings)
        f.update(PermissionState(mic: .denied, ax: true))
        #expect(f.firstPending == .micSettings && !f.canContinue)
    }

    @Test func accessibilityAfterMic() {
        var f = atPermissions()
        f.update(PermissionState(mic: .granted, ax: false))
        #expect(f.firstPending == .accessibility)
    }

    @Test func fnRowOnlyForTheFnHotkeyAndWhenWrong() {
        var f = atPermissions()
        f.update(PermissionState(mic: .granted, ax: true))
        f.updateFn(hotkeyIsFn: true, usage: 0)
        #expect(!f.fnRowShown && f.permissionsDone)
        f.updateFn(hotkeyIsFn: false, usage: 2)
        #expect(!f.fnRowShown && f.permissionsDone)
        f.updateFn(hotkeyIsFn: true, usage: 2)
        #expect(f.fnRowShown && f.firstPending == .fn && !f.permissionsDone)
        f.updateFn(hotkeyIsFn: true, usage: nil)          // key missing = the macOS default, not Do Nothing
        #expect(f.firstPending == .fn)
    }

    @Test func fnRowStaysVisibleOnceFixed() {
        var f = atPermissions()
        f.update(PermissionState(mic: .granted, ax: true))
        f.updateFn(hotkeyIsFn: true, usage: 2)
        f.updateFn(hotkeyIsFn: true, usage: 0)
        #expect(f.fnRowShown && f.fnOK && f.permissionsDone)
        #expect(f.fnUsage == 0)
    }

    @Test func awaitingClearsWhenTheGrantArrives() {
        var f = atPermissions()
        f.awaitSurface(.micAlert)
        #expect(f.awaiting == .micAlert)
        f.update(PermissionState(mic: .denied))
        #expect(f.awaiting == nil)                          // answered (either way)
        f.awaitSurface(.accessibility)
        f.update(PermissionState(mic: .denied, ax: false))
        #expect(f.awaiting == .accessibility)
        f.update(PermissionState(mic: .denied, ax: true))
        #expect(f.awaiting == nil)
        f.awaitSurface(.micSettings)
        f.update(PermissionState(mic: .granted, ax: true))
        #expect(f.awaiting == nil)
        f.updateFn(hotkeyIsFn: true, usage: 2)
        f.awaitSurface(.fnSetting)
        f.updateFn(hotkeyIsFn: true, usage: 0)
        #expect(f.awaiting == nil)
    }

    @Test func cancelAwaitShowsThePreviewAgain() {
        var f = atPermissions()
        f.awaitSurface(.accessibility)
        f.cancelAwait()
        #expect(f.awaiting == nil)
    }

    @Test func inputMonitoringRowOnlyWhenKeysDoNotFlow() {
        var f = atPermissions()
        f.update(PermissionState(mic: .granted, ax: true, inputMonitoring: false))
        #expect(!f.inputMonitoringRowShown)                  // default: never shown
        f.keysNotDelivered = true
        #expect(f.inputMonitoringRowShown)
        #expect(f.permissionsDone)                           // non-blocking
        f.update(PermissionState(mic: .granted, ax: true, inputMonitoring: false, eventsFlowing: true))
        #expect(!f.inputMonitoringRowShown)
        f.update(PermissionState(mic: .granted, ax: false, inputMonitoring: false))
        #expect(!f.inputMonitoringRowShown)                  // Accessibility first
    }
}

@Suite struct SetupFlowConnectTests {
    private func atConnect(_ langs: [SpokenLanguage] = [.uz]) -> SetupFlow {
        var f = SetupFlow()
        for l in langs { f.toggle(l) }
        f.next(); f.grantAll(); f.next()
        return f
    }

    @Test func connectNeedsAVerifiedKey() {
        var f = atConnect()
        #expect(f.step == .connect && f.provider == .google && f.keyState == .idle && !f.canContinue)
        f.markOpened()
        #expect(f.keyState == .opened)
        f.keyChecking()
        #expect(f.keyState == .checking)
        f.keyFailed(.rejected)
        #expect(f.keyState == .failed(.rejected) && !f.canContinue)
        f.keyChecking(); f.keyConnected()
        #expect(f.connected && f.canContinue)
        let r7 = f.next()
        #expect(r7 && f.step == .tryIt)
    }

    @Test func providerLockedOnceConnected() {
        var f = atConnect()
        f.setProvider(.openRouter)
        #expect(f.provider == .openRouter)
        f.keyConnected()
        f.setProvider(.google)
        #expect(f.provider == .openRouter && f.connected)
    }

    @Test func providerChangeResetsTheKeyState() {
        var f = atConnect()
        f.keyFailed(.malformed)
        f.setProvider(.openRouter)
        #expect(f.keyState == .idle)
    }

    @Test func skipGoesToTryInEnglish() {
        var f = atConnect([.ru])
        f.uiLanguage = .ru
        f.skipConnect()
        #expect(f.step == .tryIt && f.tryLanguage == .en)
    }

    @Test func togglingALanguageResetsAnUnconnectedKey() {
        var f = SetupFlow()
        f.toggle(.uz)
        f.keyFailed(.unreachable)
        f.toggle(.ru)
        #expect(f.keyState == .idle)
    }

    @Test func keyShapeFailures() {
        #expect(SetupFlow.shapeFailure("AIzaFAKE1234FAKE1234FAKE", for: .openRouter) == .wrongProvider)
        #expect(SetupFlow.shapeFailure("sk-or-FAKE1234FAKE1234FAKE", for: .google) == .wrongProvider)
        #expect(SetupFlow.shapeFailure("FAKE", for: .google) == .malformed)
        #expect(SetupFlow.shapeFailure("FAKE 1234 FAKE 1234 FAKE 1234", for: .google) == .malformed)
        #expect(SetupFlow.shapeFailure("", for: .google) == .malformed)
        #expect(SetupFlow.shapeFailure("AIzaFAKE1234FAKE1234FAKE", for: .google) == nil)
    }

    @Test func providersMapToTheExistingKinds() {
        #expect(SetupProvider.google.kind == .google && SetupProvider.google.key == .google)
        #expect(SetupProvider.openRouter.kind == .openRouter && SetupProvider.openRouter.key == .openRouter)
        #expect(SetupProvider.google.host == "aistudio.google.com" && SetupProvider.openRouter.host == "openrouter.ai")
    }
}

@Suite struct SetupFlowTryTests {
    private let t0 = Date(timeIntervalSince1970: 100)

    private func atTry(_ langs: [SpokenLanguage] = [], connect: Bool = false, ui: UILanguage = .en) -> SetupFlow {
        var f = SetupFlow()
        f.uiLanguage = ui
        for l in langs { f.toggle(l) }
        f.next(); f.grantAll(); f.next()
        if f.step == .connect {
            if connect { f.keyConnected(); f.next() } else { f.skipConnect() }
        }
        return f
    }

    @Test func successNeedsTextAfterARelease() {
        var f = atTry()
        let typed = f.recordTry(text: "FAKE", releasedAt: nil, now: t0, engine: .onDevice)
        #expect(!typed)                                  // typed, not dictated
        let r8 = f.recordTry(text: "   \n", releasedAt: t0, now: t0, engine: .onDevice)
        #expect(!r8)
        #expect(f.currentTry == nil && !f.canContinue)
        let r9 = f.recordTry(text: "FAKE words", releasedAt: t0, now: t0.addingTimeInterval(0.42), engine: .onDevice)
        #expect(r9)
        let r = f.currentTry
        #expect(r?.language == .en && r?.engine == .onDevice)
        #expect(abs((r?.seconds ?? 0) - 0.42) < 0.001)
        #expect(f.canContinue)
    }

    @Test func englishWhenNoCloudLanguageIsConnected() {
        #expect(atTry().tryLanguage == .en)
        #expect(atTry([.uz]).tryLanguage == .en)
    }

    @Test func connectedCloudLanguageFollowsTheUILanguage() {
        #expect(atTry([.uz, .ru], connect: true, ui: .ru).tryLanguage == .ru)
        #expect(atTry([.uz, .ru], connect: true, ui: .uz).tryLanguage == .uz)
        #expect(atTry([.uz, .ru], connect: true, ui: .en).tryLanguage == .uz)     // first cloud language
        #expect(atTry([.ru], connect: true, ui: .uz).tryLanguage == .ru)
    }

    @Test func staleTryIsDroppedWhenTheLanguageChanges() {
        var f = atTry([.uz, .ru], connect: true, ui: .ru)
        _ = f.recordTry(text: "FAKE", releasedAt: t0, now: t0.addingTimeInterval(1), engine: .cloud("OpenRouter"))
        #expect(f.currentTry?.language == .ru)
        f.uiLanguage = .uz
        #expect(f.currentTry == nil && !f.canContinue)
        f.uiLanguage = .ru
        #expect(f.currentTry?.language == .ru)
    }

    @Test func skipTryGoesToDone() {
        var f = atTry()
        f.skipTry()
        #expect(f.step == .done && f.currentTry == nil)
    }

    @Test func recordOnlyOnTheTryStep() {
        var f = SetupFlow()
        let r10 = f.recordTry(text: "FAKE", releasedAt: t0, now: t0, engine: .onDevice)
        #expect(!r10)
    }
}

@Suite struct SetupFlowDoneTests {
    private func atDone(_ langs: [SpokenLanguage], connect: Bool, ui: UILanguage = .en) -> SetupFlow {
        var f = SetupFlow()
        f.uiLanguage = ui
        for l in langs { f.toggle(l) }
        f.next(); f.grantAll(); f.next()
        if f.step == .connect { if connect { f.keyConnected(); f.next() } else { f.skipConnect() } }
        f.skipTry()
        return f
    }

    @Test func englishOnlyIsReady() {
        let f = atDone([], connect: false)
        #expect(f.allReady)
        #expect(f.doneRows == [SetupFlow.DoneRow(language: .en, status: .readyOnDevice)])
    }

    @Test func russianSkippedIsHonest() {
        let f = atDone([.ru], connect: false)
        #expect(!f.allReady)
        #expect(f.doneRows == [.init(language: .en, status: .readyOnDevice), .init(language: .ru, status: .connectButton)])
    }

    @Test func onlyTheFirstMissingLanguageGetsTheButton() {
        let f = atDone([.uz, .ru], connect: false)
        #expect(f.doneRows.map(\.status) == [.readyOnDevice, .connectButton, .needsKey])
        #expect(f.cloudCombo == .uzru)
    }

    @Test func connectedLanguagesAreReady() {
        let f = atDone([.uz, .ru], connect: true)
        #expect(f.allReady)
        #expect(f.doneRows.map(\.status) == [.readyOnDevice, .readyCloud, .readyCloud])
    }

    @Test func connectFromDoneReturnsToDone() {
        var f = atDone([.ru], connect: false, ui: .ru)
        f.connectLater()
        #expect(f.step == .connect && f.returnTo == .done)
        f.keyConnected()
        let r11 = f.next()
        #expect(r11 && f.step == .done && f.returnTo == nil)
        #expect(f.allReady && f.showsTryCloud)
    }

    @Test func backFromConnectOpenedFromDoneReturnsToDone() {
        var f = atDone([.ru], connect: false)
        f.connectLater()
        f.back()
        #expect(f.step == .done && f.returnTo == nil)
    }

    @Test func tryInXGoesToTryAndBackThenDisappears() {
        var f = atDone([.ru], connect: false, ui: .ru)
        f.connectLater(); f.keyConnected(); f.next()
        #expect(f.showsTryCloud && f.tryLanguage == .ru)
        f.tryCloud()
        #expect(f.step == .tryIt && f.returnTo == .done)
        let t0 = Date(timeIntervalSince1970: 1)
        _ = f.recordTry(text: "FAKE", releasedAt: t0, now: t0.addingTimeInterval(1.1), engine: .cloud("Google AI Studio"))
        let r12 = f.next()
        #expect(r12 && f.step == .done)
        #expect(!f.showsTryCloud)
    }

    @Test func noTryCloudWithoutAConnectedKey() {
        #expect(!atDone([.ru], connect: false).showsTryCloud)
        #expect(!atDone([], connect: false).showsTryCloud)
    }
}

@Suite struct SetupEngineMappingTests {
    @Test func verifiedKeyPicksThatCloud() {
        var f = SetupFlow(); f.toggle(.uz); f.setProvider(.openRouter); f.keyConnected()
        #expect(f.engine(current: .apple, currentHasVerifiedKey: false, setUpBefore: false, freeAvailable: true) == .openRouter)
        #expect(f.engine(current: .openRouter, currentHasVerifiedKey: true, setUpBefore: true, freeAvailable: true) == nil)
    }

    @Test func englishOnlyOrSkipIsTheFreeEngine() {
        var f = SetupFlow()
        #expect(f.engine(current: .openRouter, currentHasVerifiedKey: false, setUpBefore: false, freeAvailable: true) == .apple)
        #expect(f.engine(current: .apple, currentHasVerifiedKey: false, setUpBefore: false, freeAvailable: true) == nil)
        f.toggle(.ru)                                    // picked Russian, skipped the key
        #expect(f.engine(current: .google, currentHasVerifiedKey: false, setUpBefore: false, freeAvailable: true) == .apple)
    }

    @Test func neverSilentlyDropsAnExistingWorkingCloud() {
        let f = SetupFlow()
        #expect(f.engine(current: .openRouter, currentHasVerifiedKey: true, setUpBefore: true, freeAvailable: true) == nil)
        #expect(f.engine(current: .custom, currentHasVerifiedKey: false, setUpBefore: true, freeAvailable: true) == nil)
    }

    @Test func noFreeEngineKeepsTheCurrentOne() {
        let f = SetupFlow()
        #expect(f.engine(current: .openRouter, currentHasVerifiedKey: false, setUpBefore: false, freeAvailable: false) == nil)
    }

    @Test func connectedButCloudLanguageUntickedIsFree() {
        var f = SetupFlow(); f.toggle(.uz); f.keyConnected(); f.toggle(.uz)
        #expect(f.engine(current: .apple, currentHasVerifiedKey: false, setUpBefore: false, freeAvailable: true) == nil)
    }
}

@Suite struct SetupFormatTests {
    @Test func decimalCommaForUzbekAndRussian() {
        #expect(SetupFlow.seconds(0.46, language: .en) == "0.5")
        #expect(SetupFlow.seconds(0.46, language: .uz) == "0,5")
        #expect(SetupFlow.seconds(1.04, language: .ru) == "1,0")
    }
}

@Suite struct UILanguageSettingTests {
    @Test func defaultFromPreferredLanguages() {
        #expect(UILanguage.from(preferredLanguages: ["ru-RU", "en-US"]) == .ru)
        #expect(UILanguage.from(preferredLanguages: ["uz-Latn-UZ"]) == .uz)
        #expect(UILanguage.from(preferredLanguages: ["uz-Cyrl"]) == .uz)
        #expect(UILanguage.from(preferredLanguages: ["de-DE", "ru"]) == .ru)
        #expect(UILanguage.from(preferredLanguages: ["en-GB"]) == .en)
        #expect(UILanguage.from(preferredLanguages: ["de-DE", "fr"]) == .en)
        #expect(UILanguage.from(preferredLanguages: []) == .en)
    }

    @Test func roundTripsAndToleratesUnknownValues() throws {
        var s = Settings(); s.uiLanguage = .uz
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(back.uiLanguage == .uz)
        let unknown = Data(#"{"uiLanguage":"kk","hotkey":"fn"}"#.utf8)
        let d = try JSONDecoder().decode(Settings.self, from: unknown)
        #expect(d.uiLanguage == Settings().uiLanguage && d.hotkey == .fn)
    }

    @Test func oldBlobGetsTheDefault() throws {
        let blob = Data(#"{"sttModel":"google/gemini-3.5-flash"}"#.utf8)
        #expect(try JSONDecoder().decode(Settings.self, from: blob).uiLanguage == Settings().uiLanguage)
    }

    @Test func spokenLanguageMatchesUILanguage() {
        #expect(SpokenLanguage(UILanguage.ru) == .ru && SpokenLanguage(UILanguage.uz) == .uz && SpokenLanguage(UILanguage.en) == .en)
    }
}

extension SetupFlow {
    /// Test helper: every permission granted, fn already "Do Nothing".
    mutating func grantAll() {
        update(PermissionState(mic: .granted, ax: true, inputMonitoring: true))
        updateFn(hotkeyIsFn: true, usage: 0)
    }
}

@Suite struct SetupFlowReviewFixTests {
    private let t0 = Date(timeIntervalSince1970: 50)

    private func atTry() -> SetupFlow {
        var f = SetupFlow(); f.next(); f.grantAll(); f.next(); return f
    }

    @Test func resultKeepsItsText() {
        var f = atTry()
        _ = f.recordTry(text: "FAKE words", releasedAt: t0, now: t0.addingTimeInterval(0.4), engine: .onDevice)
        #expect(f.currentTry?.text == "FAKE words")
        f.next(); f.back()                                   // Finish → Back: text and result come back together
        #expect(f.step == .tryIt && f.currentTry?.text == "FAKE words")
    }

    @Test func aNewRecordingClearsTheOldResult() {
        var f = atTry()
        _ = f.recordTry(text: "FAKE", releasedAt: t0, now: t0.addingTimeInterval(0.4), engine: .onDevice)
        f.beginTryRecording()
        #expect(f.currentTry == nil && !f.canContinue)
        #expect(f.triedLanguages.contains(.en))             // Done's "Try in X" logic is unaffected
        let again = f.recordTry(text: "FAKE again", releasedAt: t0, now: t0.addingTimeInterval(0.6), engine: .onDevice)
        #expect(again && f.currentTry?.text == "FAKE again")
    }

    @Test func beginRecordingOnlyOnTry() {
        var f = SetupFlow()
        f.beginTryRecording()
        #expect(f.step == .languages)
    }

    @Test func shortOrSilentHoldSaysHoldLonger() {
        // Dropped by the pipeline: recording → idle with no transcribing in between.
        #expect(TryFeedback.after(from: .recording, to: .idle, softFailure: false, note: .writing) == .short)
        #expect(TryFeedback.after(from: .recording, to: .ready, softFailure: false, note: .writing) == .short)
        // "No speech heard" (soft card) is a silent hold too.
        #expect(TryFeedback.after(from: .transcribing, to: .failed, softFailure: true, note: .writing) == .short)
        #expect(TryFeedback.after(from: .recording, to: .failed, softFailure: true, note: .writing) == .short)
        // A real error (network, key) is not "hold longer".
        #expect(TryFeedback.after(from: .transcribing, to: .failed, softFailure: false, note: .writing) == .idle)
        // Normal progress and other notes are left alone.
        #expect(TryFeedback.after(from: .recording, to: .transcribing, softFailure: false, note: .writing) == .writing)
        #expect(TryFeedback.after(from: .recording, to: .idle, softFailure: false, note: .ok) == .ok)
        #expect(TryFeedback.after(from: .pasting, to: .done, softFailure: false, note: .writing) == .writing)
    }

    @Test func resultHiddenWhileANewRecordingRuns() {
        #expect(!TryFeedback.showsResult(note: .listening))
        #expect(!TryFeedback.showsResult(note: .writing))
        #expect(!TryFeedback.showsResult(note: .short))
        #expect(TryFeedback.showsResult(note: .ok))
    }

    @Test func rerunPreselectsSavedLanguages() {
        var f = SetupFlow()
        f.preselect([.ru])
        #expect(f.languages == [.ru] && f.steps.contains(.connect))
        f.preselect([])                                      // nothing saved: keep the default
        #expect(f.languages == [.ru])
        var g = SetupFlow(); g.preselect([])
        #expect(g.languages == [.en])
    }

    @Test func savedLanguagesAreStableOrder() {
        var f = SetupFlow(); f.toggle(.ru); f.toggle(.uz)
        #expect(f.languageList == [.en, .uz, .ru])
    }

    @Test func railMarksASkippedConnect() {
        var f = SetupFlow(); f.toggle(.ru); f.next(); f.grantAll(); f.next()
        f.skipConnect()
        #expect(f.step == .tryIt)
        #expect(f.railMark(.languages) == .done && f.railMark(.connect) == .skipped)
        #expect(f.railMark(.tryIt) == .current && f.railMark(.done) == .pending)
    }

    @Test func railTicksAConnectedConnect() {
        var f = SetupFlow(); f.toggle(.ru); f.next(); f.grantAll(); f.next()
        f.keyConnected(); f.next()
        #expect(f.railMark(.connect) == .done)
    }

    @Test func railMarksASkippedTry() {
        var f = SetupFlow(); f.next(); f.grantAll(); f.next()
        #expect(f.step == .tryIt)
        f.skipTry()
        #expect(f.step == .done && f.railMark(.tryIt) == .skipped)
    }

    @Test func railTicksATriedTry() {
        var f = SetupFlow(); f.next(); f.grantAll(); f.next()
        f.recordTry(text: "FAKE text", releasedAt: Date(timeIntervalSince1970: 10), now: Date(timeIntervalSince1970: 10.5), engine: .onDevice)
        f.next()
        #expect(f.step == .done && f.railMark(.tryIt) == .done)
    }

    @Test func connectingFromDoneClearsTheSkip() {
        var f = SetupFlow(); f.toggle(.ru); f.next(); f.grantAll(); f.next()
        f.skipConnect(); f.skipTry()
        #expect(f.railMark(.connect) == .skipped)
        f.connectLater(); f.keyConnected(); f.next()
        #expect(f.step == .done && f.railMark(.connect) == .done)
    }
}

@Suite struct SpokenLanguagesSettingTests {
    @Test func absentByDefaultAndRoundTrips() throws {
        #expect(Settings().spokenLanguages == nil)
        var s = Settings(); s.spokenLanguages = [.en, .ru]
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(back.spokenLanguages == [.en, .ru])
    }

    @Test func toleratesUnknownValues() throws {
        let blob = Data(#"{"spokenLanguages":["ru","kk"],"hotkey":"fn"}"#.utf8)
        let s = try JSONDecoder().decode(Settings.self, from: blob)
        #expect(s.spokenLanguages == nil && s.hotkey == .fn)
    }
}
