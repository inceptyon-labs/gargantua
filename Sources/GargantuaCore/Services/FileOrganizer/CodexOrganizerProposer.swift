import Foundation
import OSLog

private let codexOrganizerLogger = Logger(
    subsystem: "com.gargantua.core",
    category: "CodexOrganizerProposer"
)

/// File-organization proposer routed through the user's `codex` CLI
/// (`codex exec` one-shot). Mirrors the Claude Code path: same cluster
/// prompt, same response schema, same reassembly + validate() pipeline.
/// Uses `--output-last-message` so we read only the assistant's final
/// reply from a temp file rather than parsing the JSONL event stream.
public struct CodexOrganizerProposer: @unchecked Sendable {
    private let configurationStore: CodexAgentConfigurationStore
    private let cliResolver: CodexCLIResolver
    private let processFactory: @Sendable () -> Process
    private let now: @Sendable () -> Date
    private let fileManager: FileManager
    private let timeoutSeconds: Int

    public init(
        configurationStore: CodexAgentConfigurationStore = CodexAgentConfigurationStore(),
        cliResolver: CodexCLIResolver = CodexCLIResolver(),
        processFactory: @Sendable @escaping () -> Process = { Process() },
        now: @Sendable @escaping () -> Date = { Date() },
        fileManager: FileManager = .default,
        timeoutSeconds: Int = 240
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
            throw CodexAgentError.disabled
        }
        let executable = try cliResolver.resolve(configuration: configuration)

        let listing = try CloudOrganizerProposer.listFolder(at: sourceFolder, fileManager: fileManager)
        let clusters = OrganizerClusterer.cluster(listing)
        let prompt = CloudOrganizerProposer.buildPrompt(
            folderName: sourceFolder.lastPathComponent,
            clusters: clusters
        )

        let output = try await runOneShot(
            executable: executable,
            prompt: prompt,
            model: configuration.selectedModel
        )

        return try CloudOrganizerProposer.parseResponse(
            text: output,
            sourceFolder: sourceFolder,
            clusters: clusters,
            backend: .cloud,
            generatedAt: now()
        )
    }

    private func runOneShot(executable: URL, prompt: String, model: String) async throws -> String {
        let lastMessageFile = fileManager.temporaryDirectory
            .appendingPathComponent("gargantua-codex-out-\(UUID().uuidString).txt")
        defer { try? fileManager.removeItem(at: lastMessageFile) }

        var arguments = [
            "exec",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "-o", lastMessageFile.path,
        ]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            arguments += ["--model", trimmedModel]
        }
        arguments.append(prompt)

        codexOrganizerLogger.error(
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

        // Process exited successfully — read the last-message file. If
        // the file is missing or empty the CLI may have errored out
        // before writing it; surface as emptyResponse.
        guard let data = try? Data(contentsOf: lastMessageFile),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CodexOrganizerError.emptyResponse
        }
        return text
    }

    private func configure(
        process: Process,
        executable: URL,
        arguments: [String],
        pipes: CodexSubprocessPipes
    ) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipes.stdout
        process.standardError = pipes.stderr
    }

    private func attachReadabilityHandlers(pipes: CodexSubprocessPipes, buffers: CodexSubprocessBuffers) {
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
        pipes: CodexSubprocessPipes,
        buffers: CodexSubprocessBuffers,
        resumed: CodexAtomicFlag,
        continuation: CheckedContinuation<Void, Error>
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
            let status = proc.terminationStatus
            let stderrString = String(data: buffers.stderr.snapshot(), encoding: .utf8) ?? ""
            codexOrganizerLogger.error(
                "codex one-shot exit: status=\(status) stderr-bytes=\(stderrString.count)"
            )
            if status == 0, proc.terminationReason == .exit {
                continuation.resume(returning: ())
            } else {
                codexOrganizerLogger.error(
                    "codex CLI stderr: \(stderrString.prefix(600), privacy: .public)"
                )
                continuation.resume(throwing: CodexOrganizerError.cliFailed(
                    exitCode: Int(status),
                    stderr: stderrString
                ))
            }
        }
    }

    private func spawnTimeoutWatcher(
        process: Process,
        resumed: CodexAtomicFlag,
        continuation: CheckedContinuation<Void, Error>
    ) {
        let seconds = timeoutSeconds
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            if process.isRunning, resumed.takeIfFalse() {
                codexOrganizerLogger.error(
                    "codex CLI timed out after \(seconds)s — terminating subprocess"
                )
                process.terminate()
                continuation.resume(throwing: CodexOrganizerError.timedOut(seconds: seconds))
            }
        }
    }
}

public enum CodexOrganizerError: Error, LocalizedError, Equatable {
    case cliFailed(exitCode: Int, stderr: String)
    case emptyResponse
    case timedOut(seconds: Int)

    public var errorDescription: String? {
        switch self {
        case .cliFailed(let exitCode, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "codex CLI exited with status \(exitCode)."
            }
            return "codex CLI failed: \(trimmed)"
        case .emptyResponse:
            return "codex CLI returned no output. Check that you're logged in (`codex login`)."
        case .timedOut(let seconds):
            return "codex CLI didn't respond within \(seconds)s. Try Cloud, Claude Code, or On-device rules."
        }
    }
}

private final class CodexProcessBox: @unchecked Sendable {
    var process: Process?
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
