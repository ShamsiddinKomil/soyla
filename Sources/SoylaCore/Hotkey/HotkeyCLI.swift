import Foundation
import CoreFoundation
import AppKit
import Carbon
// OWNER: Agent C (Input/Output).
// `soyla hotkey-test [fn|rightOption|…] [--sec N] [--sim]` : print every gesture-reducer step (event → actions) for 20 s;
//                                       --sim replays the gesture table offline. Prints which permissions are granted first.
// `soyla paste-test [opts] "text"`       : waits 3 s (switch to the target app), pastes, verifies insert + clipboard restore → RESULT PASS/FAIL.
//
// Run-loop note: main.swift runs CLI subcommands inside a Task and parks the MAIN thread in `dispatchMain()`, so the
// main queue runs but the main CFRunLoop never does in CLI mode. hotkey-test therefore spins a dedicated Thread
// that owns its own CFRunLoop (the tap source is added there via HotkeyMonitor.runLoop) and delivers callbacks on a
// private serial queue (HotkeyMonitor.callbackQueue). The async function just sleeps 20 s, then stops that loop.
public enum HotkeyCLI {
    /// `soyla hotkey-test [choice] [--sec N]` : live — prints every reducer step (event → actions) while you press keys.
    /// `soyla hotkey-test --sim`               : offline — replays every gesture-table row through the reducer.
    /// In live mode a stopAndSend is followed by a simulated "pipeline idle" 1.5 s later (there is no pipeline here).
    public static func hotkeyTest(args: [String]) async throws {
        if args.contains("--sim") { simulate(); return }
        var secs = 20.0
        var rest: [String] = []
        var it = args.makeIterator()
        while let a = it.next() { if a == "--sec" { secs = Double(it.next() ?? "") ?? secs } else { rest.append(a) } }
        let name = rest.first ?? HotkeyChoice.fn.rawValue
        guard let choice = HotkeyChoice(rawValue: name) else {
            throw SoylaError.decode("unknown hotkey '\(name)'; use one of: \(HotkeyChoice.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        printPermissions()
        if choice == .fn {
            print("""
                reminder: set System Settings → Keyboard → "Press 🌐 key to" = Do Nothing (else fn opens the emoji
                picker / Dictation), and quit Wispr Flow / other apps that also hold fn.
                """)
        }

        let out = DispatchQueue(label: "soyla.hotkey-test.callbacks")
        let monitor = HotkeyMonitor(choice: choice)
        monitor.callbackQueue = out
        let t0 = monitor.now()
        monitor.onTrace = { event, actions, t in
            if actions.isEmpty && (event == .otherKey || event == .timer) { return }   // keep it readable
            print(line(event, actions, t: t, t0: t0)); fflush(stdout)
        }
        monitor.onAction = { [weak monitor] a in
            guard a == .stopAndSend else { return }
            out.asyncAfter(deadline: .now() + 1.5) { [weak monitor] in print("  (simulated: pipeline done)"); monitor?.send(.pipelineIdle) }
        }

        // Start the tap on a dedicated thread with its own run loop; hand back the loop (or the start error).
        let rl: CFRunLoop = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CFRunLoop, Error>) in
            let th = Thread {
                let rl = CFRunLoopGetCurrent()!
                monitor.runLoop = rl
                do { try monitor.start() } catch { cont.resume(throwing: error); return }
                cont.resume(returning: rl)
                CFRunLoopRun()   // returns after CFRunLoopStop below
            }
            th.name = "soyla.hotkey-test.tap"
            th.start()
        }
        print("listening for \(choice.label) for \(Int(secs)) s — hold, tap, double-press, press ESC…"); fflush(stdout)
        try await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) {
            monitor.stop()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(rl)
        try? await Task.sleep(nanoseconds: 100_000_000)
        out.sync {}   // flush pending prints
        print("done"); fflush(stdout)
    }

    /// One trace line: `+  1234 ms  up → stopAndSend, escCapture(true)`.
    static func line(_ e: HotkeyReducer.Event, _ actions: [HotkeyReducer.Action], t: Double, t0: Double) -> String {
        let acts = actions.map { a -> String in
            if case .schedule(let at) = a { return "schedule(+\(Int(((at - t) * 1000).rounded())) ms)" }
            return "\(a)"
        }
        return "+\(String(format: "%6.0f", (t - t0) * 1000)) ms  \(e) → \(acts.isEmpty ? "–" : acts.joined(separator: ", "))"
    }

