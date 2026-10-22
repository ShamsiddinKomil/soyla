import Foundation
import os
import Testing
@testable import SoylaCore

/// The ESC tap is an active tap (macOS waits for it on every key press while the pill is up), so it runs on its own
/// thread's run loop and never waits for a busy main thread (Bluetooth mic start, Keychain dialog).
@Suite struct EscTapThreadTests {
    @Test func runLoopIsNotMain() {
        #expect(EscTapThread.runLoop !== CFRunLoopGetMain())
    }

    @Test func runLoopRunsBlocksOffTheMainThread() {
        let done = DispatchSemaphore(value: 0)
        let offMain = OSAllocatedUnfairLock(initialState: false)
        CFRunLoopPerformBlock(EscTapThread.runLoop, CFRunLoopMode.commonModes.rawValue) {
            offMain.withLock { $0 = !Thread.isMainThread }
            done.signal()
        }
        CFRunLoopWakeUp(EscTapThread.runLoop)
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(offMain.withLock { $0 })
    }

    @Test func sameRunLoopEveryTime() {
        #expect(EscTapThread.runLoop === EscTapThread.runLoop)
    }
}
