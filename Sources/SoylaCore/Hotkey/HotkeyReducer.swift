import Foundation

/// Hotkey gestures as a pure state machine. No clocks, no CoreGraphics, no threads:
/// `step(event, now:)` gets the time from the caller and returns what should happen. `HotkeyMonitor` feeds it
/// edges from the event tap plus timer ticks and pipeline events, and runs the actions.
///
/// | Gesture                              | Result                                                              |
/// |--------------------------------------|---------------------------------------------------------------------|
/// | hold ≥ 0.5 s, release                | push-to-talk → `.stopAndSend`                                       |
/// | tap < 0.5 s                          | silent: recording keeps running hidden until 0.8 s after release,   |
/// |                                      | then `.cancelRecording(.tap)` (may be the first half of a double)   |
/// | second press ≤ 0.6 s after release   | `.lock` (hands-free; the same recording continues, no word lost)    |
/// | …that second press held ≥ 0.5 s      | `.unlock`: a normal hold after all, its release sends               |
/// | press while locked (≥ 1 s after lock)| `.stopAndSend`; an earlier press is ignored                         |
/// | other key while held (modifier keys) | `.cancelRecording(.otherKey)`; a hold < 0.1 s never shows anything  |
/// | press while processing               | `.busyNotice` once per processing period (rejected, not queued);    |
/// |                                      | still held when the pipeline is free → a fresh hold starts          |
/// | ESC while the pill is visible        | cancel + `.consumeEscape`; ESC capture is on only in those states   |
///
/// The pill shows nothing until 0.1 s into a hold (`.reveal`), so taps never flicker it; audio capture starts
/// at key-down regardless (`.startRecording`). ESC capture (`.escCapture(Bool)`) is derived from the state on
/// every transition, so every exit path (idle, cancel, failure, reset) turns it off.
public struct HotkeyReducer: Sendable {
    /// 0.5 s (was 0.3): the owner's natural fn taps measured 0.33–0.45 s and were sent as empty dictations, so the
    /// second tap landed on "busy" (hotkey-test trace, 2026-10-17).
    public static let holdThreshold: Double = 0.5
    /// Counted from the release (was 0.5 s from the first press). Measured release → second press gaps: 0.42–0.6 s
    /// (2026-10-17). 0.8 s (2026-10-19) turned "tap, pause, say a word" into a lock; the owner chose 0.6 s plus
    /// the tap-then-hold rule (`.unlock`).
    public static let doubleTapWindow: Double = 0.6
    /// A press within 1 s of locking is ignored: in the log it was a third tap that stopped the lock 0.6–0.8 s in,
    /// with nothing said yet. ESC still cancels.
    public static let lockGrace: Double = 1.0
    /// 0.1 s: soon enough to feel instant (was 0.2 s), late enough that fn used as a modifier (fn+←, fn+F)
    /// cancels before anything flickers.
    public static let revealDelay: Double = 0.1
    /// macOS sends a key event within ~1 ms of an fn release; it cancelled 3 of ~10 taps (trace 2026-10-17).
    /// A real key pressed within 50 ms of letting go of fn is not a shortcut either.
    public static let releaseEchoWindow: Double = 0.05

    public enum Event: Equatable, Sendable {
        case down, up
        /// A non-hotkey key went down (only reported for modifier-only hotkeys: fn, Right ⌥/⌘/⌃).
        case otherKey
        case escape
        /// A scheduled deadline (`.schedule(at:)`) passed. Stale ticks are harmless.
        case timer
        /// The pipeline started processing on its own (55 s hard stop, click on the pill, Retry).
        case processingStarted
        /// The pipeline is free again (pasted, failed, dropped, cancelled).
        case pipelineIdle
        /// Monitor stopped or the hotkey changed: finish whatever is running sensibly and go idle.
        case reset
    }

    public enum CancelReason: String, Equatable, Sendable { case tap, otherKey, escape }

    public enum Action: Equatable, Sendable {
        /// Key-down: start capture now (hidden; nothing on screen yet).
        case startRecording
        /// 0.2 s into a hold: show the pill.
        case reveal
        /// A tap that had already been revealed (0.1–0.5 s): hide the pill again, capture keeps running.
        case conceal
        /// Double press: hands-free; the pill shows a lock glyph.
        case lock
        /// The locking press was held ≥ `holdThreshold`: drop the lock glyph, it is a normal hold now.
        case unlock
        case stopAndSend
        /// Drop the recording, send nothing, show nothing.
        case cancelRecording(CancelReason)
        /// ESC while transcribing/cleaning: drop the in-flight request.
        case cancelProcessing
        /// "Still working on your last note".
        case busyNotice
        /// Swallow this ESC (only returned for `.escape` while the pill is visible).
        case consumeEscape
        /// Register / unregister the ESC-consuming tap.
        case escCapture(Bool)
        /// Call `step(.timer, now:)` at this time.
        case schedule(at: Double)
    }

    public enum State: Equatable, Sendable {
        case idle
        /// Key is down, recording; `revealed` once 0.2 s passed.
        case held(downAt: Double, revealed: Bool)
        /// Released before `holdThreshold`: still recording (hidden) until `upAt + doubleTapWindow`, waiting for a
        /// second press.
        case tapped(upAt: Double)
        /// Hands-free. `keyDown`: the locking press is still held (its release is ignored).
        case locked(keyDown: Bool)
        case processing(noticed: Bool)
    }

