import Testing
import Foundation
@testable import SoylaCore

/// All texts are made up (never real dictations).
@Suite struct LanguageScoreTests {
    @Test func eachSessionScoresItsOwnLanguageHighest() {
        let uz = "bugun men yangi versiyani test qilyapman va natijalarni yozib qo'yaman"
        let ru = "сегодня я тестирую новую версию и потом напишу результаты"
        let en = "today I am testing the new version and I will write the results later"
        #expect(LanguageScore.score(uz, code: "uz-UZ") > LanguageScore.score(uz, code: "en-US"))
        #expect(LanguageScore.score(ru, code: "ru-RU") > LanguageScore.score(ru, code: "uz-UZ"))
        #expect(LanguageScore.score(en, code: "en-US") > LanguageScore.score(en, code: "uz-UZ"))
        #expect(LanguageScore.score(uz, code: "ru-RU") == 0)            // no Cyrillic, no Russian
    }

    /// 2026-10-17: Auto locked onto English for Uzbek speech. An English session mishearing Uzbek writes Latin
    /// words that are not English; they must not outscore the Uzbek session.
    @Test func misheardUzbekInTheEnglishSessionScoresLow() {
        let enSession = "boo goon men yung ee version yanni test kill yup man"       // made up
        let uzSession = "bugun men yangi versiyani test qilyapman"
        #expect(LanguageScore.score(enSession, code: "en-US") < LanguageScore.score(uzSession, code: "uz-UZ"))
        #expect(LanguageScore.leader(["en-US": LanguageScore.score(enSession, code: "en-US"),
                                      "uz-UZ": LanguageScore.score(uzSession, code: "uz-UZ")]) == "uz-UZ")
    }

    @Test func uzbekCyrillicIsNotRussian() {
        #expect(LanguageScore.score("бугун ҳам йўқ қилиш", code: "ru-RU") < 1)
    }

    @Test func lockNeedsAClearLeader() {
        #expect(LanguageScore.leader(["uz-UZ": 6, "ru-RU": 1, "en-US": 2]) == "uz-UZ")
        #expect(LanguageScore.leader(["uz-UZ": 6, "ru-RU": 4]) == nil)        // not 2× the runner-up
        #expect(LanguageScore.leader(["uz-UZ": 2, "ru-RU": 0]) == nil)        // too little heard yet
        #expect(LanguageScore.leader(["ru-RU": 5]) == "ru-RU")
    }
}

@Suite struct LiveFastDecisionTests {
    let uzLive = LiveOutcome(text: "bugun men yangi versiyani test qilyapman va natijalarni yozib qo'yaman keyin",
                             language: "uz-UZ", locked: true, finalArrived: true)

    @Test func strictModePastesLiveWhenItIsSane() {
        let d = LiveFastDecision.decide(strict: true, live: uzLive, pieces: nil, voicedSec: 5)
        #expect(d.source == .live)
    }

    @Test func noFinalOrTooFewWordsMeansGemini() {
        var late = uzLive; late.finalArrived = false
        #expect(LiveFastDecision.decide(strict: true, live: late, pieces: nil, voicedSec: 5).source == .gemini)
        #expect(LiveFastDecision.decide(strict: true, live: nil, pieces: nil, voicedSec: 5).source == .gemini)
        // 11 words for 30 voiced seconds: Live dropped speech.
        #expect(LiveFastDecision.decide(strict: true, live: uzLive, pieces: nil, voicedSec: 30).source == .gemini)
    }

    @Test func foreignScriptMeansGemini() {
        var bad = uzLive; bad.text += " مرحبا مرحبا مرحبا"
        #expect(LiveFastDecision.decide(strict: true, live: bad, pieces: nil, voicedSec: 5).source == .gemini)
    }

    @Test func autoTrustsLiveWhenFinishedPiecesAgree() {
        let pieces = "bugun men yangi versiyani test qilyapman va"
        let d = LiveFastDecision.decide(strict: false, live: uzLive, pieces: pieces, voicedSec: 5)
        #expect(d.source == .live)
    }

    @Test func autoUsesGeminiWhenPiecesShowSwitching() {
        // Pieces heard Russian too: the Uzbek-locked Live has dropped it.
        let pieces = "bugun men yangi versiyani потом напишу результаты test qilyapman"
        #expect(LiveFastDecision.decide(strict: false, live: uzLive, pieces: pieces, voicedSec: 5).source == .gemini)
    }

    @Test func autoUsesGeminiWhenPiecesDisagree() {
        let pieces = "kecha biz boshqa narsani muhokama qildik umuman"
        #expect(LiveFastDecision.decide(strict: false, live: uzLive, pieces: pieces, voicedSec: 5).source == .gemini)
    }

    @Test func autoRejectsAWrongLockEvenWithoutPieces() {
        let wrong = LiveOutcome(text: "boo goon men yung ee version yanni test kill yup man", language: "en-US", locked: true, finalArrived: true)
        #expect(LiveFastDecision.decide(strict: false, live: wrong, pieces: nil, voicedSec: 4).source == .gemini)
        let english = LiveOutcome(text: "please deploy the new build and send me the link when it is ready", language: "en-US",
                                  locked: true, finalArrived: true)
        #expect(LiveFastDecision.decide(strict: false, live: english, pieces: nil, voicedSec: 4).source == .live)
    }

    @Test func autoWithoutPiecesNeedsALock() {
        var unlocked = uzLive; unlocked.locked = false
        #expect(LiveFastDecision.decide(strict: false, live: uzLive, pieces: nil, voicedSec: 5).source == .live)
        #expect(LiveFastDecision.decide(strict: false, live: unlocked, pieces: nil, voicedSec: 5).source == .gemini)
    }

    @Test func russianLockNeedsCyrillicPieces() {
        let ruLive = LiveOutcome(text: "сегодня я тестирую новую версию и потом напишу результаты всем", language: "ru-RU",
                                 locked: true, finalArrived: true)
        #expect(LiveFastDecision.decide(strict: false, live: ruLive, pieces: "сегодня я тестирую новую версию", voicedSec: 5).source == .live)
        #expect(LiveFastDecision.decide(strict: false, live: ruLive, pieces: "bugun men test qilyapman", voicedSec: 5).source == .gemini)
    }

    @Test func strictLanguageCodes() {
        #expect(LiveFastDecision.sessions(for: "en") == ["en-US"])
        #expect(LiveFastDecision.sessions(for: "uz") == ["uz-UZ"])
        #expect(LiveFastDecision.sessions(for: "ru") == ["ru-RU"])
        #expect(LiveFastDecision.sessions(for: nil) == ["uz-UZ", "ru-RU", "en-US"])
        #expect(LiveFastDecision.sessions(for: "ko") == nil)                  // not a uz/ru/en session: no fast path
    }
}
