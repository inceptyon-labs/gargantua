import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCPRequestDispatcher protocol")
struct MCPRequestDispatcherProtocolTests {

    // MARK: Fixtures

    private static let serverInfo = MCPServerInfo(name: "gargantua", version: "0.0.1")
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

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

    // MARK: Unknown method + notifications

    @Test("unknown method returns method-not-found")
    func unknownMethodIsMethodNotFound() {
        let dispatcher = makeDispatcher()
        let response = dispatcher.dispatch(request(method: "frobnicate"))
        #expect(response?.error?.code == MCPErrorCode.methodNotFound)
        #expect(response?.error?.message.contains("frobnicate") == true)
    }

    @Test("notification returns nil regardless of method")
    func notificationReturnsNil() {
        let dispatcher = makeDispatcher()
        let req = MCPRequest(id: nil, method: "notifications/initialized")
        #expect(dispatcher.dispatch(req) == nil)
    }

    @Test("notification for tools/call does not invoke registered handler")
    func notificationDoesNotInvokeHandler() {
        final class Box: @unchecked Sendable {
            var invocations = 0
        }
        let box = Box()
        let dispatcher = makeDispatcher()
        dispatcher.register(tool: .status) { _ in
            box.invocations += 1
            return .text("ok")
        }
        let req = MCPRequest(
            id: nil,
            method: "tools/call",
            params: .object(["name": .string("status")])
        )
        #expect(dispatcher.dispatch(req) == nil)
        #expect(box.invocations == 0)
    }

    // MARK: Response encodability

    @Test("initialize result encodes to valid JSON")
    func initializeResultEncodes() throws {
        let dispatcher = makeDispatcher()
        let response = try #require(
            dispatcher.dispatch(
                request(method: "initialize", params: Self.validInitializeParams)
            )
        )
        let data = try Self.encoder.encode(response)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"jsonrpc\":\"2.0\""))
        #expect(json.contains("\"protocolVersion\":\"\(MCPRequestDispatcher.defaultProtocolVersion)\""))
        #expect(json.contains("\"serverInfo\""))
    }

    @Test("tools/list result encodes to valid JSON and round-trips through MCPResponse")
    func toolsListResultEncodesAndRoundTrips() throws {
        let dispatcher = makeDispatcher()
        let response = try #require(dispatcher.dispatch(request(method: "tools/list")))
        let data = try Self.encoder.encode(response)
        let decoded = try JSONDecoder().decode(MCPResponse.self, from: data)
        #expect(decoded.result != nil)
        #expect(decoded.error == nil)
    }

    // MARK: Registration semantics

    @Test("register(tool:handler:) replaces any previously registered handler")
    func registerReplacesHandler() throws {
        let dispatcher = makeDispatcher()
        dispatcher.register(tool: .analyze) { _ in .text("first") }
        dispatcher.register(tool: .analyze) { _ in .text("second") }
        let params: MCPJSONAny = .object(["name": .string("analyze")])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        guard case .object(let root) = try #require(response?.result),
              case .array(let content) = root["content"],
              case .object(let block) = content.first else {
            Issue.record("result shape wrong")
            return
        }
        #expect(block["text"] == .string("second"))
    }
}
