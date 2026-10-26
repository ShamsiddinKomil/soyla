import Testing
import Foundation
@testable import SoylaCore

/// D10: `MainTimer` / `MainDelay` replace `DispatchWorkItem` + `DispatchQueue.main.asyncAfter`. These pin the
/// work item's behaviour: cancel before fire never runs, re-arming replaces, the delay is a lower bound, and main-actor
/// tasks run after the current main-thread work in FIFO order.
@MainActor @Suite(.serialized) struct MainTimerTests {
    /// What the bodies did (main-actor box: closures may not mutate captured locals).
    @MainActor final class Box { var log: [String] = []; var at: [Duration] = [] }

    /// Waits on the main actor (the main queue keeps draining meanwhile).
    func wait(_ sec: Double) async { try? await Task.sleep(for: .seconds(sec)) }
    /// Holds the main thread without yielding it (synchronous, so no queued main work runs meanwhile).
    func blockMain(_ sec: Double) { Thread.sleep(forTimeInterval: sec) }
    /// Waits until `done` holds, up to `limit` seconds. A loaded first run after a build can delay main by hundreds of
    /// ms, so "has it fired?" waits for the event instead of a fixed time (owner approved, 2026-10-26).
    func until(_ limit: Double = 3, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(limit)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func firesOnceAfterTheDelay() async {
        let t = MainTimer()
        let clock = SuspendingClock()
        let start = clock.now
        let b = Box()
        t.schedule(after: 0.05) { b.at.append(clock.now - start) }
        #expect(t.isArmed)
        await until { !b.at.isEmpty }
        await wait(0.1)   // and not a second time
        #expect(b.at.count == 1)
        #expect((b.at.first ?? .zero) >= .milliseconds(50))
        #expect(!t.isArmed)
    }

    @Test func cancelBeforeFireNeverRuns() async {
        let t = MainTimer()
        let b = Box()
        t.schedule(after: 0.05) { b.log.append("ran") }
        t.cancel()
        #expect(!t.isArmed)
        await wait(0.3)
        #expect(b.log.isEmpty)
    }

    /// The sleep is over and the continuation is queued, but main is busy; a cancel in that window still wins
    /// (a cancelled DispatchWorkItem that was already due never ran either).
    @Test func cancelAfterTheDelayButBeforeMainResumesNeverRuns() async {
        let t = MainTimer()
        let b = Box()
        t.schedule(after: 0.02) { b.log.append("ran") }
        blockMain(0.15)   // past the deadline: the continuation is queued, main can't run it
        t.cancel()
        await wait(0.3)
        #expect(b.log.isEmpty)
    }

    @Test func rearmReplacesTheOldOne() async {
        let t = MainTimer()
        let clock = SuspendingClock()
        let b = Box()
        t.schedule(after: 0.5) { b.log.append("first") }
        await Task.yield()
        let rearmed = clock.now
        t.schedule(after: 0.1) { b.log.append("second"); b.at.append(clock.now - rearmed) }
        await until { !b.log.isEmpty }
        await wait(0.6)   // past the first one's deadline: it must not fire
        #expect(b.log == ["second"])
        #expect((b.at.first ?? .zero) >= .milliseconds(100))
    }

    @Test func rearmFromInsideTheBodyKeepsTheNewOne() async {
        let t = MainTimer()
        let b = Box()
        func arm() { t.schedule(after: 0.03) { b.log.append("fired"); if b.log.count < 3 { arm() } } }
        arm()
        await until { b.log.count >= 3 }
        await wait(0.15)   // and not a fourth time
        #expect(b.log.count == 3)
        #expect(!t.isArmed)
    }

    @Test func delayReportsCancellation() async {
        let task = Task { @MainActor in await MainDelay.elapsed(5) }
        task.cancel()
        #expect(await task.value == false)
        #expect(await Task { @MainActor in await MainDelay.elapsed(0.01) }.value)
    }

    /// `Task { @MainActor in }` replaces `DispatchQueue.main.async`: it must not run inline, and runs in order.
    @Test func mainActorTasksRunAfterTheCurrentWorkInOrder() async {
        let b = Box()
        for i in 1...5 { Task { @MainActor in b.log.append("\(i)") } }
        b.log.append("0")
        await until { b.log.count >= 6 }
        #expect(b.log == ["0", "1", "2", "3", "4", "5"])
    }
}

/// D10: PanelModel's clocks (token-checked delays) behave as with `asyncAfter`: they fire after the delay, a phase
/// change before that cancels them, and a re-arm's stale delay does nothing.
@MainActor @Suite(.serialized) struct PanelClockTests {
    func wait(_ sec: Double) async { try? await Task.sleep(for: .seconds(sec)) }
    func blockMain(_ sec: Double) { Thread.sleep(forTimeInterval: sec) }
    /// Waits until `done` holds, up to `limit` seconds. A loaded first run after a build can delay main by hundreds of
    /// ms, so "has it fired?" waits for the event instead of a fixed time (owner approved, 2026-10-26).
    func until(_ limit: Double = 3, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(limit)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func waitLabelAfterItsDelay() async {
        let m = PanelModel()
        m.phase = .transcribing
        #expect(m.waitStage == .quiet)
        await until { m.waitStage == .label }
        #expect(m.waitStage == .label)
    }

    @Test func finishingFirstCancelsTheWaitClock() async {
        let m = PanelModel()
        m.phase = .transcribing
        m.phase = .done
        await wait(PillGeometry.labelAfter + 0.3)
        #expect(m.waitStage == .quiet)
    }

    /// The first run's label delay is already due (main blocked) when the next run starts; it must not label the new one.
    @Test func restartedWaitClockIgnoresTheStaleDelay() async {
        let m = PanelModel()
        m.phase = .transcribing
        blockMain(PillGeometry.labelAfter + 0.1)
        m.phase = .done
        m.phase = .transcribing
        for _ in 0..<5 { await Task.yield() }
        #expect(m.waitStage == .quiet)
        await until { m.waitStage == .label }
        #expect(m.waitStage == .label)
    }
}
