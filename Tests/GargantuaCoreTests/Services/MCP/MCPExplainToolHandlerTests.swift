import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP explain tool handler")
struct MCPExplainToolHandlerTests {

    // MARK: Fixtures

    private static let serverInfo = MCPServerInfo(name: "gargantua", version: "0.0.1")

    private static func makeOutput(
        name: String = "node_modules",
        safety: String = "review",
        confidence: Int = 50,
        explanation: String = "No AI-backed analysis available yet.",
        size: String? = "128 MB",
        lastAccessed: Date? = nil
    ) -> MCPExplainOutput {
        MCPExplainOutput(
            name: name,
            safety: safety,
            confidence: confidence,
            explanation: explanation,
            size: size,
            lastAccessed: lastAccessed
        )
    }

    private func handler(
        explain: @escaping @Sendable (MCPExplainInput) throws -> MCPExplainOutput
    ) -> MCPExplainToolHandler {
        MCPExplainToolHandler(explainProvider: explain)
    }

    private static func pathArguments(_ path: String) -> MCPToolArguments {
        MCPToolArguments(["path": .string(path)])
    }

    private static func itemIdArguments(_ id: String) -> MCPToolArguments {
        MCPToolArguments(["item_id": .string(id)])
    }

    private static func decodeOutput(_ result: MCPToolCallResult) throws -> MCPExplainOutput {
        let payload = try #require(result.structuredContent, "structured content missing")
        let data = try JSONEncoder().encode(payload)
        // MCPExplainOutput.lastAccessed is Date? encoded as ISO-8601 via
        // MCPEncoding; decode with the matching strategy to round-trip it.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MCPExplainOutput.self, from: data)
    }

    // MARK: Input decoding

    @Test("missing both path and item_id surfaces as invalidParams")
    func missingInputsInvalid() throws {
        let subject = handler(explain: { _ in Self.makeOutput() })
        do {
            _ = try subject.handle(MCPToolArguments([:]))
            Issue.record("handler should have thrown invalidParams")
        } catch MCPToolError.invalidParams {
            // expected
        }
    }

    @Test("supplying both path and item_id surfaces as invalidParams")
    func conflictingInputsInvalid() throws {
        let subject = handler(explain: { _ in Self.makeOutput() })
        do {
            _ = try subject.handle(MCPToolArguments([
                "path": .string("/tmp/foo"),
                "item_id": .string("abc"),
            ]))
            Issue.record("handler should have thrown invalidParams")
        } catch MCPToolError.invalidParams {
            // expected
        }
    }

    @Test("path-only arguments are accepted and forwarded to provider")
    func pathAccepted() throws {
        var seen: MCPExplainInput?
        let subject = handler(explain: { input in
            seen = input
            return Self.makeOutput()
        })
        _ = try subject.handle(Self.pathArguments("/tmp/foo"))
        #expect(seen?.path == "/tmp/foo")
        #expect(seen?.itemId == nil)
    }

    @Test("item_id-only arguments are accepted and forwarded to provider")
    func itemIdAccepted() throws {
        var seen: MCPExplainInput?
        let subject = handler(explain: { input in
            seen = input
            return Self.makeOutput()
        })
        _ = try subject.handle(Self.itemIdArguments("abc"))
        #expect(seen?.path == nil)
        #expect(seen?.itemId == "abc")
    }

    // MARK: Happy path

    @Test("maps provider output into MCPExplainOutput core fields")
    func mapsCoreFields() throws {
        let expected = Self.makeOutput(
            name: "node_modules",
            safety: "review",
            confidence: 65,
            explanation: "Project dependency cache.",
            size: "128 MB"
        )
        let subject = handler(explain: { _ in expected })
        let result = try subject.handle(Self.pathArguments("/Users/x/project/node_modules"))
        #expect(result.isError == false)
        let output = try Self.decodeOutput(result)
        #expect(output.name == expected.name)
        #expect(output.safety == expected.safety)
        #expect(output.confidence == expected.confidence)
        #expect(output.explanation == expected.explanation)
        #expect(output.size == expected.size)
    }

