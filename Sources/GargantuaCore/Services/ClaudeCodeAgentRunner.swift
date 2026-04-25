import Foundation

public enum ClaudeCodeAgentTranscriptStream: String, Codable, Sendable {
    case system
    case stdout
    case stderr
    case audit
}

public struct ClaudeCodeAgentTranscriptEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let stream: ClaudeCodeAgentTranscriptStream
    public let message: String

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

public enum ClaudeCodeAgentApprovalStatus: String, Codable, Equatable, Sendable {
    case pending
    case approved
    case denied
}

public struct ClaudeCodeAgentApprovalGate: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let requestedAt: Date
    public var decidedAt: Date?
    public var status: ClaudeCodeAgentApprovalStatus
    public let summary: String
    public let rawTranscript: String

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

public enum ClaudeCodeAgentSessionStatus: Equatable, Sendable {
    case idle
    case running
    case completed
    case failed(String)
    case cancelled

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

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

public struct ClaudeCodeAgentLaunchPlan: Equatable, Sendable {
    public let sessionID: UUID
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL?
    public let mcpConfigURL: URL

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

public struct ClaudeCodeAgentSessionResult: Equatable, Sendable {
    public let sessionID: UUID
    public let exitCode: Int32
    public let approvalGates: [ClaudeCodeAgentApprovalGate]
}

public final class ClaudeCodeAgentSessionRunner: @unchecked Sendable {
    public static let defaultAllowedTools = ClaudeCodeAgentPromptBuilder.readOnlyToolAllowlist.joined(separator: ",")

    private let configurationStore: ClaudeCodeAgentConfigurationStore
    private let cliResolver: ClaudeCodeCLIResolver
    private let mcpServerLaunch: ClaudeCodeMCPServerLaunch
    private let processExecutor: any ClaudeCodeAgentProcessExecuting
    private let auditWriter: AuditWriter
    private let tempDirectory: URL
    private let fileManager: FileManager

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

    public func cancel() {
        processExecutor.cancel()
    }

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
        try? auditWriter.write(entry)
    }
}

public protocol ScheduledScanAgentAuditHook: Sendable {
    func run(summary: ScheduledScanSummary) async
}

public struct NoopScheduledScanAgentAuditHook: ScheduledScanAgentAuditHook {
    public init() {}
    public func run(summary: ScheduledScanSummary) async {}
}

public struct ClaudeCodeScheduledAgentAuditHook: ScheduledScanAgentAuditHook {
    private let configurationStore: ClaudeCodeAgentConfigurationStore
    private let runner: ClaudeCodeAgentSessionRunner

    public init(
        configurationStore: ClaudeCodeAgentConfigurationStore = ClaudeCodeAgentConfigurationStore(),
        runner: ClaudeCodeAgentSessionRunner? = nil
    ) {
        self.configurationStore = configurationStore
        self.runner = runner ?? ClaudeCodeAgentSessionRunner(configurationStore: configurationStore)
    }

    public func run(summary: ScheduledScanSummary) async {
        let configuration = configurationStore.load()
        guard configuration.isEnabled, configuration.runAfterScheduledScans else { return }

        let prompt = ClaudeCodeAgentPromptBuilder.scheduledAuditPrompt(summary: summary)
        _ = try? await runner.run(
            prompt: prompt,
            allowDestructiveMCPToolsOverride: false,
            onEvent: { _ in },
            onGate: { _ in }
        )
    }
}

public struct ClaudeCodeDestructiveActionDetector: Sendable {
    public let sessionID: UUID

    public init(sessionID: UUID) {
        self.sessionID = sessionID
    }

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
