import Testing
import Foundation
@testable import GargantuaCore

private let serverInfo = MCPServerInfo(name: "gargantua", version: "0.0.1")

private func makeMetrics(
    cpuUsage: Double = 0.20,
    memoryPressure: Double = 0.40,
    memoryTotal: UInt64 = 32_000_000_000,
    memoryUsed: UInt64 = 12_800_000_000,
    diskUsage: Double = 0.50,
    diskTotal: UInt64 = 500_000_000_000,
    diskUsed: UInt64 = 250_000_000_000,
    diskFree: UInt64 = 250_000_000_000,
    thermal: ThermalLevel = .nominal
) -> SystemMetrics {
    SystemMetrics(
        cpuUsage: cpuUsage,
        memoryPressure: memoryPressure,
        memoryTotal: memoryTotal,
        memoryUsed: memoryUsed,
        diskUsage: diskUsage,
        diskTotal: diskTotal,
        diskUsed: diskUsed,
        diskFree: diskFree,
        thermalLevel: thermal
    )
}

private func makeHandler(
    metrics: @escaping @Sendable () throws -> SystemMetrics
) -> MCPAnalyzeToolHandler {
    MCPAnalyzeToolHandler(metricsProvider: metrics)
}

private let emptyArguments = MCPToolArguments([:])

@Suite("MCP analyze tool handler errors and dispatcher")
struct MCPAnalyzeToolHandlerErrorsTests {

    // MARK: - Provider errors

    @Test("provider throwing a LocalizedError surfaces description in .failure")
    func providerLocalizedError() throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "collector unavailable" }
        }
        let subject = makeHandler(metrics: { throw Boom() })
        let result = try subject.handle(emptyArguments)
        #expect(result.isError == true)
        guard case .text(let message) = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(message.contains("Analyze failed"))
        #expect(message.contains("collector unavailable"))
    }

    @Test("provider throwing a plain Error does not leak its reflection")
    func providerPlainErrorSanitized() throws {
        struct SecretLeak: Error {
            let secret = "/private/credentials"
        }
        let captured = AnalyzeCapturedLog()
        let subject = MCPAnalyzeToolHandler(
            metricsProvider: { throw SecretLeak() },
            log: { captured.append($0) }
        )
        let result = try subject.handle(emptyArguments)
        #expect(result.isError == true)
        guard case .text(let message) = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(!message.contains("SecretLeak"))
        #expect(!message.contains("/private/credentials"))
        #expect(message.contains("internal error"))
        // Raw detail still goes to stderr for operators.
        #expect(captured.joined.contains("SecretLeak"))
    }

    @Test("provider throwing MCPToolError.invalidParams rethrows for dispatcher")
    func providerInvalidParamsRethrown() throws {
        let subject = makeHandler(metrics: { throw MCPToolError.invalidParams("bad input") })
        do {
            _ = try subject.handle(emptyArguments)
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message == "bad input")
        }
    }

    @Test("provider throwing MCPToolError.internalError rethrows for dispatcher")
    func providerInternalErrorRethrown() throws {
        let subject = makeHandler(metrics: { throw MCPToolError.internalError("misconfigured") })
        do {
            _ = try subject.handle(emptyArguments)
            Issue.record("handler should have thrown")
        } catch MCPToolError.internalError(let message) {
            #expect(message == "misconfigured")
        }
    }

    // MARK: - Dispatcher integration

    @Test("registering with dispatcher routes tools/call to the handler")
    func dispatcherIntegration() throws {
        let dispatcher = MCPRequestDispatcher(serverInfo: serverInfo)
        let subject = makeHandler(metrics: { makeMetrics() })
        dispatcher.register(tool: .analyze, handler: subject.toolHandler)

        let request = MCPRequest(
            id: .int(1),
            method: "tools/call",
            params: .object([
                "name": .string("analyze"),
                "arguments": .object([:]),
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
        let subject = makeHandler(metrics: { throw Boom() })
        dispatcher.register(tool: .analyze, handler: subject.toolHandler)

        let request = MCPRequest(
            id: .int(2),
            method: "tools/call",
            params: .object([
                "name": .string("analyze"),
                "arguments": .object([:]),
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
}

// MARK: - Test capture helpers

private final class AnalyzeCapturedLog: @unchecked Sendable {
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
