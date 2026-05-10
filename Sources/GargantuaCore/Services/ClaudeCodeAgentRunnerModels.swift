import Foundation

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
