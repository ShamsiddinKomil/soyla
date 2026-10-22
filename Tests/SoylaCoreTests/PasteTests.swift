import Testing
import Foundation
import CoreGraphics
@testable import SoylaCore

@Suite struct PasteTests {
    // MARK: keycode resolution order (mocked layouts)

    /// A fake layout: keycode → char with ⌘ held.
    func layout(_ map: [UInt16: String]) -> PasteKeycode.Lookup { { map[$0] } }

    @Test func keycodeUsesCurrentLayoutFirst() {
        let dvorak = layout([47: "v", 9: "k"])
        let ascii = layout([9: "v"])
        #expect(PasteKeycode.resolve([dvorak, ascii]) == 47)
    }

    @Test func keycodeFallsBackToAsciiCapableWhenCurrentHasNoV() {
        let cyrillicNoCmdLayer = layout([9: "м"])          // no Latin ⌘ layer
        let ascii = layout([9: "v"])
        #expect(PasteKeycode.resolve([cyrillicNoCmdLayer, ascii]) == 9)
        // current layout without Unicode data (nil lookup) is skipped too
        #expect(PasteKeycode.resolve([nil, layout([47: "V"])]) == 47)
    }

    @Test func keycodeFallsBackToAnsi9WhenNothingMatches() {
        #expect(PasteKeycode.resolve([]) == 9)
        #expect(PasteKeycode.resolve([nil, nil]) == 9)
        #expect(PasteKeycode.resolve([layout([:]), layout([1: "x"])]) == 9)
    }

    @Test func keycodePrefersAnsi9WhenSeveralKeysGiveV() {
        #expect(PasteKeycode.resolve([layout([3: "v", 9: "v"])]) == 9)
    }

    @Test func keycodeLiveResolutionIsAValidKey() {
        // Whatever layout this Mac has, the result is a real keycode (< 128); on ABC/Russian/Uzbek it is 9.
        #expect(PasteKeycode.resolveLive() < 128)
    }

    // MARK: restore delay table

    @Test func delayTableByBundleId() {
        #expect(PasteDelays.restoreDelayMs(bundleId: "com.apple.Notes") == 500)
        #expect(PasteDelays.restoreDelayMs(bundleId: "com.apple.Terminal") == 500)
        #expect(PasteDelays.restoreDelayMs(bundleId: nil) == 500)
        for b in ["com.microsoft.VSCode", "com.tinyspeck.slackmacgap", "com.google.Chrome", "ru.keepcoder.Telegram", "com.hnc.Discord"] {
            #expect(PasteDelays.restoreDelayMs(bundleId: b) == 1200, "\(b)")
        }
        for b in ["com.apple.ScreenSharing", "com.microsoft.rdc.macos"] {
            #expect(PasteDelays.restoreDelayMs(bundleId: b) == 2000, "\(b)")
        }
    }

    @Test func delayUnknownElectronAppGetsChromiumDelay() {
        #expect(PasteDelays.restoreDelayMs(bundleId: "com.example.someElectronApp", isElectron: true) == 1200)
        // the table wins over the Electron flag for remote apps
        #expect(PasteDelays.restoreDelayMs(bundleId: "com.apple.ScreenSharing", isElectron: true) == 2000)
    }

    // MARK: restore guard

    @Test func restoreOnlyWhenChangeCountAndMarkerAreOurs() {
        #expect(RestoreGuard.shouldRestore(currentChangeCount: 7, ourChangeCount: 7, markerToken: "t1", ourToken: "t1"))
        // user copied something after our write
        #expect(!RestoreGuard.shouldRestore(currentChangeCount: 8, ourChangeCount: 7, markerToken: nil, ourToken: "t1"))
        // changeCount equal but our marker gone (another writer that kept the count, or a different paste session)
        #expect(!RestoreGuard.shouldRestore(currentChangeCount: 7, ourChangeCount: 7, markerToken: nil, ourToken: "t1"))
        #expect(!RestoreGuard.shouldRestore(currentChangeCount: 7, ourChangeCount: 7, markerToken: "t0", ourToken: "t1"))
    }

    // MARK: pre-flight decision

    @Test func preflightBlocksInPriorityOrder() {
        #expect(PastePreflight.decide(axTrusted: true, secureInput: false, targetPID: 10, currentPID: 10) == nil)
        #expect(PastePreflight.decide(axTrusted: false, secureInput: true, targetPID: 10, currentPID: 11) == .noAccessibility)
        #expect(PastePreflight.decide(axTrusted: true, secureInput: true, targetPID: 10, currentPID: 11) == .secureInput)
        #expect(PastePreflight.decide(axTrusted: true, secureInput: false, targetPID: 10, currentPID: 11) == .focusChanged)
    }

