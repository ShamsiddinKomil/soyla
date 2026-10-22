import Testing
import Foundation
@testable import SoylaCore

// APP-1 v3 (owner 2026-10-18): connect the API key inline, under its language, on Home and the Languages page
// (design prototype v3: langRow, cxPanel, cxConnect). No setup window for Connect from the app.

// MARK: - The row's own fix

@Suite struct RowActionTests {
    private func home(_ langs: [SpokenLanguage], provider: ProviderKind = .apple, keys: Set<KeyProvider> = [],
                      mic: PermissionState.Mic = .granted) -> HomeState {
        HomeState(mic: mic, spoken: langs, provider: provider, hasKey: { keys.contains($0) }, verified: { keys.contains($0) },
                  keychain: .ready)
    }

    @Test func firstMissingRowIsPrimaryTheRestBordered() {
        let h = home([.en, .uz, .ru])
        #expect(h.rowAction(.en, primaryAllowed: true, open: nil) == nil)
        #expect(h.rowAction(.uz, primaryAllowed: true, open: nil) == .connect(primary: true))
        #expect(h.rowAction(.ru, primaryAllowed: true, open: nil) == .connect(primary: false))
    }

    @Test func homeFillsItOnlyWhileTheMicIsAllowed() {
        let h = home([.en, .uz], mic: .denied)
        #expect(h.rowAction(.uz, primaryAllowed: h.actionIsPrimary, open: nil) == .connect(primary: false))
    }

    @Test func anOpenPanelHidesItsButtonAndUnfillsTheOthers() {
        let h = home([.en, .uz, .ru])
        #expect(h.rowAction(.uz, primaryAllowed: true, open: .language(.uz)) == nil)
        #expect(h.rowAction(.ru, primaryAllowed: true, open: .language(.uz)) == .connect(primary: false))
    }

    @Test func keyOnFileButOnThisMacIsUseCloud() {
        let h = home([.en, .ru], keys: [.google])
        #expect(h.rowAction(.ru, primaryAllowed: true, open: nil) == .useCloud)
        #expect(h.rowAction(.en, primaryAllowed: true, open: nil) == nil)
    }

    @Test func readyRowsHaveNoAction() {
        let h = home([.en, .uz], provider: .google, keys: [.google])
        #expect(h.rowAction(.uz, primaryAllowed: true, open: nil) == nil)
        #expect(h.rowAction(.en, primaryAllowed: true, open: nil) == nil)
    }

    @Test func pendingKeychainOffersNothing() {
        let h = HomeState(mic: .granted, spoken: [.en, .uz], provider: .apple, hasKey: { _ in false }, verified: { _ in false },
                          keychain: .waiting)
        #expect(h.rowAction(.uz, primaryAllowed: true, open: nil) == nil)
    }

    @Test func aHostedEngineWithNoKeyConnectsOnTheEnglishRow() {
        let h = home([.en], provider: .google)
        #expect(h.rowAction(.en, primaryAllowed: true, open: nil) == .connect(primary: true))
    }

    @Test func firstMissingLanguage() {
        #expect(home([.en, .uz, .ru]).firstMissing == .uz)
        #expect(home([.en, .ru]).firstMissing == .ru)
        #expect(home([.en]).firstMissing == nil)
        #expect(home([.en, .uz], provider: .google, keys: [.google]).firstMissing == nil)
    }
}

// MARK: - The panel (pure)

@Suite struct InlineConnectTests {
    @Test func onlyOnePanelIsOpen() {
        var c = InlineConnect()
        c.open(.language(.uz), provider: .google)
        c.edit("FAKE-draft")
        c.open(.language(.ru), provider: .google)
        #expect(c.target == .language(.ru) && c.draft.isEmpty && c.state == .idle)
        c.open(.key, provider: .openRouter)
        #expect(c.target == .key && c.provider == .openRouter)
        c.close()
        #expect(c.target == nil && c.draft.isEmpty)
    }

    @Test func connectNeedsALongEnoughKey() {
        var c = InlineConnect()
        c.open(.language(.uz), provider: .google)
        c.edit("AIzaFAKE")
        #expect(!c.canSubmit && c.submit() == nil)
        c.edit("  AIzaFAKE1234FAKE1234FAKE  ")
        #expect(c.canSubmit)
        let key = c.submit()
        #expect(key == "AIzaFAKE1234FAKE1234FAKE" && c.state == .checking && !c.canSubmit)
    }

    @Test func checkingLocksTheServiceAndTheField() {
        var c = InlineConnect()
        c.open(.language(.uz), provider: .google)
        c.edit("AIzaFAKE1234FAKE1234FAKE")
        _ = c.submit()
        c.setProvider(.openRouter)
        c.edit("changed")
        #expect(c.provider == .google && c.draft == "AIzaFAKE1234FAKE1234FAKE")
    }

    @Test func aWrongShapeFailsBeforeAnythingIsSaved() {
        var c = InlineConnect()
        c.open(.language(.uz), provider: .openRouter)
        c.edit("AIzaFAKE1234FAKE1234FAKE")
        #expect(c.submit() == nil && c.state == .failed(.wrongProvider))
    }

