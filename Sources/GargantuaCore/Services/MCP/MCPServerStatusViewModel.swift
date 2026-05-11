import Combine
import Foundation

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
    private var controlTask: Task<Void, Never>?

    public init(
        initialSnapshot: MCPServerStatusSnapshot = .stopped(),
        snapshotProvider: @escaping SnapshotProvider = {
            try MCPServerStatusPersistence().readSnapshot()
        },
        startAction: @escaping ControlAction = {
            try MCPServerProcessController.startSSEServer()
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
        guard snapshot.state != .starting else { return }
        do {
            snapshot = try snapshotProvider().withRecentActions(recentMCPActions())
        } catch {
            snapshot = errorSnapshot(message: Self.clientFacingMessage(for: error))
        }
    }

    public func start() {
        guard snapshot.state != .starting else { return }
        snapshot = startingSnapshot()
        performAsync(startAction)
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

    private func performAsync(_ action: @escaping ControlAction) {
        controlTask?.cancel()
        controlTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try action() }
            }.value

            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let updatedSnapshot):
                self.snapshot = updatedSnapshot.withRecentActions(self.recentMCPActions())
            case .failure(let error):
                self.snapshot = self.errorSnapshot(message: Self.clientFacingMessage(for: error))
            }
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

    private func startingSnapshot() -> MCPServerStatusSnapshot {
        MCPServerStatusSnapshot(
            state: .starting,
            transportMode: .sse,
            clients: snapshot.clients,
            lastErrorMessage: nil,
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
