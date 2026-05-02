import Foundation
import Testing
@testable import GargantuaCore

@Suite("MCP server status store")
struct MCPServerStatusStoreTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_000)

    @Test("running, client, action, and stopped transitions preserve dashboard state")
    func lifecycleTransitions() {
        let store = MCPServerStatusStore(now: { Self.fixedDate })

        store.markRunning(transportMode: .stdio)
        var snapshot = store.currentSnapshot()
        #expect(snapshot.state == .running)
        #expect(snapshot.transportMode == .stdio)
        #expect(snapshot.clients.isEmpty)

        let identity = MCPClientIdentity(name: "claude-code", version: "1.2.3")
        store.replaceCurrentClient(identity)
        snapshot = store.currentSnapshot()
        #expect(snapshot.state == .running)
        #expect(snapshot.clients.map(\.displayName) == ["claude-code 1.2.3"])

        store.recordToolCall(.scan, client: identity)
        snapshot = store.currentSnapshot()
        #expect(snapshot.recentActions.first?.command == "scan")
        #expect(snapshot.recentActions.first?.clientID == "claude-code")

        store.markStopped()
        snapshot = store.currentSnapshot()
        #expect(snapshot.state == .stopped)
        #expect(snapshot.clients.isEmpty)
        #expect(snapshot.recentActions.first?.command == "scan")
    }

    @Test("recent actions are capped newest-first")
    func recentActionsAreCappedNewestFirst() {
        let store = MCPServerStatusStore(now: { Self.fixedDate })
        store.markRunning(transportMode: .stdio)

        for tool in [MCPToolName.scan, .analyze, .status, .explain, .listProfiles, .clean] {
            store.recordToolCall(tool, client: nil)
        }

        let actions = store.currentSnapshot().recentActions
        #expect(actions.count == 5)
        #expect(actions.map(\.command) == ["clean", "list_profiles", "explain", "status", "analyze"])
    }

    @Test("persistence round-trips a live running snapshot")
    func persistenceRoundTripsLiveSnapshot() throws {
        let url = temporaryStatusURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let persistence = MCPServerStatusPersistence(url: url)
        let snapshot = MCPServerStatusSnapshot(
            state: .running,
            clients: [MCPConnectedClient(id: "cursor", name: "cursor")],
            updatedAt: Self.fixedDate,
            processID: ProcessInfo.processInfo.processIdentifier
        )

        try persistence.writeSnapshot(snapshot)
        let read = try persistence.readSnapshot(now: Self.fixedDate)

        #expect(read.state == .running)
        #expect(read.clients.map(\.name) == ["cursor"])
    }

    @Test("persistence demotes stale running snapshot when pid is gone")
    func persistenceDemotesStaleRunningSnapshot() throws {
        let url = temporaryStatusURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let persistence = MCPServerStatusPersistence(url: url)
        let snapshot = MCPServerStatusSnapshot(
            state: .running,
            clients: [MCPConnectedClient(id: "cursor", name: "cursor")],
            updatedAt: Self.fixedDate,
            processID: -1
        )

        try persistence.writeSnapshot(snapshot)
        let read = try persistence.readSnapshot(now: Self.fixedDate)

        #expect(read.state == .stopped)
        #expect(read.clients.isEmpty)
    }

    @MainActor
    @Test("view model loads recent MCP actions from audit entries only")
    func viewModelReadsMCPAuditEntries() {
        let mcpEntry = AuditEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!,
            timestamp: Date(timeIntervalSince1970: 20),
            tool: "native",
            command: "clean",
            files: [],
            safetyLevel: .safe,
            confirmationMethod: .mcp,
            bytesFreed: 42,
            transport: "mcp",
            clientID: "cursor"
        )
        let appEntry = AuditEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!,
            timestamp: Date(timeIntervalSince1970: 30),
            tool: "native",
            command: "clean",
            files: [],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 99
        )

        let model = MCPServerStatusViewModel(
            initialSnapshot: .stopped(updatedAt: Self.fixedDate),
            snapshotProvider: { .stopped(updatedAt: Self.fixedDate) },
            auditReader: { [appEntry, mcpEntry] }
        )

        #expect(model.snapshot.recentActions.count == 1)
        #expect(model.snapshot.recentActions.first?.clientID == "cursor")
        #expect(model.snapshot.recentActions.first?.bytesFreed == 42)
    }

    @MainActor
    @Test("view model starts asynchronously without refresh stomping the starting state")
    func viewModelStartsAsynchronously() async throws {
        let model = MCPServerStatusViewModel(
            initialSnapshot: .stopped(updatedAt: Self.fixedDate),
            snapshotProvider: { .stopped(updatedAt: Self.fixedDate) },
            startAction: {
                MCPServerStatusSnapshot(
                    state: .running,
                    transportMode: .sse,
                    updatedAt: Self.fixedDate
                )
            },
            auditReader: { [] }
        )

        model.start()
        #expect(model.snapshot.state == .starting)

        model.refresh()
        #expect(model.snapshot.state == .starting)

        try await waitUntil {
            model.snapshot.state == .running
        }
        #expect(model.snapshot.transportMode == .sse)
    }

    private func temporaryStatusURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("mcp-status.json")
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                Issue.record("condition was not met before timeout")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
