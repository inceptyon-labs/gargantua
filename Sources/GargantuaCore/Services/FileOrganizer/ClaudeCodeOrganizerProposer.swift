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

    public init(
        configurationStore: ClaudeCodeAgentConfigurationStore = ClaudeCodeAgentConfigurationStore(),
        cliResolver: ClaudeCodeCLIResolver = ClaudeCodeCLIResolver(),
        processFactory: @Sendable @escaping () -> Process = { Process() },
        now: @Sendable @escaping () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.configurationStore = configurationStore
        self.cliResolver = cliResolver
        self.processFactory = processFactory
        self.now = now
        self.fileManager = fileManager
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
        var arguments = [
            "-p",
            prompt,
            "--output-format",
            "text",
            "--max-turns",
            "1",
        ]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            arguments += ["--model", trimmedModel]
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = processFactory()
            process.executableURL = executable
            process.arguments = arguments
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let stdout = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stderr = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                if proc.terminationStatus == 0 {
                    if let text = String(data: stdout, encoding: .utf8), !text.isEmpty {
                        continuation.resume(returning: text)
                    } else {
                        continuation.resume(throwing: ClaudeCodeOrganizerError.emptyResponse)
                    }
                } else {
                    let stderrString = String(data: stderr, encoding: .utf8) ?? ""
                    claudeCodeOrganizerLogger.error(
                        "claude CLI exited \(proc.terminationStatus): \(stderrString.prefix(400), privacy: .public)"
                    )
                    continuation.resume(throwing: ClaudeCodeOrganizerError.cliFailed(
                        exitCode: Int(proc.terminationStatus),
                        stderr: stderrString
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

public enum ClaudeCodeOrganizerError: Error, LocalizedError, Equatable {
    case agentNotEnabled
    case cliFailed(exitCode: Int, stderr: String)
    case emptyResponse

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
        }
    }
}
