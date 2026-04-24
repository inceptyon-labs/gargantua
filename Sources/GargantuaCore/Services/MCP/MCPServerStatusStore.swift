import Combine
import Darwin
import Foundation

/// File-backed handoff between the MCP executable and the Dashboard app.
public struct MCPServerStatusPersistence: Sendable {
    public let url: URL

    public init(url: URL = MCPServerStatusPersistence.defaultURL()) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Gargantua", isDirectory: true)
            .appendingPathComponent("mcp-status.json")
    }

    public func readSnapshot(now: Date = Date()) throws -> MCPServerStatusSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .stopped(updatedAt: now)
        }

        let data = try Data(contentsOf: url)
        let snapshot = try Self.decoder.decode(MCPServerStatusSnapshot.self, from: data)
        guard snapshot.state == .running else {
            return snapshot
        }

        guard let processID = snapshot.processID,
              Self.isProcessRunning(processID)
        else {
            return stoppedSnapshot(from: snapshot, now: now)
        }

        return snapshot
    }

    public func stopRunningServer(now: Date = Date()) throws -> MCPServerStatusSnapshot {
        let snapshot = try readSnapshot(now: now)
        guard snapshot.state == .running else { return snapshot }

        guard let processID = snapshot.processID,
              Self.processLooksLikeGargantuaMCP(processID)
        else {
            throw MCPServerControlError.unsupported(
                "MCP stdio is owned by its launching client. Stop control requires a verified GargantuaMCP process."
            )
        }

        if kill(processID, SIGTERM) != 0, errno != ESRCH {
            throw MCPServerControlError.unsupported("MCP server could not be stopped.")
        }

        let stopped = stoppedSnapshot(from: snapshot, now: now)
        try writeSnapshot(stopped)
        return stopped
    }

    private func stoppedSnapshot(
        from snapshot: MCPServerStatusSnapshot,
        now: Date
    ) -> MCPServerStatusSnapshot {
        return MCPServerStatusSnapshot(
            state: .stopped,
            transportMode: snapshot.transportMode,
            recentActions: snapshot.recentActions,
            updatedAt: now
        )
    }

    public func writeSnapshot(_ snapshot: MCPServerStatusSnapshot) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    private static func isProcessRunning(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        if kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func processLooksLikeGargantuaMCP(_ processID: Int32) -> Bool {
        guard let path = processPath(for: processID) else { return false }
        return URL(fileURLWithPath: path).lastPathComponent == "GargantuaMCP"
    }

    private static func processPath(for processID: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let result = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

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

public enum MCPServerControlError: Error, LocalizedError, Sendable {
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let message): return message
        }
    }
}

/// Main-actor observable used by Dashboard SwiftUI views.
@MainActor
public final class MCPServerStatusViewModel: ObservableObject {
    public typealias SnapshotProvider = @Sendable () throws -> MCPServerStatusSnapshot
    public typealias ControlAction = @Sendable () throws -> MCPServerStatusSnapshot
    public typealias AuditReader = @Sendable () throws -> [AuditEntry]

    @Published public private(set) var snapshot: MCPServerStatusSnapshot

    private let snapshotProvider: SnapshotProvider
    private let startAction: ControlAction
    private let stopAction: ControlAction
    private let auditReader: AuditReader

    public init(
        initialSnapshot: MCPServerStatusSnapshot = .stopped(),
        snapshotProvider: @escaping SnapshotProvider = {
            try MCPServerStatusPersistence().readSnapshot()
        },
        startAction: @escaping ControlAction = {
            throw MCPServerControlError.unsupported(
                "MCP stdio starts when an MCP client launches GargantuaMCP. Launch-agent control is not installed yet."
            )
        },
        stopAction: @escaping ControlAction = {
            try MCPServerStatusPersistence().stopRunningServer()
        },
        auditReader: @escaping AuditReader = { try AuditWriter().readEntries() }
    ) {
        self.snapshot = initialSnapshot
        self.snapshotProvider = snapshotProvider
        self.startAction = startAction
        self.stopAction = stopAction
        self.auditReader = auditReader
        refresh()
    }

    public func refresh() {
        do {
            snapshot = try snapshotProvider().withRecentActions(recentMCPActions())
        } catch {
            snapshot = errorSnapshot(message: Self.clientFacingMessage(for: error))
        }
    }

    public func start() {
        perform(startAction)
    }

    public func stop() {
        perform(stopAction)
    }

    private func perform(_ action: ControlAction) {
        do {
            snapshot = try action().withRecentActions(recentMCPActions())
        } catch {
            snapshot = errorSnapshot(message: Self.clientFacingMessage(for: error))
        }
    }

    private func recentMCPActions() -> [MCPServerRecentAction] {
        do {
            return try auditReader()
                .filter { $0.transport == "mcp" }
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(3)
                .map(MCPServerRecentAction.init(auditEntry:))
        } catch {
            return snapshot.recentActions
        }
    }

    private func errorSnapshot(message: String) -> MCPServerStatusSnapshot {
        MCPServerStatusSnapshot(
            state: .error,
            transportMode: snapshot.transportMode,
            clients: snapshot.clients,
            lastErrorMessage: message,
            recentActions: snapshot.recentActions,
            updatedAt: Date(),
            processID: snapshot.processID
        )
    }

    private static func clientFacingMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return "MCP server control failed."
    }
}
