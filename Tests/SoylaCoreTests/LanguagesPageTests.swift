import Testing
import Foundation
@testable import SoylaCore

// APP-1 (b): the Languages page (was Engine) and the menu bar. The approved design is
// design prototype v2: `engine()` and `renderMenu()`.

// MARK: - LanguagesPageState: prototype engine()

@Suite struct LanguagesPageStateTests {
    enum KeyEngine: CaseIterable { case noKey, keyCloud, keyMac }

    private func page(_ langs: [SpokenLanguage], _ k: KeyEngine, developer: Bool = false) -> LanguagesPageState {
        let provider: ProviderKind = k == .keyCloud ? .google : .apple
        let keys: Set<KeyProvider> = k == .noKey ? [] : [.google]
        let home = HomeState(mic: .granted, spoken: langs, provider: provider, hasKey: { keys.contains($0) },
                             verified: { keys.contains($0) }, keychain: .ready)
        return LanguagesPageState(home: home, spoken: langs, provider: provider, hasKey: { keys.contains($0) }, developerMode: developer)
    }

    /// Prototype `engine()`: cloud group when a cloud language is chosen, the engine radio once a key exists, the
    /// "On this Mac" group without a cloud language or while that engine is on, the header fix only with a key.
    /// The model row follows the engine in use (its id belongs to that provider), not just "a key exists".
    @Test func cloudLanguageStatesMatchThePrototype() {
        for langs in [[SpokenLanguage.en, .uz], [.en, .uz, .ru]] {
            for k in KeyEngine.allCases {
                let p = page(langs, k)
                let key = k != .noKey
                #expect(p.showsCloud, "\(langs) \(k)")
                #expect(p.showsEngineChoice == key, "\(langs) \(k)")
                #expect(p.showsOnMac == (k != .keyCloud), "\(langs) \(k)")
                #expect(p.engineIsCloud == (k == .keyCloud), "\(langs) \(k)")
                #expect((p.headerAction != nil) == (k == .keyMac), "\(langs) \(k)")    // key + mac → Use Cloud
                #expect(p.showsModel == (k == .keyCloud), "\(langs) \(k)")   // the model belongs to the engine in use
            }
        }
    }

    @Test func englishOnlyWithoutAKeyIsOnlyThisMac() {
        let p = page([.en], .noKey)
        #expect(!p.showsCloud && !p.showsEngineChoice && p.showsOnMac && p.headerAction == nil && !p.showsModel)
    }

    @Test func englishOnlyWithAKeyStillShowsCloud() {
        // Code wins over the prototype: an English-only user dictating through Cloud (every v0.2 user) must still
        // see and manage the key and the engine.
        let cloud = page([.en], .keyCloud)
        #expect(cloud.showsCloud && cloud.showsEngineChoice && !cloud.showsOnMac && cloud.showsModel)
        let mac = page([.en], .keyMac)
        #expect(mac.showsCloud && mac.showsEngineChoice && mac.showsOnMac && !mac.showsModel)
    }

    @Test func servicesListCustomOnlyForDevelopersOrWhenInUse() {
        #expect(page([.en, .uz], .noKey).services == [.google, .openRouter])
        #expect(page([.en, .uz], .noKey, developer: true).services == [.google, .openRouter, .custom])
        let home = HomeState(mic: .granted, spoken: [.en], provider: .custom, hasKey: { _ in false }, verified: { _ in false }, keychain: .ready)
        let custom = LanguagesPageState(home: home, spoken: [.en], provider: .custom, hasKey: { _ in false }, developerMode: false)
        #expect(custom.services.contains(.custom) && custom.showsCloud && custom.showsEngineChoice && custom.engineIsCloud)
    }

    @Test func selectedServiceFollowsTheEngineThenTheKeys() {
        #expect(LanguagesPageState.defaultService(provider: .openRouter, hasKey: { _ in false }) == .openRouter)
        #expect(LanguagesPageState.defaultService(provider: .apple, hasKey: { $0 == .openRouter }) == .openRouter)
        #expect(LanguagesPageState.defaultService(provider: .apple, hasKey: { _ in false }) == .google)
        #expect(LanguagesPageState.defaultService(provider: .custom, hasKey: { _ in false }) == .custom)
    }

    @Test func modelNamesArePlain() {
        #expect(LanguagesPageState.modelName("gemini-3.5-flash-lite") == "Gemini 3.5 Flash-Lite")
        #expect(LanguagesPageState.modelName("google/gemini-3.5-flash") == "Gemini 3.5 Flash")
    }
}

