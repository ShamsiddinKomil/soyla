import Testing
import Foundation
@testable import SoylaCore

// Visual audit 2026-10-19, V-01, V-03, V-09, V-10, V-11, V-22: one shared
// `Readiness` that every surface reads, so "Ready" never shows while Soyla can't hear or type.

@Suite struct ReadinessTests {
    private func home(_ mic: PermissionState.Mic, ax: Bool = true, _ langs: [SpokenLanguage], provider: ProviderKind = .apple,
                      keys: Set<KeyProvider> = []) -> HomeState {
        HomeState(mic: mic, ax: ax, spoken: langs, provider: provider,
                  hasKey: { keys.contains($0) }, verified: { keys.contains($0) }, keychain: .ready)
    }

    @Test func aMissingPermissionWinsOverAMissingKey() {
        #expect(Readiness(micMissing: true, axMissing: false, englishNeedsKey: true, missing: .uz) == .blocked(mic: true, ax: false))
        #expect(Readiness(micMissing: false, axMissing: true, englishNeedsKey: false, missing: nil) == .blocked(mic: false, ax: true))
        #expect(Readiness(micMissing: false, axMissing: false, englishNeedsKey: false, missing: .uz) == .needsKey(.uz, englishWorks: true))
        #expect(Readiness(micMissing: false, axMissing: false, englishNeedsKey: true, missing: nil) == .needsKey(nil, englishWorks: false, englishWaits: true))
        #expect(Readiness(micMissing: false, axMissing: false, englishNeedsKey: false, missing: nil) == .ready)
    }

    @Test func englishWorksOnlyWhenNothingBlocksIt() {
        #expect(!Readiness.blocked(mic: true, ax: false).englishWorks)
        #expect(Readiness.needsKey(.ru, englishWorks: true).englishWorks)
        #expect(!Readiness.needsKey(.ru, englishWorks: false).englishWorks)
        #expect(Readiness.ready.englishWorks)
        #expect(Readiness.blocked(mic: true, ax: true).micFirst && !Readiness.blocked(mic: false, ax: true).micFirst)
    }

    @Test func homeRowsWaitWhileAPermissionIsMissing() {
        let h = home(.denied, [.en, .uz])
        #expect(h.readiness == .blocked(mic: true, ax: false))
        #expect(h.rows.map(\.status) == [.onMac, .needsKey])           // the key truth stays in `rows`
        #expect(h.shownRows.map(\.status) == [.blocked, .blocked])     // what Home, Languages and Privacy draw
        let ax = home(.granted, ax: false, [.en])
        #expect(ax.readiness == .blocked(mic: false, ax: true) && ax.shownRows.map(\.status) == [.blocked])
    }

    @Test func homeRowsAreTheirOwnOnceAllowed() {
        let h = home(.granted, [.en, .uz])
        #expect(h.readiness == .needsKey(.uz, englishWorks: true))
        #expect(h.shownRows.map(\.status) == h.rows.map(\.status))
        let ok = home(.granted, [.en, .ru], provider: .google, keys: [.google])
        #expect(ok.readiness == .ready)
    }

    @Test func aHostedEngineWithNoKeyMeansEnglishWaitsToo() {
        let h = home(.granted, [.en, .uz], provider: .openRouter)
        #expect(h.readiness == .needsKey(.uz, englishWorks: false, englishWaits: true))
        let en = home(.granted, [.en], provider: .google)
        #expect(en.readiness == .needsKey(nil, englishWorks: false, englishWaits: true))
    }

    @Test func theMenuSaysHotkeyOffOnlyWhenNoPermissionFixIsShown() {
        let blocked = MenuHeader(home: home(.denied, [.en]), secureInput: false)
        #expect(!blocked.showsHotkeyOff(hotkeyActive: false))
        let ready = MenuHeader(home: home(.granted, [.en]), secureInput: false)
        #expect(ready.showsHotkeyOff(hotkeyActive: false))
        #expect(!ready.showsHotkeyOff(hotkeyActive: true))
    }
}

@Suite struct SetupEntryHonestyTests {
    private func granted(_ f: inout SetupFlow) {
        f.update(PermissionState(mic: .granted, ax: true, inputMonitoring: true))
        f.updateFn(hotkeyIsFn: true, usage: 0)
    }

