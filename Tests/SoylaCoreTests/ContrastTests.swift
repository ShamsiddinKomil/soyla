import Testing
import AppKit
@testable import SoylaCore

// Audit 2026-10-19 V-26: Increase Contrast strengthens the faint tokens (text3 → text2's 62 %, hairlines → 14/16 %,
// lapis text → 90 %). The alpha choice is pure; the dynamic colour asks the appearance and the workspace setting.
@Suite struct IncreaseContrastTests {
    @Test func faintTokensTakeTheStrongerAlphaUnderIncreaseContrast() {
        let text3 = (light: 0.62, dark: 0.62), hairline = (light: 0.14, dark: 0.16)
        #expect(Ink.alpha(dark: false, high: false, light: 0.45, dark: 0.45, contrast: text3) == 0.45)
        #expect(Ink.alpha(dark: false, high: true, light: 0.45, dark: 0.45, contrast: text3) == 0.62)
        #expect(Ink.alpha(dark: true, high: true, light: 0.45, dark: 0.45, contrast: text3) == 0.62)
        #expect(Ink.alpha(dark: false, high: true, light: 0.08, dark: 0.09, contrast: hairline) == 0.14)
        #expect(Ink.alpha(dark: true, high: true, light: 0.08, dark: 0.09, contrast: hairline) == 0.16)
        #expect(Ink.alpha(dark: true, high: false, light: 0.08, dark: 0.09, contrast: hairline) == 0.09)
    }

    @Test func aTokenWithoutAContrastValueKeepsItsAlpha() {
        #expect(Ink.alpha(dark: false, high: true, light: 0.62, dark: 0.62, contrast: nil) == 0.62)
        #expect(Ink.alpha(dark: true, high: true, light: 1, dark: 1, contrast: nil) == 1)
    }

    @Test func theNormalAppearancesKeepTheDrawnAlphas() {
        let c = Ink.dynamic(0x1A2230, 0xE8EBF0, light: 0.45, dark: 0.45, contrast: (0.62, 0.62))
        guard !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast else { return }   // this Mac has it on
        var a: CGFloat = -1
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { a = c.usingColorSpace(.sRGB)?.alphaComponent ?? -1 }
        #expect(abs(a - 0.45) < 0.01)
    }
}