// MARK: - SetupFlow(connectFor:): Connect… / Replace… from the Languages page

@Suite struct SetupConnectForTests {
    @Test func opensConnectForThatServiceEvenWithoutACloudLanguage() {
        let f = SetupFlow(connectFor: .openRouter, languages: [.en])
        #expect(f.step == .connect && f.fromApp && f.provider == .openRouter && f.replacesKey)
        #expect(!f.connected && !f.showsBack)
    }

    @Test func aVerifiedKeyGoesToDoneThenFinishes() {
        var f = SetupFlow(connectFor: .google, languages: [.en, .uz])
        f.keyChecking(); f.keyConnected()
        let moved = f.next()
        #expect(moved && f.step == .done)
        let closed = f.next()
        #expect(closed && f.finished)
    }

    @Test func skipCloses() {
        var f = SetupFlow(connectFor: .google, languages: [.en])
        f.skipConnect()
        #expect(f.finished)
    }

    @Test func aNewKeySwitchesTheEngineOnlyForACloudLanguage() {
        // English only: the P5 offer (EngineSwitchPrompt) asks about switching; setup never switches by itself.
        var f = SetupFlow(connectFor: .openRouter, languages: [.en])
        f.keyConnected(); f.next()
        #expect(f.engine(current: .apple, currentHasVerifiedKey: false, setUpBefore: true, freeAvailable: true) == nil)
        var u = SetupFlow(connectFor: .openRouter, languages: [.en, .uz])
        u.keyConnected(); u.next()
        #expect(u.engine(current: .apple, currentHasVerifiedKey: false, setUpBefore: true, freeAvailable: true) == .openRouter)
    }
}

// MARK: - Menu routing

@Suite struct MenuRouteTests {
    @Test func itemsOpenTheMatchingSetupStep() {
        #expect(MenuHeader.Item.allowMic.route == .setup(.permissions))
        #expect(MenuHeader.Item.allowAccessibility.route == .setup(.permissions))
        #expect(MenuHeader.Item.connect(.uz).route == .setup(.connect))
        #expect(MenuHeader.Item.useCloud.route == .useCloud)
        #expect(MenuHeader.Item.addKey.route == .page(.languages))
    }

    @Test func languagesIsTheEnginePage() {
        #expect(SettingsPage.languages == .apiKeys && SettingsPage.languages.rawValue == "apiKeys")
        #expect(SettingsPage(argument: "languages") == .apiKeys)
        #expect(SettingsPage(argument: "apiKeys") == .apiKeys)
        #expect(SettingsPage(argument: "privacy") == .privacy && SettingsPage(argument: "nope") == nil)
        #expect(SettingsPage.apiKeys.title == "Languages")
    }
}

// MARK: - AppStrings for (b)

@Suite struct AppStringsMenuTests {
    @Test func languagesPageMatchesThePrototype() {
        let t = AppStrings.en
        #expect(t.eTitle == "Languages" && t.eSub == "Where each language turns into text." && t.eInfo.count == 3)
        #expect(t.engine == "Engine" && t.eCloudC == "All languages, mixed sentences" && t.eMacC == "English only · free, offline")
        #expect(t.key == "API key" && t.notAdded == "Not added" && t.replace == "Replace…" && t.connected == "Connected")
        #expect(t.macModel == "English speech model" && t.macModelC == "Apple · offline" && t.modelC == "Flash-Lite: faster, less exact")
        #expect(AppStrings.uz.engine == "Qayerda ishlaydi" && AppStrings.ru.eCloud == "Облако" && AppStrings.ru.key == "API-ключ")
    }

    @Test func mainMenuIsLocalized() {
        for l in UILanguage.allCases {
            let t = AppStrings.for(l)
            for s in [t.mmAbout, t.mmUpdates, t.mmHide, t.mmHideOthers, t.mmEdit, t.mmUndo, t.mmRedo, t.mmCut, t.mmCopy,
                      t.mmPaste, t.mmSelectAll, t.mmView, t.mmSettingsTab, t.mmWindow, t.mmSoylaWindow, t.mmMinimize,
                      t.mmClose, t.mmHelp, t.mHotkeyOff] {
                #expect(!s.isEmpty, "\(l)")
            }
        }
        #expect(AppStrings.ru.mmEdit == "Правка" && AppStrings.en.mmAbout == "About Soyla")
    }
}
