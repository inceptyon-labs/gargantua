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
    /// Item IDs the agent requested to clean, parsed from the structured
    /// `mcp__gargantua__clean` tool_use payload. Empty when only the
    /// substring fallback fired (older transcript shapes, malformed JSON,
    /// or future schema drift) — in that case the host has nothing to
    /// hydrate against and approval becomes a no-op confirmation.
    public let proposedItemIDs: [String]

    /// Creates an approval gate for a detected destructive action.
    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        requestedAt: Date = Date(),
        decidedAt: Date? = nil,
        status: ClaudeCodeAgentApprovalStatus = .pending,
        summary: String,
        rawTranscript: String,
        proposedItemIDs: [String] = []
    ) {
        self.id = id
        self.sessionID = sessionID
        self.requestedAt = requestedAt
        self.decidedAt = decidedAt
        self.status = status
        self.summary = summary
        self.rawTranscript = rawTranscript
        self.proposedItemIDs = proposedItemIDs
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

    /// True only when no session has been started yet (or the controller has
    /// been reset to idle). Used by the Agent Run view to decide whether to
    /// surface the status card — idle is already covered by the transcript
    /// empty state.
    public var isIdle: Bool {
        if case .idle = self { return true }
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

        // Resolve the working directory the agent process will launch in.
        // When the caller doesn't supply one, default to a per-session scratch
        // directory under tempDirectory rather than inheriting the parent
        // process CWD (which would expose whatever the user happened to launch
        // Gargantua from to Claude Code's allowed-write sandbox). The scratch
        // dir gives Claude a predictable, isolated place to work; nothing in
        // it survives across sessions.
        let resolvedWorkingDirectory: URL
        if let workingDirectory {
            resolvedWorkingDirectory = workingDirectory
        } else {
            let scratch = tempDirectory
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            try? fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            resolvedWorkingDirectory = scratch
        }

        // Scheduled-audit hooks (the only call site that passes `false` here)
        // force the agent into a strictly read-only launch — no clean tool at
        // all, even in dry-run mode, because there is no user present to
        // review a propose call. Interactive sessions ignore the legacy
        // `allowDestructiveMCPTools` configuration field entirely; the agent
        // is always given the `clean` tool, calls it with `dry_run: true` to
        // propose a cleanup set, and the host's gate detector raises the
        // review modal. Actual deletion runs in the host through
        // `CleanupEngine` after the user clicks Clean — same pipeline Deep
        // Scan uses.
        let forceReadOnly: Bool
        if let override = allowDestructiveMCPToolsOverride {
            forceReadOnly = !override
        } else {
            forceReadOnly = false
        }

        var allowedTools = ClaudeCodeAgentPromptBuilder.readOnlyToolAllowlist
        if forceReadOnly {
            allowedTools.removeAll { $0 == ClaudeCodeAgentPromptBuilder.destructiveTool }
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

        let modelOverride = configuration.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelOverride.isEmpty {
            arguments += ["--model", modelOverride]
        }

        if forceReadOnly {
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
            workingDirectory: resolvedWorkingDirectory,
            mcpConfigURL: mcpConfigURL
        )
    }

    /// Root under which `makeLaunchPlan` creates per-session scratch
    /// directories when the caller doesn't supply an explicit working
    /// directory. Surfaced so the agent UI can show users where the agent
    /// can write.
    public var sessionsRoot: URL {
        tempDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Starts Claude Code, streams transcript events, and captures destructive-action gates.
    ///
    /// `onStreamEvent` receives parsed `--output-format stream-json` events
    /// alongside the raw text fed to `onEvent`. Callers that don't need the
    /// parsed feed (existing tests, scheduled audits) can pass `nil` and rely
    /// on the raw transcript only.
    public func run(
        prompt: String,
        sessionID: UUID = UUID(),
        workingDirectory: URL? = nil,
        allowDestructiveMCPToolsOverride: Bool? = nil,
        onEvent: @escaping @Sendable (ClaudeCodeAgentTranscriptEvent) -> Void,
        onGate: @escaping @Sendable (ClaudeCodeAgentApprovalGate) -> Void,
        onStreamEvent: (@Sendable (ClaudeCodeStreamEvent) -> Void)? = nil
    ) async throws -> ClaudeCodeAgentSessionResult {
        let plan = try makeLaunchPlan(
            prompt: prompt,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            allowDestructiveMCPToolsOverride: allowDestructiveMCPToolsOverride
        )
        let gates = GateAccumulator()
        let detector = ClaudeCodeDestructiveActionDetector(sessionID: sessionID)
        let parser = ClaudeCodeStreamJSONParser()
        let lineBuffer = ClaudeCodeLineBuffer { line in
            // Parse first so the detector can consume any structured payload
            // (clean tool_use → item IDs) the parser exposes. Falls back to
            // pure substring detection when the line doesn't JSON-parse —
            // covers free-form transcript fragments and parser drift.
            let parsedEvent = parser.parse(line: line)
            var proposedItemIDs: [String] = []
            if case let .toolUse(_, _, .cleanRequest(itemIDs)) = parsedEvent {
                proposedItemIDs = itemIDs
            }
            if let gate = detector.detect(line, proposedItemIDs: proposedItemIDs) {
                gates.append(gate)
                onGate(gate)
                self.recordAgentAudit(command: "agent_gate_detected", sessionID: sessionID)
            }
            if let onStreamEvent, let event = parsedEvent {
                onStreamEvent(event)
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

    /// Returns an approval gate when the structured stream parser has
    /// identified a `mcp__gargantua__clean` tool_use with at least one
    /// item ID.
    ///
    /// The previous substring-matching fallback (firing when a transcript
    /// line contained both `mcp__gargantua__clean` and `item_ids`) was
    /// removed: the agent prompt now instructs the agent to use exactly those
    /// tokens to describe its plan, so every assistant message echoing the
    /// plan was tripping a duplicate gate. The structured parser is the only
    /// reliable signal for "the agent is making a clean call", and it
    /// populates `proposedItemIDs` on success.
    public func detect(
        _ line: String,
        proposedItemIDs: [String] = []
    ) -> ClaudeCodeAgentApprovalGate? {
        guard !proposedItemIDs.isEmpty else { return nil }

        let summary = proposedItemIDs.count == 1
            ? "Claude Code requested Gargantua MCP clean for 1 item."
            : "Claude Code requested Gargantua MCP clean for \(proposedItemIDs.count) items."
        return ClaudeCodeAgentApprovalGate(
            sessionID: sessionID,
            summary: summary,
            rawTranscript: line,
            proposedItemIDs: proposedItemIDs
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