    public private(set) var state: State = .idle
    private var lockedAt = -Double.infinity
    /// Physical key state, so a press held through processing can start once the pipeline is free.
    private var keyHeld = false

    public init() {}

    /// ESC is consumed (and the ESC tap registered) only while the pill is visible: recording or processing.
    public static func capturesEscape(_ s: State) -> Bool {
        switch s {
        case .held(_, let revealed): return revealed
        case .locked, .processing: return true
        case .idle, .tapped: return false
        }
    }

    public mutating func step(_ event: Event, now: Double) -> [Action] {
        let before = state
        if event == .down { keyHeld = true } else if event == .up || event == .reset { keyHeld = false }
        // The fn release's own key event, not a shortcut: the tap stays alive for its second press.
        if event == .otherKey, case .tapped(let up) = state, now - up < Self.releaseEchoWindow { return [] }
        if event == .down, state == .locked(keyDown: false), now - lockedAt < Self.lockGrace { return [] }
        var out = transition(event, now: now)
        let was = Self.capturesEscape(before), isOn = Self.capturesEscape(state)
        if was != isOn { out.append(.escCapture(isOn)) }
        return out
    }

    private mutating func transition(_ event: Event, now: Double) -> [Action] {
        switch (state, event) {
        // MARK: idle
        case (.idle, .down):
            return startHold(now)
        case (.idle, .processingStarted):
            state = .processing(noticed: false); return []
        case (.idle, _):
            return []                                         // ESC in idle: passed through untouched

        // MARK: held
        case (.held(let t0, let revealed), .up):
            if now - t0 >= Self.holdThreshold { state = .processing(noticed: false); return [.stopAndSend] }
            state = .tapped(upAt: now)
            let deadline = now + Self.doubleTapWindow
            return (revealed ? [.conceal] : []) + [.schedule(at: deadline)]
        case (.held(let t0, false), .timer):
            guard now >= t0 + Self.revealDelay else { return [] }
            state = .held(downAt: t0, revealed: true); return [.reveal]
        case (.held(_, let revealed), .escape):
            state = .idle
            return revealed ? [.cancelRecording(.escape), .consumeEscape] : [.cancelRecording(.escape)]
        case (.held, .otherKey):
            state = .idle; return [.cancelRecording(.otherKey)]
        case (.held, .processingStarted):                     // hard stop while still holding: its key-up is ignored
            state = .processing(noticed: false); return []
        case (.held(let t0, _), .reset):
            state = .idle
            return now - t0 >= Self.holdThreshold ? [.stopAndSend] : [.cancelRecording(.tap)]
        case (.held, _):
            // .down (debounced upstream), .timer after reveal, .pipelineIdle: a cancel that belonged to the previous
            // run can land here, and a start failure is resolved by the release (stopAndSend → pipeline reports idle).
            return []

        // MARK: tapped (waiting for a second press)
        case (.tapped(let t0), .down):
            if now - t0 <= Self.doubleTapWindow {
                state = .locked(keyDown: true); lockedAt = now
                return [.lock, .schedule(at: now + Self.holdThreshold)]
            }
            // The window passed but its tick hasn't arrived yet: drop the tap, this is a fresh press.
            return [.cancelRecording(.tap)] + startHold(now)
        case (.tapped(let t0), .timer):
            guard now >= t0 + Self.doubleTapWindow else { return [] }
            state = .idle; return [.cancelRecording(.tap)]
        case (.tapped, .escape):
            state = .idle; return [.cancelRecording(.escape)]  // nothing visible: ESC is not consumed
        case (.tapped, .otherKey), (.tapped, .reset):
            state = .idle; return [.cancelRecording(.tap)]
        case (.tapped, .processingStarted):
            state = .processing(noticed: false); return []
        case (.tapped, _):
            // .up, .pipelineIdle: an idle report here can be the late echo of the previous run's cancel; the
            // window's tick ends the tap anyway.
            return []

        // MARK: locked
        case (.locked(true), .up):
            state = .locked(keyDown: false); return []
        case (.locked(true), .timer):                         // tap, then press-and-hold: push-to-talk after all
            guard now >= lockedAt + Self.holdThreshold else { return [] }
            state = .held(downAt: lockedAt, revealed: true); lockedAt = -Double.infinity; return [.unlock]
        case (.locked(false), .down), (.locked, .reset):
            state = .processing(noticed: false); return [.stopAndSend]
        case (.locked, .escape):
            state = .idle; return [.cancelRecording(.escape), .consumeEscape]
        case (.locked, .processingStarted):                   // click on the pill or the 55 s hard stop
            state = .processing(noticed: false); return []
        case (.locked, .pipelineIdle):                        // recording failed to start, card is showing
            state = .idle; return []
        case (.locked, _):
            return []                                         // other keys: typing while hands-free is fine

        // MARK: processing
        case (.processing(let noticed), .down):
            if noticed { return [] }
            state = .processing(noticed: true); return [.busyNotice]
        case (.processing, .escape):
            state = .idle; return [.cancelProcessing, .consumeEscape]
        case (.processing, .pipelineIdle):
            if keyHeld { return startHold(now) }              // held through processing: record now
            state = .idle; return []
        case (.processing, .reset):
            state = .idle; return []
        case (.processing, _):
            return []
        }
    }

    private mutating func startHold(_ now: Double) -> [Action] {
        state = .held(downAt: now, revealed: false)
        return [.startRecording, .schedule(at: now + Self.revealDelay)]
    }
}

extension HotkeyReducer.CancelReason: CustomStringConvertible {
    public var description: String { rawValue }
}
