import Testing
import Foundation
@testable import SoylaCore

// Flows audit 2026-10-19 F-03, F-04, F-06 (Bigger suggestion 1): one `LanguageRoute` says where each chosen language
// goes and whether it works there.
@Suite struct LanguageRouteTests {
    @Test func englishIsOnThisMacOnlyWithTheFreeEngine() {
        #expect(LanguageRoute.route(.en, engine: .apple, engineReady: true) == .init(language: .en, place: .onMac, ready: true))
        #expect(LanguageRoute.route(.en, engine: .google, engineReady: true).place == .cloud("Google AI Studio"))
        #expect(!LanguageRoute.route(.en, engine: .openRouter, engineReady: false).ready)
        #expect(LanguageRoute.route(.en, engine: .custom, engineReady: false) == .init(language: .en, place: .cloud(nil), ready: true))
    }

    @Test func cloudLanguagesNeedTheCloudEngine() {
        #expect(LanguageRoute.route(.uz, engine: .apple, engineReady: true, keyService: "OpenRouter") == .init(language: .uz, place: .cloud("OpenRouter"), ready: false))
        #expect(LanguageRoute.route(.ru, engine: .google, engineReady: true) == .init(language: .ru, place: .cloud("Google AI Studio"), ready: true))
        #expect(!LanguageRoute.route(.ru, engine: .google, engineReady: false).ready)
    }

    @Test func onlyChosenLanguagesAreListed() {
        let r = LanguageRoute.routes([.ru, .uz], engine: .google, engineReady: true)
        #expect(r.map(\.language) == [.uz, .ru])
    }

    @Test func homeListsWhereEachLanguageGoes() {
        let h = HomeState(mic: .granted, spoken: [.en, .uz], provider: .google, hasKey: { $0 == .google }, verified: { $0 == .google }, keychain: .ready)
        #expect(h.routes.map(\.place) == [.cloud("Google AI Studio"), .cloud("Google AI Studio")])
        let mac = HomeState(mic: .granted, spoken: [.en, .uz], provider: .apple, hasKey: { _ in false }, verified: { _ in false }, keychain: .ready)
        #expect(mac.routes.first?.place == .onMac && mac.englishWorksNow)
    }

    @Test func englishWorksNowIsNeverSaidToSomeoneWhoDoesntSpeakIt() {
        let uzru = HomeState(mic: .granted, spoken: [.uz, .ru], provider: .apple, hasKey: { _ in false }, verified: { _ in false }, keychain: .ready)
        #expect(uzru.title == .oneMore(.uzru) && !uzru.englishWorksNow)
        #expect(AppStrings.en.sub(uzru) == AppStrings.en.needsKeySub)
        #expect(uzru.readiness == .needsKey(.uzru, englishWorks: false))
        let menu = MenuHeader(home: uzru, secureInput: false).text(.en, key: "fn")
        #expect(menu.detail == AppStrings.en.mKeyFirst)
        let en = HomeState(mic: .granted, spoken: [.en, .uz], provider: .apple, hasKey: { _ in false }, verified: { _ in false }, keychain: .ready)
        #expect(AppStrings.en.sub(en) == "English works now.")
    }

    @Test func doneListsOnlyTheChosenLanguages() {
        var f = SetupFlow(entry: .languages, languages: [.uz, .ru])
        f.keyConnected()
        #expect(f.doneRows.map(\.language) == [.uz, .ru])
        let withEn = SetupFlow(entry: .languages, languages: [.en, .ru])
        #expect(withEn.doneRows.map(\.language) == [.en, .ru])
    }
}
