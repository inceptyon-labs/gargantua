import Foundation

/// A record of a destructive operation for the audit trail.
///
/// Logged to ~/Library/Logs/Gargantua/audit.json (JSONL format).
public struct AuditEntry: Codable, Sendable, Identifiable {
    public let id: UUID

    /// When the operation occurred.
    public let timestamp: Date

    /// Which engine/tool performed the operation (e.g., "native").
    public let tool: String

    /// The command or action taken (e.g., "clean", "purge").
    public let command: String

    /// Files affected by this operation.
    public let files: [AuditFile]

    /// The safety level of the items that were cleaned.
    public let safetyLevel: SafetyLevel

    /// How the user confirmed the operation.
    public let confirmationMethod: ConfirmationTier

    /// The cleanup method used.
    public let cleanupMethod: CleanupMethod

    /// Total bytes freed by this operation.
    public let bytesFreed: Int64

    /// Where the operation originated. `nil` for in-app actions (default);
    /// `"mcp"` for actions invoked by an MCP client. Optional so existing
    /// JSONL entries and persisted rows predating Phase 3 decode cleanly.
    public let transport: String?

    /// Identifier of the MCP client that initiated the operation, when
    /// `transport == "mcp"`. Taken from the `initialize` handshake's
    /// `clientInfo.name`; `"unknown"` if the client did not advertise one.
    /// Always nil for in-app actions.
    public let clientID: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        tool: String,
        command: String,
        files: [AuditFile],
        safetyLevel: SafetyLevel,
        confirmationMethod: ConfirmationTier,
        cleanupMethod: CleanupMethod = .trash,
        bytesFreed: Int64,
        transport: String? = nil,
        clientID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.tool = tool
        self.command = command
        self.files = files
        self.safetyLevel = safetyLevel
        self.confirmationMethod = confirmationMethod
        self.cleanupMethod = cleanupMethod
        self.bytesFreed = bytesFreed
        self.transport = transport
        self.clientID = clientID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case tool
        case command
        case files
        case safetyLevel
        case confirmationMethod
        case cleanupMethod
        case bytesFreed
        case transport
        case clientID = "client_id"
    }
}

/// A file affected by an audit operation.
public struct AuditFile: Codable, Sendable {
    /// Absolute path of the file.
    public let path: String

    /// Size in bytes.
    public let size: Int64

    public init(path: String, size: Int64) {
        self.path = path
        self.size = size
    }
}

/// How files were removed during cleanup.
public enum CleanupMethod: String, Codable, Sendable {
    /// Moved to macOS Trash (reversible).
    case trash
    /// Permanently deleted (irreversible).
    case delete
    /// Cleaned by an external tool's native cleanup command.
    case toolNative = "tool_native"
}