    /// Every gesture-table row through the pure reducer, with the scheduled ticks fired at their deadlines.
    static func simulate() {
        typealias E = HotkeyReducer.Event
        let rows: [(String, [(Double, E)])] = [
            ("hold 1.2 s → push-to-talk", [(0, .down), (1.2, .up), (2.5, .pipelineIdle)]),
            ("tap 0.45 s → silent, dropped 0.8 s after release", [(0, .down), (0.45, .up)]),
            ("double press 0.5 s after release → locked; press again → send", [(0, .down), (0.1, .up), (0.6, .down), (0.7, .up), (5, .down), (5.1, .up), (6, .pipelineIdle)]),
            ("other key while held → abort", [(0, .down), (0.8, .otherKey), (1.0, .up)]),
            ("press while processing → one notice", [(0, .down), (1, .up), (1.5, .down), (1.6, .up), (1.8, .down), (3, .pipelineIdle)]),
            ("ESC while recording → cancel, consumed", [(0, .down), (1, .escape), (1.2, .up)]),
            ("ESC while processing → cancel request, consumed", [(0, .down), (1, .up), (2, .escape)]),
            ("ESC while idle → passed through", [(0, .escape)]),
            ("locked → hard stop → still sent", [(0, .down), (0.1, .up), (0.3, .down), (0.4, .up), (55, .processingStarted), (58, .pipelineIdle)]),
        ]
        for (title, script) in rows {
            print("— \(title)")
            var r = HotkeyReducer()
            var timers: [Double] = []
            func run(_ e: E, _ t: Double) {
                let acts = r.step(e, now: t)
                for case .schedule(let at) in acts { timers.append(at) }
                if !(acts.isEmpty && e == .timer) { print("  " + line(e, acts, t: t, t0: 0)) }
            }
            for (t, e) in script {
                while let due = timers.min(), due <= t { timers.removeAll { $0 == due }; run(.timer, due) }
                run(e, t)
            }
            while let due = timers.min() { timers.removeAll { $0 == due }; run(.timer, due) }
            print("  state: \(r.state)")
        }
    }

