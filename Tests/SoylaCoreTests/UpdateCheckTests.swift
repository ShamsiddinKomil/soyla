import Testing
import Foundation
@testable import SoylaCore

@Suite struct UpdateCheckTests {
    @Test func newer() {
        #expect(UpdateCheck.isNewer(tag: "v0.2.0", current: "0.1.0"))
        #expect(UpdateCheck.isNewer(tag: "0.1.1", current: "0.1.0"))
        #expect(UpdateCheck.isNewer(tag: "1.0", current: "0.9.9"))
        #expect(UpdateCheck.isNewer(tag: "v0.10.0", current: "0.9.0"))
    }
    @Test func notNewer() {
        #expect(!UpdateCheck.isNewer(tag: "v0.1.0", current: "0.1.0"))
        #expect(!UpdateCheck.isNewer(tag: "0.1", current: "0.1.0"))
        #expect(!UpdateCheck.isNewer(tag: "v0.0.9", current: "0.1.0"))
        #expect(!UpdateCheck.isNewer(tag: "garbage", current: "0.1.0"))
    }
    @Test func preRelease() {
        #expect(!UpdateCheck.isNewer(tag: "v0.2.0-beta", current: "0.2.0"))
        #expect(UpdateCheck.isNewer(tag: "v0.2.0", current: "0.2.0-beta"))
        #expect(UpdateCheck.isNewer(tag: "v0.3.0-beta.1", current: "0.2.0"))
    }
    @Test func dueLogic() {
        let now = Date()
        #expect(UpdateCheck.isDue(enabled: true, last: nil, now: now))
        #expect(!UpdateCheck.isDue(enabled: false, last: nil, now: now))
        #expect(!UpdateCheck.isDue(enabled: true, last: now.addingTimeInterval(-86_400), now: now))
        #expect(UpdateCheck.isDue(enabled: true, last: now.addingTimeInterval(-31 * 86_400), now: now))
    }
    @Test func parseRelease() {
        let d = Data(#"{"tag_name":"v1.2.3","html_url":"https://github.com/o/r/releases/tag/v1.2.3"}"#.utf8)
        #expect(UpdateCheck.parse(d, repo: "o/r")?.tag == "v1.2.3")
        #expect(UpdateCheck.parse(d) == nil)   // another repo's release page
        let foreign = Data(#"{"tag_name":"v9.9.9","html_url":"https://evil.example/o/r/releases/tag/v9.9.9"}"#.utf8)
        #expect(UpdateCheck.parse(foreign, repo: "o/r") == nil)
        let notRelease = Data(#"{"tag_name":"v9.9.9","html_url":"https://github.com/o/r/archive/x.zip"}"#.utf8)
        #expect(UpdateCheck.parse(notRelease, repo: "o/r") == nil)
        #expect(UpdateCheck.parse(Data("{}".utf8)) == nil)
    }
    @Test func settingsTolerantDecode() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(s.autoUpdateCheck == true)
        #expect(s.lastUpdateCheck == nil)
    }
}
