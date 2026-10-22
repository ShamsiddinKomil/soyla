import Testing
@testable import SoylaCore

/// One test per gesture-table row, with the timing edges (0.49/0.51 s hold, release + 0.6 s window).
@Suite struct HotkeyReducerTests {
    typealias R = HotkeyReducer
    typealias A = HotkeyReducer.Action

    /// Reducer + a fake clock that fires scheduled ticks in order before each event.
    struct Sim {
        var r = R()
        var timers: [Double] = []
        var log: [(Double, R.Event, [A])] = []

        @discardableResult
        mutating func at(_ t: Double, _ e: R.Event) -> [A] {
            fire(until: t)
            return step(e, t)
        }
        mutating func fire(until t: Double) {
            while let due = timers.min(), due <= t { timers.removeAll { $0 == due }; step(.timer, due) }
        }
        @discardableResult
        mutating func step(_ e: R.Event, _ t: Double) -> [A] {
            let a = r.step(e, now: t)
            for case .schedule(let at) in a { timers.append(at) }
            log.append((t, e, a))
            return a
        }
        var all: [A] { log.flatMap(\.2) }
        func has(_ a: A) -> Bool { all.contains(a) }
    }

    // Row 1: hold ≥ 0.5 s → push-to-talk.
    @Test func holdAtOrAboveThresholdSends() {
        var s = Sim()
        #expect(s.at(0, .down) == [.startRecording, .schedule(at: 0.1)])
        #expect(s.at(0.51, .up) == [.stopAndSend])
        #expect(s.r.state == .processing(noticed: false))
        #expect(s.has(.reveal))
    }

    // Row 2: tap < 0.5 s → silent no-op; capture keeps running until the double-press window closes.
    @Test func tapBelowThresholdIsSilentAndDroppedAtWindowEnd() {
        var s = Sim()
        s.at(0, .down)
        let up = s.at(0.49, .up)
        #expect(!up.contains(.stopAndSend))
        #expect(up.contains(.conceal))                  // it had been revealed at 0.1 s
        #expect(s.r.state == .tapped(upAt: 0.49))
        s.fire(until: 1.08)
        #expect(s.r.state == .tapped(upAt: 0.49))       // still waiting for a second press
        s.fire(until: 1.1)
        #expect(s.r.state == .idle)
        #expect(s.log.last?.2 == [.cancelRecording(.tap)])
        #expect(!s.has(.stopAndSend) && !s.has(.lock))
    }

    // "Show nothing until 0.1 s": a quick tap never reveals the pill.
    @Test func pillStaysHiddenBefore100ms() {
        var s = Sim()
        s.at(0, .down)
        #expect(s.r.step(.timer, now: 0.09) == [])         // early tick: nothing
        s.at(0.08, .up)
        s.fire(until: 1)
        #expect(!s.has(.reveal) && !s.has(.conceal))
        #expect(!s.all.contains(.escCapture(true)))          // ESC never captured for an invisible tap
        var h = Sim()
        h.at(0, .down)
        h.fire(until: 0.1)
        #expect(h.log.last?.2 == [.reveal, .escCapture(true)])
    }

    // Row 3: double press within 0.5 s → Locked; the same recording continues (no second startRecording).
    @Test func doublePressWithinWindowLocks() {
        var s = Sim()
        s.at(0, .down); s.at(0.1, .up)
        #expect(s.at(0.49, .down) == [.lock, .schedule(at: 0.99), .escCapture(true)])
        #expect(s.r.state == .locked(keyDown: true))
        #expect(s.all.filter { $0 == .startRecording }.count == 1)
        #expect(s.at(0.6, .up) == [])                       // releasing the locking press keeps it locked
        s.fire(until: 2)                                    // stale window tick is harmless
        #expect(s.r.state == .locked(keyDown: false))
    }

    @Test func secondPressAfterWindowIsAFreshPress() {
        // Tick arrived first (normal case).
        var s = Sim()
        s.at(0, .down); s.at(0.1, .up)
        let a = s.at(0.95, .down)
        #expect(s.log.contains { $0.1 == .timer && $0.2 == [.cancelRecording(.tap)] })
        #expect(a == [.startRecording, .schedule(at: 1.05)])
        #expect(s.r.state == .held(downAt: 0.95, revealed: false))
        // Tick late (press handled first): same outcome, in one step.
        var r = R()
        _ = r.step(.down, now: 0); _ = r.step(.up, now: 0.1)
        #expect(r.step(.down, now: 0.95) == [.cancelRecording(.tap), .startRecording, .schedule(at: 1.05)])
    }

