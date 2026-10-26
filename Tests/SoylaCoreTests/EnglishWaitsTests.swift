import Testing
import Foundation
@testable import SoylaCore

// Owner decision D22 (2026-10-25; regression pass 2026-10-20 R-03, R-04, R-05, R-15): a Cloud engine with no key and
// English chosen means English waits too, so every surface says "Soyla needs an API key", not "Uzbek and Russian".

@Suite struct EnglishWaitsTests {
    private func home(_ langs: [SpokenLanguage], _ p: ProviderKind, keys: Set<KeyProvider> = []) -> HomeState {
        HomeState(mic: .granted, spoken: langs, provider: p, hasKey: { keys.contains($0) }, verified: { keys.contains($0) }, keychain: .ready)
    }

    private func granted(_ f: inout SetupFlow) {
        f.update(PermissionState(mic: .granted, ax: true, inputMonitoring: true))
        f.updateFn(hotkeyIsFn: true, usage: 0)
    }

    private let card = PillFailure.from(SoylaError.missingAPIKey("FAKE1234"), stage: "transcribe")

    @Test func readinessSaysWhetherEnglishItselfWaits() {
        #expect(Readiness(micMissing: false, axMissing: false, englishNeedsKey: true, missing: .uzru)
            == .needsKey(.uzru, englishWorks: false, englishWaits: true))
        // English not chosen: nothing about English waits, whatever the engine.
        #expect(Readiness(micMissing: false, axMissing: false, englishNeedsKey: true, missing: .uzru, englishChosen: false)
            == .needsKey(.uzru, englishWorks: false, englishWaits: false))
        #expect(Readiness(micMissing: false, axMissing: false, englishNeedsKey: false, missing: .uz).englishWaits == false)
        #expect(Readiness.ready.englishWaits == false && Readiness.blocked(mic: true, ax: false).englishWaits == false)
    }

    @Test func thePillCardNamesSoylaWhenEnglishWaits() {
        let r = home([.en, .uz, .ru], .google).readiness
        #expect(r.englishWaits)
        let en = card.shown(.en, readiness: r)
        #expect(en.title == "Soyla needs an API key" && en.hint == "Connect a key to start dictating.")
        #expect(card.shown(.uz, readiness: r).title == AppStrings.uz.keyTitle)
        #expect(card.shown(.ru, readiness: r).title == AppStrings.ru.keyTitle)
        // Without English the card still names the cloud languages.
        let uzru = card.shown(.en, readiness: home([.uz, .ru], .google).readiness)
        #expect(uzru.title == "Uzbek and Russian need an API key")
    }

    @Test func theKeyDownPreflightCardSaysSoylaToo() {
        let h = home([.en, .uz], .google)
        #expect(KeyDownPreflight.card(home: h)?.shown(.en, readiness: h.readiness).title == "Soyla needs an API key")
    }

    @Test func setupReadinessFollowsTheEnglishRoute() {
        var f = SetupFlow(entry: .done, languages: [.en, .uz])
        granted(&f)
        #expect(f.readiness(englishReady: false) == .needsKey(.uz, englishWorks: false, englishWaits: true))
        #expect(f.readiness(englishReady: true) == f.readiness)
        #expect(f.englishWaits(englishReady: false) && !f.englishWaits(englishReady: true))
        let uz = SetupFlow(entry: .done, languages: [.uz])
        #expect(!uz.englishWaits(englishReady: false))
    }

    @Test func doneGivesConnectToEnglishWhenEnglishWaits() {
        var f = SetupFlow(entry: .done, languages: [.en, .uz, .ru])
        granted(&f)
        #expect(f.doneRows(englishReady: false).map(\.status) == [.connectButton, .needsKey, .needsKey])
        #expect(f.doneRows(englishReady: true) == f.doneRows)
        f.keyConnected()
        #expect(f.doneRows(englishReady: false).map(\.status) == [.readyOnDevice, .readyCloud, .readyCloud])
    }

    @Test func tryShowsTheKeyNudgeWhenNothingCanTranscribe() {
        var f = SetupFlow(entry: .tryIt, languages: [.en, .uz])
        granted(&f)
        #expect(f.tryWaitsForKey(englishReady: false) && !f.tryWaitsForKey(englishReady: true))
        #expect(!f.primaryEnabled && f.primaryEnabled(englishReady: false))   // nothing to try: Done closes setup
        f.keyConnected()
        #expect(!f.tryWaitsForKey(englishReady: false))                      // Uzbek goes through the new key
    }

    @Test func tryConnectReturnsToTry() {
        var f = SetupFlow(entry: .tryIt, languages: [.en, .uz])
        granted(&f)
        f.connectFromTry()
        #expect(f.step == .connect)
        f.keyConnected()
        f.next()
        #expect(f.step == .tryIt && f.tryLanguage == .uz)
        var en = SetupFlow(entry: .tryIt, languages: [.en])
        en.connectFromTry()
        #expect(en.step == .tryIt)                                           // no cloud language: no Connect step
    }
}
