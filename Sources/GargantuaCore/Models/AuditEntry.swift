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

    /// Discriminator for what shape of work this audit entry describes.
    /// Decodes to `.path` when absent so legacy JSONL and persisted rows
    /// written before command-action rules existed read back as path
    /// cleanups.
    public let kind: AuditEntryKind

    /// Tool version string captured at execution time, e.g.
    /// `"Xcode 16.2 (Build version 16C5032a)"`. Set only for `kind == .command`
    /// entries, where the tool's reported version is part of the evidence
    /// model — a future audit reader needs to know which `simctl` performed
    /// the action.
    public let commandToolVersion: String?

    /// Process exit code for command-action entries. Nil for path entries.
    public let commandExitCode: Int32?

    /// Argument list passed to the tool for command-action entries. Captured
    /// verbatim so audit consumers can replay the exact invocation.
    public let commandArguments: [String]?

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
        clientID: String? = nil,
        kind: AuditEntryKind = .path,
        commandToolVersion: String? = nil,
        commandExitCode: Int32? = nil,
        commandArguments: [String]? = nil
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
        self.kind = kind
        self.commandToolVersion = commandToolVersion
        self.commandExitCode = commandExitCode
        self.commandArguments = commandArguments
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
        case kind
        case commandToolVersion = "command_tool_version"
        case commandExitCode = "command_exit_code"
        case commandArguments = "command_arguments"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.tool = try container.decode(String.self, forKey: .tool)
        self.command = try container.decode(String.self, forKey: .command)
        self.files = try container.decode([AuditFile].self, forKey: .files)
        self.safetyLevel = try container.decode(SafetyLevel.self, forKey: .safetyLevel)
        self.confirmationMethod = try container.decode(ConfirmationTier.self, forKey: .confirmationMethod)
        self.cleanupMethod = try container.decode(CleanupMethod.self, forKey: .cleanupMethod)
        self.bytesFreed = try container.decode(Int64.self, forKey: .bytesFreed)
        self.transport = try container.decodeIfPresent(String.self, forKey: .transport)
        self.clientID = try container.decodeIfPresent(String.self, forKey: .clientID)
        // Default to .path so audit entries written before this discriminator
        // existed decode cleanly.
        self.kind = (try container.decodeIfPresent(AuditEntryKind.self, forKey: .kind)) ?? .path
        self.commandToolVersion = try container.decodeIfPresent(String.self, forKey: .commandToolVersion)
        self.commandExitCode = try container.decodeIfPresent(Int32.self, forKey: .commandExitCode)
        self.commandArguments = try container.decodeIfPresent([String].self, forKey: .commandArguments)
    }
}

/// Discriminator for what kind of cleanup work an `AuditEntry` describes.
///
/// `path` is the historical default — the cleanup pipeline removed one or
/// more filesystem entries via Trash or direct delete. `command` covers the
/// command-action rule shape, where Gargantua asked an external tool to
/// clean its own data and recorded the invocation as evidence.
public enum AuditEntryKind: String, Codable, Sendable, CaseIterable {
    case path
    case command
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
