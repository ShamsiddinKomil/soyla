import Testing
import Foundation
@testable import SoylaCore

// OB-2: Home and the menu bar notice a skipped key (Uzbek/Russian picked in setup, no verified cloud key).
@Suite struct CloudNudgeTests {
    private func nudge(_ spoken: [SpokenLanguage]?, _ provider: ProviderKind, verified: Set<KeyProvider> = [],
                       keychainReady: Bool = true) -> CloudCombo? {
        CloudNudge.missing(spoken: spoken, provider: provider, verified: { verified.contains($0) }, keychainReady: keychainReady)
    }

    @Test func noCloudLanguageNeverNudges() {
        for p in [ProviderKind.apple, .google, .openRouter, .custom] {
            #expect(nudge(nil, p) == nil)
            #expect(nudge([], p) == nil)
            #expect(nudge([.en], p) == nil)
        }
    }

    @Test func skippedKeyOnTheFreeEngineNudges() {
        #expect(nudge([.uz], .apple) == .uz)
        #expect(nudge([.en, .ru], .apple) == .ru)
        #expect(nudge([.en, .uz, .ru], .apple) == .uzru)
    }

    @Test func aKeyThatIsNotInUseStillNudges() {
        // Verified OpenRouter key but still on the free engine: Uzbek doesn't work yet.
        #expect(nudge([.uz], .apple, verified: [.openRouter]) == .uz)
        // On Google, but only the OpenRouter key is verified.
        #expect(nudge([.ru], .google, verified: [.openRouter]) == .ru)
    }

    @Test func verifiedKeyForTheEngineInUseHides() {
        #expect(nudge([.uz, .ru], .google, verified: [.google]) == nil)
        #expect(nudge([.ru], .openRouter, verified: [.openRouter]) == nil)
    }

    @Test func cloudProviderWithAnUnverifiedKeyNudges() {
        #expect(nudge([.uz], .openRouter) == .uz)
        #expect(nudge([.uz], .google) == .uz)
    }

    @Test func customEndpointIsTrusted() {
        #expect(nudge([.uz], .custom) == nil)
    }

    @Test func waitingOnTheKeychainIsNotMissing() {
        #expect(nudge([.uz], .apple, keychainReady: false) == nil)
    }

    @Test func copy() {
        #expect(CloudNudge.homeText(.uz) == "Uzbek isn't connected yet · English works now")
        #expect(CloudNudge.homeText(.uzru) == "Uzbek and Russian aren't connected yet · English works now")
        #expect(CloudNudge.button(.ru) == "Connect Russian")
        #expect(CloudNudge.menuLine(.uz) == "Uzbek needs an API key")
        #expect(CloudNudge.menuLine(.uzru) == "Uzbek and Russian need an API key")
    }
}

@Suite struct SetupJumpToConnectTests {
    @Test func opensConnectAndReturnsToDone() {
        var f = SetupFlow()
        f.preselect([.en, .ru])
        f.jumpToConnect()
        #expect(f.step == .connect && f.returnTo == .done)
        f.keyConnected()
        let moved = f.next()
        #expect(moved && f.step == .done && f.showsTryCloud)
    }

    @Test func backGoesToDone() {
        var f = SetupFlow(); f.preselect([.uz]); f.jumpToConnect()
        f.back()
        #expect(f.step == .done)
    }

    @Test func nothingToConnectWithoutACloudLanguage() {
        var f = SetupFlow(); f.jumpToConnect()
        #expect(f.step == .languages && f.returnTo == nil)
    }
}