    @Test("lastAccessed Date round-trips as ISO-8601 on the wire")
    func lastAccessedIso8601() throws {
        let fixed = Date(timeIntervalSince1970: 1_712_836_200) // 2024-04-11T11:10:00Z
        let subject = handler(explain: { _ in Self.makeOutput(lastAccessed: fixed) })
        let payload = try #require(
            try subject.handle(Self.pathArguments("/tmp/foo")).structuredContent
        )
        guard case .object(let root) = payload else {
            Issue.record("payload should be object")
            return
        }
        guard case .string(let lastAccessed) = root["last_accessed"] else {
            Issue.record("last_accessed should be an ISO-8601 string")
            return
        }
        // Sanity-check the shape; exact formatting comes from JSONEncoder's
        // .iso8601 strategy so avoid asserting the literal millisecond suffix.
        #expect(lastAccessed.hasPrefix("2024-04-11T"))
        #expect(lastAccessed.hasSuffix("Z"))
    }

    @Test("size is omitted from the wire payload when nil")
    func sizeNilOmitted() throws {
        let subject = handler(explain: { _ in Self.makeOutput(size: nil) })
        let payload = try #require(
            try subject.handle(Self.pathArguments("/tmp/foo")).structuredContent
        )
        guard case .object(let root) = payload else {
            Issue.record("payload should be object")
            return
        }
        #expect(root["size"] == nil)
    }

    @Test("wire envelope uses snake_case keys matching PRD contract")
    func wireKeysSnakeCase() throws {
        let fixed = Date(timeIntervalSince1970: 1_712_836_200)
        let subject = handler(explain: { _ in Self.makeOutput(lastAccessed: fixed) })
        let payload = try #require(
            try subject.handle(Self.pathArguments("/tmp/foo")).structuredContent
        )
        guard case .object(let root) = payload else {
            Issue.record("payload should be object")
            return
        }
        #expect(root["name"] != nil)
        #expect(root["safety"] != nil)
        #expect(root["confidence"] != nil)
        #expect(root["explanation"] != nil)
        #expect(root["size"] != nil)
        #expect(root["last_accessed"] != nil)
    }

    @Test("result is .structured with text summary derived from output")
    func structuredResultShape() throws {
        let subject = handler(explain: { _ in
            Self.makeOutput(name: "cache.db", size: "1.2 GB")
        })
        let result = try subject.handle(Self.pathArguments("/tmp/cache.db"))
        #expect(result.isError == false)
        #expect(result.structuredContent != nil)
        guard case .text(let summary) = result.content.first else {
            Issue.record("content[0] should be text")
            return
        }
        #expect(summary.contains("cache.db"))
        #expect(summary.contains("1.2 GB"))
        #expect(summary.contains("review"))
    }

    // MARK: Provider errors

    @Test("provider throwing MCPToolError.invalidParams rethrows for dispatcher")
    func providerInvalidParamsRethrown() throws {
        let subject = handler(explain: { _ in
            throw MCPToolError.invalidParams("item_id lookup not supported")
        })
        do {
            _ = try subject.handle(Self.itemIdArguments("abc"))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.contains("item_id"))
        }
    }

    @Test("provider throwing MCPToolError.internalError rethrows for dispatcher")
    func providerInternalErrorRethrown() throws {
        let subject = handler(explain: { _ in
            throw MCPToolError.internalError("misconfigured")
        })
        do {
            _ = try subject.handle(Self.pathArguments("/tmp/foo"))
            Issue.record("handler should have thrown")
        } catch MCPToolError.internalError(let message) {
            #expect(message == "misconfigured")
        }
    }

    @Test("provider throwing a LocalizedError surfaces description in .failure")
    func providerLocalizedError() throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "inference unavailable" }
        }
        let subject = handler(explain: { _ in throw Boom() })
        let result = try subject.handle(Self.pathArguments("/tmp/foo"))
        #expect(result.isError == true)
        guard case .text(let message) = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(message.contains("Explain failed"))
        #expect(message.contains("inference unavailable"))
    }

    @Test("provider throwing a plain Error does not leak its reflection")
    func providerPlainErrorSanitized() throws {
        struct SecretLeak: Error {
            let secret = "/private/credentials"
        }
        let captured = ExplainCapturedLog()
        let subject = MCPExplainToolHandler(
            explainProvider: { _ in throw SecretLeak() },
            log: { captured.append($0) }
        )
        let result = try subject.handle(Self.pathArguments("/tmp/foo"))
        #expect(result.isError == true)
        guard case .text(let message) = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(!message.contains("SecretLeak"))
        #expect(!message.contains("/private/credentials"))
        #expect(message.contains("internal error"))
        #expect(captured.joined.contains("SecretLeak"))
    }

    // MARK: Dispatcher integration

    @Test("registering with dispatcher routes tools/call to the handler")
    func dispatcherIntegration() throws {
        let dispatcher = MCPRequestDispatcher(serverInfo: Self.serverInfo)
        let subject = handler(explain: { _ in Self.makeOutput() })
        dispatcher.register(tool: .explain, handler: subject.toolHandler)

        let request = MCPRequest(
            id: .int(1),
            method: "tools/call",
            params: .object([
                "name": .string("explain"),
                "arguments": .object([
                    "path": .string("/tmp/foo"),
                ]),
            ])
        )
        let response = try #require(dispatcher.dispatch(request))
        #expect(response.error == nil)
        guard case .object(let envelope) = response.result else {
            Issue.record("result should be an object")
            return
        }
        #expect(envelope["content"] != nil)
        #expect(envelope["structuredContent"] != nil)
        #expect(envelope["isError"] == nil)
    }

    @Test("dispatcher reports tool-domain failure as isError=true, not JSON-RPC error")
    func dispatcherPropagatesDomainFailure() throws {
        struct Boom: Error {}
        let dispatcher = MCPRequestDispatcher(serverInfo: Self.serverInfo)
        let subject = handler(explain: { _ in throw Boom() })
        dispatcher.register(tool: .explain, handler: subject.toolHandler)

        let request = MCPRequest(
            id: .int(2),
            method: "tools/call",
            params: .object([
                "name": .string("explain"),
                "arguments": .object([
                    "path": .string("/tmp/foo"),
                ]),
            ])
        )
        let response = try #require(dispatcher.dispatch(request))
        #expect(response.error == nil)
        guard case .object(let envelope) = response.result else {
            Issue.record("result should be an object")
            return
        }
        #expect(envelope["isError"] == .bool(true))
    }

    @Test("invalidParams on input decoding surfaces as JSON-RPC -32602 via dispatcher")
    func dispatcherReportsInvalidParams() throws {
        let dispatcher = MCPRequestDispatcher(serverInfo: Self.serverInfo)
        let subject = handler(explain: { _ in Self.makeOutput() })
        dispatcher.register(tool: .explain, handler: subject.toolHandler)

        let request = MCPRequest(
            id: .int(3),
            method: "tools/call",
            params: .object([
                "name": .string("explain"),
                "arguments": .object([:]),
            ])
        )
        let response = try #require(dispatcher.dispatch(request))
        #expect(response.error?.code == -32602)
    }
}

// MARK: - Test capture helpers

private final class ExplainCapturedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var joined: String {
        lock.lock()
        defer { lock.unlock() }
        return entries.joined(separator: "\n")
    }
}
