import Foundation
import OSLog

private let oneShotLogger = Logger(
    subsystem: "com.gargantua.core",
    category: "ClaudeCodeOneShotRunner"
)

/// Runs the user's `claude` CLI as a single non-interactive completion:
/// `claude -p "<prompt>" --output-format text --max-turns 1` with an empty,
/// strict MCP config so the CLI doesn't probe servers or attempt agentic tool
/// discovery. Captures stdout and maps exit codes / timeouts to typed errors.
///
/// Shared by every one-shot Claude Code consumer (file-organization proposals,
/// deeper explanations) so the subprocess plumbing — async pipe draining,
/// cancellation, timeout, single-resume continuation — lives in exactly one
/// place.
public struct ClaudeCodeOneShotRunner: @unchecked Sendable {
    private let processFactory: @Sendable () -> Process
    private let fileManager: FileManager
    private let timeoutSeconds: Int

    public init(
        processFactory: @Sendable @escaping () -> Process = { Process() },
        fileManager: FileManager = .default,
        timeoutSeconds: Int = 240
    ) {
        self.processFactory = processFactory
        self.fileManager = fileManager
        self.timeoutSeconds = timeoutSeconds
    }

    /// Run one completion and return stdout. `model` may be empty to use the
    /// CLI's default model.
    public func run(executable: URL, prompt: String, model: String) async throws -> String {
        try ExecutableTrustPolicy.verify(executable)
        // Stop claude from probing MCP servers, allowed tools, or any other
        // agentic discovery — we want a one-shot completion only. A minimal
        // empty MCP config + --strict-mcp-config short-circuits the search.
        let emptyMCPConfig = try writeEmptyMCPConfig()
        defer { try? fileManager.removeItem(at: emptyMCPConfig) }

        var arguments = [
            "-p",
            prompt,
            "--output-format",
            "text",
            "--max-turns",
            "1",
            // Pure text completion only: disable every built-in tool (Bash,
            // Read, Grep, …) so the model can't read local files or run
            // commands — it answers from the prompt alone. Combined with the
            // empty + strict MCP config below, no tools of any kind are
            // available. This matters for the deeper-explain path, which sends
            // metadata only and must not let the CLI pull file contents.
            "--tools",
            "",
            "--mcp-config",
            emptyMCPConfig.path,
            "--strict-mcp-config",
        ]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            arguments += ["--model", trimmedModel]
        }

        oneShotLogger.error(
            "claude one-shot start: \(executable.path, privacy: .public) prompt-len=\(prompt.count) model=\(trimmedModel, privacy: .public)"
        )

        let processBox = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = processFactory()
                processBox.process = process
                let pipes = SubprocessPipes(stdout: Pipe(), stderr: Pipe())
                let buffers = SubprocessBuffers(stdout: DataBuffer(), stderr: DataBuffer())
                let resumed = AtomicFlag()
                let termination = TerminationInfo()
                configure(process: process, executable: executable, arguments: arguments, pipes: pipes)

