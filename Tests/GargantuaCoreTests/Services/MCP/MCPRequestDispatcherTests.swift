import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP request dispatcher")
struct MCPRequestDispatcherTests {

    // MARK: Fixtures

    private static let serverInfo = MCPServerInfo(name: "gargantua", version: "0.0.1")
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private func makeDispatcher(
        tools: [MCPToolDescriptor] = MCPPhase2Tools.all
    ) -> MCPRequestDispatcher {
        MCPRequestDispatcher(serverInfo: Self.serverInfo, tools: tools)
    }

    private func request(
        id: MCPRequestID? = .int(1),
        method: String,
        params: MCPJSONAny? = nil
    ) -> MCPRequest {
        MCPRequest(id: id, method: method, params: params)
    }

    // MARK: initialize

    @Test("initialize returns protocolVersion, capabilities, and serverInfo")
    func initializeShape() throws {
        let dispatcher = makeDispatcher()
        let response = dispatcher.dispatch(request(method: "initialize"))
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
        let response = dispatcher.dispatch(request(id: .string("handshake-1"), method: "initialize"))
        #expect(response?.id == .string("handshake-1"))
        #expect(response?.error == nil)
    }

    // MARK: tools/list

    @Test("tools/list advertises all Phase 2 tools")
    func toolsListContainsAllPhase2Tools() throws {
        let dispatcher = makeDispatcher()
        let response = dispatcher.dispatch(request(method: "tools/list"))
        let result = try #require(response?.result)
        guard case .object(let root) = result, case .array(let tools) = root["tools"] else {
            Issue.record("tools/list result missing tools array: \(result)")
            return
        }
        let names = tools.compactMap { entry -> String? in
            guard case .object(let obj) = entry, case .string(let name) = obj["name"] else { return nil }
            return name
        }
        #expect(Set(names) == Set(MCPToolName.allCases.map(\.rawValue)))
    }

    @Test("tools/list encodes the schema in MCP shape (name/description/inputSchema)")
    func toolsListEntryShape() throws {
        let dispatcher = makeDispatcher()
        let response = dispatcher.dispatch(request(method: "tools/list"))
        let result = try #require(response?.result)
        guard case .object(let root) = result, case .array(let tools) = root["tools"], let first = tools.first,
              case .object(let entry) = first else {
            Issue.record("tools/list missing entries")
            return
        }
        #expect(entry.keys.contains("name"))
        #expect(entry.keys.contains("description"))
        #expect(entry.keys.contains("inputSchema"))

        // Schemas should round-trip into MCPJSONSchema so downstream decoders
        // (and clients) see the exact structure defined in MCPToolDescriptor.
        guard case .object(let inputSchema) = entry["inputSchema"] else {
            Issue.record("inputSchema missing")
            return
        }
        #expect(inputSchema["type"] == .string("object"))
    }

    @Test("tools/list preserves scan.dry_run const=true")
    func toolsListPreservesScanDryRunConstant() throws {
        let dispatcher = makeDispatcher()
        let response = dispatcher.dispatch(request(method: "tools/list"))
        let result = try #require(response?.result)
        guard case .object(let root) = result, case .array(let tools) = root["tools"] else {
            Issue.record("missing tools array")
            return
        }
        let scanEntry = tools.first { entry in
            guard case .object(let obj) = entry, case .string(let name) = obj["name"] else { return false }
            return name == "scan"
        }
        guard let scanEntry, case .object(let obj) = scanEntry,
              case .object(let schema) = obj["inputSchema"],
              case .object(let properties) = schema["properties"],
              case .object(let dryRun) = properties["dry_run"] else {
            Issue.record("scan.dry_run schema missing")
            return
        }
        // The const must be the boolean true — the PRD §7.4 dry-run guarantee.
        #expect(dryRun["const"] == .bool(true))
    }

    // MARK: tools/call — dispatch

