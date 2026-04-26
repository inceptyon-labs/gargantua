import Foundation
import OSLog

private let runnerLogger = Logger(subsystem: "com.gargantua.core", category: "ClaudeCodeAgentRunner")

/// Output stream categories captured from a Claude Code agent session.
public enum ClaudeCodeAgentTranscriptStream: String, Codable, Sendable {
    /// Internal status messages emitted by Gargantua.
    case system
    /// Standard output emitted by the Claude Code process.
    case stdout
    /// Standard error emitted by the Claude Code process.
    case stderr
    /// Audit-specific session events.
    case audit
}

/// Timestamped transcript event for an agent session.
public struct ClaudeCodeAgentTranscriptEvent: Identifiable, Codable, Equatable, Sendable {
    /// Stable event identifier.
    public let id: UUID
    /// Time when the event was captured.
    public let timestamp: Date
    /// Stream that produced the event.
    public let stream: ClaudeCodeAgentTranscriptStream
    /// Event text.
    public let message: String

    /// Creates a transcript event.
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        stream: ClaudeCodeAgentTranscriptStream,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.stream = stream
        self.message = message
    }
}

/// Approval decision state for destructive agent actions.
public enum ClaudeCodeAgentApprovalStatus: String, Codable, Equatable, Sendable {
    /// The action is awaiting a user decision.
    case pending
    /// The user approved the action.
    case approved
    /// The user denied the action.
    case denied
}

/// User approval gate raised when Claude Code requests destructive MCP tools.
public struct ClaudeCodeAgentApprovalGate: Identifiable, Codable, Equatable, Sendable {
    /// Stable approval gate identifier.
    public let id: UUID
    /// Agent session that produced the gate.
    public let sessionID: UUID
    /// Time when the gate was requested.
    public let requestedAt: Date
    /// Time when the gate was decided.
    public var decidedAt: Date?
    /// Current approval status.
    public var status: ClaudeCodeAgentApprovalStatus
    /// Short user-facing summary of the requested action.
    public let summary: String
    /// Raw transcript line that triggered the gate.
    public let rawTranscript: String

    /// Creates an approval gate for a detected destructive action.
    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        requestedAt: Date = Date(),
        decidedAt: Date? = nil,
        status: ClaudeCodeAgentApprovalStatus = .pending,
        summary: String,
        rawTranscript: String
    ) {
        self.id = id
        self.sessionID = sessionID
        self.requestedAt = requestedAt
        self.decidedAt = decidedAt
        self.status = status
        self.summary = summary
        self.rawTranscript = rawTranscript
    }
}

/// High-level lifecycle state for a Claude Code agent session.
public enum ClaudeCodeAgentSessionStatus: Equatable, Sendable {
    /// No session is currently active.
    case idle
    /// A session process is currently running.
    case running
    /// The session completed successfully.
    case completed
    /// The session failed with a message.
    case failed(String)
    /// The session was cancelled by the user.
    case cancelled

