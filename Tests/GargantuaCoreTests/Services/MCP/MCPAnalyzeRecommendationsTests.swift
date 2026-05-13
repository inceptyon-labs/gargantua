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

@Suite("MCP analyze tool handler recommendations")
struct MCPAnalyzeRecommendationsTests {

    @Test("high disk usage produces a disk recommendation")
    func diskRecommendation() throws {
        let subject = makeHandler(metrics: {
            makeMetrics(diskUsage: 0.92)
        })
        let output = try decodeOutput(try subject.handle(emptyArguments))
        #expect(output.recommendations.contains { $0.lowercased().contains("disk") })
        #expect(output.recommendations.contains { $0.contains("92") })
    }

    @Test("high memory pressure produces a memory recommendation")
    func memoryRecommendation() throws {
        let subject = makeHandler(metrics: {
            makeMetrics(memoryPressure: 0.90)
        })
        let output = try decodeOutput(try subject.handle(emptyArguments))
        #expect(output.recommendations.contains { $0.lowercased().contains("memory") })
    }

    @Test("serious thermal state produces a thermal recommendation")
    func thermalRecommendation() throws {
        let subject = makeHandler(metrics: {
            makeMetrics(thermal: .serious)
        })
        let output = try decodeOutput(try subject.handle(emptyArguments))
        #expect(output.recommendations.contains { $0.lowercased().contains("thermal") })
    }

    @Test("critical thermal also triggers the thermal recommendation")
    func thermalCritical() throws {
        let subject = makeHandler(metrics: {
            makeMetrics(thermal: .critical)
        })
        let output = try decodeOutput(try subject.handle(emptyArguments))
        #expect(output.recommendations.contains { $0.lowercased().contains("thermal") })
    }

    @Test("fair thermal does NOT trigger a thermal recommendation")
    func thermalFairIsHealthy() throws {
        let subject = makeHandler(metrics: {
            makeMetrics(thermal: .fair)
        })
        let output = try decodeOutput(try subject.handle(emptyArguments))
        #expect(!output.recommendations.contains { $0.lowercased().contains("thermal") })
    }

    @Test("moderate disk usage (below 85%) does NOT trigger a disk recommendation")
    func diskBelowThreshold() throws {
        let subject = makeHandler(metrics: {
            makeMetrics(diskUsage: 0.80)
        })
        let output = try decodeOutput(try subject.handle(emptyArguments))
        #expect(output.recommendations.isEmpty)
    }

    @Test("disk usage at exactly 0.85 triggers the recommendation (>= threshold)")
    func diskAtExactThreshold() throws {
        let subject = makeHandler(metrics: {
            makeMetrics(diskUsage: 0.85)
        })
        let output = try decodeOutput(try subject.handle(emptyArguments))
        #expect(output.recommendations.contains { $0.lowercased().contains("disk") })
    }

    @Test("disk usage just below 0.85 does NOT trigger (< threshold)")
    func diskJustBelowThreshold() throws {
        let subject = makeHandler(metrics: {
            makeMetrics(diskUsage: 0.849)
        })
        let output = try decodeOutput(try subject.handle(emptyArguments))
        #expect(output.recommendations.isEmpty)
    }
}
