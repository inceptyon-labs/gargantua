import Darwin
import Foundation

/// Default `ProcessRunner` that uses `posix_spawn` directly so the child is
/// placed in its own process group *before* exec. That closes a race in the
/// previous `Foundation.Process`-based implementation where descendants that
/// forked before the parent's post-spawn `setpgid` call landed in the parent's
/// group and escaped our timeout/escalation signalling.
public struct DefaultProcessRunner: ProcessRunner {
    /// Default byte cap applied when a caller does not specify one.
    /// 1 MiB is comfortable for `brew --version`, `docker system df`, and the
    /// rest of the developer-tool preview surface; scan adapters that emit
    /// large JSON payloads (fclones, czkawka_cli) pass an explicit override.
    public static let defaultMaxCapturedBytes: Int = 1 * 1024 * 1024

    public init() {}

    public func run(executable: URL, arguments: [String]) throws -> ProcessOutput {
        try run(
            executable: executable,
            arguments: arguments,
            timeout: nil,
            maxCapturedBytes: Self.defaultMaxCapturedBytes
        )
    }

    public func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval?
    ) throws -> ProcessOutput {
        try run(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            maxCapturedBytes: Self.defaultMaxCapturedBytes
        )
    }

    public func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval?,
        maxCapturedBytes: Int
    ) throws -> ProcessOutput {
        let drain = ProcessOutputDrain(maxCapturedBytes: maxCapturedBytes)

        let pid: pid_t
        do {
            pid = try ProcessSpawner.spawnInNewProcessGroup(
                executable: executable,
                arguments: arguments,
                stdoutPipe: drain.stdoutPipe,
                stderrPipe: drain.stderrPipe
            )
        } catch let ProcessSpawnerError.spawnFailed(errnoVal) {
            throw ProcessRunnerError.spawnFailed(errno: errnoVal)
        }

        drain.startDraining()

        let coordinator = ProcessRunnerTimeoutCoordinator()
        var watchdog: DispatchWorkItem?
        if let timeout, timeout > 0 {
            let deadline = DispatchTime.now() + timeout
            let item = DispatchWorkItem {
                // Atomically claim the timeout state. If the main thread has
                // already marked natural completion, bail — we lost the race.
                guard coordinator.tryArmTimeout() else { return }

                // We always have a process group now (posix_spawn guarantees
                // it), so killpg is always the right call. killpg on a dead
                // group returns ESRCH, which is harmless.
                _ = killpg(pid, SIGTERM)

                // Escalate to SIGKILL after a grace period — but only if the
                // main thread hasn't already reaped the child. Without this
                // gate, the 0.5s-delayed killpg could land on a pgid that was
                // recycled after waitpid freed it, hitting an innocent
                // process group.
                let killDeadline = DispatchTime.now() + 0.5
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: killDeadline) {
                    if coordinator.shouldEscalateKill() {
                        _ = killpg(pid, SIGKILL)
                    }
                }
            }
            watchdog = item
            // `.userInitiated` rather than `.utility`: same reasoning as the
            // drain queue above. On the GitHub macos-15 runner, `.utility`
            // tasks were starved long enough that the watchdog fired AFTER
            // short-lived children (e.g. `sleep 10` with `timeout: 0.2`) had
            // already exited naturally — `tryArmTimeout` then refused to
            // arm because the child was already reaped, and the test saw a
            // successful run instead of `ProcessRunnerError.timedOut`. The
            // SIGKILL escalation queued in the watchdog above runs at the
            // same QoS for the same reason.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline, execute: item)
        }

        // waitpid blocks until the child exits (or is killed). WUNTRACED/WCONTINUED
        // are not set, so we only return for exit events. Retry on EINTR so a
        // stray signal delivered to our thread doesn't leave the child
        // un-reaped and our status word uninitialized.
        var status: Int32 = 0
        var waitResult: pid_t = 0
        repeat {
            waitResult = waitpid(pid, &status, 0)
        } while waitResult == -1 && errno == EINTR
        if waitResult == -1 {
            // Bubble up to the caller rather than silently reporting exit 0.
            // ECHILD/EINVAL here indicate serious process-accounting failure
            // (child reaped by someone else, bad args) — masking it would
            // give callers fake success.
            let waitErrno = errno
            coordinator.markReaped()
            watchdog?.cancel()
            throw ProcessRunnerError.waitFailed(errno: waitErrno)
        }

        // Tell any pending SIGKILL escalation that the child is already
        // reaped and its pid is eligible for reuse — don't signal it.
        coordinator.markReaped()
        // DispatchWorkItem.cancel() prevents a *queued* item from running but
        // does NOT interrupt one already executing. The coordinator serializes
        // "natural exit" vs "timeout fired" under a single lock to close the
        // race at the instant of deadline.
        let timedOut = coordinator.markNaturalCompletion() == .timedOut
        watchdog?.cancel()

        drain.finish()

        if timedOut, let timeout {
            throw ProcessRunnerError.timedOut(seconds: timeout)
        }

        // waitpid status word layout on Darwin:
        //   low 7 bits = signal that killed the process (0 if normal exit)
        //   next 8 bits = exit code (valid only on normal exit)
        // This matches Foundation.Process.terminationStatus conventions:
        // the exit code on normal exit, the signal number on signal exit.
        let termSignal = status & 0x7F
        let exitCode: Int32 = termSignal == 0 ? (status >> 8) & 0xFF : termSignal

        return drain.makeOutput(exitCode: exitCode)
    }
}
