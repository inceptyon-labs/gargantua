import Testing
import Foundation
@testable import GargantuaCore

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

private func decodeOutput(_ result: MCPToolCallResult) throws -> MCPAnalyzeOutput {
    let payload = try #require(result.structuredContent, "structured content missing")
    let data = try JSONEncoder().encode(payload)
    return try JSONDecoder().decode(MCPAnalyzeOutput.self, from: data)
}

@Suite("MCP analyze tool handler happy path")
struct MCPAnalyzeToolHandlerHappyPathTests {

    @Test("maps SystemMetrics into MCPAnalyzeOutput core fields")
    func mapsCoreFields() throws {
        let metrics = makeMetrics(
            diskTotal: 500_000_000_000,
            diskUsed: 380_000_000_000,
            diskFree: 120_000_000_000
        )
        let subject = makeHandler(metrics: { metrics })
        let result = try subject.handle(emptyArguments)
        #expect(result.isError == false)
        let output = try decodeOutput(result)
        #expect(output.healthScore == metrics.healthScore)
        #expect(output.disk.total == "500 GB")
        #expect(output.disk.used == "380 GB")
        #expect(output.disk.free == "120 GB")
    }

    @Test("top_consumers is empty until scan-backed source lands")
    func topConsumersEmpty() throws {
        let subject = makeHandler(metrics: { makeMetrics() })
        let output = try decodeOutput(try subject.handle(emptyArguments))
        #expect(output.topConsumers.isEmpty)
    }

    @Test("healthy snapshot produces no recommendations")
    func healthyProducesNoRecommendations() throws {
        let subject = makeHandler(metrics: { makeMetrics() })
        let output = try decodeOutput(try subject.handle(emptyArguments))
        #expect(output.recommendations.isEmpty)
    }

    @Test("wire envelope uses snake_case keys matching PRD contract")
    func wireKeysSnakeCase() throws {
        let subject = makeHandler(metrics: { makeMetrics() })
        let payload = try #require(try subject.handle(emptyArguments).structuredContent)
        guard case .object(let root) = payload else {
            Issue.record("payload should be object")
            return
        }
        #expect(root["health_score"] != nil)
        #expect(root["disk"] != nil)
        #expect(root["top_consumers"] != nil)
        #expect(root["recommendations"] != nil)
    }

    @Test("result is .structured with non-empty text summary")
    func structuredResultShape() throws {
        let subject = makeHandler(metrics: { makeMetrics() })
        let result = try subject.handle(emptyArguments)
        #expect(result.isError == false)
        #expect(result.structuredContent != nil)
        guard case .text(let summary) = result.content.first else {
            Issue.record("content[0] should be text")
            return
        }
        #expect(summary.contains("Health"))
        #expect(summary.contains("disk"))
    }

    // MARK: - Robustness

    @Test("non-finite metrics do not crash the handler (healthScore trap guard)")
    func nonFiniteMetricsDoNotCrash() throws {
        // Production collector always returns finite values, but the
        // provider surface is public and a misbehaving injection must not
        // be able to crash the MCP server via SystemMetrics.healthScore's
        // `Int(_.rounded())` cast.
        let metrics = makeMetrics(
            cpuUsage: .nan,
            memoryPressure: .infinity,
            diskUsage: -.infinity
        )
        let subject = makeHandler(metrics: { metrics })
        let result = try subject.handle(emptyArguments)
        #expect(result.isError == false)
        let output = try decodeOutput(result)
        // Sanitized fractions all become 0, so healthScore falls out of
        // the weighted composite at a deterministic value.
        #expect(output.healthScore >= 0 && output.healthScore <= 100)
    }

    @Test("extra unknown fields on analyze arguments are ignored")
    func extraFieldsIgnored() throws {
        let subject = makeHandler(metrics: { makeMetrics() })
        let result = try subject.handle(MCPToolArguments([
            "foo": .string("bar"),
            "nested": .object(["a": .int(1)]),
        ]))
        #expect(result.isError == false)
    }
}
