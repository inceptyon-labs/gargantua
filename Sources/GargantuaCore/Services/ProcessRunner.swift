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

    /// Run with a wall-clock timeout and a byte cap on captured stdout/stderr.
    /// Bytes past `maxCapturedBytes` are read from the pipe (so the child is
    /// not blocked on a full buffer) but dropped from the returned payload,
    /// and the corresponding `stdoutTruncated` / `stderrTruncated` flag is
    /// set. Default implementation ignores the cap and delegates to the
    /// timeout-only overload; runners that actually spawn processes override
    /// this.
    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval?,
        maxCapturedBytes: Int
    ) throws -> ProcessOutput
}

public extension ProcessRunner {
    func run(executable: URL, arguments: [String], timeout: TimeInterval?) throws -> ProcessOutput {
        try run(executable: executable, arguments: arguments)
    }

    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval?,
        maxCapturedBytes _: Int
    ) throws -> ProcessOutput {
        try run(executable: executable, arguments: arguments, timeout: timeout)
    }
}

public enum ProcessRunnerError: Error, LocalizedError, Sendable, Equatable {
    case timedOut(seconds: TimeInterval)
    case spawnFailed(errno: Int32)
    case waitFailed(errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            "Process did not finish within \(Int(seconds))s and was terminated."
        case .spawnFailed(let errno):
            "Failed to spawn process (errno \(errno))."
        case .waitFailed(let errno):
            "Failed to wait for process exit (errno \(errno))."
        }
    }
}

public struct ProcessOutput: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    /// True when the child produced more stdout than the runner was willing
    /// to retain. The returned `stdout` is the truncated prefix.
    public let stdoutTruncated: Bool
    /// True when the child produced more stderr than the runner was willing
    /// to retain. The returned `stderr` is the truncated prefix.
    public let stderrTruncated: Bool

    public init(
        stdout: String,
        stderr: String,
        exitCode: Int32,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }
}

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
        let outPipe = Pipe()
        let errPipe = Pipe()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let outBuffer = DataBuffer(limit: maxCapturedBytes)
        let errBuffer = DataBuffer(limit: maxCapturedBytes)

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
        // `.userInitiated` rather than `.utility`: the drain reads are on the
        // critical path of returning correct stdout to the caller. Under heavy
        // parallel subprocess load (10+ concurrent runners), `.utility` tasks
        // could be starved long enough for the grace-period force-close below
        // to fire before `readToEnd()` was ever scheduled, returning empty
        // output for a child that had cleanly produced bytes.
        let drainQueue = DispatchQueue.global(qos: .userInitiated)
        // Read in bounded chunks rather than `readToEnd()`: the latter
        // allocates one `Data` for the entire stream, defeating the byte cap.
        // The throwing `read(upToCount:)` returns empty Data on EOF and
        // throws when the force-close path below closes the fd out from
        // under a blocking read (legacy `availableData` would raise an
        // NSException and crash the process). The buffer drops bytes past
        // its cap but we keep pulling chunks out of the pipe so the child
        // never blocks on a full kernel buffer.
        drainQueue.async(group: drainGroup) {
            drainPipe(handle: outHandle, into: outBuffer)
        }
        drainQueue.async(group: drainGroup) {
            drainPipe(handle: errHandle, into: errBuffer)
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

                // Escalate to SIGKILL after a grace period — but only if the
                // main thread hasn't already reaped the child. Without this
                // gate, the 0.5s-delayed killpg could land on a pgid that was
                // recycled after waitpid freed it, hitting an innocent
                // process group.
                let killDeadline = DispatchTime.now() + 0.5
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: killDeadline) {
                    if coordinator.shouldEscalateKill() {
                        _ = killpg(pid, SIGKILL)
                    }
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

        // Pipe ends close on child exit, so the blocking reads should return
        // shortly after waitpid. However, if a descendant inherited the fd
        // and is still writing, the read could hang indefinitely. Use a fixed
        // 1s grace: the child has already exited, so drain budget has no
        // relationship to the original wall-clock timeout. Previous
        // `timeout * 0.1` scaling gave 0.5s for a 5s timeout which, under
        // heavy parallel load, wasn't enough for the `.userInitiated` drain
        // tasks to even schedule before the force-close fired. 1s is long
        // enough to drain bounded kernel pipe buffers under load, short
        // enough to keep run() bounded when a descendant genuinely holds
        // the inherited fd.
        let drainResult = drainGroup.wait(timeout: DispatchTime.now() + 1.0)
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
            exitCode: exitCode,
            stdoutTruncated: outBuffer.wasTruncated(),
            stderrTruncated: errBuffer.wasTruncated()
        )
    }

    /// Pulls bytes from `handle` in bounded chunks until EOF or the handle
    /// is closed. `buffer` may drop bytes past its cap; we still keep reading
    /// to avoid blocking the child on a full kernel pipe buffer.
    private func drainPipe(handle: FileHandle, into buffer: DataBuffer) {
        let chunkSize = 16 * 1024
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                // Force-close path closed the fd out from under us; treat as EOF.
                return
            }
            guard let chunk, !chunk.isEmpty else { return }
            buffer.append(chunk)
        }
    }

    private final class DataBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var truncated = false
        private let limit: Int

        init(limit: Int) {
            self.limit = max(0, limit)
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            let remaining = limit - data.count
            if remaining <= 0 {
                truncated = true
                return
            }
            if chunk.count <= remaining {
                data.append(chunk)
            } else {
                data.append(chunk.prefix(remaining))
                truncated = true
            }
        }

        func snapshot() -> Data {
            lock.lock(); defer { lock.unlock() }
            return data
        }

        func wasTruncated() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return truncated
        }
    }
}

private enum TimeoutState: Sendable { case running, naturallyCompleted, timedOut }

/// Serializes the "process exited naturally" vs "watchdog fired" decision,
/// and the "child still reapable" vs "already reaped" decision.
///
/// Only one transition out of `.running` is possible; whichever thread grabs
/// the lock first wins. The `reaped` flag is set by the main thread after
/// `waitpid` returns and is consulted by the delayed SIGKILL escalation to
/// avoid signalling a pid/pgid that has already been freed and may now
/// identify an unrelated process group.
private final class TimeoutCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var state: TimeoutState = .running
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
    func markNaturalCompletion() -> TimeoutState {
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
