import Testing
import Foundation
@testable import GargantuaCore

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

private func makeHandler(
    snapshot: @escaping @Sendable () throws -> SystemStatusSnapshot
) -> MCPStatusToolHandler {
    MCPStatusToolHandler(snapshotProvider: snapshot)
}

private let emptyArguments = MCPToolArguments([:])

private func decodeOutput(_ result: MCPToolCallResult) throws -> MCPStatusOutput {
    let payload = try #require(result.structuredContent, "structured content missing")
    let data = try JSONEncoder().encode(payload)
    return try JSONDecoder().decode(MCPStatusOutput.self, from: data)
}

@Suite("MCP status tool handler happy path")
struct MCPStatusToolHandlerHappyPathTests {

    // MARK: - Happy path

    @Test("maps snapshot into MCPStatusOutput fields with PRD §7.3 example values")
    func mapsExampleFields() throws {
        let subject = makeHandler(snapshot: { makeSnapshot() })
        let result = try subject.handle(emptyArguments)
        #expect(result.isError == false)
        let output = try decodeOutput(result)
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
        let snapshot = makeSnapshot()
        let subject = makeHandler(snapshot: { snapshot })
        let output = try decodeOutput(try subject.handle(emptyArguments))
        #expect(output.healthScore == snapshot.metrics.healthScore)
    }

    @Test("wire envelope uses snake_case keys matching PRD contract")
    func wireKeysSnakeCase() throws {
        let subject = makeHandler(snapshot: { makeSnapshot() })
        let payload = try #require(try subject.handle(emptyArguments).structuredContent)
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

    // MARK: - Percent rounding

    @Test("percent fields are rounded to one decimal place")
    func percentRoundingOneDecimal() throws {
        let subject = makeHandler(snapshot: {
            makeSnapshot(
                cpuUsage: 0.123_456,
                memoryPressure: 0.987_654,
                diskUsage: 0.500_049
            )
        })
        let output = try decodeOutput(try subject.handle(emptyArguments))
        #expect(output.cpu.usage == 12.3)
        #expect(output.memory.percent == 98.8)
        #expect(output.disk.percent == 50.0)
    }

    @Test("percent fields clamp to 0..100 for out-of-range fractions")
    func percentClamping() throws {
        // SystemMetrics init already clamps, but confirm the handler doesn't
        // overshoot even if a future data source feeds it raw values.
        let subject = makeHandler(snapshot: {
            makeSnapshot(cpuUsage: 2.0, memoryPressure: -0.5, diskUsage: 1.0)
        })
        let output = try decodeOutput(try subject.handle(emptyArguments))
        #expect(output.cpu.usage == 100.0)
        #expect(output.memory.percent == 0.0)
        #expect(output.disk.percent == 100.0)
    }

    // MARK: - Robustness

    @Test("non-finite metrics do not crash the handler")
    func nonFiniteMetricsDoNotCrash() throws {
        // Production collector always returns finite values, but the
        // provider surface is public and a misbehaving injection must not
        // be able to crash the MCP server via SystemMetrics.healthScore's
        // `Int(_.rounded())` cast or via `formatUptime`.
        let subject = makeHandler(snapshot: {
            makeSnapshot(
                cpuUsage: .nan,
                memoryPressure: .infinity,
                diskUsage: -.infinity,
                uptime: .nan
            )
        })
        let result = try subject.handle(emptyArguments)
        #expect(result.isError == false)
        let output = try decodeOutput(result)
        #expect(output.uptime == "0m")
        #expect(output.healthScore >= 0 && output.healthScore <= 100)
    }

    @Test("extra unknown fields on status arguments are ignored")
    func extraFieldsIgnored() throws {
        let subject = makeHandler(snapshot: { makeSnapshot() })
        let result = try subject.handle(MCPToolArguments([
            "foo": .string("bar"),
            "nested": .object(["a": .int(1)]),
        ]))
        #expect(result.isError == false)
    }
}