    // Row 4: press while locked → stop and paste.
    @Test func pressWhileLockedSends() {
        var s = Sim()
        s.at(0, .down); s.at(0.1, .up); s.at(0.3, .down); s.at(0.4, .up)
        #expect(s.at(10, .down) == [.stopAndSend])
        #expect(s.at(10.1, .up) == [])
        #expect(s.r.state == .processing(noticed: false))
        #expect(s.at(12, .pipelineIdle) == [.escCapture(false)])
        #expect(s.r.state == .idle)
    }

    // Row 5: any other key while held → abort, nothing sent (fn+F-keys, Right ⌥ typing).
    @Test func otherKeyWhileHeldAborts() {
        var s = Sim()
        s.at(0, .down)
        #expect(s.at(0.05, .otherKey) == [.cancelRecording(.otherKey)])  // fn as a modifier (fn+←): never shown
        #expect(s.at(0.2, .up) == [])
        var l = Sim()
        l.at(0, .down)
        #expect(l.at(1.0, .otherKey) == [.cancelRecording(.otherKey), .escCapture(false)])
        #expect(l.at(1.5, .up) == [])                                    // its release does not send
        #expect(!l.has(.stopAndSend))
    }

    @Test func otherKeyWhileLockedIsTyping() {
        var s = Sim()
        s.at(0, .down); s.at(0.1, .up); s.at(0.3, .down); s.at(0.4, .up)
        #expect(s.at(2, .otherKey) == [])
        #expect(s.r.state == .locked(keyDown: false))
    }

    // Real timings from the owner's hotkey-test trace (2026-10-17), ms since the first press.
    @Test func ownerTraceDoubleTapsLock() {
        // 0.34 s tap (was sent as an empty dictation under the 0.3 s threshold), second press 0.53 s after release.
        var a = Sim()
        a.at(0, .down); a.at(0.344, .up)
        #expect(a.at(0.874, .down) == [.lock, .schedule(at: 1.374), .escCapture(true)])
        // 0.14 s tap, second press 0.49 s after release (missed the old 0.5 s-from-press window by 0.12 s).
        var b = Sim()
        b.at(0, .down); b.at(0.136, .up)
        #expect(b.at(0.623, .down) == [.lock, .schedule(at: 1.123), .escCapture(true)])
        // 0.41 s tap, 0.59 s gap.
        var c = Sim()
        c.at(0, .down); c.at(0.41, .up)
        #expect(c.at(1.0, .down) == [.lock, .schedule(at: 1.5), .escCapture(true)])
    }

    // 2026-10-19 log: second presses 0.62–0.65 s after release just missed the 0.6 s window. They locked under the
    // 0.8 s window; the owner then chose 0.6 s again (accidental locks were worse), so this gap is a fresh press.
    @Test func ownerSlowerDoubleTapLocks() {
        var s = Sim()
        s.at(0, .down); s.at(0.133, .up)
        #expect(!s.at(0.758, .down).contains(.lock))
    }

    // Owner, 2026-10-19 (manual test U4): tap, wait, then press-and-hold a word must send, not lock.
    @Test func tapThenHoldSendsOnRelease() {
        var s = Sim()
        s.at(0, .down); s.at(0.1, .up)
        #expect(s.at(0.4, .down).contains(.lock))          // looks like a double tap at first
        s.fire(until: 0.95)
        #expect(s.has(.unlock))                             // held past 0.5 s: back to a normal hold
        #expect(s.at(2.0, .up) == [.stopAndSend])
        #expect(s.r.state == .processing(noticed: false))
        var q = Sim()                                       // a quick second press still locks
        q.at(0, .down); q.at(0.1, .up); q.at(0.4, .down); q.at(0.55, .up)
        q.fire(until: 2)
        #expect(!q.has(.unlock) && q.r.state == .locked(keyDown: false))
    }

    // Owner, 2026-10-19: a second press 0.65 s after the tap no longer locks (window 0.8 → 0.6 s).
    @Test func secondPressAfter600msIsAFreshPress() {
        var s = Sim()
        s.at(0, .down); s.at(0.1, .up)
        #expect(!s.at(0.75, .down).contains(.lock))
        #expect(s.r.state == .held(downAt: 0.75, revealed: false))
    }

