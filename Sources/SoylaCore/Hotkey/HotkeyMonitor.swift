import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
// OWNER: Agent C (Input/Output).
//
// Listen-only CGEventTap (session level) on flagsChanged + keyDown/keyUp. Detects hold/release of the
// configured HotkeyChoice (fn = .maskSecondaryFn flag; Right ⌥/⌘/⌃ via keycodes 61/54/62; ⌃⇧Space; F13).
// Edges go into HotkeyReducer (B2 gestures: hold / double-press lock / ESC); see HotkeyMonitor below.
// Re-enables itself on .tapDisabledByTimeout / .tapDisabledByUserInput. Callbacks are delivered on the main thread.
//
// macOS wrinkles (cannot be fixed in code):
// - fn (🌐): unless System Settings → Keyboard → "Press 🌐 key to" = Do Nothing, tapping fn also opens the
//   emoji picker / starts Apple Dictation / switches input source. A listen-only tap cannot swallow that.
// - Wispr Flow (and maybe Amical) also hold fn — quit them while testing, or both apps fire.
// - TCC: Accessibility / Input Monitoring grants are tied to the code signature. An ad-hoc signed binary
//   (`codesign -s -`, or the linker-signed `swift build` product) gets a new identity on each rebuild, so the
//   toggle may show ON while the tap still fails. Toggle off/on, or `tccutil reset Accessibility ai.soyla.app`.
// - Threading: by default the tap source goes on the MAIN run loop and callbacks go to DispatchQueue.main
//   (the GUI app runs NSApplication there). The CLI cannot use that: main.swift blocks the main thread in
//   `sem.wait()`, so HotkeyCLI uses the internal `runLoop` / `callbackQueue` overrides (see HotkeyCLI.swift).

/// Pure matcher: event → edge. No CoreGraphics objects, so it is unit-testable.
struct HotkeyMatcher {
    enum Kind { case flagsChanged, keyDown, keyUp }
    enum Edge: Equatable { case down, up }

    // Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK) — tell right from left.
    static let deviceLeftCtrl: UInt64 = 0x0000_0001
    static let deviceLeftCmd: UInt64 = 0x0000_0008
    static let deviceRightCmd: UInt64 = 0x0000_0010
    static let deviceLeftAlt: UInt64 = 0x0000_0020
    static let deviceRightAlt: UInt64 = 0x0000_0040
    static let deviceRightCtrl: UInt64 = 0x0000_2000

    static let keySpace: Int64 = 49
    static let keyF13: Int64 = 105
    static let keyRightOption: Int64 = 61
    static let keyRightCommand: Int64 = 54
    static let keyRightControl: Int64 = 62

    var choice: HotkeyChoice { didSet { if choice != oldValue { isDown = false } } }
    private(set) var isDown = false

    /// Keycodes whose key-down/up also toggles the secondary-fn bit on Apple keyboards (arrows, Home/End, PgUp/PgDn, fwd-Delete).
    static let fnLikeKeys: Set<Int64> = [123, 124, 125, 126, 115, 119, 116, 121, 117]

    var isModifierHold: Bool { switch choice { case .fn, .rightOption, .rightCommand, .rightControl: return true; default: return false } }

    /// Force the released state; returns true if it was held (caller emits .up or cancel).
    mutating func release() -> Bool { defer { isDown = false }; return isDown }

    init(choice: HotkeyChoice) { self.choice = choice }

    /// Returns an edge only on a state change (debounced: one .down per hold, one .up per release).
    mutating func handle(kind: Kind, keyCode: Int64, flags: UInt64, isAutorepeat: Bool) -> Edge? {
        if isAutorepeat { return nil }
        let pressed: Bool?
        switch choice {
        case .fn:
            guard kind == .flagsChanged, !Self.fnLikeKeys.contains(keyCode) else { return nil }
            pressed = (flags & CGEventFlags.maskSecondaryFn.rawValue) != 0
        case .rightOption:
            pressed = Self.rightModifier(kind, keyCode, flags, key: Self.keyRightOption,
                                         generic: CGEventFlags.maskAlternate.rawValue,
                                         right: Self.deviceRightAlt, left: Self.deviceLeftAlt)
        case .rightCommand:
            pressed = Self.rightModifier(kind, keyCode, flags, key: Self.keyRightCommand,
                                         generic: CGEventFlags.maskCommand.rawValue,
                                         right: Self.deviceRightCmd, left: Self.deviceLeftCmd)
        case .rightControl:
            pressed = Self.rightModifier(kind, keyCode, flags, key: Self.keyRightControl,
                                         generic: CGEventFlags.maskControl.rawValue,
                                         right: Self.deviceRightCtrl, left: Self.deviceLeftCtrl)
        case .ctrlShiftSpace:
            guard keyCode == Self.keySpace else { return nil }
            switch kind {
            case .keyDown:
                let need = CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
                pressed = (flags & need) == need ? true : nil
            case .keyUp: pressed = false   // space up ends the hold even if ⌃/⇧ were released first
            case .flagsChanged: pressed = nil
            }
        case .f13:
            guard keyCode == Self.keyF13 else { return nil }
            switch kind {
            case .keyDown: pressed = true
            case .keyUp: pressed = false
            case .flagsChanged: pressed = nil
            }
        }
        guard let p = pressed, p != isDown else { return nil }
        isDown = p
        return p ? .down : .up
    }

