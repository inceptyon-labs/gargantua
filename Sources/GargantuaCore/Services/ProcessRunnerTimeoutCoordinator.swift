import Foundation

enum ProcessRunnerTimeoutState: Sendable { case running, naturallyCompleted, timedOut }

/// Serializes the "process exited naturally" vs "watchdog fired" decision,
/// and the "child still reapable" vs "already reaped" decision.
///
/// Only one transition out of `.running` is possible; whichever thread grabs
/// the lock first wins. The `reaped` flag is set by the main thread after
/// `waitpid` returns and is consulted by the delayed SIGKILL escalation to
/// avoid signalling a pid/pgid that has already been freed and may now
/// identify an unrelated process group.
final class ProcessRunnerTimeoutCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var state: ProcessRunnerTimeoutState = .running
    private var reaped: Bool = false

    /// Called by the watchdog block. Returns true only if the timeout
    /// transition was claimed (caller should send the TERM/KILL signals).
    /// Also refuses to arm once the child has been reaped — if the main
    /// thread's `waitpid` already returned, no signal we send from here can
    /// be safely delivered to the original pid.
    func tryArmTimeout() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .running && !reaped else { return false }
        state = .timedOut
        return true
    }

    /// Called by the main thread after `waitpid` returns. Records natural
    /// completion unless the watchdog already won the race.
    func markNaturalCompletion() -> ProcessRunnerTimeoutState {
        lock.lock(); defer { lock.unlock() }
        if state == .running {
            state = .naturallyCompleted
        }
        return state
    }

    /// Called by the main thread after `waitpid` returns (including on
    /// error). Once set, the pending SIGKILL escalation must not fire.
    func markReaped() {
        lock.lock(); defer { lock.unlock() }
        reaped = true
    }

    /// Consulted by the delayed SIGKILL escalation closure. Returns true
    /// only if the timeout path armed us AND the main thread has not yet
    /// reaped the child.
    func shouldEscalateKill() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state == .timedOut && !reaped
    }
}
