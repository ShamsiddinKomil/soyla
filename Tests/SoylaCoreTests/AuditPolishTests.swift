import Testing
import Foundation
@testable import SoylaCore

// Owner decision D24 (2026-10-25): the regression pass's polish batch R-11..R-17.

@Suite struct AuditPolishTests {
    @Test func infoButtonsAreAnnouncedAsAbout() {                           // R-11
        #expect(AppStrings.en.about("Languages") == "About Languages")
        #expect(AppStrings.uz.about("Tillar") == "Tillar haqida")
        #expect(AppStrings.ru.about("Языки") == "Подробнее: Языки")
    }

    @Test func uzbekKeyTitlesKeepAPIKeyOnOneLine() {                       // R-12
        #expect(SetupStrings.uz.cTitle(.uz).contains("API\u{00A0}key"))
        #expect(SetupStrings.uz.cTitle(.uzru).contains("API\u{00A0}key"))
        #expect(AppStrings.uz.keyTitle.contains("API\u{00A0}key"))
    }

    @Test func scrollingPagesKeepTheirWidthWithLegacyScrollBars() {         // R-14
        #expect(AppPageLayout.scrollTrailing(side: 72, legacy: true, scroller: 17) == 55)
        #expect(AppPageLayout.scrollTrailing(side: 72, legacy: false, scroller: 17) == 72)
    }
}
