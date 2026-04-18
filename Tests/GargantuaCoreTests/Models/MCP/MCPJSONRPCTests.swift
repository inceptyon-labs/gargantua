import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP JSON-RPC 2.0 framing types")
struct MCPJSONRPCTests {

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder = JSONDecoder()

    // MARK: MCPRequestID

    @Test("request id decodes from int, string, and null")
    func requestIDDecodesAllVariants() throws {
        let intID = try Self.decoder.decode(MCPRequestID.self, from: Data("42".utf8))
        let stringID = try Self.decoder.decode(MCPRequestID.self, from: Data("\"abc\"".utf8))
        let nullID = try Self.decoder.decode(MCPRequestID.self, from: Data("null".utf8))

        #expect(intID == .int(42))
        #expect(stringID == .string("abc"))
        #expect(nullID == .null)
    }

    @Test("request id rejects boolean and array")
    func requestIDRejectsInvalidShapes() {
        #expect(throws: DecodingError.self) {
            _ = try Self.decoder.decode(MCPRequestID.self, from: Data("true".utf8))
        }
        #expect(throws: DecodingError.self) {
            _ = try Self.decoder.decode(MCPRequestID.self, from: Data("[1]".utf8))
        }
    }

    @Test("request id round-trips through encode/decode")
    func requestIDRoundTrip() throws {
        for id in [MCPRequestID.int(7), .string("task-9"), .null] {
            let data = try Self.encoder.encode(id)
            let decoded = try Self.decoder.decode(MCPRequestID.self, from: data)
            #expect(decoded == id)
        }
    }

    // MARK: MCPRequest

    @Test("request decodes with int id and params object")
    func requestDecodesIntIDAndParams() throws {
        let json = """
        {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"cursor":"abc"}}
        """
        let req = try Self.decoder.decode(MCPRequest.self, from: Data(json.utf8))
        #expect(req.jsonrpc == "2.0")
        #expect(req.id == .int(1))
        #expect(req.method == "tools/list")
        guard case .object(let obj) = req.params else {
            Issue.record("params was not an object: \(String(describing: req.params))")
            return
        }
        #expect(obj["cursor"] == .string("abc"))
    }

    @Test("request with absent id is a notification")
    func requestWithoutIDIsNotification() throws {
        let json = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let req = try Self.decoder.decode(MCPRequest.self, from: Data(json.utf8))
        #expect(req.id == nil)
        #expect(req.isNotification)
    }

    @Test("request with explicit null id is not a notification")
    func requestWithNullIDIsNotANotification() throws {
        let json = #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#
        let req = try Self.decoder.decode(MCPRequest.self, from: Data(json.utf8))
        #expect(req.id == .null)
        #expect(!req.isNotification)
    }

    @Test("request rejects wrong jsonrpc version")
    func requestRejectsWrongVersion() {
        let json = #"{"jsonrpc":"1.0","id":1,"method":"x"}"#
        #expect(throws: DecodingError.self) {
            _ = try Self.decoder.decode(MCPRequest.self, from: Data(json.utf8))
        }
    }

    @Test("request encodes notification without id field")
    func requestEncodesNotificationWithoutID() throws {
        let req = MCPRequest(id: nil, method: "log")
        let data = try Self.encoder.encode(req)
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("\"id\""))
        #expect(json.contains("\"method\":\"log\""))
    }

    @Test("request encodes explicit null id")
    func requestEncodesExplicitNullID() throws {
        let req = MCPRequest(id: .null, method: "ping")
        let data = try Self.encoder.encode(req)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"id\":null"))
    }

    // MARK: MCPResponse

    @Test("success response round-trips")
    func successResponseRoundTrip() throws {
        let original = MCPResponse.success(id: .int(5), result: .object(["ok": .bool(true)]))
        let data = try Self.encoder.encode(original)
        let decoded = try Self.decoder.decode(MCPResponse.self, from: data)
        #expect(decoded == original)
    }

    @Test("failure response round-trips")
    func failureResponseRoundTrip() throws {
        let original = MCPResponse.failure(
            id: .string("abc"),
            code: MCPErrorCode.methodNotFound,
            message: "Method not found: tools/foo"
        )
        let data = try Self.encoder.encode(original)
        let decoded = try Self.decoder.decode(MCPResponse.self, from: data)
        #expect(decoded == original)
    }

    @Test("response with both result and error is rejected")
    func responseRejectsBothResultAndError() {
        let json = #"""
        {"jsonrpc":"2.0","id":1,"result":{},"error":{"code":-32601,"message":"x"}}
        """#
        #expect(throws: DecodingError.self) {
            _ = try Self.decoder.decode(MCPResponse.self, from: Data(json.utf8))
        }
    }

    @Test("response with neither result nor error is rejected")
    func responseRejectsNeitherResultNorError() {
        let json = #"{"jsonrpc":"2.0","id":1}"#
        #expect(throws: DecodingError.self) {
            _ = try Self.decoder.decode(MCPResponse.self, from: Data(json.utf8))
        }
    }

    @Test("response with explicit result: null is a successful response")
    func responseWithExplicitNullResultIsSuccess() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"result":null}"#
        let response = try Self.decoder.decode(MCPResponse.self, from: Data(json.utf8))
        #expect(response.id == .int(1))
        #expect(response.result == .null)
        #expect(response.error == nil)
    }

    @Test("success with null result round-trips through encode/decode")
    func successNullResultRoundTrip() throws {
        let original = MCPResponse.success(id: .int(9), result: .null)
        let data = try Self.encoder.encode(original)
        let decoded = try Self.decoder.decode(MCPResponse.self, from: data)
        #expect(decoded == original)
    }

    // MARK: Request params presence

    @Test("request preserves explicit null params")
    func requestPreservesNullParams() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"method":"x","params":null}"#
        let req = try Self.decoder.decode(MCPRequest.self, from: Data(json.utf8))
        #expect(req.params == .null)
    }

    @Test("request with absent params decodes to nil")
    func requestAbsentParamsIsNil() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"method":"x"}"#
        let req = try Self.decoder.decode(MCPRequest.self, from: Data(json.utf8))
        #expect(req.params == nil)
    }

    @Test("success response does not emit an error key")
    func successResponseHasNoErrorKey() throws {
        let data = try Self.encoder.encode(
            MCPResponse.success(id: .int(1), result: .null)
        )
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("\"error\""))
    }

    @Test("failure response does not emit a result key")
    func failureResponseHasNoResultKey() throws {
        let data = try Self.encoder.encode(
            MCPResponse.failure(id: .int(1), code: -32_601, message: "x")
        )
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("\"result\""))
    }

    // MARK: MCPJSONAny

    @Test("MCPJSONAny round-trips nested structures")
    func jsonAnyRoundTrip() throws {
        let value: MCPJSONAny = .object([
            "scalars": .array([.null, .bool(true), .int(7), .number(1.5), .string("x")]),
            "nested": .object(["deep": .array([.int(1), .int(2)])]),
        ])
        let data = try Self.encoder.encode(value)
        let decoded = try Self.decoder.decode(MCPJSONAny.self, from: data)
        #expect(decoded == value)
    }

    @Test("MCPJSONAny encodes null explicitly")
    func jsonAnyEncodesNull() throws {
        let data = try Self.encoder.encode(MCPJSONAny.null)
        #expect(String(data: data, encoding: .utf8) == "null")
    }
}
