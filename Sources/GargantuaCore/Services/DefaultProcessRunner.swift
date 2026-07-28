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
        let watchdog = ProcessTimeoutWatchdog(pid: pid, timeout: timeout)

        let status: Int32
        do {
            status = try Self.waitForExit(pid: pid)
        } catch {
            watchdog.markReaped()
            watchdog.cancel()
            throw error
        }
        watchdog.markReaped()
        let timedOut = watchdog.resolveTimedOut()

        drain.finish()

        if timedOut, let timeout {
            throw ProcessRunnerError.timedOut(seconds: timeout)
        }
        return drain.makeOutput(exitCode: Self.exitCode(fromWaitStatus: status))
    }

    /// Blocks until the child exits (or is killed). WUNTRACED/WCONTINUED are
    /// not set, so we only return for exit events. Retry on EINTR so a stray
    /// signal delivered to our thread doesn't leave the child un-reaped and the
    /// status word uninitialized.
    ///
    /// A `waitpid` failure bubbles up rather than silently reporting exit 0:
    /// ECHILD/EINVAL indicate serious process-accounting failure (child reaped
    /// by someone else, bad args) and masking it would give callers fake success.
    private static func waitForExit(pid: pid_t) throws -> Int32 {
        var status: Int32 = 0
        var waitResult: pid_t = 0
        repeat {
            waitResult = waitpid(pid, &status, 0)
        } while waitResult == -1 && errno == EINTR
        guard waitResult != -1 else {
            throw ProcessRunnerError.waitFailed(errno: errno)
        }
        return status
    }

    /// waitpid status word layout on Darwin:
    ///   low 7 bits = signal that killed the process (0 if normal exit)
    ///   next 8 bits = exit code (valid only on normal exit)
    /// This matches `Foundation.Process.terminationStatus` conventions: the
    /// exit code on normal exit, the signal number on signal exit.
    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let termSignal = status & 0x7F
        return termSignal == 0 ? (status >> 8) & 0xFF : termSignal
    }
}
