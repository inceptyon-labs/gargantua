import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP stdio transport")
struct MCPStdioTransportTests {

    // MARK: In-memory doubles

    // Both doubles are driven synchronously on the test's own thread — the
    // transport is never sent to another queue here — so the unguarded
    // mutable state is safe without a lock.
    private final class QueueSource: MCPMessageSource, @unchecked Sendable {
        private var lines: [String]
        init(_ lines: [String]) { self.lines = lines }
        func readLine() -> String? {
            guard !lines.isEmpty else { return nil }
            return lines.removeFirst()
        }
    }

    private final class RecordingSink: MCPMessageSink, @unchecked Sendable {
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

    // MARK: Encode-failure fallback

    @Test("non-finite handler result falls back to internal-error response")
    func nonFiniteResultFallsBackToInternalError() {
        let line = #"{"jsonrpc":"2.0","id":5,"method":"bad"}"#
        let responses = runTransport(lines: [line]) { _ in
            .success(id: .int(5), result: .number(Double.infinity))
        }
        #expect(responses.count == 1)
        #expect(responses[0].id == .int(5))
        #expect(responses[0].error?.code == MCPErrorCode.internalError)
        #expect(responses[0].error?.message.contains("failed to encode") == true)
    }

    // MARK: Encoding format

    @Test("Encoded responses keep sorted keys and unescaped slashes")
    func encodedResponsesKeepSortedKeysAndUnescapedSlashes() {
        // Every other assertion in this suite decodes the response, which
        // normalizes away both `.sortedKeys` and `.withoutEscapingSlashes`.
        // This test asserts on the raw encoded line so a dropped flag on the
        // transport's encoder actually fails a test.
        let line = #"{"jsonrpc":"2.0","id":42,"method":"tools/unknown"}"#
        let source = QueueSource([line])
        let sink = RecordingSink()
        let transport = MCPStdioTransport(source: source, sink: sink, handler: Self.methodNotFoundHandler)
        transport.run()
        #expect(sink.lines.count == 1)
        let raw = sink.lines[0]

        // Guards `.withoutEscapingSlashes`: the method name's slash must survive
        // in the raw output unescaped.
        #expect(raw.contains("tools/unknown"))
        #expect(!raw.contains(#"tools\/unknown"#))

        // Guards `.sortedKeys`: top-level object keys must appear in sorted order.
        let topLevelKeys = Self.topLevelKeys(in: raw)
        #expect(!topLevelKeys.isEmpty)
        #expect(topLevelKeys == topLevelKeys.sorted())
    }

    /// Manual scan for the keys of a JSON object, at depth 1 only — nested
    /// keys (e.g. inside `"error": {...}`) are skipped so this only reflects
    /// the ordering `.sortedKeys` actually controls at the top level.
    private static func topLevelKeys(in json: String) -> [String] {
        var scanner = TopLevelKeyScanner()
        for char in json {
            scanner.consume(char)
        }
        return scanner.keys
    }

    private struct TopLevelKeyScanner {
        private(set) var keys: [String] = []
        private var depth = 0
        private var inString = false
        private var escaped = false
        private var expectingKey = false
        private var currentKey = ""

        mutating func consume(_ char: Character) {
            if inString {
                consumeInString(char)
            } else {
                consumeStructural(char)
            }
        }

        private mutating func consumeInString(_ char: Character) {
            if escaped {
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "\"" {
                inString = false
                endKeyIfExpected()
            } else if depth == 1, expectingKey {
                currentKey.append(char)
            }
        }

        private mutating func consumeStructural(_ char: Character) {
            switch char {
            case "{":
                depth += 1
                if depth == 1 { expectingKey = true }
            case "}":
                depth -= 1
            case ",":
                if depth == 1 { expectingKey = true }
            case "\"":
                inString = true
                if depth == 1, expectingKey { currentKey = "" }
            default:
                break
            }
        }

        private mutating func endKeyIfExpected() {
            guard depth == 1, expectingKey else { return }
            keys.append(currentKey)
            expectingKey = false
        }
    }

    // MARK: Log truncation

    @Test("log truncates oversized input and escapes control characters")
    func logTruncatesAndEscapes() {
        final class LogSink: @unchecked Sendable {
            var entries: [String] = []
            func append(_ message: String) { entries.append(message) }
        }
        let sink = LogSink()
        let huge = String(repeating: "x", count: 2_000)
        let payloadWithControl = "\u{07}\(huge)" // BEL at the head
        let source = QueueSource([payloadWithControl])
        let outSink = RecordingSink()
        let transport = MCPStdioTransport(
            source: source,
            sink: outSink,
            handler: Self.methodNotFoundHandler,
            log: { sink.append($0) }
        )
        transport.run()
        #expect(sink.entries.count == 1)
        let entry = sink.entries[0]
        #expect(entry.contains("\\u0007"), "control chars must be escaped: \(entry.prefix(40))")
        #expect(entry.contains("truncated"), "oversize logs must be truncated")
        #expect(!entry.contains("\u{07}"), "raw BEL must not leak to stderr")
    }
}
