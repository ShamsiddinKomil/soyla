import Testing
import Foundation
@testable import SoylaCore

// APP-1 (a): the main window shell, Home and setup re-entry. The approved design is
// design prototype v2; its `home()`/`langRow()`/`renderMenu()`/`renderSetup()` are the spec.

// MARK: - SetupFlow(entry:): setup opened from the app

@Suite struct SetupEntryTests {
    private func granted(_ f: inout SetupFlow) {
        f.update(PermissionState(mic: .granted, ax: true, inputMonitoring: true))
        f.updateFn(hotkeyIsFn: true, usage: 0)
    }

    @Test func startsAtTheEntryWithNoWelcome() {
        let f = SetupFlow(entry: .languages, languages: [.en, .uz])
        #expect(f.step == .languages && f.fromApp && !f.hasWelcome)
        #expect(f.languages == [.en, .uz])
    }

    @Test func backIsANoOp() {
        var f = SetupFlow(entry: .languages, languages: [.en])
        f.back()
        #expect(f.step == .languages)
        var p = SetupFlow(entry: .permissions, languages: [.en])
        p.back()
        #expect(p.step == .permissions)
        var c = SetupFlow(entry: .connect, languages: [.en, .ru])
        c.back()
        #expect(c.step == .connect)
        #expect(!f.showsBack && !p.showsBack && !c.showsBack)
    }

    @Test func railMarksEveryOtherStepDone() {
        let f = SetupFlow(entry: .permissions, languages: [.en])
        #expect(f.railMark(.languages) == .done)
        #expect(f.railMark(.permissions) == .current)
        #expect(f.railMark(.tryIt) == .done)
        #expect(f.railMark(.done) == .done)
    }

    @Test func aSkippedConnectStaysSkippedOnTheRail() {
        let f = SetupFlow(entry: .permissions, languages: [.en, .uz])
        #expect(f.railMark(.connect) == .skipped)
        let ok = SetupFlow(entry: .permissions, languages: [.en, .uz], provider: .google, cloudReady: true)
        #expect(ok.railMark(.connect) == .done)
    }

    @Test func languagesContinueWithAMissingKeyGoesToConnect() {
        var f = SetupFlow(entry: .languages, languages: [.en])
        f.toggle(.uz)
        #expect(!f.finishesOnNext)
        let moved1 = f.next()
        #expect(moved1)
        #expect(f.step == .connect && !f.finished)
    }

    @Test func languagesContinueOtherwiseFinishes() {
        var f = SetupFlow(entry: .languages, languages: [.en, .uz])
        f.toggle(.uz)
        #expect(f.finishesOnNext)
        let moved2 = f.next()
        #expect(moved2)
        #expect(f.finished && f.languageList == [.en])

        var keyed = SetupFlow(entry: .languages, languages: [.en], provider: .openRouter, cloudReady: true)
        keyed.toggle(.ru)
        #expect(keyed.finishesOnNext)
        keyed.next()
        #expect(keyed.finished && keyed.provider == .openRouter)
    }

    @Test func permissionsContinueOnceDoneFinishesWithDone() {
        var f = SetupFlow(entry: .permissions, languages: [.en, .uz])
        #expect(!f.canContinue)
        let moved3 = f.next()
        #expect(!moved3 && !f.finished)
        granted(&f)
        #expect(f.finishesOnNext)
        let moved4 = f.next()
        #expect(moved4)
        #expect(f.finished)
    }

    @Test func connectWithAVerifiedKeyGoesToDoneWithTryCloud() {
        var f = SetupFlow(entry: .connect, languages: [.en, .uz])
        #expect(f.step == .connect)
        f.keyChecking(); f.keyConnected()
        let moved5 = f.next()
        #expect(moved5)
        #expect(f.step == .done && !f.finished)
        #expect(f.showsTryCloud)
        f.tryCloud()
        #expect(f.step == .tryIt)
        #expect(f.showsBack)                       // Try opened from Done returns to Done
        f.back()
        #expect(f.step == .done)
        let moved6 = f.next()
        #expect(moved6 && f.finished)
    }

    @Test func connectSkipFinishes() {
        var f = SetupFlow(entry: .connect, languages: [.en, .ru])
        f.skipConnect()
        #expect(f.finished && f.connectSkipped)
    }

