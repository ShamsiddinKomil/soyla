import Foundation
import os

/// The run loop of a dedicated, app-lifetime thread that hosts the ESC tap (`HotkeyMonitor`). The ESC tap is an
/// active tap: while it exists macOS waits for its callback on every key press, so it must not sit on the main run
/// loop, where a slow Bluetooth start or a Keychain dialog would delay typing in every app.
enum EscTapThread {
    /// Started on first use. Held in the lock (which is Sendable) because CFRunLoop itself is not marked Sendable,
    /// although CFRunLoop's API is thread-safe.
    private static let box: OSAllocatedUnfairLock<CFRunLoop?> = start()

    static var runLoop: CFRunLoop {
        guard let rl = box.withLockUnchecked({ $0 }) else { fatalError("ESC tap thread did not start") }
        return rl
    }

    private static func start() -> OSAllocatedUnfairLock<CFRunLoop?> {
        let ready = DispatchSemaphore(value: 0)
        let box = OSAllocatedUnfairLock<CFRunLoop?>(uncheckedState: nil)
        let thread = Thread {
            let rl = CFRunLoopGetCurrent()
            // A run loop without sources returns at once; a timer that never fires keeps this one alive.
            let keepAlive = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(rl, keepAlive, .commonModes)
            box.withLockUnchecked { $0 = rl }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "ai.soyla.esc-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return box
    }
}
