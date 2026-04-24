import Foundation

/// High-level lifecycle state for a Gargantua MCP server instance.
public enum MCPServerRunState: String, Codable, Sendable, Equatable {
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

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        command: String,
        clientID: String,
        bytesFreed: Int64? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.command = command
        self.clientID = clientID
        self.bytesFreed = bytesFreed
    }

    public init(auditEntry: AuditEntry) {
        self.init(
            id: auditEntry.id,
            timestamp: auditEntry.timestamp,
            command: auditEntry.command,
            clientID: auditEntry.clientID ?? "unknown",
            bytesFreed: auditEntry.bytesFreed
        )
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