    @Test("tools/call invokes the registered handler with its arguments")
    func toolsCallRoutesToHandler() throws {
        let dispatcher = makeDispatcher()
        final class Capture: @unchecked Sendable {
            var received: MCPJSONAny?
        }
        let capture = Capture()
        dispatcher.register(tool: .analyze) { args in
            capture.received = args
            return .object(["health_score": .int(99)])
        }
        let params: MCPJSONAny = .object([
            "name": .string("analyze"),
            "arguments": .object(["detail": .string("full")]),
        ])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        #expect(response?.error == nil)
        guard case .object(let result) = try #require(response?.result) else {
            Issue.record("result was not an object")
            return
        }
        #expect(result["health_score"] == .int(99))
        #expect(capture.received == .object(["detail": .string("full")]))
    }

    @Test("tools/call with absent arguments passes nil to the handler")
    func toolsCallAbsentArgumentsPassesNil() throws {
        let dispatcher = makeDispatcher()
        final class Capture: @unchecked Sendable {
            var seenNoArgs = false
        }
        let capture = Capture()
        dispatcher.register(tool: .status) { args in
            capture.seenNoArgs = (args == nil)
            return .object([:])
        }
        let params: MCPJSONAny = .object(["name": .string("status")])
        _ = dispatcher.dispatch(request(method: "tools/call", params: params))
        #expect(capture.seenNoArgs == true)
    }

    @Test("tools/call preserves explicit-null arguments distinct from absent")
    func toolsCallExplicitNullArguments() throws {
        let dispatcher = makeDispatcher()
        final class Capture: @unchecked Sendable {
            var received: MCPJSONAny?
            var didRun = false
        }
        let capture = Capture()
        dispatcher.register(tool: .status) { args in
            capture.received = args
            capture.didRun = true
            return .object([:])
        }
        let params: MCPJSONAny = .object([
            "name": .string("status"),
            "arguments": .null,
        ])
        _ = dispatcher.dispatch(request(method: "tools/call", params: params))
        #expect(capture.didRun)
        #expect(capture.received == .null)
    }

    // MARK: tools/call — error mapping

    @Test("tools/call with unknown tool name returns invalid-params")
    func toolsCallUnknownToolIsInvalidParams() {
        let dispatcher = makeDispatcher()
        let params: MCPJSONAny = .object([
            "name": .string("not_a_tool"),
            "arguments": .object([:]),
        ])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        #expect(response?.error?.code == MCPErrorCode.invalidParams)
        #expect(response?.error?.message.contains("not_a_tool") == true)
    }

    @Test("tools/call with known tool but no handler returns internal-error")
    func toolsCallUnregisteredToolIsInternalError() {
        let dispatcher = makeDispatcher()
        let params: MCPJSONAny = .object([
            "name": .string("scan"),
            "arguments": .object(["dry_run": .bool(true)]),
        ])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        #expect(response?.error?.code == MCPErrorCode.internalError)
        #expect(response?.error?.message.contains("Tool not implemented") == true)
    }

    @Test("tools/call with missing params returns invalid-params")
    func toolsCallMissingParamsIsInvalid() {
        let dispatcher = makeDispatcher()
        let response = dispatcher.dispatch(request(method: "tools/call", params: nil))
        #expect(response?.error?.code == MCPErrorCode.invalidParams)
    }

    @Test("tools/call with missing name field returns invalid-params")
    func toolsCallMissingNameIsInvalid() {
        let dispatcher = makeDispatcher()
        let params: MCPJSONAny = .object(["arguments": .object([:])])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        #expect(response?.error?.code == MCPErrorCode.invalidParams)
    }

    @Test("handler throwing MCPToolError.invalidParams yields invalid-params")
    func handlerInvalidParamsIsMapped() {
        let dispatcher = makeDispatcher()
        dispatcher.register(tool: .explain) { _ in
            throw MCPToolError.invalidParams("path or item_id required")
        }
        let params: MCPJSONAny = .object([
            "name": .string("explain"),
            "arguments": .object([:]),
        ])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        #expect(response?.error?.code == MCPErrorCode.invalidParams)
        #expect(response?.error?.message.contains("path or item_id required") == true)
    }

    @Test("handler throwing MCPToolError.internalError yields internal-error")
    func handlerInternalErrorIsMapped() {
        let dispatcher = makeDispatcher()
        dispatcher.register(tool: .scan) { _ in
            throw MCPToolError.internalError("scan engine unavailable")
        }
        let params: MCPJSONAny = .object([
            "name": .string("scan"),
            "arguments": .object(["dry_run": .bool(true)]),
        ])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        #expect(response?.error?.code == MCPErrorCode.internalError)
        #expect(response?.error?.message.contains("scan engine unavailable") == true)
    }

    @Test("handler throwing an unrelated error yields internal-error")
    func handlerGenericErrorBecomesInternalError() {
        struct Boom: Error {}
        let dispatcher = makeDispatcher()
        dispatcher.register(tool: .listProfiles) { _ in throw Boom() }
        let params: MCPJSONAny = .object([
            "name": .string("list_profiles"),
        ])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        #expect(response?.error?.code == MCPErrorCode.internalError)
        #expect(response?.error?.message.contains("list_profiles") == true)
    }

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
            var count = 0
        }
        let box = Box()
        let dispatcher = makeDispatcher()
        dispatcher.register(tool: .status) { _ in
            box.count += 1
            return .object([:])
        }
        let req = MCPRequest(
            id: nil,
            method: "tools/call",
            params: .object(["name": .string("status")])
        )
        #expect(dispatcher.dispatch(req) == nil)
        #expect(box.count == 0)
    }

    // MARK: Response encodability

    @Test("initialize result encodes to valid JSON")
    func initializeResultEncodes() throws {
        let dispatcher = makeDispatcher()
        let response = try #require(dispatcher.dispatch(request(method: "initialize")))
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
        dispatcher.register(tool: .analyze) { _ in .string("first") }
        dispatcher.register(tool: .analyze) { _ in .string("second") }
        let params: MCPJSONAny = .object(["name": .string("analyze")])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        #expect(response?.result == .string("second"))
    }
}
