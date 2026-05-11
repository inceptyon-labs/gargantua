import Foundation

/// Receives runtime events from MCP transport/dispatch code.
public protocol MCPServerStatusReporting: Sendable {
    func markRunning(transportMode: MCPServerTransportMode)
    func markStopped()
    func recordError(_ message: String)
    func replaceCurrentClient(_ identity: MCPClientIdentity?)
    func recordToolCall(_ toolName: MCPToolName, client: MCPClientIdentity?)
}

/// Thread-safe in-process status store for the MCP server executable.
public final class MCPServerStatusStore: MCPServerStatusReporting, @unchecked Sendable {
    public typealias DateProvider = @Sendable () -> Date

    private let lock = NSLock()
    private let now: DateProvider
    private let persistence: MCPServerStatusPersistence?
    private var snapshot: MCPServerStatusSnapshot

    public init(
        initialSnapshot: MCPServerStatusSnapshot = .stopped(),
        persistence: MCPServerStatusPersistence? = nil,
        now: @escaping DateProvider = { Date() }
    ) {
        self.snapshot = initialSnapshot
        self.persistence = persistence
        self.now = now
    }

    public func currentSnapshot() -> MCPServerStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    public func markRunning(transportMode: MCPServerTransportMode = .stdio) {
        update { current in
            MCPServerStatusSnapshot(
                state: .running,
                transportMode: transportMode,
                clients: current.clients,
                lastErrorMessage: nil,
                recentActions: current.recentActions,
                updatedAt: now(),
                processID: ProcessInfo.processInfo.processIdentifier
            )
        }
    }

    public func markStopped() {
        update { current in
            MCPServerStatusSnapshot(
                state: .stopped,
                transportMode: current.transportMode,
                clients: [],
                lastErrorMessage: nil,
                recentActions: current.recentActions,
                updatedAt: now()
            )
        }
    }

    public func recordError(_ message: String) {
        update { current in
            MCPServerStatusSnapshot(
                state: .error,
                transportMode: current.transportMode,
                clients: current.clients,
                lastErrorMessage: message,
                recentActions: current.recentActions,
                updatedAt: now(),
                processID: current.processID
            )
        }
    }

    public func replaceCurrentClient(_ identity: MCPClientIdentity?) {
        update { current in
            let clients = identity.map { [MCPConnectedClient(identity: $0, connectedAt: now())] } ?? []
            return MCPServerStatusSnapshot(
                state: current.state == .stopped ? .running : current.state,
                transportMode: current.transportMode,
                clients: clients,
                lastErrorMessage: current.lastErrorMessage,
                recentActions: current.recentActions,
                updatedAt: now(),
                processID: current.processID
            )
        }
    }

    public func recordToolCall(_ toolName: MCPToolName, client: MCPClientIdentity?) {
        update { current in
            var actions = current.recentActions
            actions.insert(
                MCPServerRecentAction(
                    timestamp: now(),
                    command: toolName.rawValue,
                    clientID: client?.name ?? "unknown"
                ),
                at: 0
            )
            if actions.count > 5 {
                actions.removeLast(actions.count - 5)
            }
            return MCPServerStatusSnapshot(
                state: current.state == .stopped ? .running : current.state,
                transportMode: current.transportMode,
                clients: current.clients,
                lastErrorMessage: current.lastErrorMessage,
                recentActions: actions,
                updatedAt: now(),
                processID: current.processID
            )
        }
    }

    private func update(_ transform: (MCPServerStatusSnapshot) -> MCPServerStatusSnapshot) {
        lock.lock()
        snapshot = transform(snapshot)
        try? persistence?.writeSnapshot(snapshot)
        lock.unlock()
    }
}
