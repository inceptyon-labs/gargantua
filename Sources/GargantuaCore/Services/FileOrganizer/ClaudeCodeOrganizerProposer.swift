import Foundation
import OSLog

private let claudeCodeOrganizerLogger = Logger(
    subsystem: "com.gargantua.core",
    category: "ClaudeCodeOrganizerProposer"
)

/// File-organization proposer routed through the user's `claude` CLI
/// (the same one the Claude Code agent feature uses). Spawns a one-shot
/// `claude -p "<prompt>" --output-format text --max-turns 1` subprocess,
/// captures stdout, and feeds the response into the existing
/// `CloudOrganizerProposer.parseResponse` parser.
///
/// Reuses the agent's configuration (CLI path + selectedModel) so a
/// user who has Claude Code set up doesn't need a separate Anthropic
/// API key for the organizer.
public struct ClaudeCodeOrganizerProposer: Sendable {
    private let configurationStore: ClaudeCodeAgentConfigurationStore
    private let cliResolver: ClaudeCodeCLIResolver
    private let processFactory: @Sendable () -> Process
    private let now: @Sendable () -> Date
    private let fileManager: FileManager
    private let timeoutSeconds: Int

    public init(
        configurationStore: ClaudeCodeAgentConfigurationStore = ClaudeCodeAgentConfigurationStore(),
        cliResolver: ClaudeCodeCLIResolver = ClaudeCodeCLIResolver(),
        processFactory: @Sendable @escaping () -> Process = { Process() },
        now: @Sendable @escaping () -> Date = Date.init,
        fileManager: FileManager = .default,
        timeoutSeconds: Int = 90
    ) {
        self.configurationStore = configurationStore
        self.cliResolver = cliResolver
        self.processFactory = processFactory
        self.now = now
        self.fileManager = fileManager
        self.timeoutSeconds = timeoutSeconds
    }

    public func propose(sourceFolder: URL) async throws -> OrganizationProposal {
        let configuration = configurationStore.load()
        guard configuration.isEnabled else {
            throw ClaudeCodeOrganizerError.agentNotEnabled
        }
        let executable = try cliResolver.resolve(configuration: configuration)

        let listing = try CloudOrganizerProposer.listFolder(at: sourceFolder, fileManager: fileManager)
        let prompt = try CloudOrganizerProposer.buildPrompt(
            folderName: sourceFolder.lastPathComponent,
            items: listing
        )

        let output = try await runOneShot(
            executable: executable,
            prompt: prompt,
            model: configuration.selectedModel
        )

        return try CloudOrganizerProposer.parseResponse(
            text: output,
            sourceFolder: sourceFolder,
            listing: listing,
            generatedAt: now()
        )
    }