    // Manual test U1: holding fn again while the last note is still processing records once it is free.
    @Test func pressHeldThroughProcessingStartsWhenIdle() {
        var s = Sim()
        s.at(0, .down); s.at(1, .up)
        #expect(s.at(1.3, .down) == [.busyNotice])
        #expect(s.at(2.0, .pipelineIdle).starts(with: [.startRecording, .schedule(at: 2.1)]))
        #expect(s.at(4.0, .up) == [.stopAndSend])
        var r = Sim()                                       // released before it was free: nothing starts
        r.at(0, .down); r.at(1, .up); r.at(1.3, .down); r.at(1.4, .up)
        #expect(r.at(2.0, .pipelineIdle) == [.escCapture(false)])
        #expect(r.r.state == .idle)
    }

    // 2026-10-19 log: a third press 0.6–0.8 s after locking stopped it before anything was said.
    @Test func pressRightAfterLockingIsIgnored() {
        var s = Sim()
        s.at(0, .down); s.at(0.1, .up); s.at(0.3, .down); s.at(0.4, .up)
        #expect(s.at(1.0, .down) == [])
        #expect(s.at(1.1, .up) == [])
        #expect(s.r.state == .locked(keyDown: false))
        #expect(s.at(1.4, .down) == [.stopAndSend])   // ≥ 1 s after the lock: stop as usual
        var e = Sim()
        e.at(0, .down); e.at(0.1, .up); e.at(0.3, .down); e.at(0.4, .up)
        #expect(e.at(0.6, .escape).contains(.cancelRecording(.escape)))   // ESC still cancels at once
    }

    @Test func releaseEchoKeyDoesNotDropTheTap() {
        var s = Sim()
        s.at(0, .down); s.at(0.22, .up)
        #expect(s.at(0.221, .otherKey) == [])          // macOS key event right at the fn release
        #expect(s.r.state == .tapped(upAt: 0.22))
        #expect(s.at(0.6, .down) == [.lock, .schedule(at: 1.1), .escCapture(true)])
        var t = Sim()
        t.at(0, .down); t.at(0.1, .up)
        #expect(t.at(0.16, .otherKey) == [.cancelRecording(.tap)])   // a real key after the echo window still drops it
    }

    @Test func otherKeyDuringTapWindowDropsTheTap() {
        var s = Sim()
        s.at(0, .down); s.at(0.1, .up)
        #expect(s.at(0.2, .otherKey) == [.cancelRecording(.tap)])
        #expect(s.r.state == .idle)
    }

    // Row 6: press while processing → one notice, rejected (not queued).
    @Test func pressWhileProcessingGivesOneNotice() {
        var s = Sim()
        s.at(0, .down); s.at(1, .up)
        #expect(s.at(1.5, .down) == [.busyNotice])
        #expect(s.at(1.6, .up) == [])
        #expect(s.at(1.8, .down) == [])                       // one notice per processing period
        s.at(1.9, .up)                                        // released before it was free: not queued
        #expect(!s.log.dropFirst(2).contains { $0.2.contains(.startRecording) })
        #expect(s.at(3, .pipelineIdle) == [.escCapture(false)])
        #expect(s.at(4, .down).first == .startRecording)      // free again
    }

    // Row 7: ESC while recording / processing → cancel, consumed.
    @Test func escapeWhileRecordingCancelsAndIsConsumed() {
        var s = Sim()
        s.at(0, .down)
        #expect(s.at(1, .escape) == [.cancelRecording(.escape), .consumeEscape, .escCapture(false)])
        #expect(s.at(1.2, .up) == [])
        var l = Sim()
        l.at(0, .down); l.at(0.1, .up); l.at(0.3, .down)
        #expect(l.at(5, .escape) == [.cancelRecording(.escape), .consumeEscape, .escCapture(false)])
    }

    @Test func escapeWhileProcessingCancelsRequest() {
        var s = Sim()
        s.at(0, .down); s.at(1, .up)
        #expect(s.at(2, .escape) == [.cancelProcessing, .consumeEscape, .escCapture(false)])
        #expect(s.r.state == .idle)
        #expect(s.at(2.5, .pipelineIdle) == [])               // the pipeline's own idle report is harmless
    }

    // ESC in idle (Claude Code's terminal, vim…) is never touched.
    @Test func escapeInIdleIsPassedThrough() {
        var r = R()
        #expect(r.step(.escape, now: 0) == [])
        #expect(r.state == .idle)
        var s = Sim()                                          // and after a finished dictation
        s.at(0, .down); s.at(1, .up); s.at(2, .pipelineIdle)
        #expect(s.at(3, .escape) == [])
    }

