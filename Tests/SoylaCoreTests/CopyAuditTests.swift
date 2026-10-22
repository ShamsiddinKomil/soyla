import Testing
import Foundation
@testable import SoylaCore

// Audit 2026-10-19 copy findings: V-08 (macOS's words by the Mac's language), V-04, V-12, V-13, V-14, V-24, V-30,
// V-31, V-32.

@Suite struct MacTermsTests {
    @Test func theMacsLanguageDecides() {
        #expect(MacTerms.language(preferred: ["ru-RU", "en-US"]) == .ru)
        #expect(MacTerms.language(preferred: ["ru"]) == .ru)
        #expect(MacTerms.language(preferred: ["en-US", "ru-RU"]) == .en)
        #expect(MacTerms.language(preferred: ["uz-Latn-UZ"]) == .en)       // macOS has no Uzbek: it shows English
        #expect(MacTerms.language(preferred: []) == .en)
        #expect(MacTerms.language(preferred: ["rus"]) == .en)               // not a prefix match on "ru…"
    }

    @Test func russianMacNamesItsOwnControls() {
        #expect(MacTerms.name("Allow", .ru) == "Разрешить" && MacTerms.name("Don’t Allow", .ru) == "Не разрешать")
        #expect(MacTerms.name("Do Nothing", .ru) == "Ничего не делать")
        #expect(MacTerms.name("Allow", .en) == "Allow" && MacTerms.name("Do Nothing", .en) == "Do Nothing")
    }

    @Test func uzbekKeepsItsSentenceAroundTheMacsWord() {
        let uz = SetupStrings.shown(.uz, mac: .ru)
        #expect(uz.gMic == "macOS so‘raydi.\n**Разрешить**’ni bosing.")
        #expect(uz.aw[.fnSetting] == "**Ничего не делать**’ni tanlang.")
        #expect(uz.hFnT == "«Ничего не делать»’ni tanlang")
        #expect(uz.pSet == "«Системные настройки»’ni ochish…")
    }

    @Test func russianUIOnARussianMac() {
        let ru = SetupStrings.shown(.ru, mac: .ru)
        #expect(ru.gMic == "macOS спросит.\nНажмите **Разрешить**.")
        #expect(ru.aw[.micAlert] == "Нажмите **Разрешить**." && ru.gFn.contains("**Ничего не делать**"))
        #expect(ru.pSet == "Открыть настройки…")                              // already Russian: unchanged
    }

    @Test func anEnglishMacKeepsTodaysWords() {
        for l in UILanguage.allCases {
            let base = SetupStrings.for(l), shown = SetupStrings.shown(l, mac: .en)
            #expect(shown.gMic == base.gMic && shown.gFn == base.gFn && shown.aw == base.aw && shown.pSet == base.pSet && shown.hFnT == base.hFnT)
        }
        #expect(SetupStrings.shown(.en, mac: .en).gMic == "macOS will ask.\nClick **Allow**.")
    }

    @Test func onlyTheNamedLinesChange() {
        let ru = SetupStrings.shown(.en, mac: .ru)
        #expect(ru.pMicB == "Allow…")                    // Soyla's own button, not macOS's
        #expect(ru.gMic == "macOS will ask.\nClick **Разрешить**.")
    }
}

@Suite struct CopyAuditTests {
    @Test func uzbekPicksWhatApplies() {
        #expect(SetupStrings.uz.lSub == "Keraklilarini belgilang.")
        #expect(SetupStrings.en.lSub == "Pick all that apply." && SetupStrings.ru.lSub == "Отметьте все подходящие.")
    }

    @Test func uzbekSuffixesTakeTheApostrophe() {
        let t = SetupStrings.uz
        for s in [t.gMic, t.gFn, t.hFnT] + Array(t.aw.values) {
            #expect(!s.contains("** ni ") && !s.contains("» ni ") && !s.hasSuffix(" ni"), "\(s)")
        }
        #expect(t.cOpen("aistudio.google.com") == "aistudio.google.com saytini ochish")
        #expect(AppStrings.uz.pillOpen("Tillar") == "Tillar’ni ochish" && AppStrings.uz.plHidden("16:00") == "16:00gacha yashirin")
    }

    @Test func uzbekSaysIndikatorEnglishKeepsPill() {
        #expect(AppStrings.uz.page[.pill] == "Indikator" && AppStrings.en.page[.pill] == "Pill")
        #expect(!AppStrings.uz.plPosI.contains("pill") && !AppStrings.uz.d.pcLockedHint("fn").contains("pill"))
        #expect(AppStrings.uz.page[.hotkey] == "Tezkor tugma")
    }

    @Test func russianAllowsAccessToTheMicrophone() {
        let t = AppStrings.ru
        for s in [t.micOffSub, t.mMic, t.mMicFirst] { #expect(s.contains("доступ к микрофону"), "\(s)") }
        #expect(t.mAx == "Включить Универсальный доступ…")
        #expect(t.warmC == "Быстрый запуск" && t.d.dcWrite == "Писать как")
    }

    @Test func uzbekPolish() {
        #expect(SetupStrings.uz.cO == "Ishlatganingizga yarasha to‘lov" && AppStrings.uz.oC == "Ishlatganingizga yarasha to‘lov")
        #expect(SetupStrings.uz.cSub == "Bitta API key, bir marta qo‘shiladi.")
        #expect(SetupStrings.uz.cTip[1].contains("Aralash tilli gaplar uchun eng yaxshisi."))
        #expect(AppStrings.uz.d.pcPasting == "Qo‘yyapman…")
    }

    @Test func theFnRowSaysSetNotAllowed() {
        #expect(AppStrings.en.pFnSet == "Set" && AppStrings.uz.pFnSet == "Sozlangan" && AppStrings.ru.pFnSet == "Настроено")
    }

    @Test func englishUsesTheCurlyApostrophe() {
        let straight = try? NSRegularExpression(pattern: "\\p{L}'\\p{L}")
        for (name, s) in Mirror(reflecting: AppStrings.en.d).children.compactMap({ c in (c.value as? String).map { (c.label ?? "", $0) } }) {
            #expect(straight?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil, "\(name): \(s)")
        }
        #expect(PillCopy.curly("Didn't understand that") == "Didn’t understand that")
        #expect(PillCopy.curly("HTTP 'x'") == "HTTP 'x'")                     // only letter–apostrophe–letter
    }
}
