import Foundation
import Testing
@testable import GargantuaCore

@Suite("MCP request dispatcher status reporting")
struct MCPRequestDispatcherStatusTests {
    private static let serverInfo = MCPServerInfo(name: "gargantua", version: "0.0.1")

    private static let validInitializeParams: MCPJSONAny = .object([
        "protocolVersion": .string("2024-11-05"),
        "capabilities": .object([:]),
        "clientInfo": .object([
            "name": .string("test-client"),
            "version": .string("0.0"),
        ]),
    ])

    private func makeDispatcher(statusReporter: MCPServerStatusReporting) -> MCPRequestDispatcher {
        MCPRequestDispatcher(
            serverInfo: Self.serverInfo,
            statusReporter: statusReporter
        )
    }

    private func request(
        id: MCPRequestID? = .int(1),
        method: String,
        params: MCPJSONAny? = nil
    ) -> MCPRequest {
        MCPRequest(id: id, method: method, params: params)
    }

    @Test("initialize reports the current connected client to the status store")
    func initializeReportsClientToStatusStore() {
        let store = MCPServerStatusStore()
        let dispatcher = makeDispatcher(statusReporter: store)

        _ = dispatcher.dispatch(
            request(method: "initialize", params: Self.validInitializeParams)
        )

        let snapshot = store.currentSnapshot()
        #expect(snapshot.state == .running)
        #expect(snapshot.clients.map(\.displayName) == ["test-client 0.0"])
    }

    @Test("re-initialize without clientInfo clears connected clients in the status store")
    func initializeClearsStatusStoreClient() {
        let store = MCPServerStatusStore()
        let dispatcher = makeDispatcher(statusReporter: store)

        _ = dispatcher.dispatch(
            request(method: "initialize", params: Self.validInitializeParams)
        )
        let params: MCPJSONAny = .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
        ])
        _ = dispatcher.dispatch(request(method: "initialize", params: params))

        #expect(store.currentSnapshot().clients.isEmpty)
    }

    @Test("tools/call records recent MCP action with current client")
    func toolsCallRecordsRecentAction() throws {
        let store = MCPServerStatusStore()
        let dispatcher = makeDispatcher(statusReporter: store)
        _ = dispatcher.dispatch(
            request(method: "initialize", params: Self.validInitializeParams)
        )
        dispatcher.register(tool: .status) { _ in .text("ok") }

        let params: MCPJSONAny = .object(["name": .string("status")])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))

        #expect(response?.error == nil)
        let action = try #require(store.currentSnapshot().recentActions.first)
        #expect(action.command == "status")
        #expect(action.clientID == "test-client")
    }
}