    @Test func connectReachedFromLanguagesSkipFinishes() {
        var f = SetupFlow(entry: .languages, languages: [.en])
        f.toggle(.ru); f.next()
        f.skipConnect()
        #expect(f.finished && f.languageList == [.en, .ru])
    }

    @Test func tryInXGoesToTryThenBackToDone() {
        var f = SetupFlow(entry: .connect, languages: [.en, .uz])
        f.keyConnected(); f.next()
        f.tryCloud()
        #expect(f.step == .tryIt)
        let ok = f.recordTry(text: "FAKE matn", releasedAt: Date(timeIntervalSince1970: 1), now: Date(timeIntervalSince1970: 2), engine: .cloud("Google AI Studio"))
        #expect(ok)
        let moved7 = f.next()
        #expect(moved7)
        #expect(f.step == .done && !f.showsTryCloud)
        let moved8 = f.next()
        #expect(moved8 && f.finished)
    }

    @Test func connectEntryWithoutACloudLanguageFallsBackToLanguages() {
        let f = SetupFlow(entry: .connect, languages: [.en])
        #expect(f.step == .languages)
    }

    @Test func fromTheAppTheEngineChangesOnlyForAKeyAddedHere() {
        // Opened from Home with a key on file but the free engine in use: finishing must not switch engines
        // (Home offers "Use Cloud" for that), and dropping a language must not switch to the free engine either.
        var keyed = SetupFlow(entry: .languages, languages: [.en], provider: .google, cloudReady: true)
        keyed.toggle(.uz); keyed.next()
        #expect(keyed.engine(current: .apple, currentHasVerifiedKey: false, setUpBefore: true, freeAvailable: true) == nil)
        var dropped = SetupFlow(entry: .languages, languages: [.en, .uz])
        dropped.toggle(.uz); dropped.next()
        #expect(dropped.engine(current: .google, currentHasVerifiedKey: false, setUpBefore: true, freeAvailable: true) == nil)
        var added = SetupFlow(entry: .connect, languages: [.en, .uz])
        added.setProvider(.openRouter); added.keyConnected(); added.next()
        #expect(added.engine(current: .apple, currentHasVerifiedKey: false, setUpBefore: true, freeAvailable: true) == .openRouter)
    }

    @Test func theOldInitsStayFirstRunFlows() {
        #expect(!SetupFlow().fromApp && !SetupFlow(welcome: true).fromApp)
        #expect(SetupFlow().showsBack && SetupFlow(welcome: true).step == .welcome)
        var f = SetupFlow()
        #expect(!f.finishesOnNext)
        f.next()
        #expect(f.step == .permissions && !f.finished)
    }
}

// MARK: - HomeState: prototype home()/langRow() for all 27 states

@Suite struct HomeStateTests {
    /// Prototype "API key" × engine: no key (engine on this Mac), key + Cloud, key but "On this Mac".
    enum KeyEngine: CaseIterable { case noKey, keyCloud, keyMac }

    private func state(_ mic: PermissionState.Mic, _ langs: [SpokenLanguage], _ k: KeyEngine, ax: Bool = true) -> HomeState {
        let provider: ProviderKind = k == .keyCloud ? .google : .apple
        let keys: Set<KeyProvider> = k == .noKey ? [] : [.google]
        return HomeState(mic: mic, ax: ax, spoken: langs, provider: provider,
                         hasKey: { keys.contains($0) }, verified: { keys.contains($0) }, keychain: .ready)
    }

    private struct Expected {
        let title: HomeState.Title
        let hero: HomeState.Hero
        let action: HomeState.Action?
        let rows: [HomeState.LangStatus]
    }

    /// A straight port of the prototype's `home()` title, the hero switch, `langFix()` and `langRow()`.
    private func prototype(_ mic: PermissionState.Mic, _ langs: [SpokenLanguage], _ k: KeyEngine) -> Expected {
        let key = k != .noKey, cloudOn = k == .keyCloud
        let cloud = langs.filter(\.isCloud)
        let combo: CloudCombo? = cloud.count == 2 ? .uzru : cloud.first.map { $0 == .uz ? .uz : .ru }
        let mc = cloudOn ? nil : combo
        let title: HomeState.Title = mic != .granted ? .micOff : mc.map { .oneMore($0) } ?? .ready
        let action: HomeState.Action? = mc.map { key ? .useCloud : .connect($0) }
        let rows: [HomeState.LangStatus] = langs.map { l in
            if l == .en { return cloudOn ? .cloud("Google AI Studio") : .onMac }
            if cloudOn { return .cloud("Google AI Studio") }
            return key ? .off : .needsKey
        }
        return Expected(title: title, hero: mic == .granted ? .fnKey : .permissions, action: action, rows: rows)
    }

