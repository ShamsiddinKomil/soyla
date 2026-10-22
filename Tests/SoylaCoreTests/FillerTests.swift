import Testing
@testable import SoylaCore

/// Made-up sentences, no real transcripts.
@Suite struct FillerTests {
    @Test func hesitationSoundsGoRealWordsStay() {
        #expect(Fillers.strip("A-a вроде бы хорошо. М-м а-а ответ, знаешь, а-а это") == "Вроде бы хорошо. Ответ, знаешь, это")
        #expect(Fillers.strip("Bu ммм yaxshi, eee, lekin") == "Bu yaxshi, lekin")
        #expect(Fillers.strip("Hmm, I think uh it works") == "I think it works")
    }

    @Test func keepsWordsThatLookClose() {
        let s = "А ты придёшь? Э, нет. Asta-asta, tez tez, o'g'il, ha-ha, Emma, um-bra, mama"
        #expect(Fillers.strip(s) == s)
        #expect(Fillers.strip("a") == "a")
        #expect(Fillers.strip("") == "")
    }

    @Test func tidiesPunctuationLeftBehind() {
        #expect(Fillers.strip("Yaxshi. А-а, keyin nima?") == "Yaxshi. Keyin nima?")
        #expect(Fillers.strip("one м-м , two") == "one, two")
    }
}