    /// `soyla paste-test [--app NAME] [--expect pasted|copied] [--wait S] [--delay MS] [--unicode] ["text"]`
    /// `soyla paste-test --keycodes` : print the resolved ⌘V keycode for the current and every installed layout.
    ///
    /// Owner check per app: put the cursor in a text field of the app, run the command in Terminal, switch to the app
    /// within the countdown. Prints one `RESULT` line: inserted (AX read-back of a unique token), clipboard restored
    /// (a sentinel placed on the clipboard before the paste is back), and whether the outcome matched --expect.
    public static func pasteTest(args: [String]) async throws {
        var rest: [String] = []
        var appLabel: String?
        var expect = "pasted"
        var wait = 3.0
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--keycodes": printKeycodes(); return
            case "--app": appLabel = it.next()
            case "--expect": expect = it.next() ?? expect
            case "--wait": wait = Double(it.next() ?? "") ?? wait
            case "--delay": Paster.restoreDelayOverrideMs = Int(it.next() ?? "")
            case "--unicode": Paster.allowUnicodeTyping = true
            default: rest.append(a)
            }
        }
        guard expect == "pasted" || expect == "copied" else { throw SoylaError.decode("--expect must be pasted or copied") }
        let token = "soyla\(Int.random(in: 1000...9999))"
        let text = (rest.isEmpty ? "salom привет oʻzbek" : rest.joined(separator: " ")) + " " + token

        printPermissions()
        let cur = PasteKeycode.onMain { TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() }
        print("keyboard layout: \(PasteKeycode.sourceId(cur) ?? "?")  ⌘V keycode: \(PasteKeycode.resolveLive())")
        print("switch to the target app and click into a text field — pasting in \(Int(wait)) s"); fflush(stdout)
        try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))

        // Sentinel on the clipboard so we can prove the restore.
        let sentinel = "soyla-sentinel-\(UUID().uuidString.prefix(8))"
        Paster.copy(sentinel)

        let target = PasteTarget.frontmost()   // stands in for "frontmost at hotkey release"
        let name = appLabel ?? target.name ?? "?"
        print("target: \(target.name ?? "?") (\(target.bundleId ?? "?"))  secure input: \(IsSecureEventInputEnabled() ? "ON" : "off")  restore delay: \(Paster.restoreDelayMs(for: target)) ms")
        let tl = RunTimeline()
        tl.mark(.responseReceived)   // zero point: "text ready" → .pasted is the paste cost
        let outcome = await Paster.paste(text, target: target, timeline: tl)
        await Paster.awaitIdle()
        try? await Task.sleep(nanoseconds: 150_000_000)   // let the target app finish inserting before reading back

        let cost = tl.ms(from: .responseReceived, to: .pasted).map { String(format: "%.0f ms", $0) } ?? "-"
        let clip = NSPasteboard.general.string(forType: .string)
        let readBack = PasteTest.readBack(contains: token)
        let inserted: String
        switch readBack {
        case .some(true): inserted = "yes"
        case .some(false): inserted = "NO (token not found in the focused field)"
        case .none: inserted = "unverified (AX can't read this app — check by eye)"
        }
        let verdict = PasteTest.verdict(expect: expect, outcome: outcome, readBack: readBack,
                                        clipboardIsSentinel: clip == sentinel, clipboardIsText: clip == PasteText.prepare(text, bundleId: target.bundleId))
        print("outcome: \(outcome.label)  text_ready→pasted: \(cost)")
        print("inserted: \(inserted)")
        print("clipboard: \(clip == sentinel ? "restored" : (clip == PasteText.prepare(text, bundleId: target.bundleId) ? "holds the text (not restored)" : "something else"))")
        print("RESULT \(name): \(verdict.pass ? "PASS" : "FAIL")\(verdict.note.isEmpty ? "" : " — " + verdict.note)")
        fflush(stdout)
    }

    private static func printKeycodes() { PasteKeycode.onMain { printKeycodesOnMain() } }

    private static func printKeycodesOnMain() {
        let cur = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        print("current: \(PasteKeycode.sourceId(cur) ?? "?")  ascii-capable: \(PasteKeycode.sourceId(ascii) ?? "?")  → ⌘V keycode \(PasteKeycode.resolveLive())")
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        let all = (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
        for src in all {
            guard let id = PasteKeycode.sourceId(src) else { continue }
            let k = PasteKeycode.resolve([PasteKeycode.lookup(for: src), PasteKeycode.lookup(for: ascii)])
            let own = PasteKeycode.resolve([PasteKeycode.lookup(for: src)])
            print("\(id): \(k)\(own != k ? " (own layout has no ⌘V; ascii fallback)" : "")")
        }
    }

    private static func printPermissions() {
        // prompt: true — macOS only shows each dialog once per binary identity, so this is "prompting once".
        let ax = Permissions.accessibilityTrusted(prompt: true)
        let im = Permissions.inputMonitoring(prompt: true)
        print("permissions: Accessibility=\(ax ? "granted" : "MISSING")  Input Monitoring=\(im ? "granted" : "MISSING")")
        if !ax || !im {
            print("""
                grant them in System Settings → Privacy & Security → Accessibility / Input Monitoring for this binary
                (\(CommandLine.arguments.first ?? "soyla")) or the terminal app running it, then re-run. After a rebuild an
                ad-hoc signed binary may need the toggle switched off/on.
                """)
        }
        fflush(stdout)
    }
}

/// paste-test helpers; `verdict` is pure (unit-tested).
enum PasteTest {
    /// Does the focused element's AX value contain `token`? nil = AX could not read it.
    static func readBack(contains token: String) -> Bool? {
        guard let el = PastePreflight.focusedElement() else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &ref) == .success,
              let v = ref as? String else { return nil }
        return v.contains(token)
    }

    static func verdict(expect: String, outcome: PasteOutcome, readBack: Bool?,
                        clipboardIsSentinel: Bool, clipboardIsText: Bool) -> (pass: Bool, note: String) {
        if expect == "copied" {
            if outcome.inserted { return (false, "expected a copy card, but it pasted (\(outcome.label))") }
            return clipboardIsText ? (true, "not inserted (\(outcome.label)), text is on the clipboard")
                                   : (false, "not inserted, but the clipboard does not hold the text")
        }
        guard outcome.inserted else { return (false, "not inserted: \(outcome.label)") }
        if readBack == false { return (false, "⌘V posted but the text is not in the field") }
        if !clipboardIsSentinel { return (false, "inserted, but the clipboard was not restored") }
        return (true, readBack == nil ? "clipboard restored; confirm the text appeared (AX can't read this app)" : "")
    }
}
