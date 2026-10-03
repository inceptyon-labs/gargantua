import Darwin
import Foundation
import os

/// Lets an async caller kill a child process that a synchronous
/// `DefaultProcessRunner.run` is blocked on when the calling task is
/// cancelled. Without it a cancelled scan or a Rescan left fclones or
/// czkawka running to completion beside the new one.
///
/// `run(_:)` binds a handle as a task-local for the duration of `body`; the
/// runner registers each child's process group with it between spawn and
/// reap, and task cancellation SIGKILLs that group. Outside `run(_:)` the
/// runner behaves as before.
public final class ProcessCancellation: Sendable {
    @TaskLocal static var current: ProcessCancellation?

    private struct State {
        var pid: pid_t?
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Runs `body`, killing any child it spawns through `DefaultProcessRunner`
    /// if the current task is cancelled before that child exits.
    public static func run<T>(_ body: () throws -> T) async rethrows -> T {
        let handle = ProcessCancellation()
        return try await withTaskCancellationHandler {
            try $current.withValue(handle) { try body() }
        } onCancel: {
            handle.cancel()
        }
    }

    /// Called by the runner right after spawning. Kills immediately if the
    /// task was already cancelled.
    func register(_ pid: pid_t) {
        state.withLock { state in
            state.pid = pid
            if state.cancelled {
                _ = killpg(pid, SIGKILL)
            }
        }
    }

    /// Called by the runner as soon as the child is reaped, so a late cancel
    /// can't signal a process group ID that has since been reused.
    func unregister() {
        state.withLock { $0.pid = nil }
    }

    private func cancel() {
        state.withLock { state in
            state.cancelled = true
            if let pid = state.pid {
                _ = killpg(pid, SIGKILL)
            }
        }
    }
}
