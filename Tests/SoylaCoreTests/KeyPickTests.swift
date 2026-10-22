import AppKit
import Testing
@testable import SoylaCore

// HOTKEY-1: choosing the hotkey by pressing it, the Hotkey page's live test, and "use another key" on the fn row.
@Suite struct KeyPickTests {
    private let fnFlag = NSEvent.ModifierFlags.function, cmd = NSEvent.ModifierFlags.command
    private let opt = NSEvent.ModifierFlags.option, ctrl = NSEvent.ModifierFlags.control, shift = NSEvent.ModifierFlags.shift

    @Test func aModifierPressedAndReleasedAlonePicksIt() {
        var p = KeyPick()
        #expect(p.flagsChanged(keyCode: 54, flags: cmd) == nil)        // right ⌘ down: not yet
        #expect(p.flagsChanged(keyCode: 54, flags: []) == .rightCommand)
        #expect(p.flagsChanged(keyCode: 61, flags: opt) == nil)
        #expect(p.flagsChanged(keyCode: 61, flags: []) == .rightOption)
        #expect(p.flagsChanged(keyCode: 62, flags: ctrl) == nil)
        #expect(p.flagsChanged(keyCode: 62, flags: []) == .rightControl)
        #expect(p.flagsChanged(keyCode: 63, flags: fnFlag) == nil)
        #expect(p.flagsChanged(keyCode: 63, flags: []) == .fn)
    }

    @Test func aShortcutIsNotAPick() {
        var p = KeyPick()
        _ = p.flagsChanged(keyCode: 54, flags: cmd)
        #expect(p.keyDown(keyCode: 13, flags: cmd) == nil)              // ⌘W
        #expect(p.flagsChanged(keyCode: 54, flags: []) == nil)
    }

    @Test func leftModifiersAreNotOffered() {
        var p = KeyPick()
        _ = p.flagsChanged(keyCode: 55, flags: cmd)                     // left ⌘
        #expect(p.flagsChanged(keyCode: 55, flags: []) == nil)
        _ = p.flagsChanged(keyCode: 58, flags: opt)                     // left ⌥
        #expect(p.flagsChanged(keyCode: 58, flags: []) == nil)
    }

    @Test func twoModifiersTogetherAreNotAPick() {
        var p = KeyPick()
        _ = p.flagsChanged(keyCode: 54, flags: cmd)
        _ = p.flagsChanged(keyCode: 61, flags: [cmd, opt])
        #expect(p.flagsChanged(keyCode: 61, flags: cmd) == nil)
        #expect(p.flagsChanged(keyCode: 54, flags: []) == nil)
    }

    @Test func f13AndControlShiftSpaceArePickedOnKeyDown() {
        var p = KeyPick()
        #expect(p.keyDown(keyCode: 105, flags: []) == .f13)
        #expect(p.keyDown(keyCode: 49, flags: [ctrl, shift]) == .ctrlShiftSpace)
        #expect(p.keyDown(keyCode: 49, flags: []) == nil)               // plain space types a space
        #expect(p.keyDown(keyCode: 49, flags: [ctrl, shift, cmd]) == nil)
    }

    @Test func aModifierNameSplitsIntoSideAndGlyphForTheBigKey() {
        #expect(FnKeyCap.sideAndGlyph("Правый ⌥")! == ("Правый", "⌥"))
        #expect(FnKeyCap.sideAndGlyph("O‘ng ⌘")! == ("O‘ng", "⌘"))
        #expect(FnKeyCap.sideAndGlyph("fn") == nil)
        #expect(FnKeyCap.sideAndGlyph("F13") == nil)
        #expect(FnKeyCap.sideAndGlyph("⌃⇧Space") == nil)
    }

    @Test func theRowOffersTheKeysOnEveryMacAndTheRestUnderMore() {
        #expect(KeyPick.main == [.fn, .rightCommand, .rightOption])
        #expect(Set(KeyPick.main + KeyPick.more) == Set(HotkeyChoice.allCases))
        #expect(KeyPick.main.count + KeyPick.more.count == HotkeyChoice.allCases.count)
    }
}

@Suite struct KeyTestTests {
    @Test func holdingThenReleasingWorks() {
        var t = KeyTest.idle
        t.note(.startRecording)
        #expect(t == .held)
        t.note(.reveal)
        #expect(t == .held)
        t.note(.stopAndSend)
        #expect(t == .worked)
    }

    @Test func aQuickTapStillProvesTheKey() {
        var t = KeyTest.idle
        t.note(.startRecording)
        t.note(.cancelRecording(.tap))
        #expect(t == .worked)
    }

    @Test func aDoublePressWorksAndAnotherPressEndsIt() {
        var t = KeyTest.idle
        t.note(.startRecording); t.note(.lock)
        #expect(t == .worked)
        t.note(.startRecording)
        #expect(t == .held)
        t.note(.stopAndSend)
        #expect(t == .worked)
    }

    @Test func nothingBeforeAPressIsIgnored() {
        var t = KeyTest.idle
        t.note(.stopAndSend)
        #expect(t == .idle)
    }
}

@Suite struct FnRowSwapTests {
    private func fnRowNeeded() -> SetupFlow {
        var f = SetupFlow(); f.next()
        f.update(PermissionState(mic: .granted, ax: true))
        f.updateFn(hotkeyIsFn: true, usage: 2)
        return f
    }

    @Test func anotherKeyClearsTheFnRowAndKeepsItShown() {
        var f = fnRowNeeded()
        #expect(f.firstPending == .fn)
        f.updateFn(hotkeyIsFn: false, usage: 2)
        #expect(f.fnRowShown && f.fnOK && f.permissionsDone)            // the row stays, showing the key picked
    }

    @Test func backToFnWithGlobeStillSetAsksAgain() {
        var f = fnRowNeeded()
        f.updateFn(hotkeyIsFn: false, usage: 2)
        f.updateFn(hotkeyIsFn: true, usage: 2)
        #expect(f.fnRowShown && f.firstPending == .fn)
    }
}
