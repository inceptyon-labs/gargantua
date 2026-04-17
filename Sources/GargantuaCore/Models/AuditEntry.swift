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

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        tool: String,
        command: String,
        files: [AuditFile],
        safetyLevel: SafetyLevel,
        confirmationMethod: ConfirmationTier,
        cleanupMethod: CleanupMethod = .trash,
        bytesFreed: Int64
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
}
