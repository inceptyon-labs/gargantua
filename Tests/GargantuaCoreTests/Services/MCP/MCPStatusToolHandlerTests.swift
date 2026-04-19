import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP status tool handler")
struct MCPStatusToolHandlerTests {

    // MARK: Fixtures

    private static let serverInfo = MCPServerInfo(name: "gargantua", version: "0.0.1")

    private static func makeSnapshot(
        cpuUsage: Double = 0.452,
        memoryPressure: Double = 0.444,
        memoryTotal: UInt64 = 32_000_000_000,
        memoryUsed: UInt64 = 14_200_000_000,
        diskUsage: Double = 0.76,
        diskTotal: UInt64 = 500_000_000_000,
        diskUsed: UInt64 = 380_000_000_000,
        diskFree: UInt64 = 120_000_000_000,
        thermal: ThermalLevel = .nominal,
        uptime: TimeInterval = 6 * 86_400 + 12 * 3_600, // 6d 12h
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

    private func handler(
        snapshot: @escaping @Sendable () throws -> SystemStatusSnapshot
    ) -> MCPStatusToolHandler {
        MCPStatusToolHandler(snapshotProvider: snapshot)
    }

    private static let emptyArguments = MCPToolArguments([:])

    private static func decodeOutput(_ result: MCPToolCallResult) throws -> MCPStatusOutput {
        let payload = try #require(result.structuredContent, "structured content missing")
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(MCPStatusOutput.self, from: data)
    }

    // MARK: Happy path

    @Test("maps snapshot into MCPStatusOutput fields with PRD §7.3 example values")
    func mapsExampleFields() throws {
        let subject = handler(snapshot: { Self.makeSnapshot() })
        let result = try subject.handle(Self.emptyArguments)
        #expect(result.isError == false)
        let output = try Self.decodeOutput(result)
        #expect(output.cpu.usage == 45.2)
        #expect(output.cpu.cores == 10)
        // AlertItem.formatBytes drops the decimal for values >= 10 of a
        // unit, so 14.2 GB renders as "14 GB". The PRD §7.3 example shows
        // "14.2 GB" but the app's canonical formatter is authoritative.
        #expect(output.memory.used == "14 GB")
        #expect(output.memory.total == "32 GB")
        #expect(output.memory.percent == 44.4)
        #expect(output.disk.used == "380 GB")
        #expect(output.disk.total == "500 GB")
        #expect(output.disk.percent == 76.0)
        #expect(output.uptime == "6d 12h")
    }

    @Test("healthScore reflects the underlying SystemMetrics composite")
    func healthScoreMatchesMetrics() throws {
        let snapshot = Self.makeSnapshot()
        let subject = handler(snapshot: { snapshot })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        #expect(output.healthScore == snapshot.metrics.healthScore)
    }

    @Test("wire envelope uses snake_case keys matching PRD contract")
    func wireKeysSnakeCase() throws {
        let subject = handler(snapshot: { Self.makeSnapshot() })
        let payload = try #require(try subject.handle(Self.emptyArguments).structuredContent)
        guard case .object(let root) = payload else {
            Issue.record("payload should be object")
            return
        }
        #expect(root["health_score"] != nil)
        #expect(root["cpu"] != nil)
        #expect(root["memory"] != nil)
        #expect(root["disk"] != nil)
        #expect(root["uptime"] != nil)
    }

    // MARK: Percent rounding

    @Test("percent fields are rounded to one decimal place")
    func percentRoundingOneDecimal() throws {
        let subject = handler(snapshot: {
            Self.makeSnapshot(
                cpuUsage: 0.123_456,
                memoryPressure: 0.987_654,
                diskUsage: 0.500_049
            )
        })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        #expect(output.cpu.usage == 12.3)
        #expect(output.memory.percent == 98.8)
        #expect(output.disk.percent == 50.0)
    }

    @Test("percent fields clamp to 0..100 for out-of-range fractions")
    func percentClamping() throws {
        // SystemMetrics init already clamps, but confirm the handler doesn't
        // overshoot even if a future data source feeds it raw values.
        let subject = handler(snapshot: {
            Self.makeSnapshot(cpuUsage: 2.0, memoryPressure: -0.5, diskUsage: 1.0)
        })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        #expect(output.cpu.usage == 100.0)
        #expect(output.memory.percent == 0.0)
        #expect(output.disk.percent == 100.0)
    }

    // MARK: Uptime formatting

    @Test("uptime formats as days+hours when >= 1 day")
    func uptimeDaysAndHours() {
        let formatted = MCPStatusToolHandler.formatUptime(6 * 86_400 + 12 * 3_600)
        #expect(formatted == "6d 12h")
    }

    @Test("uptime formats as hours+minutes when < 1 day")
    func uptimeHoursAndMinutes() {
        let formatted = MCPStatusToolHandler.formatUptime(3 * 3_600 + 15 * 60)
        #expect(formatted == "3h 15m")
    }

    @Test("uptime formats as minutes when < 1 hour")
    func uptimeMinutesOnly() {
        let formatted = MCPStatusToolHandler.formatUptime(42 * 60)
        #expect(formatted == "42m")
    }

    @Test("uptime at exactly 1 day renders 1d 0h")
    func uptimeExactlyOneDay() {
        let formatted = MCPStatusToolHandler.formatUptime(86_400)
        #expect(formatted == "1d 0h")
    }

    @Test("uptime zero renders 0m")
    func uptimeZero() {
        let formatted = MCPStatusToolHandler.formatUptime(0)
        #expect(formatted == "0m")
    }

    @Test("negative uptime clamps to 0m")
    func uptimeNegativeClamped() {
        let formatted = MCPStatusToolHandler.formatUptime(-100)
        #expect(formatted == "0m")
    }

    // MARK: Provider errors

    @Test("provider throwing a LocalizedError surfaces description in .failure")
    func providerLocalizedError() throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "metrics backend down" }
        }
        let subject = handler(snapshot: { throw Boom() })
        let result = try subject.handle(Self.emptyArguments)
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
        let result = try subject.handle(Self.emptyArguments)
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
        let subject = handler(snapshot: {
            throw MCPToolError.invalidParams("bad input")
        })
        do {
            _ = try subject.handle(Self.emptyArguments)
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message == "bad input")
        }
    }

    @Test("provider throwing MCPToolError.internalError rethrows for dispatcher")
    func providerInternalErrorRethrown() throws {
        let subject = handler(snapshot: {
            throw MCPToolError.internalError("misconfigured")
        })
        do {
            _ = try subject.handle(Self.emptyArguments)
            Issue.record("handler should have thrown")
        } catch MCPToolError.internalError(let message) {
            #expect(message == "misconfigured")
        }
    }

    // MARK: Dispatcher integration

    @Test("registering with dispatcher routes tools/call to the handler")
    func dispatcherIntegration() throws {
        let dispatcher = MCPRequestDispatcher(serverInfo: Self.serverInfo)
        let subject = handler(snapshot: { Self.makeSnapshot() })
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
