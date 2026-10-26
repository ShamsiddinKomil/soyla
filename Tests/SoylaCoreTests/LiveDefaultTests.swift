import Foundation
import Testing
@testable import SoylaCore

/// Owner, 2026-10-26: the Live fast path is on by default only when Google AI Studio is the chosen engine; a choice
/// made by hand is kept on any engine. Settings saved while it was off by default pick up the new default once.
@Suite struct LiveDefaultTests {
    func decode(_ json: String) throws -> Settings { try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }

    @Test func onByDefaultOnlyWhenGoogleIsTheEngine() throws {
        var g = Settings()
        g.provider = .google
        #expect(g.liveFastPath)
        var o = Settings()
        o.provider = .openRouter
        #expect(!o.liveFastPath)                                  // audio goes only to the provider you chose
        #expect(try decode(#"{"provider": "google"}"#).liveFastPath)
    }

    @Test func anOldOffIsTheOldDefaultSoItFollowsTheEngine() throws {
        #expect(try decode(#"{"provider": "google", "liveFastPath": false}"#).liveFastPath)
        #expect(try !decode(#"{"provider": "openRouter", "liveFastPath": false}"#).liveFastPath)
    }

    @Test func aChoiceMadeByHandIsKeptOnAnyEngine() throws {
        var on = Settings()
        on.provider = .openRouter
        on.liveFastPath = true
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(on)).liveFastPath)
        var off = Settings()
        off.provider = .google
        off.liveFastPath = false
        #expect(try !JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(off)).liveFastPath)
    }
}
