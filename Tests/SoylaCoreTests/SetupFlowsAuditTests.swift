import Testing
import Foundation
@testable import SoylaCore

// Flows audit 2026-10-19: F-14, F-17, F-20, F-21 in setup.
@Suite struct SetupFlowsAuditTests {
    @Test func aConnectedKeyCanBeReplaced() {
        var f = SetupFlow(entry: .connect, languages: [.en, .uz])
        f.keyConnected()
        #expect(f.connected && f.canContinue)
        f.replaceKey()
        #expect(f.keyState == .idle && !f.canContinue)
        f.keyChecking(); f.keyConnected()
        #expect(f.connected)
    }

    @Test func replaceOnlyAppliesToAConnectedKeyOnConnect() {
        var f = SetupFlow(entry: .connect, languages: [.en, .uz])
        f.keyFailed(.rejected)
        f.replaceKey()
        #expect(f.keyState == .failed(.rejected))
    }

    @Test func oneRejectionMessageWithANextStep() {
        for l in UILanguage.allCases {
            #expect(SetupStrings.for(l).keyFail[.rejected] == AppStrings.for(l).cxFail, "\(l)")
        }
    }

    @Test func thePermissionsStageDoesNotRepeatTheSubtitle() {
        for l in UILanguage.allCases {
            let t = SetupStrings.for(l)
            #expect(!t.gDone.contains("Soyla"), "\(l): \(t.gDone)")
        }
        #expect(SetupStrings.en.gDone == "Hold to talk.")
    }

    @Test func theFnStateIsInTheMacsWords() {
        #expect(SetupStrings.shown(.ru, mac: .ru).pFnDone == "Выбрано «Ничего не делать»")
        #expect(SetupStrings.shown(.ru, mac: .en).pFnDone == "Выбрано «Do Nothing»")
        #expect(SetupStrings.shown(.uz, mac: .ru).pFnDone == "«Ничего не делать» tanlandi")
    }
}

// Flows audit 2026-10-19: F-09, F-23, F-24, F-25, F-27 in the app.
@Suite struct AppFlowsAuditTests {
    @Test func onThisMacIsOfferedOnlyToEnglishSpeakers() {
        #expect(!EngineSwitchPrompt.toFree.fits(spoken: [.uz, .ru]))
        #expect(EngineSwitchPrompt.toFree.fits(spoken: [.en, .ru]) && EngineSwitchPrompt.toFree.fits(spoken: nil))
        #expect(EngineSwitchPrompt.toCloud(.google).fits(spoken: [.uz]))
    }

    @Test func removingAKeySaysWhatStops() {
        #expect(AppStrings.en.keyRemoveStops(.uzru) == "Uzbek and Russian will stop working.")
        #expect(AppStrings.ru.keyRemoveStops(.uzru) == "Узбекский и русский перестанут работать.")
        #expect(AppStrings.ru.keyRemoveStops(.uz) == "Узбекский перестанет работать.")
        #expect(AppStrings.uz.keyRemoveStops(.ru) == "Rus tili ishlamay qoladi.")
    }

    @Test func wordsForWhatTheUserSees() {
        #expect(AppStrings.en.eWhere == "Where it runs" && AppStrings.uz.eWhere == "Qayerda ishlaydi")
        #expect(AppStrings.en.plSoundsC == "Start and stop")
        #expect(AppStrings.en.modelCFull != AppStrings.en.modelC)
        #expect(AppStrings.ru.plSub != AppStrings.ru.page[.pill] && !AppStrings.ru.plSub.contains("Индикатор"))
    }
}

@Suite struct DoneSubtitleTests {
    @Test func doneHasALineForSomeoneWithoutEnglish() {
        for l in UILanguage.allCases {
            let t = SetupStrings.for(l)
            #expect(t.dnMoreNoEn.contains("{key}") && t.dnMoreNoEn != t.dnMoreSub, "\(l)")
        }
    }
}
