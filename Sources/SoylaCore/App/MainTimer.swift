import Foundation

/// D10: the main-actor replacement for `DispatchQueue.main.asyncAfter(deadline: .now() + sec)`.
enum MainDelay {
    /// Waits `sec` and says whether the caller may go on: false once its task is cancelled.
    /// - Sleeps on `SuspendingClock`, the uptime clock `DispatchTime` uses (it stops while the Mac sleeps).
    /// - `@MainActor` on purpose: the cancel check runs on main after the sleep. A cancel that lands after the sleep
    ///   ended but before the task got main back therefore still wins, as with a cancelled `DispatchWorkItem`. A bare
    ///   `try? await Task.sleep` misses that window and would run the body.
    @MainActor static func elapsed(_ sec: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(sec), clock: .suspending)
        return !Task.isCancelled
    }
}

/// D10: a one-shot main-actor timer in place of a stored `DispatchWorkItem` + `asyncAfter` + `cancel()`.
/// - `schedule` cancels the pending one first (re-arming replaces it), then runs `body` once after `sec`.
/// - `cancel()` before it fires means the body never runs (`MainTimerTests`).
/// - `isArmed` is true while one is pending; it is cleared just before the body runs, so the body may re-arm.
@MainActor final class MainTimer {
    private var task: Task<Void, Never>?

    var isArmed: Bool { task != nil }

    func schedule(after sec: Double, _ body: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { [weak self] in
            guard await MainDelay.elapsed(sec), let self else { return }
            self.task = nil
            body()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