    private func runOneShot(executable: URL, prompt: String, model: String) async throws -> String {
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
            "--mcp-config",
            emptyMCPConfig.path,
            "--strict-mcp-config",
        ]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            arguments += ["--model", trimmedModel]
        }

        claudeCodeOrganizerLogger.error(
            "claude one-shot start: \(executable.path, privacy: .public) prompt-len=\(prompt.count) model=\(trimmedModel, privacy: .public)"
        )

        let processBox = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = processFactory()
                processBox.process = process
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let stdoutBuffer = DataBuffer()
                let stderrBuffer = DataBuffer()
                let resumed = AtomicFlag()

                let pipes = SubprocessPipes(stdout: stdoutPipe, stderr: stderrPipe)
                let buffers = SubprocessBuffers(stdout: stdoutBuffer, stderr: stderrBuffer)
                configure(
                    process: process,
                    executable: executable,
                    arguments: arguments,
                    pipes: pipes
                )
                attachReadabilityHandlers(pipes: pipes, buffers: buffers)
                process.terminationHandler = makeTerminationHandler(
                    pipes: pipes,
                    buffers: buffers,
                    resumed: resumed,
                    continuation: continuation
                )
                spawnTimeoutWatcher(process: process, resumed: resumed, continuation: continuation)

                do {
                    try process.run()
                } catch {
                    if resumed.takeIfFalse() {
                        continuation.resume(throwing: error)
                    }
                }
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
    private func attachReadabilityHandlers(pipes: SubprocessPipes, buffers: SubprocessBuffers) {
        pipes.stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                buffers.stdout.append(chunk)
            }
        }
        pipes.stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                buffers.stderr.append(chunk)
            }
        }
    }

    private func makeTerminationHandler(
        pipes: SubprocessPipes,
        buffers: SubprocessBuffers,
        resumed: AtomicFlag,
        continuation: CheckedContinuation<String, Error>
    ) -> @Sendable (Process) -> Void {
        return { proc in
            pipes.stdout.fileHandleForReading.readabilityHandler = nil
            pipes.stderr.fileHandleForReading.readabilityHandler = nil
            if let remaining = try? pipes.stdout.fileHandleForReading.readToEnd() {
                buffers.stdout.append(remaining)
            }
            if let remaining = try? pipes.stderr.fileHandleForReading.readToEnd() {
                buffers.stderr.append(remaining)
            }

            guard resumed.takeIfFalse() else { return }
            let stdout = buffers.stdout.snapshot()
            let stderr = buffers.stderr.snapshot()
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            claudeCodeOrganizerLogger.error(
                "claude one-shot exit: status=\(status) reason=\(reason.rawValue) stdout-bytes=\(stdout.count) stderr-bytes=\(stderr.count)"
            )
            if status == 0, reason == .exit {
                if let text = String(data: stdout, encoding: .utf8), !text.isEmpty {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: ClaudeCodeOrganizerError.emptyResponse)
                }
            } else {
                let stderrString = String(data: stderr, encoding: .utf8) ?? ""
                claudeCodeOrganizerLogger.error(
                    "claude CLI stderr: \(stderrString.prefix(600), privacy: .public)"
                )
                continuation.resume(throwing: ClaudeCodeOrganizerError.cliFailed(
                    exitCode: Int(status),
                    stderr: stderrString
                ))
            }
        }
    }

    private func spawnTimeoutWatcher(
        process: Process,
        resumed: AtomicFlag,
        continuation: CheckedContinuation<String, Error>
    ) {
        let seconds = timeoutSeconds
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            if process.isRunning, resumed.takeIfFalse() {
                claudeCodeOrganizerLogger.error(
                    "claude CLI timed out after \(seconds)s — terminating subprocess"
                )
                process.terminate()
                continuation.resume(throwing: ClaudeCodeOrganizerError.timedOut(seconds: seconds))
            }
        }
    }

    private func writeEmptyMCPConfig() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("gargantua-organizer-mcp-\(UUID().uuidString).json")
        try Data(#"{"mcpServers":{}}"#.utf8).write(to: url)
        return url
    }
}

/// Shared mutable handle to the in-flight subprocess so the cancel
/// callback can reach it from outside the continuation closure.
private final class ProcessBox: @unchecked Sendable {
    var process: Process?
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

public enum ClaudeCodeOrganizerError: Error, LocalizedError, Equatable {
    case agentNotEnabled
    case cliFailed(exitCode: Int, stderr: String)
    case emptyResponse
    case timedOut(seconds: Int)

    public var errorDescription: String? {
        switch self {
        case .agentNotEnabled:
            return "Claude Code agent is not enabled. Turn it on in Settings → AI → Claude Code Agent."
        case .cliFailed(let exitCode, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "claude CLI exited with status \(exitCode)."
            }
            return "claude CLI failed: \(trimmed)"
        case .emptyResponse:
            return "claude CLI returned no output."
        case .timedOut(let seconds):
            return "claude CLI didn't respond within \(seconds)s. Try Cloud or On-device rules, or check that the CLI is logged in."
        }
    }
}
