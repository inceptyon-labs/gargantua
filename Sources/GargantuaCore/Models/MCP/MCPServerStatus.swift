import Foundation

/// High-level lifecycle state for a Gargantua MCP server instance.
public enum MCPServerRunState: String, Codable, Sendable, Equatable {
    case starting
    case stopped
    case running
    case error
}

/// Transport mode used by an MCP server instance.
public enum MCPServerTransportMode: String, Codable, Sendable, Equatable {
    case stdio
    case sse
    case stdioAndSSE = "stdio_sse"

    public var displayName: String {
        switch self {
        case .stdio: return "stdio"
        case .sse: return "SSE"
        case .stdioAndSSE: return "stdio + SSE"
        }
    }
}

/// A client connected to the MCP server during the current server lifetime.
public struct MCPConnectedClient: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let version: String?
    public let connectedAt: Date

    public init(
        id: String,
        name: String,
        version: String? = nil,
        connectedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.connectedAt = connectedAt
    }

    public init(identity: MCPClientIdentity, connectedAt: Date = Date()) {
        let id = [identity.name, identity.version].compactMap { $0 }.joined(separator: "@")
        self.init(
            id: id.isEmpty ? identity.name : id,
            name: identity.name,
            version: identity.version,
            connectedAt: connectedAt
        )
    }

    public var displayName: String {
        guard let version, !version.isEmpty else { return name }
        return "\(name) \(version)"
    }
}

/// Small activity row for the Dashboard's MCP mini-log.
public struct MCPServerRecentAction: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let command: String
    public let clientID: String
    public let bytesFreed: Int64?

    /// Whether the underlying audit entry was an attempt or an outcome.
    /// Carries the audit entry's two-phase status through to the snapshot so
    /// a consumer can distinguish a crashed clean from a completed 0-byte one.
    public let status: AuditEntryStatus

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        command: String,
        clientID: String,
        bytesFreed: Int64? = nil,
        status: AuditEntryStatus = .completed
    ) {
        self.id = id
        self.timestamp = timestamp
        self.command = command
        self.clientID = clientID
        self.bytesFreed = bytesFreed
        self.status = status
    }

    public init(auditEntry: AuditEntry) {
        self.init(
            id: auditEntry.id,
            timestamp: auditEntry.timestamp,
            command: auditEntry.command,
            clientID: auditEntry.clientID ?? "unknown",
            bytesFreed: auditEntry.bytesFreed,
            status: auditEntry.status
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case command
        case clientID
        case bytesFreed
        case status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.command = try container.decode(String.self, forKey: .command)
        self.clientID = try container.decode(String.self, forKey: .clientID)
        self.bytesFreed = try container.decodeIfPresent(Int64.self, forKey: .bytesFreed)
        // Default to .completed so persisted snapshots written before this
        // field existed decode cleanly.
        self.status = (try container.decodeIfPresent(AuditEntryStatus.self, forKey: .status)) ?? .completed
    }
}

/// Snapshot consumed by the Dashboard and updated by MCP runtime wiring.
public struct MCPServerStatusSnapshot: Codable, Sendable, Equatable {
    public let state: MCPServerRunState
    public let transportMode: MCPServerTransportMode
    public let clients: [MCPConnectedClient]
    public let lastErrorMessage: String?
    public let recentActions: [MCPServerRecentAction]
    public let updatedAt: Date
    public let processID: Int32?

    public init(
        state: MCPServerRunState,
        transportMode: MCPServerTransportMode = .stdio,
        clients: [MCPConnectedClient] = [],
        lastErrorMessage: String? = nil,
        recentActions: [MCPServerRecentAction] = [],
        updatedAt: Date = Date(),
        processID: Int32? = nil
    ) {
        self.state = state
        self.transportMode = transportMode
        self.clients = clients
        self.lastErrorMessage = lastErrorMessage
        self.recentActions = recentActions
        self.updatedAt = updatedAt
        self.processID = processID
    }

    public static func stopped(
        transportMode: MCPServerTransportMode = .stdio,
        updatedAt: Date = Date()
    ) -> MCPServerStatusSnapshot {
        MCPServerStatusSnapshot(
            state: .stopped,
            transportMode: transportMode,
            updatedAt: updatedAt
        )
    }

    public var connectedClientCount: Int { clients.count }

    public var isRunning: Bool { state == .running }

    /// Equality that ignores `updatedAt`.
    ///
    /// Freshly-read snapshots carry a new read timestamp even when nothing
    /// observable changed (e.g. `readSnapshot` synthesizes `.stopped(updatedAt:
    /// now)` when the status file is missing). Polling callers use this to
    /// skip redundant `@Published` assignments that would re-render SwiftUI.
    public func isEquivalent(to other: MCPServerStatusSnapshot) -> Bool {
        state == other.state
            && transportMode == other.transportMode
            && clients == other.clients
            && lastErrorMessage == other.lastErrorMessage
            && recentActions == other.recentActions
            && processID == other.processID
    }

    public func withRecentActions(_ actions: [MCPServerRecentAction]) -> MCPServerStatusSnapshot {
        MCPServerStatusSnapshot(
            state: state,
            transportMode: transportMode,
            clients: clients,
            lastErrorMessage: lastErrorMessage,
            recentActions: actions,
            updatedAt: updatedAt,
            processID: processID
        )
    }
}
