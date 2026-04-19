import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP analyze tool handler")
struct MCPAnalyzeToolHandlerTests {

    // MARK: Fixtures

    private static let serverInfo = MCPServerInfo(name: "gargantua", version: "0.0.1")

    /// Baseline "healthy" snapshot; tests tweak individual fields.
    private static func makeMetrics(
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

    private func handler(
        metrics: @escaping @Sendable () throws -> SystemMetrics
    ) -> MCPAnalyzeToolHandler {
        MCPAnalyzeToolHandler(metricsProvider: metrics)
    }

    private static let emptyArguments = MCPToolArguments([:])

    private static func decodeOutput(_ result: MCPToolCallResult) throws -> MCPAnalyzeOutput {
        let payload = try #require(result.structuredContent, "structured content missing")
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(MCPAnalyzeOutput.self, from: data)
    }

    // MARK: Happy path

    @Test("maps SystemMetrics into MCPAnalyzeOutput core fields")
    func mapsCoreFields() throws {
        let metrics = Self.makeMetrics(
            diskTotal: 500_000_000_000,
            diskUsed: 380_000_000_000,
            diskFree: 120_000_000_000
        )
        let subject = handler(metrics: { metrics })
        let result = try subject.handle(Self.emptyArguments)
        #expect(result.isError == false)
        let output = try Self.decodeOutput(result)
        #expect(output.healthScore == metrics.healthScore)
        #expect(output.disk.total == "500 GB")
        #expect(output.disk.used == "380 GB")
        #expect(output.disk.free == "120 GB")
    }

    @Test("top_consumers is empty until scan-backed source lands")
    func topConsumersEmpty() throws {
        let subject = handler(metrics: { Self.makeMetrics() })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        #expect(output.topConsumers.isEmpty)
    }

    @Test("healthy snapshot produces no recommendations")
    func healthyProducesNoRecommendations() throws {
        let subject = handler(metrics: { Self.makeMetrics() })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        #expect(output.recommendations.isEmpty)
    }

    @Test("wire envelope uses snake_case keys matching PRD contract")
    func wireKeysSnakeCase() throws {
        let subject = handler(metrics: { Self.makeMetrics() })
        let payload = try #require(try subject.handle(Self.emptyArguments).structuredContent)
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
        let subject = handler(metrics: { Self.makeMetrics() })
        let result = try subject.handle(Self.emptyArguments)
        #expect(result.isError == false)
        #expect(result.structuredContent != nil)
        guard case .text(let summary) = result.content.first else {
            Issue.record("content[0] should be text")
            return
        }
        #expect(summary.contains("Health"))
        #expect(summary.contains("disk"))
    }

    // MARK: Recommendations

    @Test("high disk usage produces a disk recommendation")
    func diskRecommendation() throws {
        let subject = handler(metrics: {
            Self.makeMetrics(diskUsage: 0.92)
        })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        #expect(output.recommendations.contains { $0.lowercased().contains("disk") })
        #expect(output.recommendations.contains { $0.contains("92") })
    }

    @Test("high memory pressure produces a memory recommendation")
    func memoryRecommendation() throws {
        let subject = handler(metrics: {
            Self.makeMetrics(memoryPressure: 0.90)
        })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        #expect(output.recommendations.contains { $0.lowercased().contains("memory") })
    }

    @Test("serious thermal state produces a thermal recommendation")
    func thermalRecommendation() throws {
        let subject = handler(metrics: {
            Self.makeMetrics(thermal: .serious)
        })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        #expect(output.recommendations.contains { $0.lowercased().contains("thermal") })
    }

    @Test("critical thermal also triggers the thermal recommendation")
    func thermalCritical() throws {
        let subject = handler(metrics: {
            Self.makeMetrics(thermal: .critical)
        })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        #expect(output.recommendations.contains { $0.lowercased().contains("thermal") })
    }

    @Test("fair thermal does NOT trigger a thermal recommendation")
    func thermalFairIsHealthy() throws {
        let subject = handler(metrics: {
            Self.makeMetrics(thermal: .fair)
        })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        #expect(!output.recommendations.contains { $0.lowercased().contains("thermal") })
    }

    @Test("moderate disk usage (below 85%) does NOT trigger a disk recommendation")
    func diskBelowThreshold() throws {
        let subject = handler(metrics: {
            Self.makeMetrics(diskUsage: 0.80)
        })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        #expect(output.recommendations.isEmpty)
    }

    @Test("disk usage at exactly 0.85 triggers the recommendation (>= threshold)")
    func diskAtExactThreshold() throws {
        let subject = handler(metrics: {
            Self.makeMetrics(diskUsage: 0.85)
        })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        #expect(output.recommendations.contains { $0.lowercased().contains("disk") })
    }

    @Test("disk usage just below 0.85 does NOT trigger (< threshold)")
    func diskJustBelowThreshold() throws {
        let subject = handler(metrics: {
            Self.makeMetrics(diskUsage: 0.849)
        })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        #expect(output.recommendations.isEmpty)
    }

    // MARK: Robustness

    @Test("non-finite metrics do not crash the handler (healthScore trap guard)")
    func nonFiniteMetricsDoNotCrash() throws {
        // Production collector always returns finite values, but the
        // provider surface is public and a misbehaving injection must not
        // be able to crash the MCP server via SystemMetrics.healthScore's
        // `Int(_.rounded())` cast.
        let metrics = Self.makeMetrics(
            cpuUsage: .nan,
            memoryPressure: .infinity,
            diskUsage: -.infinity
        )
        let subject = handler(metrics: { metrics })
        let result = try subject.handle(Self.emptyArguments)
        #expect(result.isError == false)
        let output = try Self.decodeOutput(result)
        // Sanitized fractions all become 0, so healthScore falls out of
        // the weighted composite at a deterministic value.
        #expect(output.healthScore >= 0 && output.healthScore <= 100)
    }

    @Test("extra unknown fields on analyze arguments are ignored")
    func extraFieldsIgnored() throws {
        let subject = handler(metrics: { Self.makeMetrics() })
        let result = try subject.handle(MCPToolArguments([
            "foo": .string("bar"),
            "nested": .object(["a": .int(1)]),
        ]))
        #expect(result.isError == false)
    }

    // MARK: Provider errors

    @Test("provider throwing a LocalizedError surfaces description in .failure")
    func providerLocalizedError() throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "collector unavailable" }
        }
        let subject = handler(metrics: { throw Boom() })
        let result = try subject.handle(Self.emptyArguments)
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
        let result = try subject.handle(Self.emptyArguments)
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
        let subject = handler(metrics: { throw MCPToolError.invalidParams("bad input") })
        do {
            _ = try subject.handle(Self.emptyArguments)
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message == "bad input")
        }
    }

    @Test("provider throwing MCPToolError.internalError rethrows for dispatcher")
    func providerInternalErrorRethrown() throws {
        let subject = handler(metrics: { throw MCPToolError.internalError("misconfigured") })
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
        let subject = handler(metrics: { Self.makeMetrics() })
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
        let dispatcher = MCPRequestDispatcher(serverInfo: Self.serverInfo)
        let subject = handler(metrics: { throw Boom() })
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
