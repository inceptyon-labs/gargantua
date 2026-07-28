import Darwin
import Foundation

/// Arms and disarms the SIGTERM -> SIGKILL escalation ladder for one spawned
/// child, wrapping `ProcessRunnerTimeoutCoordinator` so the race handling and
/// the dispatch plumbing sit behind a single seam.
///
/// A nil or non-positive timeout yields an inert watchdog: every method stays
/// safe to call, so `run()` needs no branch.
struct ProcessTimeoutWatchdog {
    /// Grace between SIGTERM and SIGKILL.
    private static let killEscalationDelay: TimeInterval = 0.5

    private let coordinator: ProcessRunnerTimeoutCoordinator
    private let item: DispatchWorkItem?

    /// - Note: `.userInitiated` rather than `.utility`. On the GitHub macos-15
    ///   runner, `.utility` tasks were starved long enough that the watchdog
    ///   fired AFTER short-lived children (e.g. `sleep 10` with `timeout: 0.2`)
    ///   had already exited naturally — `tryArmTimeout` then refused to arm
    ///   because the child was already reaped, and the test saw a successful
    ///   run instead of `ProcessRunnerError.timedOut`. The SIGKILL escalation
    ///   runs at the same QoS for the same reason.
    init(pid: pid_t, timeout: TimeInterval?) {
        let coordinator = ProcessRunnerTimeoutCoordinator()
        self.coordinator = coordinator

        guard let timeout, timeout > 0 else {
            item = nil
            return
        }

        let deadline = DispatchTime.now() + timeout
        let item = DispatchWorkItem {
            // Atomically claim the timeout state. If the main thread has
            // already marked natural completion, bail — we lost the race.
            guard coordinator.tryArmTimeout() else { return }

            // We always have a process group (posix_spawn guarantees it), so
            // killpg is always the right call. killpg on a dead group returns
            // ESRCH, which is harmless.
            _ = killpg(pid, SIGTERM)

            // Escalate to SIGKILL after a grace period — but only if the main
            // thread hasn't already reaped the child. Without this gate, the
            // delayed killpg could land on a pgid that was recycled after
            // waitpid freed it, hitting an innocent process group.
            let killDeadline = DispatchTime.now() + Self.killEscalationDelay
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: killDeadline) {
                if coordinator.shouldEscalateKill() {
                    _ = killpg(pid, SIGKILL)
                }
            }
        }
        self.item = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline, execute: item)
    }

    /// Tell any pending SIGKILL escalation that the child is already reaped and
    /// its pid is eligible for reuse — don't signal it. Call immediately after
    /// `waitpid` returns, including on error.
    func markReaped() {
        coordinator.markReaped()
    }

    /// Prevent a still-queued deadline item from running. Does NOT interrupt
    /// one already executing — that race is closed by the coordinator's lock.
    func cancel() {
        item?.cancel()
    }

    /// Record natural completion and report whether the watchdog beat us to it.
    /// The coordinator serializes "natural exit" vs "timeout fired" under a
    /// single lock to close the race at the instant of the deadline.
    func resolveTimedOut() -> Bool {
        let timedOut = coordinator.markNaturalCompletion() == .timedOut
        cancel()
        return timedOut
    }
}
