import Testing
import CoreGraphics
@testable import SoylaCore

@Suite struct HotkeyTests {
    typealias M = HotkeyMatcher
    let fn = CGEventFlags.maskSecondaryFn.rawValue
    let alt = CGEventFlags.maskAlternate.rawValue
    let ctrl = CGEventFlags.maskControl.rawValue
    let shift = CGEventFlags.maskShift.rawValue

    @Test func fnHoldReleaseIsDebounced() {
        var m = M(choice: .fn)
        #expect(m.handle(kind: .flagsChanged, keyCode: 63, flags: fn, isAutorepeat: false) == .down)
        // another modifier toggles while fn still held → no second DOWN
        #expect(m.handle(kind: .flagsChanged, keyCode: 56, flags: fn | shift, isAutorepeat: false) == nil)
        #expect(m.handle(kind: .keyDown, keyCode: 0, flags: fn, isAutorepeat: false) == nil)
        #expect(m.handle(kind: .flagsChanged, keyCode: 63, flags: 0, isAutorepeat: false) == .up)
        #expect(m.handle(kind: .flagsChanged, keyCode: 63, flags: 0, isAutorepeat: false) == nil)
    }

    @Test func rightOptionIgnoresLeftOption() {
        var m = M(choice: .rightOption)
        // left option (58) → ignored
        #expect(m.handle(kind: .flagsChanged, keyCode: 58, flags: alt | M.deviceLeftAlt, isAutorepeat: false) == nil)
        #expect(m.handle(kind: .flagsChanged, keyCode: 61, flags: alt | M.deviceLeftAlt | M.deviceRightAlt, isAutorepeat: false) == .down)
        // right released while left still held: generic alt still set, right device bit gone → UP
        #expect(m.handle(kind: .flagsChanged, keyCode: 61, flags: alt | M.deviceLeftAlt, isAutorepeat: false) == .up)
    }

    @Test func rightModifierFallsBackToGenericMask() {
        var m = M(choice: .rightCommand)
        #expect(m.handle(kind: .flagsChanged, keyCode: 54, flags: CGEventFlags.maskCommand.rawValue, isAutorepeat: false) == .down)
        #expect(m.handle(kind: .flagsChanged, keyCode: 54, flags: 0, isAutorepeat: false) == .up)
    }

    @Test func ctrlShiftSpaceIgnoresAutorepeatAndPlainSpace() {
        var m = M(choice: .ctrlShiftSpace)
        #expect(m.handle(kind: .keyDown, keyCode: 49, flags: 0, isAutorepeat: false) == nil)
        #expect(m.handle(kind: .keyUp, keyCode: 49, flags: 0, isAutorepeat: false) == nil)
        #expect(m.handle(kind: .keyDown, keyCode: 49, flags: ctrl | shift, isAutorepeat: false) == .down)
        #expect(m.handle(kind: .keyDown, keyCode: 49, flags: ctrl | shift, isAutorepeat: true) == nil)
        #expect(m.handle(kind: .keyUp, keyCode: 49, flags: 0, isAutorepeat: false) == .up)
    }

    @Test func f13KeyDownUp() {
        var m = M(choice: .f13)
        #expect(m.handle(kind: .keyDown, keyCode: 105, flags: fn, isAutorepeat: false) == .down)
        #expect(m.handle(kind: .keyDown, keyCode: 105, flags: fn, isAutorepeat: true) == nil)
        #expect(m.handle(kind: .keyUp, keyCode: 104, flags: 0, isAutorepeat: false) == nil)
        #expect(m.handle(kind: .keyUp, keyCode: 105, flags: 0, isAutorepeat: false) == .up)
    }

    @Test func changingChoiceResetsState() {
        var m = M(choice: .fn)
        #expect(m.handle(kind: .flagsChanged, keyCode: 63, flags: fn, isAutorepeat: false) == .down)
        m.choice = .f13
        #expect(m.isDown == false)
        #expect(m.handle(kind: .keyDown, keyCode: 105, flags: 0, isAutorepeat: false) == .down)
    }
}