    @Test func preflightUnknownFocusNeverBlocks() {
        #expect(PastePreflight.decide(axTrusted: true, secureInput: false, targetPID: nil, currentPID: 11) == nil)
        #expect(PastePreflight.decide(axTrusted: true, secureInput: false, targetPID: 10, currentPID: nil) == nil)
    }

    @Test func notEditableIsOnlyAWarningSignal() {
        #expect(PastePreflight.looksEditable(role: "AXTextArea", settableValue: nil) == true)
        #expect(PastePreflight.looksEditable(role: "AXButton", settableValue: true) == true)
        #expect(PastePreflight.looksEditable(role: "AXButton", settableValue: false) == false)
        #expect(PastePreflight.looksEditable(role: "AXGroup", settableValue: false) == nil)   // web/Electron: unknown
        #expect(PastePreflight.looksEditable(role: nil, settableValue: nil) == nil)
    }

    // MARK: outcome, card, terminal text, CLI verdict

    @Test func outcomeLabelsAndCards() {
        #expect(PasteOutcome.pasted(method: .commandV, targetLooksEditable: nil).label == "commandV")
        #expect(PasteOutcome.copiedOnly(reason: .secureInput).label == "copied:secureInput")
        #expect(!PasteOutcome.copiedOnly(reason: .focusChanged).inserted)
        let f = PillFailure.paste(.secureInput)
        #expect(f.kind == .warning && f.title == "Not pasted: it's on your clipboard" && !f.canRetry)
        #expect(PillFailure.paste(.noAccessibility).openSettings)
    }

    @Test func terminalTargetsNeverGetATrailingNewline() {
        #expect(PasteText.prepare("ls -la\n", bundleId: "com.apple.Terminal") == "ls -la")
        #expect(PasteText.prepare("echo hi\r\n\n", bundleId: "com.googlecode.iterm2") == "echo hi")
        #expect(PasteText.prepare("line\n", bundleId: "com.apple.Notes") == "line\n")
        #expect(PasteText.prepare("salom", bundleId: "com.apple.Terminal") == "salom")   // no trailing space added
    }

    @Test func pasteTestVerdict() {
        let ok = PasteOutcome.pasted(method: .commandV, targetLooksEditable: true)
        let copied = PasteOutcome.copiedOnly(reason: .secureInput)
        #expect(PasteTest.verdict(expect: "pasted", outcome: ok, readBack: true, clipboardIsSentinel: true, clipboardIsText: false).pass)
        #expect(PasteTest.verdict(expect: "pasted", outcome: ok, readBack: nil, clipboardIsSentinel: true, clipboardIsText: false).pass)
        #expect(!PasteTest.verdict(expect: "pasted", outcome: ok, readBack: false, clipboardIsSentinel: true, clipboardIsText: false).pass)
        #expect(!PasteTest.verdict(expect: "pasted", outcome: ok, readBack: true, clipboardIsSentinel: false, clipboardIsText: false).pass)
        #expect(!PasteTest.verdict(expect: "pasted", outcome: copied, readBack: nil, clipboardIsSentinel: false, clipboardIsText: true).pass)
        #expect(PasteTest.verdict(expect: "copied", outcome: copied, readBack: nil, clipboardIsSentinel: false, clipboardIsText: true).pass)
        #expect(!PasteTest.verdict(expect: "copied", outcome: ok, readBack: true, clipboardIsSentinel: true, clipboardIsText: false).pass)
    }

    // MARK: serialization gate

    @Test func gateSerializesInOrder() async {
        let g = PasteGate()
        final class Log: @unchecked Sendable { var v: [Int] = []; let l = NSLockShim() }
        let log = Log()
        await g.acquire()
        let t = Task { await g.acquire(); log.l.run { log.v.append(2) }; g.release() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        log.l.run { log.v.append(1) }   // still holding: the waiter must not have run
        g.release()
        await t.value
        #expect(log.v == [1, 2])
    }
}

/// Minimal lock helper for the gate test.
final class NSLockShim: @unchecked Sendable {
    private let l = NSLock()
    func run(_ f: () -> Void) { l.lock(); f(); l.unlock() }
}
