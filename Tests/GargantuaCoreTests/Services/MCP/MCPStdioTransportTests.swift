import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP stdio transport")
struct MCPStdioTransportTests {

    // MARK: In-memory doubles

    private final class QueueSource: MCPMessageSource {
        private var lines: [String]
        init(_ lines: [String]) { self.lines = lines }
        func readLine() -> String? {
            guard !lines.isEmpty else { return nil }
            return lines.removeFirst()
        }
    }

    private final class RecordingSink: MCPMessageSink {
        private(set) var lines: [String] = []
        func writeLine(_ line: String) { lines.append(line) }
    }

    private static let decoder = JSONDecoder()

    // MARK: Helpers

    private func runTransport(
        lines: [String],
        handler: @escaping MCPMessageHandler = Self.methodNotFoundHandler
    ) -> [MCPResponse] {
        let source = QueueSource(lines)
        let sink = RecordingSink()
        let transport = MCPStdioTransport(source: source, sink: sink, handler: handler)
        transport.run()
        return sink.lines.map { line in
            do {
                return try Self.decoder.decode(MCPResponse.self, from: Data(line.utf8))
            } catch {
                Issue.record("response did not decode: \(line) \(error)")
                return MCPResponse.failure(id: .null, code: -1, message: "undecodable")
            }
        }
    }

    private static let methodNotFoundHandler: MCPMessageHandler = { request in
        .failure(
            id: request.id ?? .null,
            code: MCPErrorCode.methodNotFound,
            message: "Method not found: \(request.method)"
        )
    }

    // MARK: Parse + invalid request

    @Test("non-JSON line produces a parse-error response with null id")
    func nonJSONLineYieldsParseError() {
        let responses = runTransport(lines: ["not json at all"])
        #expect(responses.count == 1)
        #expect(responses[0].id == .null)
        #expect(responses[0].error?.code == MCPErrorCode.parseError)
    }

    @Test("valid JSON with missing jsonrpc field produces invalid-request")
    func missingJSONRPCFieldIsInvalidRequest() {
        let line = #"{"id":1,"method":"tools/list"}"#
        let responses = runTransport(lines: [line])
        #expect(responses.count == 1)
        #expect(responses[0].error?.code == MCPErrorCode.invalidRequest)
    }

    @Test("invalid request preserves salvageable request id")
    func invalidRequestSalvagesID() {
        // Valid JSON but wrong jsonrpc version; id should still come back as 7.
        let line = #"{"jsonrpc":"1.0","id":7,"method":"x"}"#
        let responses = runTransport(lines: [line])
        #expect(responses.count == 1)
        #expect(responses[0].id == .int(7))
        #expect(responses[0].error?.code == MCPErrorCode.invalidRequest)
    }

    @Test("string request id survives parse failure")
    func stringIDSurvivesParseFailure() {
        let line = #"{"jsonrpc":"1.0","id":"req-abc","method":"x"}"#
        let responses = runTransport(lines: [line])
        #expect(responses[0].id == .string("req-abc"))
    }

    @Test("invalid boolean id on parse failure falls back to null")
    func booleanIDFallsBackToNull() {
        let line = #"{"jsonrpc":"1.0","id":true,"method":"x"}"#
        let responses = runTransport(lines: [line])
        #expect(responses[0].id == .null)
    }

    // MARK: Default handler behavior

    @Test("well-formed request receives method-not-found from default handler")
    func defaultHandlerReportsMethodNotFound() {
        let line = #"{"jsonrpc":"2.0","id":42,"method":"tools/unknown"}"#
        let responses = runTransport(lines: [line])
        #expect(responses.count == 1)
        #expect(responses[0].id == .int(42))
        #expect(responses[0].error?.code == MCPErrorCode.methodNotFound)
        #expect(responses[0].error?.message.contains("tools/unknown") == true)
    }

    @Test("handler returning nil for request surfaces internal error")
    func nilHandlerResponseBecomesInternalError() {
        let line = #"{"jsonrpc":"2.0","id":1,"method":"x"}"#
        let responses = runTransport(lines: [line]) { _ in nil }
        #expect(responses.count == 1)
        #expect(responses[0].error?.code == MCPErrorCode.internalError)
    }

    // MARK: Notifications

    @Test("notification receives no response")
    func notificationSuppressesResponse() {
        let line = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let responses = runTransport(lines: [line])
        #expect(responses.isEmpty)
    }

    @Test("notification still invokes handler for side effects")
    func notificationStillInvokesHandler() {
        final class Box: @unchecked Sendable { var count = 0 }
        let box = Box()
        let line = #"{"jsonrpc":"2.0","method":"notifications/ping"}"#
        _ = runTransport(lines: [line]) { _ in
            box.count += 1
            return nil
        }
        #expect(box.count == 1)
    }

    // MARK: Framing details

    @Test("blank lines are skipped without producing responses")
    func blankLinesSkipped() {
        let responses = runTransport(lines: ["", "   ", "\t"])
        #expect(responses.isEmpty)
    }

    @Test("multiple requests in sequence each get a response in order")
    func multipleRequestsInOrder() {
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"a"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"b"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"c"}"#,
        ]
        let responses = runTransport(lines: lines)
        #expect(responses.map(\.id) == [.int(1), .int(2), .int(3)])
        #expect(responses.allSatisfy { $0.error?.code == MCPErrorCode.methodNotFound })
    }

    @Test("EOF ends the run loop cleanly with no extra output")
    func eofEndsLoop() {
        // QueueSource returns nil after its buffer empties.
        let responses = runTransport(lines: [])
        #expect(responses.isEmpty)
    }

    @Test("transport writes exactly one line per response (no embedded newlines)")
    func responseIsSingleLine() {
        let line = #"{"jsonrpc":"2.0","id":1,"method":"x"}"#
        let source = QueueSource([line])
        let sink = RecordingSink()
        let transport = MCPStdioTransport(
            source: source,
            sink: sink,
            handler: Self.methodNotFoundHandler
        )
        transport.run()
        #expect(sink.lines.count == 1)
        #expect(!sink.lines[0].contains("\n"))
    }

    @Test("explicit null id in request is echoed in response")
    func explicitNullIDEchoed() {
        let line = #"{"jsonrpc":"2.0","id":null,"method":"tools/unknown"}"#
        let responses = runTransport(lines: [line])
        #expect(responses.count == 1)
        #expect(responses[0].id == .null)
    }
}
