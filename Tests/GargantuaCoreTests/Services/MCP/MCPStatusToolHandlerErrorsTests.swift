import Testing
import Foundation
@testable import GargantuaCore

private let serverInfo = MCPServerInfo(name: "gargantua", version: "0.0.1")

private func makeSnapshot(
    cpuUsage: Double = 0.452,
    memoryPressure: Double = 0.444,
    memoryTotal: UInt64 = 32_000_000_000,
    memoryUsed: UInt64 = 14_200_000_000,
    diskUsage: Double = 0.76,
    diskTotal: UInt64 = 500_000_000_000,
    diskUsed: UInt64 = 380_000_000_000,
    diskFree: UInt64 = 120_000_000_000,
    thermal: ThermalLevel = .nominal,
    uptime: TimeInterval = 6 * 86_400 + 12 * 3_600,
    cores: Int = 10
) -> SystemStatusSnapshot {
    let metrics = SystemMetrics(
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
    return SystemStatusSnapshot(metrics: metrics, uptime: uptime, coreCount: cores)
}

private func makeHandler(
    snapshot: @escaping @Sendable () throws -> SystemStatusSnapshot
) -> MCPStatusToolHandler {
    MCPStatusToolHandler(snapshotProvider: snapshot)
}

private let emptyArguments = MCPToolArguments([:])

@Suite("MCP status tool handler errors and dispatcher")
struct MCPStatusToolHandlerErrorsTests {

    // MARK: - Provider errors

    @Test("provider throwing a LocalizedError surfaces description in .failure")
    func providerLocalizedError() throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "metrics backend down" }
        }
        let subject = makeHandler(snapshot: { throw Boom() })
        let result = try subject.handle(emptyArguments)
        #expect(result.isError == true)
        guard case .text(let message) = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(message.contains("Status failed"))
        #expect(message.contains("metrics backend down"))
    }

    @Test("provider throwing a plain Error does not leak its reflection")
    func providerPlainErrorSanitized() throws {
        struct SecretLeak: Error {
            let secret = "/private/credentials"
        }
        let captured = StatusCapturedLog()
        let subject = MCPStatusToolHandler(
            snapshotProvider: { throw SecretLeak() },
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
        #expect(captured.joined.contains("SecretLeak"))
    }

    @Test("provider throwing MCPToolError.invalidParams rethrows for dispatcher")
    func providerInvalidParamsRethrown() throws {
        let subject = makeHandler(snapshot: {
            throw MCPToolError.invalidParams("bad input")
        })
        do {
            _ = try subject.handle(emptyArguments)
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message == "bad input")
        }
    }

    @Test("provider throwing MCPToolError.internalError rethrows for dispatcher")
    func providerInternalErrorRethrown() throws {
        let subject = makeHandler(snapshot: {
            throw MCPToolError.internalError("misconfigured")
        })
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
        let subject = makeHandler(snapshot: { makeSnapshot() })
        dispatcher.register(tool: .status, handler: subject.toolHandler)

        let request = MCPRequest(
            id: .int(3),
            method: "tools/call",
            params: .object([
                "name": .string("status"),
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
}

// MARK: - Test capture helpers

private final class StatusCapturedLog: @unchecked Sendable {
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