    /// Whether the status represents an active running session.
    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// Short user-facing status label.
    public var label: String {
        switch self {
        case .idle: "Ready"
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

/// Resolved process launch details for a Claude Code agent session.
public struct ClaudeCodeAgentLaunchPlan: Equatable, Sendable {
    /// Session identifier passed to the agent environment.
    public let sessionID: UUID
    /// Resolved Claude Code executable URL.
    public let executableURL: URL
    /// Command-line arguments for the process.
    public let arguments: [String]
    /// Environment variables for the process.
    public let environment: [String: String]
    /// Optional working directory for the process.
    public let workingDirectory: URL?
    /// Temporary MCP configuration file URL.
    public let mcpConfigURL: URL

    /// Creates a resolved launch plan.
    public init(
        sessionID: UUID,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        mcpConfigURL: URL
    ) {
        self.sessionID = sessionID
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.mcpConfigURL = mcpConfigURL
    }
}

/// Terminal result for a Claude Code agent session.
public struct ClaudeCodeAgentSessionResult: Equatable, Sendable {
    /// Session identifier associated with the result.
    public let sessionID: UUID
    /// Process exit code.
    public let exitCode: Int32
    /// Approval gates detected during the session.
    public let approvalGates: [ClaudeCodeAgentApprovalGate]
}

/// Builds and runs Claude Code sessions against Gargantua's MCP server.
public final class ClaudeCodeAgentSessionRunner: @unchecked Sendable {
    /// Comma-separated read-only tool allowlist used by default.
    public static let defaultAllowedTools = ClaudeCodeAgentPromptBuilder.readOnlyToolAllowlist.joined(separator: ",")

    private let configurationStore: ClaudeCodeAgentConfigurationStore
    private let cliResolver: ClaudeCodeCLIResolver
    private let mcpServerLaunch: ClaudeCodeMCPServerLaunch
    private let processExecutor: any ClaudeCodeAgentProcessExecuting
    private let auditWriter: AuditWriter
    private let tempDirectory: URL
    private let fileManager: FileManager

    /// Creates a session runner with injected stores, resolver, process executor, and filesystem dependencies.
    public init(
        configurationStore: ClaudeCodeAgentConfigurationStore = ClaudeCodeAgentConfigurationStore(),
        cliResolver: ClaudeCodeCLIResolver = ClaudeCodeCLIResolver(),
        mcpServerLaunch: ClaudeCodeMCPServerLaunch = ClaudeCodeMCPConfigBuilder.defaultServerLaunch(),
        processExecutor: any ClaudeCodeAgentProcessExecuting = FoundationClaudeCodeProcessExecutor(),
        auditWriter: AuditWriter = AuditWriter(),
        tempDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("GargantuaClaudeCode", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.configurationStore = configurationStore
        self.cliResolver = cliResolver
        self.mcpServerLaunch = mcpServerLaunch
        self.processExecutor = processExecutor
        self.auditWriter = auditWriter
        self.tempDirectory = tempDirectory
        self.fileManager = fileManager
    }

    /// Resolves configuration and writes the temporary MCP config needed to start a session.
    public func makeLaunchPlan(
        prompt: String,
        sessionID: UUID = UUID(),
        workingDirectory: URL? = nil,
        allowDestructiveMCPToolsOverride: Bool? = nil
    ) throws -> ClaudeCodeAgentLaunchPlan {
        let configuration = configurationStore.load()
        guard configuration.isEnabled else {
            throw ClaudeCodeAgentError.disabled
        }

        let executable = try cliResolver.resolve(configuration: configuration)
        let mcpConfigURL = try ClaudeCodeMCPConfigBuilder.writeConfiguration(
            server: mcpServerLaunch,
            sessionID: sessionID,
            directory: tempDirectory,
            fileManager: fileManager
        )

        let allowDestructiveMCPTools = allowDestructiveMCPToolsOverride ?? configuration.allowDestructiveMCPTools
        var allowedTools = ClaudeCodeAgentPromptBuilder.readOnlyToolAllowlist
        if allowDestructiveMCPTools {
            allowedTools.append(ClaudeCodeAgentPromptBuilder.destructiveTool)
        }

        var arguments = [
            "-p",
            prompt,
            "--mcp-config",
            mcpConfigURL.path,
            "--strict-mcp-config",
            "--output-format",
            "stream-json",
            "--verbose",
            "--max-turns",
            "\(configuration.maxTurns)",
            "--allowedTools",
            allowedTools.joined(separator: ","),
        ]

        if !allowDestructiveMCPTools {
            arguments += [
                "--disallowedTools",
                ClaudeCodeAgentPromptBuilder.destructiveTool,
            ]
        }

        return ClaudeCodeAgentLaunchPlan(
            sessionID: sessionID,
            executableURL: executable,
            arguments: arguments,
            environment: [
                "GARGANTUA_AGENT_SESSION_ID": sessionID.uuidString,
            ],
            workingDirectory: workingDirectory,
            mcpConfigURL: mcpConfigURL
        )
    }

    /// Starts Claude Code, streams transcript events, and captures destructive-action gates.
    public func run(
        prompt: String,
        sessionID: UUID = UUID(),
        workingDirectory: URL? = nil,
        allowDestructiveMCPToolsOverride: Bool? = nil,
        onEvent: @escaping @Sendable (ClaudeCodeAgentTranscriptEvent) -> Void,
        onGate: @escaping @Sendable (ClaudeCodeAgentApprovalGate) -> Void
    ) async throws -> ClaudeCodeAgentSessionResult {
        let plan = try makeLaunchPlan(
            prompt: prompt,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            allowDestructiveMCPToolsOverride: allowDestructiveMCPToolsOverride
        )
        let gates = GateAccumulator()
        let detector = ClaudeCodeDestructiveActionDetector(sessionID: sessionID)
        let lineBuffer = ClaudeCodeLineBuffer { line in
            if let gate = detector.detect(line) {
                gates.append(gate)
                onGate(gate)
                self.recordAgentAudit(command: "agent_gate_detected", sessionID: sessionID)
            }
        }

        recordAgentAudit(command: "agent_start", sessionID: sessionID)
        onEvent(ClaudeCodeAgentTranscriptEvent(
            stream: .system,
            message: "Starting Claude Code with Gargantua MCP config \(plan.mcpConfigURL.lastPathComponent)."
        ))

        do {
            let exitCode = try await processExecutor.start(
                executable: plan.executableURL,
                arguments: plan.arguments,
                environment: plan.environment,
                workingDirectory: plan.workingDirectory
            ) { output in
                switch output {
                case .stdout(let text):
                    lineBuffer.append(text)
                    onEvent(ClaudeCodeAgentTranscriptEvent(stream: .stdout, message: text))
                case .stderr(let text):
                    onEvent(ClaudeCodeAgentTranscriptEvent(stream: .stderr, message: text))
                }
            }

            lineBuffer.finish()
            if exitCode == 0 {
                recordAgentAudit(command: "agent_complete", sessionID: sessionID)
            } else {
                recordAgentAudit(command: "agent_failed", sessionID: sessionID)
            }
            return ClaudeCodeAgentSessionResult(
                sessionID: sessionID,
                exitCode: exitCode,
                approvalGates: gates.all()
            )
        } catch {
            recordAgentAudit(command: "agent_failed", sessionID: sessionID)
            throw error
        }
    }

    /// Cancels the active process through the configured executor.
    public func cancel() {
        processExecutor.cancel()
    }

    /// Writes an audit event for the agent session.
    public func recordAgentAudit(command: String, sessionID: UUID) {
        let entry = AuditEntry(
            tool: "claude-code",
            command: command,
            files: [],
            safetyLevel: .review,
            confirmationMethod: .mcp,
            cleanupMethod: .toolNative,
            bytesFreed: 0,
            transport: "agent",
            clientID: sessionID.uuidString
        )
        do {
            try auditWriter.write(entry)
        } catch {
            runnerLogger.warning("Failed to write agent audit entry: \(error.localizedDescription)")
        }
    }
}

/// Hook that can run follow-up agent work after scheduled scans.
public protocol ScheduledScanAgentAuditHook: Sendable {
    func run(summary: ScheduledScanSummary) async
}

/// Scheduled scan audit hook that performs no work.
public struct NoopScheduledScanAgentAuditHook: ScheduledScanAgentAuditHook {
    /// Creates a no-op scheduled scan audit hook.
    public init() {}
    /// Ignores the scheduled scan summary.
    public func run(summary: ScheduledScanSummary) async {}
}

/// Runs a read-only Claude Code audit after scheduled scans when enabled.
public struct ClaudeCodeScheduledAgentAuditHook: ScheduledScanAgentAuditHook {
    private let configurationStore: ClaudeCodeAgentConfigurationStore
    private let runner: ClaudeCodeAgentSessionRunner

    /// Creates an audit hook with optional runner injection.
    public init(
        configurationStore: ClaudeCodeAgentConfigurationStore = ClaudeCodeAgentConfigurationStore(),
        runner: ClaudeCodeAgentSessionRunner? = nil
    ) {
        self.configurationStore = configurationStore
        self.runner = runner ?? ClaudeCodeAgentSessionRunner(configurationStore: configurationStore)
    }

    /// Runs the scheduled-scan prompt when the Claude Code integration allows it.
    public func run(summary: ScheduledScanSummary) async {
        let configuration = configurationStore.load()
        guard configuration.isEnabled, configuration.runAfterScheduledScans else { return }

        let prompt = ClaudeCodeAgentPromptBuilder.scheduledAuditPrompt(summary: summary)
        do {
            _ = try await runner.run(
                prompt: prompt,
                allowDestructiveMCPToolsOverride: false,
                onEvent: { _ in },
                onGate: { _ in }
            )
        } catch {
            runnerLogger.warning("Scheduled Claude Code audit hook failed: \(error.localizedDescription)")
        }
    }
}

/// Detects transcript lines where Claude Code requested destructive MCP cleanup.
public struct ClaudeCodeDestructiveActionDetector: Sendable {
    /// Session identifier to attach to approval gates.
    public let sessionID: UUID

    /// Creates a detector for a specific agent session.
    public init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    /// Returns an approval gate when the transcript line mentions MCP cleanup with item IDs.
    public func detect(_ line: String) -> ClaudeCodeAgentApprovalGate? {
        let normalized = line.lowercased()
        let mentionsCleanTool = normalized.contains("mcp__gargantua__clean")
            || normalized.contains("\"name\":\"clean\"")
            || normalized.contains("\"name\": \"clean\"")
        let mentionsItemIDs = normalized.contains("item_ids") || normalized.contains("item ids")
        guard mentionsCleanTool && mentionsItemIDs else { return nil }

        return ClaudeCodeAgentApprovalGate(
            sessionID: sessionID,
            summary: "Claude Code requested Gargantua MCP clean.",
            rawTranscript: line
        )
    }
}

private final class GateAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [ClaudeCodeAgentApprovalGate] = []

    func append(_ gate: ClaudeCodeAgentApprovalGate) {
        lock.lock()
        gates.append(gate)
        lock.unlock()
    }

    func all() -> [ClaudeCodeAgentApprovalGate] {
        lock.lock()
        defer { lock.unlock() }
        return gates
    }
}

private final class ClaudeCodeLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ text: String) {
        lock.lock()
        pending.append(text)
        let lines = pending.components(separatedBy: .newlines)
        pending = lines.last ?? ""
        let complete = lines.dropLast()
        lock.unlock()

        for line in complete where !line.isEmpty {
            onLine(line)
        }
    }

    func finish() {
        lock.lock()
        let line = pending
        pending = ""
        lock.unlock()

        if !line.isEmpty {
            onLine(line)
        }
    }
}
