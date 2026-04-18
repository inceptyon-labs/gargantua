import Darwin
import Foundation

/// Runs an external process and returns captured stdout.
///
/// Broken out as a protocol so tests can stub binaries (czkawka_cli, fclones)
/// without actually spawning a subprocess.
public protocol ProcessRunner: Sendable {
    func run(executable: URL, arguments: [String]) throws -> ProcessOutput

    /// Run with a wall-clock timeout. A nil timeout means no limit.
    /// Default implementation ignores the timeout and delegates to `run(executable:arguments:)`;
    /// runners that actually spawn processes (e.g. `DefaultProcessRunner`) override this.
    func run(executable: URL, arguments: [String], timeout: TimeInterval?) throws -> ProcessOutput
}

public extension ProcessRunner {
    func run(executable: URL, arguments: [String], timeout: TimeInterval?) throws -> ProcessOutput {
        try run(executable: executable, arguments: arguments)
    }
}

public enum ProcessRunnerError: Error, LocalizedError, Sendable, Equatable {
    case timedOut(seconds: TimeInterval)
    case spawnFailed(errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            "Process did not finish within \(Int(seconds))s and was terminated."
        case .spawnFailed(let errno):
            "Failed to spawn process (errno \(errno))."
        }
    }
}

public struct ProcessOutput: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// Default `ProcessRunner` that uses `posix_spawn` directly so the child is
/// placed in its own process group *before* exec. That closes a race in the
/// previous `Foundation.Process`-based implementation where descendants that
/// forked before the parent's post-spawn `setpgid` call landed in the parent's
/// group and escaped our timeout/escalation signalling.
public struct DefaultProcessRunner: ProcessRunner {
    public init() {}

    public func run(executable: URL, arguments: [String]) throws -> ProcessOutput {
        try run(executable: executable, arguments: arguments, timeout: nil)
    }

