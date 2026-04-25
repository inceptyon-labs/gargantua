import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP request dispatcher")
struct MCPRequestDispatcherTests {

    // MARK: Fixtures

    private static let serverInfo = MCPServerInfo(name: "gargantua", version: "0.0.1")

    private func makeDispatcher(
        tools: [MCPToolDescriptor] = MCPPhase2Tools.all,
        log: MCPDispatcherLog? = nil
    ) -> MCPRequestDispatcher {
        MCPRequestDispatcher(serverInfo: Self.serverInfo, tools: tools, log: log)
    }

    private func request(
        id: MCPRequestID? = .int(1),
        method: String,
        params: MCPJSONAny? = nil
    ) -> MCPRequest {
        MCPRequest(id: id, method: method, params: params)
    }

    /// Minimal valid `initialize` params per MCP spec (`protocolVersion` key).
    private static let validInitializeParams: MCPJSONAny = .object([
        "protocolVersion": .string("2024-11-05"),
        "capabilities": .object([:]),
        "clientInfo": .object([
            "name": .string("test-client"),
            "version": .string("0.0"),
        ]),
    ])

    // MARK: initialize

    @Test("initialize returns protocolVersion, capabilities, and serverInfo")
    func initializeShape() throws {
        let dispatcher = makeDispatcher()
        let response = dispatcher.dispatch(
            request(method: "initialize", params: Self.validInitializeParams)
        )
        let result = try #require(response?.result)
        guard case .object(let root) = result else {
            Issue.record("result was not an object")
            return
        }
        #expect(root["protocolVersion"] == .string(MCPRequestDispatcher.defaultProtocolVersion))

        guard case .object(let capabilities) = root["capabilities"] else {
            Issue.record("capabilities missing or wrong type")
            return
        }
        #expect(capabilities["tools"] == .object([:]))

        guard case .object(let info) = root["serverInfo"] else {
            Issue.record("serverInfo missing or wrong type")
            return
        }
        #expect(info["name"] == .string("gargantua"))
        #expect(info["version"] == .string("0.0.1"))
    }

    @Test("initialize response is tagged with the request id")
    func initializeEchoesRequestID() throws {
        let dispatcher = makeDispatcher()
        let response = dispatcher.dispatch(
            request(
                id: .string("handshake-1"),
                method: "initialize",
                params: Self.validInitializeParams
            )
        )
        #expect(response?.id == .string("handshake-1"))
        #expect(response?.error == nil)
    }

    @Test("initialize with missing params returns invalid-params")
    func initializeMissingParamsIsInvalid() {
        let dispatcher = makeDispatcher()
        let response = dispatcher.dispatch(request(method: "initialize"))
        #expect(response?.error?.code == MCPErrorCode.invalidParams)
    }

    @Test("initialize with params missing protocolVersion returns invalid-params")
    func initializeMissingProtocolVersionIsInvalid() {
        let dispatcher = makeDispatcher()
        // No protocolVersion — MCP spec requires it.
        let params: MCPJSONAny = .object([
            "capabilities": .object([:]),
        ])
        let response = dispatcher.dispatch(
            request(method: "initialize", params: params)
        )
        #expect(response?.error?.code == MCPErrorCode.invalidParams)
    }

    // MARK: clientInfo capture (Task 3 — gargantua-afft)

    @Test("currentClientIdentity is nil before any initialize arrives")
    func currentClientIdentityNilBeforeInitialize() {
        let dispatcher = makeDispatcher()
        #expect(dispatcher.currentClientIdentity() == nil)
    }

    @Test("initialize captures clientInfo.name and version for destructive-tool attribution")
    func initializeCapturesClientInfo() {
        let dispatcher = makeDispatcher()
        _ = dispatcher.dispatch(
            request(method: "initialize", params: Self.validInitializeParams)
        )
        let identity = dispatcher.currentClientIdentity()
        #expect(identity?.name == "test-client")
        #expect(identity?.version == "0.0")
    }

