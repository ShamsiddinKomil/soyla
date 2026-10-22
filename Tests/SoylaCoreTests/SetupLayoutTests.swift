import Testing
import Foundation
@testable import SoylaCore

// OB-2: window scale and the System Settings helper's placement.
@Suite struct HelperPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 230, height: 110)

    @Test func besideTheSettingsWindowWhenThereIsRoom() {
        let s = CGRect(x: 300, y: 200, width: 700, height: 600)
        let p = HelperPlacement.place(settings: s, helper: size, screen: screen)
        #expect(p.arrow == .left && p.origin.x == s.maxX + HelperPlacement.gap)
        #expect(p.origin.y + size.height <= s.maxY)
    }

    @Test func underItWhenTheRightSideIsFull() {
        let s = CGRect(x: 600, y: 300, width: 800, height: 500)
        let p = HelperPlacement.place(settings: s, helper: size, screen: screen)
        #expect(p.arrow == .top && p.origin.y + size.height <= s.minY && p.origin.x + size.width <= screen.maxX)
    }

    @Test func topRightWhenNotFoundOrNoRoom() {
        let none = HelperPlacement.place(settings: nil, helper: size, screen: screen)
        #expect(none.arrow == .none && none.origin.x == screen.maxX - size.width - 16)
        let full = HelperPlacement.place(settings: CGRect(x: 200, y: 20, width: 1240, height: 850), helper: size, screen: screen)
        #expect(full.arrow == .none)
    }
}

// OB-2 review fixes (REVIEW_APP_v1.md).

@Suite struct SetupScaleTests {
    @Test func oneRatioSnappedToTheGrid() {
        #expect(SetupScale.ratio == 1.1)
        #expect(SetupScale.pt(72) == 80 && SetupScale.pt(64) == 72 && SetupScale.pt(54) == 60 && SetupScale.pt(32) == 36)
        #expect(SetupScale.pt(120) == 132 && SetupScale.pt(110) == 120 && SetupScale.pt(100) == 112)
        #expect(SetupScale.pt(6) == 6)                                  // small insets stay as drawn
        for v: CGFloat in [10, 14, 20, 24, 28, 54, 64, 72, 88, 260, 340, 960] {
            #expect(SetupScale.pt(v).truncatingRemainder(dividingBy: 4) == 0 && SetupScale.pt(v) >= v)
        }
    }

    @Test func typeScale() {
        #expect(SetupScale.type(28) == 31 && SetupScale.type(14) == 15.5 && SetupScale.type(12.5) == 14 && SetupScale.type(22) == 24)
    }

    @Test func fitsA13InchAirWithMargin() {
        let visible = CGSize(width: 1470, height: 920)
        let tallest = SetupStep.allCases.map(SetupFlow.height).max() ?? 0
        #expect(visible.width - SetupFlow.width >= 400 && visible.height - tallest >= 240)
        // The per-step heights keep v5's proportions (560:580) within a grid step.
        #expect(abs(SetupFlow.height(.languages) / SetupFlow.height(.tryIt) - 560.0 / 580.0) < 0.01)
    }
}