    @Test func failureStaysOpenAndClearsOnEdit() {
        var c = InlineConnect()
        c.open(.language(.uz), provider: .google)
        c.edit("AIzaFAKE1234FAKE1234FAKE"); _ = c.submit()
        c.checked(.failed(.rejected))
        #expect(c.target == .language(.uz) && c.state == .failed(.rejected))
        c.edit(c.draft)                                   // the field echoing its own text keeps the message
        #expect(c.state == .failed(.rejected))
        c.edit("AIzaFAKE12345")
        #expect(c.state == .idle)
    }

    @Test func successCloses() {
        var c = InlineConnect()
        c.open(.language(.uz), provider: .google)
        c.edit("AIzaFAKE1234FAKE1234FAKE"); _ = c.submit()
        c.checked(.ok)
        #expect(c.target == nil && c.state == .idle && c.draft.isEmpty)
    }

    @Test func messages() {
        let t = AppStrings.en, s = SetupStrings.en
        #expect(InlineConnect.message(.rejected, t, s) == "That key didn’t work. Check it and try again.")
        #expect(InlineConnect.message(.unreachable, t, s) == s.keyFail[.unreachable])
        #expect(InlineConnect.message(.wrongProvider, t, s) == s.keyFail[.wrongProvider])
    }

    @Test func footnoteNamesTheServiceAndBothLanguages() {
        let t = AppStrings.en
        #expect(InlineConnect.footnote(t, provider: .google, combo: .uz, target: .language(.uz)) == "Audio goes straight to Google AI Studio.")
        #expect(InlineConnect.footnote(t, provider: .openRouter, combo: .uzru, target: .language(.uz))
                == "Audio goes straight to OpenRouter. One key covers Uzbek and Russian.")
        #expect(InlineConnect.footnote(t, provider: .google, combo: .uzru, target: .key) == "Audio goes straight to Google AI Studio.")
        #expect(InlineConnect.footnote(.uz, provider: .google, combo: .uzru, target: .language(.ru))
                == "Ovoz to‘g‘ridan-to‘g‘ri Google AI Studio’ga boradi. Bitta API key o‘zbek va rus tili uchun ishlaydi.")
        #expect(InlineConnect.footnote(.ru, provider: .openRouter, combo: .uzru, target: .language(.uz))
                == "Звук идёт напрямую в OpenRouter. Один ключ работает для узбекского и русского.")
    }

    @Test func engineFollowsSetupsConnect() {
        // A verified key for a chosen cloud language → that provider; otherwise the engine stays.
        #expect(InlineConnect.engine(after: .openRouter, spoken: [.en, .uz], current: .apple) == .openRouter)
        #expect(InlineConnect.engine(after: .google, spoken: [.en, .uz], current: .google) == nil)
        #expect(InlineConnect.engine(after: .google, spoken: [.en], current: .apple) == nil)
        #expect(InlineConnect.engine(after: .google, spoken: nil, current: .openRouter) == nil)
    }

    @Test func defaultServiceIsTheOneInUseElseGoogle() {
        #expect(InlineConnect.defaultProvider(for: .openRouter) == .openRouter)
        #expect(InlineConnect.defaultProvider(for: .apple) == .google)
        #expect(InlineConnect.defaultProvider(for: .custom) == .google)
    }
}

// MARK: - Routing and the Languages page

@Suite struct InlineRoutingTests {
    @Test func connectFromTheAppOpensTheLanguagesPagePanel() {
        #expect(MenuHeader.Item.connect(.uz).route.inApp == .connectInline)
        #expect(PillFix.connectKey.route(cloudLanguage: true).inApp == .connectInline)
        #expect(PillFix.connectKey.route(cloudLanguage: false).inApp == .page(.languages))
        #expect(MenuRoute.setup(.permissions).inApp == .setup(.permissions))
        #expect(MenuRoute.useCloud.inApp == .useCloud)
    }

    @Test func cloudSectionOnlyOnceAKeyExists() {
        func page(_ langs: [SpokenLanguage], _ provider: ProviderKind, _ keys: Set<KeyProvider>) -> LanguagesPageState {
            let h = HomeState(mic: .granted, spoken: langs, provider: provider, hasKey: { keys.contains($0) },
                              verified: { keys.contains($0) }, keychain: .ready)
            return LanguagesPageState(home: h, spoken: langs, provider: provider, hasKey: { keys.contains($0) }, developerMode: false)
        }
        #expect(!page([.en, .uz], .apple, []).showsCloudSection)
        #expect(page([.en, .uz], .apple, [.google]).showsCloudSection)
        #expect(page([.en], .google, [.google]).showsCloudSection)
        #expect(page([.en], .custom, []).showsCloudSection)          // a custom endpoint needs no key
    }
}

// MARK: - Strings

@Suite struct InlineConnectStringsTests {
    @Test func everyLanguageHasThePanelWords() {
        for l in UILanguage.allCases {
            let t = AppStrings.for(l)
            for s in [t.cxChecking, t.cxFail, t.cxCancel, t.cxBoth, t.cxPriv("OpenRouter")] {
                #expect(!s.trimmingCharacters(in: .whitespaces).isEmpty, "\(l)")
                #expect(!s.lowercased().contains("kalit") && !s.contains("Bulut"), "\(l): \(s)")
            }
        }
        #expect(AppStrings.en.cxChecking == "Checking…" && AppStrings.ru.cxChecking == "Проверяю…" && AppStrings.uz.cxCancel == "Bekor qilish")
    }
}