                // Completion is gated on EOF of BOTH pipes AND process exit, so
                // no buffered output can be missed. The old design snapshotted
                // in the terminationHandler, which could race an in-flight
                // readability append and drop the final stderr/stdout bytes.
                let group = DispatchGroup()
                group.enter() // stdout EOF
                group.enter() // stderr EOF
                group.enter() // process exit
                attachReadabilityHandlers(pipes: pipes, buffers: buffers, group: group)
                process.terminationHandler = { proc in
                    termination.recordExit(status: proc.terminationStatus, reason: proc.terminationReason)
                    group.leave()
                }
                group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                    guard resumed.takeIfFalse() else { return }
                    self.finish(buffers: buffers, termination: termination, continuation: continuation)
                }

                do {
                    try process.run()
                } catch {
                    termination.recordLaunchError(error)
                    // The child never started, so Foundation won't close the
                    // parent write-ends; close them so the readers see EOF, and
                    // balance the process-exit enter that will never fire.
                    try? pipes.stdout.fileHandleForWriting.close()
                    try? pipes.stderr.fileHandleForWriting.close()
                    group.leave()
                }

                spawnTimeoutWatcher(process: process, resumed: resumed, continuation: continuation)
            }
        } onCancel: {
            processBox.process?.terminate()
        }
    }

    // MARK: - Subprocess helpers

    private func configure(
        process: Process,
        executable: URL,
        arguments: [String],
        pipes: SubprocessPipes
    ) {
        process.executableURL = executable
        process.arguments = arguments
        // Close stdin so claude doesn't sit waiting for an interactive
        // turn that will never come.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipes.stdout
        process.standardError = pipes.stderr
    }

    /// Drain the pipes asynchronously while the process runs. Otherwise
    /// a >16KB response (Sonnet on a busy folder hits this fast) fills
    /// the pipe buffer, the CLI blocks on write, and the process never
    /// exits.
    /// Drain the pipes asynchronously while the process runs (otherwise a
    /// >16KB response fills the pipe buffer, the CLI blocks on write, and the
    /// process never exits). Each handler `leave()`s the group exactly once on
    /// EOF (empty chunk), so completion can wait until every byte has landed.
    private func attachReadabilityHandlers(pipes: SubprocessPipes, buffers: SubprocessBuffers, group: DispatchGroup) {
        pipes.stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                buffers.stdout.append(chunk)
            }
        }
        pipes.stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                buffers.stderr.append(chunk)
            }
        }
    }

    /// Build the typed result once both pipes have hit EOF and the process has
    /// exited. Runs from the group's `notify`, so the buffers are fully drained.
    private func finish(
        buffers: SubprocessBuffers,
        termination: TerminationInfo,
        continuation: CheckedContinuation<String, Error>
    ) {
        if let launchError = termination.launchError {
            continuation.resume(throwing: launchError)
            return
        }
        let stdout = buffers.stdout.snapshot()
        let stderr = buffers.stderr.snapshot()
        let status = termination.status
        oneShotLogger.error(
            "claude one-shot exit: status=\(status) stdout-bytes=\(stdout.count) stderr-bytes=\(stderr.count)"
        )
        if status == 0, termination.reason == .exit {
            if let text = String(data: stdout, encoding: .utf8), !text.isEmpty {
                continuation.resume(returning: text)
            } else {
                continuation.resume(throwing: ClaudeCodeOneShotError.emptyResponse)
            }
        } else {
            let stderrString = String(data: stderr, encoding: .utf8) ?? ""
            oneShotLogger.error("claude CLI stderr: \(stderrString.prefix(600), privacy: .public)")
            continuation.resume(throwing: ClaudeCodeOneShotError.cliFailed(
                exitCode: Int(status),
                stderr: stderrString
            ))
        }
    }

    private func spawnTimeoutWatcher(
        process: Process,
        resumed: AtomicFlag,
        continuation: CheckedContinuation<String, Error>
    ) {
        let seconds = timeoutSeconds
        Task {
            // Poll instead of one long sleep, so the watcher (and the Process
            // and pipes it holds) goes away within a second of a normal exit
            // rather than lingering for the whole timeout.
            let deadline = Date().addingTimeInterval(TimeInterval(seconds))
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(for: .seconds(1))
            }
            if process.isRunning, resumed.takeIfFalse() {
                oneShotLogger.error(
                    "claude CLI timed out after \(seconds)s — terminating subprocess"
                )
                process.terminate()
                continuation.resume(throwing: ClaudeCodeOneShotError.timedOut(seconds: seconds))
            }
        }
    }

    private func writeEmptyMCPConfig() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("gargantua-oneshot-mcp-\(UUID().uuidString).json")
        try Data(#"{"mcpServers":{}}"#.utf8).write(to: url)
        return url
    }
}

/// Failure modes of a one-shot `claude` invocation. Callers map these onto
/// their own feature-specific error types for user-facing messages.
public enum ClaudeCodeOneShotError: Error, Equatable {
    case cliFailed(exitCode: Int, stderr: String)
    case emptyResponse
    case timedOut(seconds: Int)
}

/// Shared mutable handle to the in-flight subprocess so the cancel
/// callback can reach it from outside the continuation closure.
private final class ProcessBox: @unchecked Sendable {
    var process: Process?
}

/// Lock-guarded outcome of the subprocess, written by either the termination
/// handler (normal/abnormal exit) or the launch-failure path, and read once by
/// `finish` from the group's `notify`.
private final class TerminationInfo: @unchecked Sendable {
    private let lock = NSLock()
    private var _status: Int32 = 0
    private var _reason: Process.TerminationReason?
    private var _launchError: Error?

    func recordExit(status: Int32, reason: Process.TerminationReason) {
        lock.lock(); _status = status; _reason = reason; lock.unlock()
    }

    func recordLaunchError(_ error: Error) {
        lock.lock(); _launchError = error; lock.unlock()
    }

    var status: Int32 { lock.lock(); defer { lock.unlock() }; return _status }
    var reason: Process.TerminationReason? { lock.lock(); defer { lock.unlock() }; return _reason }
    var launchError: Error? { lock.lock(); defer { lock.unlock() }; return _launchError }
}

private struct SubprocessPipes {
    let stdout: Pipe
    let stderr: Pipe
}

private struct SubprocessBuffers {
    let stdout: DataBuffer
    let stderr: DataBuffer
}

/// One-shot flag used to make sure exactly one path (success, error,
/// timeout, cancel) resumes the continuation. Without this, racing the
/// terminationHandler against the timeout Task can crash.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flipped = false

    /// Atomically flip the flag from false → true. Returns true if THIS
    /// caller did the flip; false if someone got there first.
    func takeIfFalse() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if flipped { return false }
        flipped = true
        return true
    }
}

/// Lock-guarded `Data` buffer for accumulating subprocess output from
/// `FileHandle.readabilityHandler` (which fires on a background queue).
private final class DataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
