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

    @Test("MCPServerRecentAction carries the audit entry's status through")
    func recentActionCarriesAuditEntryStatus() {
        let attemptedEntry = AuditEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A003")!,
            timestamp: Date(timeIntervalSince1970: 40),
            tool: "native",
            command: "clean",
            files: [],
            safetyLevel: .safe,
            confirmationMethod: .mcp,
            bytesFreed: 0,
            transport: "mcp",
            clientID: "cursor",
            status: .attempted
        )

        let action = MCPServerRecentAction(auditEntry: attemptedEntry)
        #expect(action.status == .attempted)

        let completedEntry = AuditEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A004")!,
            timestamp: Date(timeIntervalSince1970: 41),
            tool: "native",
            command: "clean",
            files: [],
            safetyLevel: .safe,
            confirmationMethod: .mcp,
            bytesFreed: 100,
            transport: "mcp",
            clientID: "cursor",
            status: .completed
        )
        #expect(MCPServerRecentAction(auditEntry: completedEntry).status == .completed)
    }

    @Test("persisted snapshot JSON lacking the status key decodes recent actions as completed")
    func persistedSnapshotWithoutStatusKeyDecodesAsCompleted() throws {
        let url = temporaryStatusURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Simulates a snapshot persisted before `status` existed on
        // MCPServerRecentAction — no "status" key in the recentActions entry.
        let json = """
        {
            "state": "stopped",
            "transportMode": "stdio",
            "clients": [],
            "recentActions": [
                {
                    "id": "00000000-0000-0000-0000-00000000A005",
                    "timestamp": "1970-01-01T00:00:50Z",
                    "command": "clean",
                    "clientID": "cursor",
                    "bytesFreed": 42
                }
            ],
            "updatedAt": "1970-01-01T00:00:50Z"
        }
        """
        try Data(json.utf8).write(to: url)

        let persistence = MCPServerStatusPersistence(url: url)
        let snapshot = try persistence.readSnapshot(now: Self.fixedDate)

        #expect(snapshot.recentActions.count == 1)
        #expect(snapshot.recentActions.first?.status == .completed)
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

        // Join the control task instead of polling on a deadline — the poll
        // flakes under parallel test load when the detached start action
        // doesn't get scheduled within the timeout.
        await model.controlTask?.value
        #expect(model.snapshot.state == .running)
        #expect(model.snapshot.transportMode == .sse)
    }

    private func temporaryStatusURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("mcp-status.json")
    }
}