    public func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval?
    ) throws -> ProcessOutput {
        let outPipe = Pipe()
        let errPipe = Pipe()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let outBuffer = DataBuffer()
        let errBuffer = DataBuffer()

        let pid: pid_t
        do {
            pid = try ProcessSpawner.spawnInNewProcessGroup(
                executable: executable,
                arguments: arguments,
                stdoutPipe: outPipe,
                stderrPipe: errPipe
            )
        } catch let ProcessSpawnerError.spawnFailed(errnoVal) {
            throw ProcessRunnerError.spawnFailed(errno: errnoVal)
        }

        // Close the write ends in the parent so EOF on the read ends happens
        // when the child exits (if no descendant inherited them). Failing to
        // close these would leave the drain reads blocked forever.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        // Drain each pipe on a dedicated background queue with a single
        // blocking `readToEnd()`. This is deliberately simpler than a
        // readabilityHandler + post-exit readDataToEndOfFile pair: that
        // approach can race because setting the handler to nil is not
        // documented to block for in-flight invocations, so a late handler
        // chunk can interleave with the final drain. Here, exactly one read
        // per pipe returns all bytes up to EOF. EOF requires every writer to
        // the pipe to close — normally just the child, but a descendant that
        // inherits and keeps the fd open could delay or prevent EOF.
        // To harden against inherited-fd hangs, we bound the drain wait with
        // a grace period, closing the pipe fds if drain doesn't finish.
        // Draining concurrently on both pipes also prevents a full 64K buffer
        // on one stream from blocking the child while we sit on waitpid.
        let drainGroup = DispatchGroup()
        let drainQueue = DispatchQueue.global(qos: .utility)
        // Use the Swift-throwing `readToEnd()` rather than
        // `readDataToEndOfFile()`: when the force-close path below closes the
        // fd out from under a blocking read, the legacy API raises an
        // NSException that crashes the process; the throwing variant returns
        // a Swift error we can swallow.
        drainQueue.async(group: drainGroup) {
            if let data = try? outHandle.readToEnd() {
                outBuffer.append(data)
            }
        }
        drainQueue.async(group: drainGroup) {
            if let data = try? errHandle.readToEnd() {
                errBuffer.append(data)
            }
        }

        let coordinator = TimeoutCoordinator()
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

                // Escalate to SIGKILL after a grace period. The group may
                // already be gone while a descendant holds the pipe; sending
                // killpg unconditionally is safe.
                let killDeadline = DispatchTime.now() + 0.5
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: killDeadline) {
                    _ = killpg(pid, SIGKILL)
                }
            }
            watchdog = item
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline, execute: item)
        }

        // waitpid blocks until the child exits (or is killed). WUNTRACED/WCONTINUED
        // are not set, so we only return for exit events. Retry on EINTR so a
        // stray signal delivered to our thread doesn't leave the child
        // un-reaped and our status word uninitialized.
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {
            continue
        }

        // DispatchWorkItem.cancel() prevents a *queued* item from running but
        // does NOT interrupt one already executing. The coordinator serializes
        // "natural exit" vs "timeout fired" under a single lock to close the
        // race at the instant of deadline.
        let timedOut = coordinator.markNaturalCompletion() == .timedOut
        watchdog?.cancel()

        // Pipe ends close on child exit, so the blocking reads should return
        // shortly after waitpid. However, if a descendant inherited the fd
        // and is still writing, the read could hang indefinitely. Use a bounded
        // wait with a grace period; if drain doesn't finish, close the pipe fds
        // directly to unblock the reads.
        let drainGracePeriod: DispatchTime = {
            // Floor at 100ms so tiny timeouts still leave room for the drain
            // to finish; cap at 1s so a huge timeout doesn't leave us waiting
            // forever on a genuinely stuck inherited fd.
            let graceSecs = timeout.map { min(max($0 * 0.1, 0.1), 1.0) } ?? 1.0
            return DispatchTime.now() + graceSecs
        }()

        let drainResult = drainGroup.wait(timeout: drainGracePeriod)
        if drainResult == .timedOut {
            // Force-close the pipe file descriptors to unblock the pending reads.
            // This prevents an indefinite hang if a descendant inherited the fds.
            try? outHandle.close()
            try? errHandle.close()
            // Wait a bit longer for the drain tasks to finish after we've closed the fds.
            _ = drainGroup.wait(timeout: DispatchTime.now() + 0.1)
        }

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

        return ProcessOutput(
            stdout: String(data: outBuffer.snapshot(), encoding: .utf8) ?? "",
            stderr: String(data: errBuffer.snapshot(), encoding: .utf8) ?? "",
            exitCode: exitCode
        )
    }

    private final class DataBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
        }

        func snapshot() -> Data {
            lock.lock(); defer { lock.unlock() }
            return data
        }
    }
}

private enum TimeoutState: Sendable { case running, naturallyCompleted, timedOut }

/// Serializes the "process exited naturally" vs "watchdog fired" decision.
///
/// Only one transition out of `.running` is possible; whichever thread grabs
/// the lock first wins. Unlike the previous `Process`-backed version, we do
/// not re-check liveness from the watchdog — with a guaranteed process group
/// from `posix_spawn`, `killpg` on a dead group is a harmless ESRCH, and the
/// state-machine ordering is sufficient to avoid signalling a recycled pid
/// (main thread marks natural completion before we waitpid, so any late
/// watchdog call sees `.naturallyCompleted` and bails).
private final class TimeoutCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var state: TimeoutState = .running

    /// Called by the watchdog block. Returns true only if the timeout
    /// transition was claimed (caller should send the TERM/KILL signals).
    func tryArmTimeout() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .running else { return false }
        state = .timedOut
        return true
    }

    /// Called by the main thread after `waitpid` returns. Records natural
    /// completion unless the watchdog already won the race.
    func markNaturalCompletion() -> TimeoutState {
        lock.lock(); defer { lock.unlock() }
        if state == .running {
            state = .naturallyCompleted
        }
        return state
    }
}