    @Test func escapeWhileInvisibleCancelsButIsNotConsumed() {
        var s = Sim()
        s.at(0, .down)
        #expect(s.at(0.05, .escape) == [.cancelRecording(.escape)])    // < 0.1 s: pill not shown yet
        var t = Sim()
        t.at(0, .down); t.at(0.1, .up)
        #expect(t.at(0.2, .escape) == [.cancelRecording(.escape)])     // in the tap window
    }

    // Lock → walk away → the pipeline's 55 s hard stop still transcribes (reducer just follows).
    @Test func hardStopWhileLockedGoesToProcessing() {
        var s = Sim()
        s.at(0, .down); s.at(0.1, .up); s.at(0.3, .down); s.at(0.4, .up)
        #expect(s.at(55, .processingStarted) == [])
        #expect(s.r.state == .processing(noticed: false))
        #expect(s.at(58, .pipelineIdle) == [.escCapture(false)])
        var h = Sim()                                          // hard stop while still holding: release ignored
        h.at(0, .down)
        h.at(55, .processingStarted)
        #expect(h.at(56, .up) == [])
        #expect(!h.has(.stopAndSend))
    }

    @Test func lateIdleEchoDoesNotEndANewHold() {
        var s = Sim()
        s.at(0, .down)
        #expect(s.at(0.05, .pipelineIdle) == [])
        #expect(s.r.state == .held(downAt: 0, revealed: false))
        var t = Sim()
        t.at(0, .down); t.at(0.1, .up)
        #expect(t.at(0.15, .pipelineIdle) == [])
        #expect(t.r.state == .tapped(upAt: 0.1))
    }

    @Test func startFailureWhileLockedReturnsToIdle() {
        var s = Sim()
        s.at(0, .down); s.at(0.1, .up); s.at(0.3, .down)
        #expect(s.at(0.5, .pipelineIdle) == [.escCapture(false)])
        #expect(s.r.state == .idle)
    }

    @Test func resetFinishesSensibly() {
        var a = R(); _ = a.step(.down, now: 0)
        #expect(a.step(.reset, now: 0.51) == [.stopAndSend])            // never revealed: no ESC capture to drop
        var b = R(); _ = b.step(.down, now: 0)
        #expect(b.step(.reset, now: 0.1) == [.cancelRecording(.tap)])
        var c = R(); _ = c.step(.down, now: 0); _ = c.step(.up, now: 0.1); _ = c.step(.down, now: 0.2)
        #expect(c.step(.reset, now: 3).first == .stopAndSend)
        #expect(c.state == .processing(noticed: false))
        #expect(c.step(.reset, now: 4) == [.escCapture(false)])
        #expect(c.state == .idle)
    }

    /// ESC capture is on exactly while the pill is visible and switched off on every exit path: fuzz random
    /// event sequences and check the emitted toggles track the state, alternate, and end off in idle.
    @Test func escapeCaptureNeverLeaks() {
        let events: [R.Event] = [.down, .up, .otherKey, .escape, .timer, .processingStarted, .pipelineIdle, .reset]
        var seed: UInt64 = 0x5EED
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        for _ in 0..<300 {
            var r = R()
            var on = false
            var t = 0.0
            for _ in 0..<40 {
                t += Double(next() % 700) / 1000
                let e = events[Int(next() % UInt64(events.count))]
                let acts = r.step(e, now: t)
                for case .escCapture(let v) in acts { #expect(v != on); on = v }
                #expect(on == R.capturesEscape(r.state))
                if acts.contains(.consumeEscape) { #expect(e == .escape) }
                if r.state == .idle { #expect(!on) }
            }
        }
    }
}

@Suite struct GesturePillTests {
    @MainActor @Test func lockedCaptionAndBusyNotice() {
        let m = PanelModel()
        m.hotkeyLabel = HotkeyChoice.fn.label
        m.phase = .recording
        m.locked = true
        #expect(m.caption == nil)                      // the lock glyph is the hint, no words
        m.warn = true; m.elapsedSec = 50; m.hardStopSec = 55
        #expect(m.caption == "5 s left")
        m.hotkeyLabel = HotkeyChoice.rightOption.label
        m.warn = false
        #expect(m.caption == nil)
        m.reset()
        #expect(!m.locked && m.notice == nil)
        m.phase = .transcribing
        m.notice = "Still working on your last note"
        #expect(m.caption == "Still working on your last note")
        m.notice = nil
        #expect(m.caption == nil)
    }
}