    @Test(arguments: [PermissionState.Mic.granted, .notDetermined, .denied])
    func all27States(mic: PermissionState.Mic) {
        let sets: [[SpokenLanguage]] = [[.en], [.en, .uz], [.en, .uz, .ru]]
        var n = 0
        for langs in sets {
            for k in KeyEngine.allCases {
                let s = state(mic, langs, k), e = prototype(mic, langs, k)
                #expect(s.title == e.title, "title \(mic) \(langs) \(k)")
                #expect(s.hero == e.hero, "hero \(mic) \(langs) \(k)")
                #expect(s.action == e.action, "action \(mic) \(langs) \(k)")
                #expect(s.rows.map(\.language) == langs, "row order \(mic) \(langs) \(k)")
                #expect(s.rows.map(\.status) == e.rows, "rows \(mic) \(langs) \(k)")
                #expect(!s.keychainNotice)
                n += 1
            }
        }
        #expect(n == 9)
    }

    @Test func spotChecks() {
        let a = state(.granted, [.en, .uz, .ru], .noKey)
        #expect(a.title == .oneMore(.uzru) && a.action == .connect(.uzru))
        #expect(a.rows.map(\.status) == [.onMac, .needsKey, .needsKey])
        let b = state(.granted, [.en, .ru], .keyMac)
        #expect(b.title == .oneMore(.ru) && b.action == .useCloud && b.rows.last?.status == .off)
        let c = state(.denied, [.en], .noKey)
        #expect(c.title == .micOff && c.hero == .permissions && c.action == nil && c.micMissing && !c.axMissing)
    }

    @Test func existingUsersWithNoChoiceAreEnglishOnly() {
        let s = HomeState(mic: .granted, spoken: nil, provider: .google, hasKey: { _ in true }, verified: { _ in true }, keychain: .ready)
        #expect(s.title == .ready && s.rows.map(\.language) == [.en])
    }

    @Test func customEndpointCountsAsConnected() {
        let s = HomeState(mic: .granted, spoken: [.en, .uz], provider: .custom, hasKey: { _ in false }, verified: { _ in false }, keychain: .ready)
        #expect(s.title == .ready && s.action == nil)
        #expect(s.rows.map(\.status) == [.cloud(nil), .cloud(nil)])
    }

    @Test func keychainPendingMeansNothingIsMissingYet() {
        let s = HomeState(mic: .granted, spoken: [.en, .uz], provider: .google, hasKey: { _ in false }, verified: { _ in false }, keychain: .waiting)
        #expect(s.title == .ready && s.action == nil)
        #expect(s.keychainNotice)
        let denied = HomeState(mic: .granted, spoken: [.en], provider: .openRouter, hasKey: { _ in false }, verified: { _ in false }, keychain: .denied)
        #expect(denied.keychainNotice && denied.title == .ready)
    }

    @Test func noKeychainNoticeWithoutACloudKeyInUse() {
        // GAPS 7: no cloud language and no cloud provider → never a Keychain or key notice.
        for access in [Secrets.KeychainAccess.waiting, .denied] {
            let s = HomeState(mic: .granted, spoken: [.en], provider: .apple, hasKey: { _ in false }, verified: { _ in false }, keychain: access)
            #expect(!s.keychainNotice && s.title == .ready && s.action == nil)
            #expect(s.rows.map(\.status) == [.onMac])
        }
    }

