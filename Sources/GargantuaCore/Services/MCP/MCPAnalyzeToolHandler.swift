import Foundation

// Handler for the MCP `analyze` tool. Shapes a `SystemMetrics` snapshot into
// the `MCPAnalyzeOutput` payload the PRD §7.3 contract promises.
//
// The handler is synchronous to match `MCPToolHandler`. The real
// `SystemMetricCollector.collect()` is async; the call site in
// `Sources/GargantuaMCP/main.swift` bridges to sync via the shared
// `runBlocking` helper, same pattern as the scan handler.
//
// Scope: this Task (gargantua-2xod) wires only `SystemMetrics` + disk usage.
// `top_consumers` is returned as an empty array for now — a scan-backed
// source lands in a follow-up Task. `recommendations` are derived from
// threshold rules on the current metrics snapshot.

/// Tool handler for `analyze`.
public struct MCPAnalyzeToolHandler: Sendable {

    /// Synchronous metrics provider. Throwing `MCPToolError.invalidParams`
    /// or `.internalError` propagates with the appropriate JSON-RPC code;
    /// any other thrown error is surfaced to the client as a tool-domain
    /// `.failure(...)` result.
    public typealias MetricsProvider = @Sendable () throws -> SystemMetrics

    private let metricsProvider: MetricsProvider
    private let log: MCPDispatcherLog?

    public init(
        metricsProvider: @escaping MetricsProvider,
        log: MCPDispatcherLog? = nil
    ) {
        self.metricsProvider = metricsProvider
        self.log = log
    }

    /// Bridges this handler to the `MCPToolHandler` shape the dispatcher
    /// expects:
    /// `dispatcher.register(tool: .analyze, handler: handler.toolHandler)`.
    public var toolHandler: MCPToolHandler {
        let this = self
        return { arguments in try this.handle(arguments) }
    }

    /// Execute the handler against a decoded arguments payload. Exposed for
    /// unit tests that want to bypass the dispatcher.
    public func handle(_ arguments: MCPToolArguments) throws -> MCPToolCallResult {
        // `analyze` takes no parameters; decode-round-trip is a cheap
        // schema check that rejects unexpected shapes (e.g. a non-object
        // payload) up front.
        _ = try arguments.decode(MCPAnalyzeInput.self)

        let metrics: SystemMetrics
        do {
            metrics = try metricsProvider()
        } catch let error as MCPToolError {
            throw error
        } catch {
            log?("analyze handler error: \(error)")
            return .failure("Analyze failed: \(MCPEncoding.clientFacingMessage(for: error))")
        }

        let output = Self.makeOutput(from: metrics)
        let payload = try MCPEncoding.encodeAsJSONAny(output)
        return .structured(payload, summary: Self.summary(for: output))
    }

    // MARK: - Helpers

    static func makeOutput(from metrics: SystemMetrics) -> MCPAnalyzeOutput {
        MCPAnalyzeOutput(
            healthScore: metrics.healthScore,
            disk: MCPDiskUsage(
                total: AlertItem.formatBytes(Int64(clamping: metrics.diskTotal)),
                used: AlertItem.formatBytes(Int64(clamping: metrics.diskUsed)),
                free: AlertItem.formatBytes(Int64(clamping: metrics.diskFree))
            ),
            // Top-consumer enumeration needs a scan backend; wired in a
            // follow-up Task. Empty array is a valid payload per the schema.
            topConsumers: [],
            recommendations: Self.recommendations(from: metrics)
        )
    }

    /// Threshold-based recommendations derived from the metrics snapshot.
    /// Intentionally conservative — only flags conditions a user should
    /// actually act on. A healthy snapshot produces an empty array.
    static func recommendations(from metrics: SystemMetrics) -> [String] {
        var out: [String] = []
        if metrics.diskUsage >= 0.85 {
            out.append(
                "Disk usage is at \(Self.percentString(metrics.diskUsage))% — "
                + "run a scan to find reclaimable space."
            )
        }
        if metrics.memoryPressure >= 0.85 {
            out.append(
                "Memory pressure is high (\(Self.percentString(metrics.memoryPressure))%). "
                + "Quitting unused apps may help."
            )
        }
        if metrics.thermalLevel >= .serious {
            out.append(
                "System is thermally throttled (\(metrics.thermalLevel.rawValue)). "
                + "Heavy cleanup tasks may take longer than usual."
            )
        }
        return out
    }

    /// Rounded integer-percent for display in a recommendation string.
    private static func percentString(_ fraction: Double) -> String {
        String(Int((fraction * 100.0).rounded()))
    }

    private static func summary(for output: MCPAnalyzeOutput) -> String {
        let disk = "\(output.disk.used) used / \(output.disk.total)"
        let recs = output.recommendations.isEmpty
            ? "no recommendations"
            : "\(output.recommendations.count) recommendation(s)"
        return "Health \(output.healthScore)/100; disk \(disk); \(recs)."
    }
}