    @Test func theRailTicksOnlyWhatHappened() {
        let f = SetupFlow(entry: .languages, languages: [.en])
        #expect(f.shownRailMark(.languages) == .current)
        #expect(f.shownRailMark(.permissions) == .skipped)       // nothing granted
        #expect(f.shownRailMark(.tryIt) == .skipped)             // nothing tried
        #expect(f.shownRailMark(.done) == .pending)
        var g = SetupFlow(entry: .languages, languages: [.en])
        granted(&g)
        #expect(g.shownRailMark(.permissions) == .done && g.shownRailMark(.done) == .done)
        #expect(g.shownRailMark(.tryIt) == .skipped)
    }

    @Test func aFirstRunRailIsUnchanged() {
        var f = SetupFlow()
        f.next()
        for s in SetupStep.allCases { #expect(f.shownRailMark(s) == f.railMark(s)) }
    }

    @Test func setupReadinessMatchesTheApps() {
        var f = SetupFlow(entry: .done, languages: [.en, .uz])
        #expect(f.readiness == .blocked(mic: true, ax: true))
        granted(&f)
        #expect(f.readiness == .needsKey(.uz, englishWorks: true))
        f.keyConnected()
        #expect(f.readiness == .ready)
    }

    @Test func permissionsFromTheAppCanAlwaysBeLeft() {
        var f = SetupFlow(entry: .permissions, languages: [.en])
        #expect(!f.canContinue && f.primaryEnabled)
        f.leave()
        #expect(f.finished)
    }

    @Test func tryFromTheAppCanBeLeftWhileBlocked() {
        var f = SetupFlow(entry: .tryIt, languages: [.en])
        #expect(f.step == .tryIt && f.readiness.isBlocked && f.primaryEnabled)
        granted(&f)
        #expect(!f.primaryEnabled)                               // allowed now: try it first (or Back/close)
    }

    @Test func aFirstRunCannotBeLeft() {
        var f = SetupFlow()
        f.next()
        #expect(f.step == .permissions && !f.primaryEnabled)
        f.leave()
        #expect(!f.finished)
    }
}

@Suite struct PillKeyCardTests {
    private let card = PillFailure.from(SoylaError.missingAPIKey("FAKE"), stage: "transcribe")

    @Test func aMissingKeyIsACalmInfoCard() {
        #expect(card.kind == .info && card.fix == .connectKey)
        let en = card.shown(.en, readiness: .needsKey(.uz, englishWorks: true))
        #expect(en.kind == .info && en.title == "Uzbek needs an API key" && en.hint == "English works without one.")
        let uz = card.shown(.uz, readiness: .needsKey(.uz, englishWorks: true))
        #expect(uz.title == "O‘zbek tili uchun API key kerak" && uz.hint == "Ingliz tili usiz ishlaydi.")
        let ru = card.shown(.ru, readiness: .needsKey(.uz, englishWorks: true))
        #expect(ru.title == "Для узбекского нужен API-ключ" && ru.hint == "Английский работает и без него.")
        #expect(card.shown(.en, readiness: .needsKey(.uzru, englishWorks: true)).title == "Uzbek and Russian need an API key")
    }

    @Test func itNeverSaysEnglishWorksWhenItDoesnt() {
        // D22 (owner-approved change): a hosted engine with no key and English chosen names Soyla, not Uzbek.
        let hosted = card.shown(.en, readiness: .needsKey(.uz, englishWorks: false, englishWaits: true))
        #expect(hosted.title == "Soyla needs an API key" && hosted.hint == "Connect a key to start dictating.")
        let noEnglish = card.shown(.en, readiness: .needsKey(.uz, englishWorks: false))
        #expect(noEnglish.title == "Uzbek needs an API key" && noEnglish.hint == "Connect a key to start dictating.")
        let none = card.shown(.en, readiness: .needsKey(nil, englishWorks: false))
        #expect(none.title == "Soyla needs an API key" && none.hint == "Connect a key to start dictating.")
        #expect(card.shown(.ru, readiness: .needsKey(nil, englishWorks: false)).title == "Soyla нужен API-ключ")
    }

    @Test func otherCardsAreOnlyTranslated() {
        let other = PillFailure.from(URLError(.notConnectedToInternet), stage: "transcribe")
        #expect(other.shown(.uz, readiness: .ready) == other.localized(.uz))
        let en = other.shown(.en, readiness: .blocked(mic: true, ax: false))
        #expect(en.title == other.title && en.hint == "Your recording is saved. Retry when you’re online.")   // V-32: ’
    }
}
