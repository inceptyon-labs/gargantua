import Testing
import Foundation
@testable import GargantuaCore

private let serverInfo = MCPServerInfo(name: "gargantua", version: "0.0.1")

private func makeOutput(
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

private func makeHandler(
    explain: @escaping @Sendable (MCPExplainInput) throws -> MCPExplainOutput
) -> MCPExplainToolHandler {
    MCPExplainToolHandler(explainProvider: explain)
}

private func pathArguments(_ path: String) -> MCPToolArguments {
    MCPToolArguments(["path": .string(path)])
}

private func itemIdArguments(_ id: String) -> MCPToolArguments {
    MCPToolArguments(["item_id": .string(id)])
}

@Suite("MCP explain tool handler errors and dispatcher")
struct MCPExplainToolHandlerErrorsTests {

    // MARK: - Provider errors

    @Test("provider throwing MCPToolError.invalidParams rethrows for dispatcher")
    func providerInvalidParamsRethrown() throws {
        let subject = makeHandler(explain: { _ in
            throw MCPToolError.invalidParams("item_id lookup not supported")
        })
        do {
            _ = try subject.handle(itemIdArguments("abc"))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.contains("item_id"))
        }
    }

    @Test("provider throwing MCPToolError.internalError rethrows for dispatcher")
    func providerInternalErrorRethrown() throws {
        let subject = makeHandler(explain: { _ in
            throw MCPToolError.internalError("misconfigured")
        })
        do {
            _ = try subject.handle(pathArguments("/tmp/foo"))
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
        let subject = makeHandler(explain: { _ in throw Boom() })
        let result = try subject.handle(pathArguments("/tmp/foo"))
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
        let result = try subject.handle(pathArguments("/tmp/foo"))
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

    // MARK: - Dispatcher integration

    @Test("registering with dispatcher routes tools/call to the handler")
    func dispatcherIntegration() throws {
        let dispatcher = MCPRequestDispatcher(serverInfo: serverInfo)
        let subject = makeHandler(explain: { _ in makeOutput() })
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
        let dispatcher = MCPRequestDispatcher(serverInfo: serverInfo)
        let subject = makeHandler(explain: { _ in throw Boom() })
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
        let dispatcher = MCPRequestDispatcher(serverInfo: serverInfo)
        let subject = makeHandler(explain: { _ in makeOutput() })
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