    /// Right-side modifier: only flagsChanged for that exact keycode counts. Prefer the device-dependent right
    /// bit; if the event has no device bits for this modifier at all (some virtual keyboards), use the generic mask.
    private static func rightModifier(_ kind: Kind, _ keyCode: Int64, _ flags: UInt64, key: Int64,
                                      generic: UInt64, right: UInt64, left: UInt64) -> Bool? {
        guard kind == .flagsChanged, keyCode == key else { return nil }
        if flags & generic == 0 { return false }
        if flags & (right | left) == 0 { return true }
        return flags & right != 0
    }
}

// SAFETY (unchecked Sendable, below): every mutable field is guarded by `lock`; the CGEventTap C callback reaches
// `self` through an unretained refcon and must run synchronously on the tap's run loop, so this cannot be an actor.
/// Feeds the event tap into `HotkeyReducer` and runs what it decides.
///
/// - Main tap: listen-only (never delays typing), on `runLoop` (main by default). It only copies fields and
///   steps the reducer under a lock; callbacks go out with `callbackQueue.async` (never `main.sync`).
/// - ESC tap: a second, *active* tap on keyDown only, installed while the reducer says the pill is visible
///   (`.escCapture(true)`) and removed on every exit (`.escCapture(false)`), so ESC is never swallowed system-wide
///   (Handy / VoiceInk #983). Needs Accessibility; without it ESC still cancels but is not consumed.
/// - Events posted by `Paster` (`eventSourceUserData == Paster.syntheticEventTag`) are ignored.
/// - Watchdog: every 30 s `CGEvent.tapIsEnabled`, re-enable or recreate; recreate on wake and on session
///   reactivation (Hex: tap silently dead after sleep). After each re-enable the held state is re-read from
///   `CGEventSource.keyState`, so a key-up missed while the tap was off ends the hold.
public final class HotkeyMonitor: @unchecked Sendable {
    public typealias Action = HotkeyReducer.Action
    public typealias Event = HotkeyReducer.Event

    /// Reducer actions for the app, in order, on `callbackQueue`. `.escCapture`, `.schedule` and
    /// `.consumeEscape` are handled here and not delivered.
    public var onAction: (@Sendable (Action) -> Void)?
    /// Every reducer step (event, all actions, time). Internal: `soyla hotkey-test` prints it, and the app drives
    /// Home's key cap from its `.down` / `.up` / `.reset` edges (`PanelModel.noteHotkeyEvent`). One slot: don't
    /// reassign it on the app's monitor.
    var onTrace: (@Sendable (Event, [Action], Double) -> Void)?