    @Test func aHostedEngineWithNoKeyIsNotReady() {
        // Real behaviour (the old Home banner): English goes through the chosen service, so without its key nothing works.
        let s = HomeState(mic: .granted, spoken: [.en], provider: .google, hasKey: { _ in false }, verified: { _ in false }, keychain: .ready)
        #expect(s.title == .needsKey && s.action == .addKey && s.rows.map(\.status) == [.needsKey])
        let u = HomeState(mic: .granted, spoken: [.en, .uz], provider: .openRouter, hasKey: { _ in false }, verified: { _ in false }, keychain: .ready)
        #expect(u.title == .needsKey && u.action == .connect(.uz))
        // A saved but not yet verified key still dictates English: not "needs a key".
        let saved = HomeState(mic: .granted, spoken: [.en], provider: .google, hasKey: { _ in true }, verified: { _ in false }, keychain: .ready)
        #expect(saved.title == .ready && saved.rows.map(\.status) == [.cloud("Google AI Studio")])
    }

    @Test func accessibilityOffShowsThePermissionsGroup() {
        let s = state(.granted, [.en], .noKey, ax: false)
        #expect(s.title == .axOff && s.hero == .permissions && s.axMissing && !s.micMissing)
        let both = state(.notDetermined, [.en], .noKey, ax: false)
        #expect(both.title == .micOff && both.micMissing && both.axMissing)
    }

    @Test func primaryActionOnlyWhileTheMicIsOn() {
        #expect(state(.granted, [.en, .uz], .noKey).actionIsPrimary)
        #expect(!state(.denied, [.en, .uz], .noKey).actionIsPrimary)
    }
}

// MARK: - MenuHeader

@Suite struct MenuHeaderTests {
    private func home(_ mic: PermissionState.Mic = .granted, _ langs: [SpokenLanguage] = [.en], keyMac: Bool = false) -> HomeState {
        HomeState(mic: mic, spoken: langs, provider: .apple, hasKey: { _ in keyMac }, verified: { _ in keyMac }, keychain: .ready)
    }

    @Test func micOff() {
        let h = MenuHeader(home: home(.denied, [.en, .uz]), secureInput: false)
        #expect(h.tone == .warn && h.item == .allowMic && h.badge)
        let t = h.text(.en, key: "fn")
        #expect(t.title == "Soyla can’t hear you yet" && t.detail == "Allow the microphone first." && t.item == "Allow the Microphone…")
    }

    @Test func missingCloud() {
        let h = MenuHeader(home: home(.granted, [.en, .uz]), secureInput: false)
        #expect(h.tone == .warn && h.item == .connect(.uz))
        #expect(!h.badge)                                  // a skipped key is calm: no badge
        let t = h.text(.en, key: "fn")
        #expect(t.title == "One more step for Uzbek" && t.detail == "English works now." && t.item == "Connect Uzbek…")
        let ru = MenuHeader(home: home(.granted, [.en, .uz, .ru]), secureInput: false).text(.ru, key: "fn")
        #expect(ru.title == "Ещё один шаг для узбекского и русского" && ru.item == "Подключить узбекский и русский…")
    }

    @Test func keyOnFileButOnThisMacOffersUseCloud() {
        let h = MenuHeader(home: home(.granted, [.en, .ru], keyMac: true), secureInput: false)
        #expect(h.item == .useCloud && h.text(.en, key: "fn").item == "Use Cloud")
    }

    @Test func ready() {
        let h = MenuHeader(home: home(), secureInput: false)
        #expect(h.tone == .ok && h.item == nil && !h.badge && h.secureInput == false)
        let t = h.text(.en, key: "fn")
        #expect(t.title == "Soyla is ready" && t.detail == "Hold fn in any app" && t.item == nil && t.secure == nil)
        #expect(MenuHeader(home: home(), secureInput: false).text(.uz, key: "fn").title == "Soyla tayyor")
    }

    @Test func secureInputKeepsItsLineBelow() {
        let h = MenuHeader(home: home(), secureInput: true)
        #expect(h.tone == .ok && h.secureInput && h.badge)
        #expect(h.text(.en, key: "fn").secure == "Secure Input is on: paste disabled")
        let warn = MenuHeader(home: home(.granted, [.en, .uz]), secureInput: true)
        #expect(warn.item == .connect(.uz) && warn.secureInput)
    }
}

// MARK: - AppStrings

@Suite struct AppStringsTests {
    private static let all: [(UILanguage, AppStrings)] = UILanguage.allCases.map { ($0, AppStrings.for($0)) }

