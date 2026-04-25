import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCPRequestDispatcher tools/call validation and errors")
struct MCPRequestDispatcherToolCallTests {

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
}
