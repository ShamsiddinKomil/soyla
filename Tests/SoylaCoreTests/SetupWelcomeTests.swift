import Testing
import Foundation
@testable import SoylaCore

// OB-2 v6: the Welcome step (owner-approved, prototype-v6.html).
@Suite struct SetupWelcomeTests {
    @Test func setupOpensOnWelcome() {
        let f = SetupFlow(welcome: true)
        #expect(f.step == .welcome && f.canContinue && !f.hotkeysReachPipeline)
        #expect(f.steps.first == .languages && !f.steps.contains(.welcome))      // the rail starts at Languages
        #expect(!f.showsRail)
    }

    @Test func startGoesToLanguagesAndBackReturns() {
        var f = SetupFlow(welcome: true)
        let moved = f.next()
        #expect(moved && f.step == .languages && f.showsRail && f.railIndex == 0)
        f.back()
        #expect(f.step == .welcome)
        f.back()
        #expect(f.step == .welcome)
    }

    @Test func plainFlowHasNoWelcome() {
        var f = SetupFlow()
        #expect(f.step == .languages)
        f.back()
        #expect(f.step == .languages)
    }

    @Test func rerunPreselectsOnWelcome() {
        var f = SetupFlow(welcome: true)
        f.preselect([.ru])
        #expect(f.languages == [.ru])
        f.next()
        #expect(f.step == .languages && f.languages == [.ru])
    }

    @Test func homeConnectSkipsWelcome() {
        var f = SetupFlow(welcome: true)
        f.preselect([.uz]); f.jumpToConnect()
        #expect(f.step == .connect && f.returnTo == .done)
    }

    @Test func welcomeIsTheShortHeight() {
        #expect(SetupFlow.height(.welcome) == 616)
    }

    @Test func restartKeepsTheWelcome() {
        var f = SetupFlow(welcome: true); f.next(); f.next()
        f.restart()
        #expect(f.step == .welcome)
    }
}

@Suite struct WelcomeMotionTests {
    @Test func barsRestUntilTheirStart() {
        for i in 0..<5 {
            #expect(WelcomeMotion.barScale(at: 0, index: i) == 1)
            #expect(WelcomeMotion.barScale(at: 0.69 + 0.16 * Double(i), index: i) == 1)
        }
    }

    @Test func swellReachesItsLowAtHalfPeriodAndReturns() {
        let start = WelcomeMotion.loopDelay
        #expect(abs(WelcomeMotion.barScale(at: start + 1.45, index: 0) - 0.62) < 0.001)
        #expect(abs(WelcomeMotion.barScale(at: start + 2.9, index: 0) - 1) < 0.001)
        // Staggered 160 ms left to right.
        let s4 = start + 4 * 0.16
        #expect(abs(WelcomeMotion.barScale(at: s4 + 1.45, index: 4) - 0.62) < 0.001)
        #expect(WelcomeMotion.barScale(at: start + 1.45, index: 4) > 0.62)
    }

    @Test func swellStaysInRange() {
        var t = 0.0
        while t < 10 {
            for i in 0..<5 {
                let v = WelcomeMotion.barScale(at: t, index: i)
                #expect(v >= 0.6199 && v <= 1.0001)
            }
            t += 0.037
        }
    }

    @Test func easingCurves() {
        // cubic-bezier(.45,0,.55,1) is symmetric: 0.5 → 0.5; the entrance curve (.16,1,.3,1) is fast early.
        #expect(abs(WelcomeMotion.bezier(0.45, 0, 0.55, 1, 0.5) - 0.5) < 0.001)
        #expect(WelcomeMotion.bezier(0.16, 1, 0.3, 1, 0.25) > 0.75)
        #expect(WelcomeMotion.bezier(0.16, 1, 0.3, 1, 0) == 0 && abs(WelcomeMotion.bezier(0.16, 1, 0.3, 1, 1) - 1) < 0.0001)
    }
}

@Suite struct WelcomeStringsTests {
    @Test func copyMatchesV6() {
        #expect(SetupStrings.en.wLine == "You speak. Soyla types." && SetupStrings.en.wStart == "Start" && SetupStrings.en.wTime == "About 2 minutes")
        #expect(SetupStrings.uz.wLine == "Siz gapirasiz, Soyla yozadi." && SetupStrings.uz.wStart == "Boshlash" && SetupStrings.uz.wTime == "Taxminan 2 daqiqa")
        #expect(SetupStrings.ru.wLine == "Вы говорите, Soyla печатает." && SetupStrings.ru.wStart == "Начать" && SetupStrings.ru.wTime == "Около 2 минут")
    }
}