    /// Run loop the tap sources are added to; nil → main run loop. Internal: only the CLI overrides it.
    var runLoop: CFRunLoop?
    /// Queue callbacks are delivered on. Internal: only the CLI overrides it (its main thread is blocked).
    var callbackQueue: DispatchQueue = .main
    /// Monotonic clock in seconds (the reducer's time base).
    var now: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }

    static let keyEscape: Int64 = 53
    static let watchdogInterval: Double = 30

    private let lock = NSLock()
    private var matcher: HotkeyMatcher
    private var reducer = HotkeyReducer()
    private var running = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var installedOn: CFRunLoop?
    private var escTap: CFMachPort?
    private var escSource: CFRunLoopSource?
    private let timerQueue = DispatchQueue(label: "soyla.hotkey.timers")
    private var watchdog: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var _lastEventAt: Date?
    /// When the tap last received any key event: proof macOS delivers keys (onboarding step 2c, Hex #250).
    public var lastEventAt: Date? { lock.lock(); defer { lock.unlock() }; return _lastEventAt }

    public init(choice: HotkeyChoice) { matcher = HotkeyMatcher(choice: choice) }

    deinit { stop() }

    /// Current gesture state (tests / diagnostics).
    public var state: HotkeyReducer.State { lock.lock(); defer { lock.unlock() }; return reducer.state }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        if running { return }
        // macOS 26 observed: with NEITHER permission, tapCreate still returns a tap — it just never receives
        // key events. So a non-nil tap is not proof it works; require at least one grant (either suffices
        // for a listen-only tap).
        let ax = Permissions.accessibilityTrusted(prompt: false)
        let im = Permissions.inputMonitoring(prompt: false)
        guard (ax || im), installMainTap() else {
            throw SoylaError.permission("""
                keyboard event tap unavailable (Accessibility: \(ax ? "granted" : "MISSING"), \
                Input Monitoring: \(im ? "granted" : "MISSING")). Grant both to this binary (or to the terminal app \
                running it) in System Settings → Privacy & Security → Accessibility and → Input Monitoring, then \
                relaunch. If they already show ON after a rebuild, toggle them off/on (the ad-hoc signature changed) \
                or run `tccutil reset Accessibility \(Soyla.bundleId)`.
                """)
        }
        running = true
        startWatchdog()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] n in
                self?.timerQueue.async { [weak self, why = n.name.rawValue] in self?.recreate(why: why) }
            })
        }
    }

    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        watchdog?.cancel(); watchdog = nil
        let obs = observers; observers = []
        removeEscTap()
        removeMainTap()
        _ = matcher.release()
        if wasRunning { feed(.reset) }        // a hold/lock in progress is sent, a hidden tap dropped
        lock.unlock()
        for o in obs { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    /// Pipeline → reducer (`.processingStarted`, `.pipelineIdle`). Safe from any thread.
    public func send(_ event: Event) {
        lock.lock(); defer { lock.unlock() }
        _ = feed(event)
    }

    /// Swap the matcher without recreating the tap. A gesture in progress is finished (`.reset`).
    public func update(choice: HotkeyChoice) {
        lock.lock(); defer { lock.unlock() }
        guard matcher.choice != choice else { return }
        matcher.choice = choice
        _ = feed(.reset)
    }

    // MARK: reducer plumbing (lock held)

    /// Steps the reducer and runs its actions. Returns true if this ESC must be swallowed.
    @discardableResult
    private func feed(_ event: Event) -> Bool {
        let t = now()
        let actions = reducer.step(event, now: t)
        if let trace = onTrace { callbackQueue.async { trace(event, actions, t) } }
        var consume = false
        for a in actions {
            switch a {
            case .consumeEscape: consume = true
            case .escCapture(let on): if on { installEscTap() } else { removeEscTap() }
            case .schedule(let at):
                timerQueue.asyncAfter(deadline: .now() + max(0, at - t) + 0.001) { [weak self] in self?.send(.timer) }
            default:
                // async inside the lock keeps the actions of concurrent steps in order.
                if let cb = onAction { callbackQueue.async { cb(a) } }
            }
        }
        return consume
    }

    // MARK: taps (lock held)

    @discardableResult
    private func installMainTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        // Non-capturing C callback: `self` travels through userInfo, unretained — the owner keeps the monitor
        // alive, and stop()/deinit tears the tap down before self goes away.
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let rl = runLoop ?? CFRunLoopGetMain()
        CFRunLoopAddSource(rl, src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port; source = src; installedOn = rl
        return true
    }

    private func removeMainTap() {
        let port = tap, src = source, rl = installedOn
        tap = nil; source = nil
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let src, let rl { CFRunLoopRemoveSource(rl, src, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
    }

    private func installEscTap() {
        guard escTap == nil, running else { return }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return me.handleEscape(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        // Active tap (can swallow ESC): needs Accessibility. Without it ESC still cancels via the main tap.
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: 1 << CGEventType.keyDown.rawValue, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log("ESC tap unavailable (Accessibility missing?) — ESC cancels but is not swallowed")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(escRunLoop, src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        escTap = port; escSource = src
    }

    /// Disabled at once; the source is removed on the next run-loop turn (we may be inside its own callback).
    private func removeEscTap() {
        guard let port = escTap else { return }
        let src = escSource
        escTap = nil; escSource = nil
        CGEvent.tapEnable(tap: port, enable: false)
        let rl = escRunLoop
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) {
            if let src { CFRunLoopRemoveSource(rl, src, .commonModes) }
            CFMachPortInvalidate(port)
        }
        CFRunLoopWakeUp(rl)
    }

    // MARK: event handling (tap thread)

    private static func isSynthetic(_ e: CGEvent) -> Bool {
        e.getIntegerValueField(.eventSourceUserData) == Paster.syntheticEventTag
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let kind: HotkeyMatcher.Kind
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            lock.lock()
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            resyncHeldState()
            lock.unlock()
            log("hotkey tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input") — re-enabled")
            return
        case .flagsChanged: kind = .flagsChanged
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: return
        }
        if Self.isSynthetic(event) { return }                  // our own ⌘V
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = kind == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        lock.lock(); defer { lock.unlock() }
        _lastEventAt = Date()   // proof macOS delivers keys (onboarding step 2c)
        if kind == .keyDown, keyCode == Self.keyEscape {
            // The active ESC tap owns ESC while it is installed; otherwise cancel without swallowing.
            if escTap == nil, !isRepeat { feed(.escape) }
            return
        }
        // Any ordinary key while a modifier-only hotkey is involved (fn+←, Right⌘+C, Right ⌥ typing on uz/ru
        // layouts) is a shortcut, not dictation. The reducer decides what that means in the current state.
        if kind == .keyDown, !isRepeat, matcher.isModifierHold, reducer.state != .idle {
            feed(.otherKey)
            return
        }
        switch matcher.handle(kind: kind, keyCode: keyCode, flags: event.flags.rawValue, isAutorepeat: isRepeat) {
        case .down?: feed(.down)
        case .up?: feed(.up)
        case nil: break
        }
    }

    /// ESC tap callback. Returns true to swallow the event.
    private func handleEscape(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); if let p = escTap { CGEvent.tapEnable(tap: p, enable: true) }; lock.unlock()
            return false
        }
        guard type == .keyDown, !Self.isSynthetic(event),
              event.getIntegerValueField(.keyboardEventKeycode) == Self.keyEscape else { return false }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return false }
        lock.lock(); defer { lock.unlock() }
        guard escTap != nil else { return false }
        return feed(.escape)
    }

    // MARK: watchdog / recreate

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + Self.watchdogInterval, repeating: Self.watchdogInterval)
        t.setEventHandler { [weak self] in self?.checkTap() }
        t.resume()
        watchdog = t
    }

    private func checkTap() {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        guard let port = tap else {                      // a recreate (e.g. right at wake) failed: retry now
            if installMainTap() { log("hotkey tap re-installed by the watchdog"); resyncHeldState() }
            return
        }
        if CGEvent.tapIsEnabled(tap: port) { return }
        CGEvent.tapEnable(tap: port, enable: true)
        if CGEvent.tapIsEnabled(tap: port) {
            log("hotkey tap was disabled — re-enabled by the watchdog")
        } else {
            log("hotkey tap could not be re-enabled — recreating")
            recreateLocked()
        }
        resyncHeldState()
    }

    private func recreate(why: String) {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        log("hotkey tap recreated (\(why))")
        recreateLocked()
        resyncHeldState()
    }

    private func recreateLocked() {
        let hadEsc = escTap != nil
        removeEscTap()
        removeMainTap()
        if !installMainTap() { log("hotkey tap recreate FAILED — will retry in \(Int(Self.watchdogInterval)) s") }
        if hadEsc { installEscTap() }
    }

    /// After the tap was off we may have missed the key-up: compare with the live key state (lock held).
    private func resyncHeldState() {
        guard matcher.isDown, !Self.physicallyHeld(matcher.choice) else { return }
        _ = matcher.release()
        feed(.up)
    }

    static func physicallyHeld(_ choice: HotkeyChoice) -> Bool {
        func key(_ k: Int64) -> Bool { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(k)) }
        switch choice {
        case .fn:
            return key(63) || CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        case .rightOption: return key(HotkeyMatcher.keyRightOption)
        case .rightCommand: return key(HotkeyMatcher.keyRightCommand)
        case .rightControl: return key(HotkeyMatcher.keyRightControl)
        case .ctrlShiftSpace: return key(HotkeyMatcher.keySpace)
        case .f13: return key(HotkeyMatcher.keyF13)
        }
    }

    private func log(_ s: String) { FileHandle.standardError.write(Data("soyla: \(s)\n".utf8)) }
}

public enum Permissions {
    /// AXIsProcessTrustedWithOptions; with prompt == true macOS shows the "grant Accessibility" dialog.
    public static func accessibilityTrusted(prompt: Bool) -> Bool {
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt (avoids the global var).
        let opts = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Input Monitoring (kTCCServiceListenEvent). CGRequestListenEventAccess prompts / adds the binary to the list.
    public static func inputMonitoring(prompt: Bool) -> Bool {
        if CGPreflightListenEventAccess() { return true }
        return prompt ? CGRequestListenEventAccess() : false
    }
}

extension HotkeyMonitor {
    /// The CLI's own tap thread when it set `runLoop`; in the app a dedicated thread, never main (see EscTapThread).
    fileprivate var escRunLoop: CFRunLoop { runLoop ?? EscTapThread.runLoop }
}