    @Test("initialize without clientInfo leaves identity nil (minimal-client compatibility)")
    func initializeWithoutClientInfoLeavesIdentityNil() {
        let dispatcher = makeDispatcher()
        let params: MCPJSONAny = .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
        ])
        _ = dispatcher.dispatch(request(method: "initialize", params: params))
        #expect(dispatcher.currentClientIdentity() == nil)
    }

    @Test("malformed clientInfo is tolerated — handshake still succeeds with nil identity")
    func initializeWithMalformedClientInfoIsTolerated() {
        let dispatcher = makeDispatcher()
        // `name` is required; omitting it makes the block malformed. The
        // handshake should still return a successful initialize response so
        // minimal clients aren't rejected; the identity simply stays nil.
        let params: MCPJSONAny = .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "version": .string("1.0"),
            ]),
        ])
        let response = dispatcher.dispatch(request(method: "initialize", params: params))
        #expect(response?.error == nil, "malformed clientInfo must not fail handshake")
        #expect(dispatcher.currentClientIdentity() == nil)
    }

    @Test("clientInfo without a version captures just the name")
    func initializeCapturesNameOnlyWhenVersionAbsent() {
        let dispatcher = makeDispatcher()
        let params: MCPJSONAny = .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("anon-client"),
            ]),
        ])
        _ = dispatcher.dispatch(request(method: "initialize", params: params))
        let identity = dispatcher.currentClientIdentity()
        #expect(identity?.name == "anon-client")
        #expect(identity?.version == nil)
    }

    @Test("re-initialize without clientInfo clears the prior captured identity")
    func reinitializeWithoutClientInfoClearsIdentity() {
        let dispatcher = makeDispatcher()
        _ = dispatcher.dispatch(
            request(method: "initialize", params: Self.validInitializeParams)
        )
        #expect(dispatcher.currentClientIdentity()?.name == "test-client")

        // Second handshake: no clientInfo. The stale identity must be
        // cleared — a rogue client must not inherit a prior session's
        // attribution by omitting clientInfo on a later init.
        let params: MCPJSONAny = .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
        ])
        _ = dispatcher.dispatch(request(method: "initialize", params: params))
        #expect(dispatcher.currentClientIdentity() == nil)
    }

    @Test("re-initialize with malformed clientInfo clears the prior captured identity")
    func reinitializeWithMalformedClientInfoClearsIdentity() {
        let dispatcher = makeDispatcher()
        _ = dispatcher.dispatch(
            request(method: "initialize", params: Self.validInitializeParams)
        )
        #expect(dispatcher.currentClientIdentity()?.name == "test-client")

        let params: MCPJSONAny = .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "version": .string("1.0"),
                // No `name` — malformed per MCP spec.
            ]),
        ])
        _ = dispatcher.dispatch(request(method: "initialize", params: params))
        #expect(dispatcher.currentClientIdentity() == nil)
    }

    @Test("empty clientInfo.name is normalized to nil (no sneaky rate-limit shard)")
    func emptyClientNameNormalizedToNil() {
        let dispatcher = makeDispatcher()
        let params: MCPJSONAny = .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(""),
                "version": .string("1.0"),
            ]),
        ])
        _ = dispatcher.dispatch(request(method: "initialize", params: params))
        #expect(dispatcher.currentClientIdentity() == nil)
    }

    @Test("whitespace-only clientInfo.name is normalized to nil")
    func whitespaceClientNameNormalizedToNil() {
        let dispatcher = makeDispatcher()
        let params: MCPJSONAny = .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("   \t\n"),
            ]),
        ])
        _ = dispatcher.dispatch(request(method: "initialize", params: params))
        #expect(dispatcher.currentClientIdentity() == nil)
    }

    @Test("clientInfo.name with surrounding whitespace is trimmed")
    func clientNameWhitespaceTrimmed() {
        let dispatcher = makeDispatcher()
        let params: MCPJSONAny = .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("  claude-code  "),
            ]),
        ])
        _ = dispatcher.dispatch(request(method: "initialize", params: params))
        #expect(dispatcher.currentClientIdentity()?.name == "claude-code")
    }
}
