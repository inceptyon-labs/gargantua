import Foundation
import OSLog

private let codexOneShotLogger = Logger(
    subsystem: "com.gargantua.core",
    category: "CodexOneShotRunner"
)

/// Runs the user's `codex` CLI as a single read-only completion:
/// `codex exec --skip-git-repo-check --sandbox read-only -o <file> [--model m]
/// "<prompt>"`. Codex writes only the assistant's final message to the `-o`
/// file, which this returns; the read-only sandbox blocks writes and actions.
///
/// Shared by every one-shot Codex consumer (file-organization proposals,
/// deeper explanations) so the subprocess plumbing lives in one place.
public struct CodexOneShotRunner: @unchecked Sendable {
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

    public func run(executable: URL, prompt: String, model: String) async throws -> String {
        try ExecutableTrustPolicy.verify(executable)
        let lastMessageFile = fileManager.temporaryDirectory
            .appendingPathComponent("gargantua-codex-out-\(UUID().uuidString).txt")
        defer { try? fileManager.removeItem(at: lastMessageFile) }

        var arguments = [
            "exec",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            // One-shot, no persisted session. (Codex has no flag to disable
            // file-reading tools the way Claude does, so read-only is the
            // tightest filesystem boundary available here.)
            "--ephemeral",
            "-o", lastMessageFile.path,
        ]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            arguments += ["--model", trimmedModel]
        }
        arguments.append(prompt)

        codexOneShotLogger.error(
            "codex one-shot start: \(executable.path, privacy: .public) prompt-len=\(prompt.count) model=\(trimmedModel, privacy: .public)"
        )

        let processBox = CodexProcessBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = processFactory()
                processBox.process = process
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let stdoutBuffer = CodexDataBuffer()
                let stderrBuffer = CodexDataBuffer()
                let resumed = CodexAtomicFlag()

                let pipes = CodexSubprocessPipes(stdout: stdoutPipe, stderr: stderrPipe)
                let buffers = CodexSubprocessBuffers(stdout: stdoutBuffer, stderr: stderrBuffer)
                let termination = CodexTerminationInfo()
                configure(process: process, executable: executable, arguments: arguments, pipes: pipes)

                // Completion is gated on EOF of BOTH pipes AND process exit, so
                // no buffered stderr can be missed by a snapshot that raced an
                // in-flight readability append.
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
                    try? pipes.stdout.fileHandleForWriting.close()
                    try? pipes.stderr.fileHandleForWriting.close()
                    group.leave()
                }

                spawnTimeoutWatcher(process: process, resumed: resumed, continuation: continuation)
            }
        } onCancel: {
            processBox.process?.terminate()
        }

        guard let data = try? Data(contentsOf: lastMessageFile),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CodexOneShotError.emptyResponse
        }
        return text
    }

    // MARK: - Subprocess helpers

    private func configure(process: Process, executable: URL, arguments: [String], pipes: CodexSubprocessPipes) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipes.stdout
        process.standardError = pipes.stderr
    }

    /// Drain each pipe asynchronously and `leave()` the group on EOF, so the
    /// outcome is only built once every byte has landed.
    private func attachReadabilityHandlers(pipes: CodexSubprocessPipes, buffers: CodexSubprocessBuffers, group: DispatchGroup) {
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

    /// Resolve the run once both pipes have hit EOF and the process has exited.
    private func finish(
        buffers: CodexSubprocessBuffers,
        termination: CodexTerminationInfo,
        continuation: CheckedContinuation<Void, Error>
    ) {
        if let launchError = termination.launchError {
            continuation.resume(throwing: launchError)
            return
        }
        let status = termination.status
        let stderrString = String(data: buffers.stderr.snapshot(), encoding: .utf8) ?? ""
        codexOneShotLogger.error("codex one-shot exit: status=\(status) stderr-bytes=\(stderrString.count)")
        if status == 0, termination.reason == .exit {
            continuation.resume(returning: ())
        } else {
            codexOneShotLogger.error("codex CLI stderr: \(stderrString.prefix(600), privacy: .public)")
            continuation.resume(throwing: CodexOneShotError.cliFailed(
                exitCode: Int(status),
                stderr: stderrString
            ))
        }
    }

    private func spawnTimeoutWatcher(
        process: Process,
        resumed: CodexAtomicFlag,
        continuation: CheckedContinuation<Void, Error>
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
                codexOneShotLogger.error("codex CLI timed out after \(seconds)s — terminating subprocess")
                process.terminate()
                continuation.resume(throwing: CodexOneShotError.timedOut(seconds: seconds))
            }
        }
    }
}

/// Failure modes of a one-shot `codex` invocation. Callers map these onto
/// their own feature-specific error types for user-facing messages.
public enum CodexOneShotError: Error, Equatable {
    case cliFailed(exitCode: Int, stderr: String)
    case emptyResponse
    case timedOut(seconds: Int)
}

private final class CodexProcessBox: @unchecked Sendable {
    var process: Process?
}

/// Lock-guarded subprocess outcome, written by the termination handler or the
/// launch-failure path and read once by `finish` from the group's `notify`.
private final class CodexTerminationInfo: @unchecked Sendable {
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

private struct CodexSubprocessPipes {
    let stdout: Pipe
    let stderr: Pipe
}

private struct CodexSubprocessBuffers {
    let stdout: CodexDataBuffer
    let stderr: CodexDataBuffer
}

private final class CodexAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flipped = false

    func takeIfFalse() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if flipped { return false }
        flipped = true
        return true
    }
}

private final class CodexDataBuffer: @unchecked Sendable {
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
