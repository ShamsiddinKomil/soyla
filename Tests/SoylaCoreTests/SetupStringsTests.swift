import Testing
import Foundation
@testable import SoylaCore

// OB-2: the setup copy table (ported from the approved v5 prototype).
@Suite struct SetupStringsTests {
    private static let all: [(UILanguage, SetupStrings)] = UILanguage.allCases.map { ($0, SetupStrings.for($0)) }

    /// Every plain string and dictionary value in a table (closures are checked separately).
    private func strings(_ t: SetupStrings) -> [String] {
        var out: [String] = []
        for child in Mirror(reflecting: t).children {
            switch child.value {
            case let s as String: out.append(s)
            case let a as [String]: out += a
            case let d as [SetupStep: String]: out += d.values
            case let d as [SystemSurface: String]: out += d.values
            case let d as [PendingPermission: String]: out += d.values
            case let d as [SpokenLanguage: String]: out += d.values
            case let d as [SetupKeyFailure: String]: out += d.values
            default: break
            }
        }
        return out
    }

    @Test func everyLanguageIsComplete() {
        for (_, t) in Self.all {
            #expect(strings(t).count > 90)
            #expect(strings(t).allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            #expect(Set(t.rail.keys) == Set(SetupStep.allCases))
            #expect(t.aw.count == 5 && t.keyFail.count == 5 && t.pNext.count == 4 && t.n.count == 3 && t.tReadIn.count == 3)
            for c in [CloudCombo.uz, .ru, .uzru] {
                #expect(!t.lCloud(c).isEmpty && !t.cTitle(c).isEmpty && !t.dnMore(c).isEmpty)
            }
        }
    }

    @Test func englishMatchesThePrototype() {
        let t = SetupStrings.en
        #expect(t.lTitle == "Which languages do you speak?")
        #expect(t.cTitle(.uzru) == "Connect Uzbek and Russian")
        #expect(t.dnMore(.ru) == "One more step for Russian")
        #expect(t.dnTry(.ru) == "Try in Russian")
        #expect(t.stepOf(2, 4) == "Step 2 of 4")
        #expect(t.lCloud(.uz) == "Uzbek: one more step, about 2 minutes.")
    }

    @Test func uzbekKeepsTechTermsInEnglish() {
        let t = SetupStrings.uz
        let joined = strings(t).joined(separator: " ").lowercased()
        #expect(!joined.contains("kalit") && !joined.contains("bulut"))
        #expect(joined.contains("api key") && joined.contains("cloud"))
        #expect(t.cTitle(.uz) == "O‘zbek tili uchun API key ulang")
        #expect(t.dnTry(.ru) == "Rus tilida sinab ko‘ring")
        #expect(t.gMic.contains("**Allow**") && t.gFn.contains("**Do Nothing**"))
    }

    @Test func russianBrandIsFeminine() {
        let t = SetupStrings.ru
        #expect(t.dnTitle == "Soyla готова")
        #expect(t.dsHere.contains("живёт"))
        #expect(t.cTitle(.ru) == "Подключите русский")
        #expect(t.dnMore(.uzru) == "Ещё один шаг для узбекского и русского")
        #expect(!strings(t).joined().contains("код"))     // the noun is always «ключ»
    }

    @Test func sampleSentencesHaveNoProperNouns() {
        for l in SpokenLanguage.allCases {
            let s = SetupStrings.sample[l] ?? ""
            #expect(!s.isEmpty && !s.contains("Soyla"))
        }
    }

    @Test func keyPlaceholder() {
        #expect(SetupStrings.fill(SetupStrings.en.pSub, key: "fn") == "Soyla listens only while you hold fn.")
        let parts = SetupStrings.around(SetupStrings.uz.tSub)
        #expect(parts?.before == "" && parts?.after.hasPrefix("’ni bosib turing") == true)
        #expect(SetupStrings.around("no key here") == nil)
    }

    @Test func fnCaptionFollowsTheSetting() {
        let t = SetupStrings.en
        #expect(t.fnCaption(usage: 2) == "Now opens emoji")
        #expect(t.fnCaption(usage: nil) == "Now opens emoji")
        #expect(t.fnCaption(usage: 1) == "Now switches input source")
        #expect(t.fnCaption(usage: 3) == "Now starts Dictation")
    }
}