    private func strings(_ t: AppStrings) -> [String] {
        var out: [String] = []
        for child in Mirror(reflecting: t).children {
            switch child.value {
            case let s as String: out.append(s)
            case let a as [String]: out += a
            case let d as [SpokenLanguage: String]: out += d.values
            case let d as [SettingsPage: String]: out += d.values
            default: break
            }
        }
        for c in [CloudCombo.uz, .ru, .uzru] { out += [t.more(c), t.mConnect(c)] }
        out += [t.cloudVia("OpenRouter"), t.via("OpenRouter"), t.today(3, "0.5"), t.version("0.3.0")]
        return out
    }

    @Test func noEmptyFieldInAnyLanguage() {
        for (l, t) in Self.all {
            let s = strings(t)
            #expect(s.count > 60, "\(l)")
            #expect(s.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, "\(l)")
            #expect(t.n.count == 3, "\(l)")
            #expect(Set(t.page.keys) == Set(SettingsPage.allCases), "\(l)")
        }
    }

    @Test func uzbekKeepsTechTermsInEnglish() {
        for s in strings(.uz) {
            #expect(!s.lowercased().contains("kalit"), "\(s)")
            #expect(!s.contains("Bulut"), "\(s)")
        }
    }

    @Test func russianBrandIsFeminine() {
        #expect(AppStrings.ru.ready == "Soyla готова")
        #expect(!strings(.ru).contains { $0.contains("готов ") || $0.hasSuffix("готов") })
    }

    @Test func keyPlaceholdersAreFilled() {
        for (_, t) in Self.all {
            for s in [t.holdSub, t.micOffSub, t.axOffSub, t.needsKeySub, t.mHold] {
                let filled = AppStrings.fill(s, key: "fn")
                #expect(!filled.contains("{") && !filled.contains("}"), "\(filled)")
            }
            #expect(t.holdSub.contains("{key}") && t.micOffSub.contains("{key}"))
        }
    }

    @Test func englishMatchesThePrototype() {
        let t = AppStrings.en
        #expect(t.navHome == "Home" && t.navHistory == "History" && t.page[.apiKeys] == "Languages" && t.page[.privacy] == "Privacy & data")
        #expect(t.version("0.3.0") == "Version 0.3.0" && t.setupA == "Setup Assistant…")
        #expect(AppStrings.fill(t.holdSub, key: "fn") == "Hold fn in any app.")
        #expect(t.more(.uzru) == "One more step for Uzbek and Russian" && t.moreSub == "English works now.")
        #expect(t.micOff == "Soyla can’t hear you yet" && AppStrings.fill(t.micOffSub, key: "fn") == "Allow the microphone, then hold fn.")
        #expect(t.langs == "Your languages" && t.change == "Change…" && t.cloudVia("OpenRouter") == "Cloud · OpenRouter")
        #expect(t.readyW == "Ready" && t.needsKey == "Needs an API key" && t.connect == "Connect…" && t.offW == "Off" && t.useCloud == "Use Cloud")
        #expect(t.today(14, "0.5") == "Today: 14 · usually 0.5 s" && t.allHist == "All in History")
        #expect(t.mConnect(.ru) == "Connect Russian…" && t.mQuit == "Quit Soyla")
    }

    @Test func uzbekAndRussianMatchThePrototype() {
        #expect(AppStrings.uz.more(.uz) == "O‘zbek tili uchun yana bir qadam")
        #expect(AppStrings.uz.mConnect(.uzru) == "O‘zbek va rus tillari uchun API key ulash…")
        #expect(AppStrings.uz.today(3, "0,5") == "Bugun: 3 ta · odatda 0,5 s")
        #expect(AppStrings.ru.more(.ru) == "Ещё один шаг для русского" && AppStrings.ru.mConnect(.uz) == "Подключить узбекский…")
        #expect(AppStrings.ru.page[.privacy] == "Конфиденциальность" && AppStrings.ru.needsKey == "Нужен API-ключ")
    }

    @Test func secondsUseTheDecimalComma() {
        #expect(AppStrings.seconds(512, language: .en) == "0.5")
        #expect(AppStrings.seconds(512, language: .uz) == "0,5" && AppStrings.seconds(1480, language: .ru) == "1,5")
    }
}
