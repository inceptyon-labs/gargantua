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

    public var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            "Process did not finish within \(Int(seconds))s and was terminated."
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

/// Default `ProcessRunner` that shells out via `Foundation.Process`.
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
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain both pipes concurrently so large stderr output can't block the
        // child on a full 64K pipe buffer while we sit on waitUntilExit.
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let outBuffer = DataBuffer()
        let errBuffer = DataBuffer()
        outHandle.readabilityHandler = { outBuffer.append($0.availableData) }
        errHandle.readabilityHandler = { errBuffer.append($0.availableData) }

        try process.run()

        let coordinator = TimeoutCoordinator()
        var watchdog: DispatchWorkItem?
        if let timeout, timeout > 0 {
            let deadline = DispatchTime.now() + timeout
            let item = DispatchWorkItem { [weak process] in
                guard let process else { return }
                // Atomically claim the timeout state. If the main thread has
                // already marked natural completion, bail — we lost the race.
                guard coordinator.tryArmTimeout(process: process) else { return }
                process.terminate()
            }
            watchdog = item
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline, execute: item)
        }
        process.waitUntilExit()
        // DispatchWorkItem.cancel() prevents a *queued* item from running but
        // does NOT interrupt one already executing. The coordinator serializes
        // "natural exit" vs "timeout fired" under a single lock to close the
        // race at the instant of deadline.
        let timedOut = coordinator.markNaturalCompletion() == .timedOut
        watchdog?.cancel()

        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil
        outBuffer.append(outHandle.readDataToEndOfFile())
        errBuffer.append(errHandle.readDataToEndOfFile())

        if timedOut, let timeout {
            throw ProcessRunnerError.timedOut(seconds: timeout)
        }

        return ProcessOutput(
            stdout: String(data: outBuffer.snapshot(), encoding: .utf8) ?? "",
            stderr: String(data: errBuffer.snapshot(), encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
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
/// the lock first wins. The watchdog additionally re-checks `process.isRunning`
/// under the lock so a process that just exited before the watchdog block
/// dispatched isn't spuriously marked as timed out.
private final class TimeoutCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var state: TimeoutState = .running

    /// Called by the watchdog block. Returns true only if the timeout
    /// transition was claimed (caller should call `terminate()`).
    func tryArmTimeout(process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .running else { return false }
        // Process may have exited between the deadline firing and this block
        // being dispatched; treat that as natural completion.
        guard process.isRunning else {
            state = .naturallyCompleted
            return false
        }
        state = .timedOut
        return true
    }

    /// Called by the main thread after `waitUntilExit` returns. Records
    /// natural completion unless the watchdog already won the race.
    func markNaturalCompletion() -> TimeoutState {
        lock.lock(); defer { lock.unlock() }
        if state == .running {
            state = .naturallyCompleted
        }
        return state
    }
}
