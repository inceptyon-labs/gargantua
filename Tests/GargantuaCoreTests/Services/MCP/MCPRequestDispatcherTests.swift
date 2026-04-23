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
        #expect(Set(names) == Set(MCPPhase2Tools.all.map(\.name.rawValue)))
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
        #expect(dryRun["const"] == .bool(true))
    }

    // MARK: tools/call — result envelope (MCP CallToolResult shape)

    @Test("tools/call result wraps handler output in MCP CallToolResult envelope")
    func toolsCallResultHasContentEnvelope() throws {
        let dispatcher = makeDispatcher()
        dispatcher.register(tool: .analyze) { _ in
            .structured(.object(["health_score": .int(99)]), summary: "Healthy")
        }
        let params: MCPJSONAny = .object([
            "name": .string("analyze"),
            "arguments": .object([:]),
        ])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        #expect(response?.error == nil)
        guard case .object(let root) = try #require(response?.result) else {
            Issue.record("result was not an object")
            return
        }
        // `content` must be present as an array of blocks; the first block
        // must be a text block with the summary we provided.
        guard case .array(let content) = root["content"],
              let firstBlock = content.first,
              case .object(let block) = firstBlock else {
            Issue.record("content[] missing or malformed")
            return
        }
        #expect(block["type"] == .string("text"))
        #expect(block["text"] == .string("Healthy"))
        // The typed payload rides along under `structuredContent`.
        guard case .object(let structured) = root["structuredContent"] else {
            Issue.record("structuredContent missing")
            return
        }
        #expect(structured["health_score"] == .int(99))
        // Success responses do not emit isError.
        #expect(root["isError"] == nil)
    }

    @Test("tools/call result omits structuredContent for plain-text handlers")
    func toolsCallTextOnlyResult() throws {
        let dispatcher = makeDispatcher()
        dispatcher.register(tool: .status) { _ in .text("ok") }
        let params: MCPJSONAny = .object(["name": .string("status")])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        guard case .object(let root) = try #require(response?.result) else {
            Issue.record("result was not an object")
            return
        }
        #expect(root["structuredContent"] == nil)
        #expect(root["isError"] == nil)
        guard case .array(let content) = root["content"], case .object(let block) = content.first else {
            Issue.record("content missing")
            return
        }
        #expect(block["type"] == .string("text"))
        #expect(block["text"] == .string("ok"))
    }

    @Test("tool-domain failure returns isError:true success result, not a JSON-RPC error")
    func toolsCallFailureIsReportedAsIsError() throws {
        let dispatcher = makeDispatcher()
        dispatcher.register(tool: .explain) { _ in .failure("item not found") }
        let params: MCPJSONAny = .object([
            "name": .string("explain"),
            "arguments": .object(["path": .string("/missing")]),
        ])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        // Tool-domain failures ride the result, not the JSON-RPC error slot.
        #expect(response?.error == nil)
        guard case .object(let root) = try #require(response?.result) else {
            Issue.record("result was not an object")
            return
        }
        #expect(root["isError"] == .bool(true))
        guard case .array(let content) = root["content"], case .object(let block) = content.first else {
            Issue.record("content missing")
            return
        }
        #expect(block["text"] == .string("item not found"))
    }

    // MARK: tools/call — arguments validation

    @Test("tools/call invokes the registered handler with its arguments")
    func toolsCallRoutesToHandler() throws {
        let dispatcher = makeDispatcher()
        final class Capture: @unchecked Sendable {
            var received: [String: MCPJSONAny]?
        }
        let capture = Capture()
        dispatcher.register(tool: .analyze) { args in
            capture.received = args.raw
            return .text("ok")
        }
        let params: MCPJSONAny = .object([
            "name": .string("analyze"),
            "arguments": .object(["detail": .string("full")]),
        ])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        #expect(response?.error == nil)
        #expect(capture.received == ["detail": .string("full")])
    }

    @Test("tools/call with absent arguments passes empty arguments to handler")
    func toolsCallAbsentArgumentsPassesEmpty() throws {
        let dispatcher = makeDispatcher()
        final class Capture: @unchecked Sendable {
            var sawEmpty = false
        }
        let capture = Capture()
        dispatcher.register(tool: .status) { args in
            capture.sawEmpty = args.isEmpty
            return .text("ok")
        }
        let params: MCPJSONAny = .object(["name": .string("status")])
        _ = dispatcher.dispatch(request(method: "tools/call", params: params))
        #expect(capture.sawEmpty == true)
    }

    @Test("tools/call with explicit-null arguments is rejected as invalid-params")
    func toolsCallExplicitNullArgumentsRejected() {
        let dispatcher = makeDispatcher()
        dispatcher.register(tool: .status) { _ in
            Issue.record("handler must not be invoked for invalid arguments shape")
            return .text("unreached")
        }
        let params: MCPJSONAny = .object([
            "name": .string("status"),
            "arguments": .null,
        ])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        #expect(response?.error?.code == MCPErrorCode.invalidParams)
        #expect(response?.error?.message.contains("must be an object") == true)
    }

    @Test("tools/call with array arguments is rejected as invalid-params")
    func toolsCallArrayArgumentsRejected() {
        let dispatcher = makeDispatcher()
        let params: MCPJSONAny = .object([
            "name": .string("status"),
            "arguments": .array([.string("a")]),
        ])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        #expect(response?.error?.code == MCPErrorCode.invalidParams)
    }

    @Test("tools/call with scalar arguments is rejected as invalid-params")
    func toolsCallScalarArgumentsRejected() {
        let dispatcher = makeDispatcher()
        let params: MCPJSONAny = .object([
            "name": .string("status"),
            "arguments": .int(42),
        ])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        #expect(response?.error?.code == MCPErrorCode.invalidParams)
    }

    // MARK: MCPToolArguments decoding

    @Test("MCPToolArguments.decode surfaces decode errors as invalidParams")
    func toolArgumentsDecodeTypedStruct() throws {
        struct Input: Decodable, Equatable {
            let path: String
        }
        let good = MCPToolArguments(["path": .string("/tmp")])
        let decoded = try good.decode(Input.self)
        #expect(decoded == Input(path: "/tmp"))

        let bad = MCPToolArguments(["path": .int(7)])
        #expect(throws: MCPToolError.self) {
            _ = try bad.decode(Input.self)
        }
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

    @Test("handler throwing MCPToolError.invalidParams yields invalid-params with handler message")
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

    @Test("handler throwing MCPToolError.internalError yields internal-error with handler message")
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

    @Test("generic handler exception is sanitised in the client response and logged")
    func handlerGenericErrorIsSanitisedAndLogged() {
        struct LeakyError: Error { let secret: String }
        final class LogBox: @unchecked Sendable {
            var entries: [String] = []
            func append(_ s: String) { entries.append(s) }
        }
        let box = LogBox()
        let dispatcher = makeDispatcher(log: { box.append($0) })
        dispatcher.register(tool: .listProfiles) { _ in
            throw LeakyError(secret: "/Users/alice/.ssh/id_rsa")
        }
        let params: MCPJSONAny = .object(["name": .string("list_profiles")])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        #expect(response?.error?.code == MCPErrorCode.internalError)
        // Client never sees the sensitive path.
        #expect(response?.error?.message.contains("/Users/alice") == false)
        #expect(response?.error?.message.contains("secret") == false)
        #expect(response?.error?.message == "Internal error: Tool execution failed")
        // Log sink records the detail for operators.
        #expect(box.entries.contains { $0.contains("list_profiles") })
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
            return .text("ok")
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
