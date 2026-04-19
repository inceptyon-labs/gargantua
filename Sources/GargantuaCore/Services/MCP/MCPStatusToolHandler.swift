import Foundation

// Handler for the MCP `status` tool. Shapes a `SystemStatusSnapshot` into the
// `MCPStatusOutput` payload the PRD §7.3 contract promises.
//
// The handler is synchronous to match `MCPToolHandler`. The real
// `SystemMetricCollector.collect()` is async; the call site in
// `Sources/GargantuaMCP/main.swift` bridges to sync via the shared
// `runBlocking` helper, same pattern as the scan and analyze handlers.
//
// Percent fields land on the wire as 0–100 floats with one decimal place
// (e.g. `45.2`), per the PRD §7.3 example. Bytes are formatted via
// `AlertItem.formatBytes` for consistency with the rest of the app.
// Uptime and core count are injected alongside the `SystemMetrics` snapshot
// so tests can exercise the formatter without depending on the host machine.

/// Combined system-status snapshot. Bundles the `SystemMetrics` collector
/// output with the two `ProcessInfo`-derived scalars the status payload
/// needs so the handler has a single dependency to accept and tests have a
/// single struct to build.
public struct SystemStatusSnapshot: Sendable, Equatable {
    public let metrics: SystemMetrics
    /// Seconds since system boot (as from `ProcessInfo.processInfo.systemUptime`).
    public let uptime: TimeInterval
    /// Number of active CPU cores (as from `ProcessInfo.processInfo.activeProcessorCount`).
    public let coreCount: Int

    public init(metrics: SystemMetrics, uptime: TimeInterval, coreCount: Int) {
        self.metrics = metrics
        self.uptime = uptime
        self.coreCount = coreCount
    }
}

/// Tool handler for `status`.
public struct MCPStatusToolHandler: Sendable {

    /// Synchronous snapshot provider. Throwing `MCPToolError.invalidParams`
    /// or `.internalError` propagates with the appropriate JSON-RPC code;
    /// any other thrown error is surfaced to the client as a tool-domain
    /// `.failure(...)` result.
    public typealias SnapshotProvider = @Sendable () throws -> SystemStatusSnapshot

    private let snapshotProvider: SnapshotProvider
    private let log: MCPDispatcherLog?

    public init(
        snapshotProvider: @escaping SnapshotProvider,
        log: MCPDispatcherLog? = nil
    ) {
        self.snapshotProvider = snapshotProvider
        self.log = log
    }

    /// Bridges this handler to the `MCPToolHandler` shape the dispatcher
    /// expects:
    /// `dispatcher.register(tool: .status, handler: handler.toolHandler)`.
    public var toolHandler: MCPToolHandler {
        let this = self
        return { arguments in try this.handle(arguments) }
    }

    /// Execute the handler against a decoded arguments payload. Exposed for
    /// unit tests that want to bypass the dispatcher.
    public func handle(_ arguments: MCPToolArguments) throws -> MCPToolCallResult {
        // `status` takes no parameters; decode-round-trip is a cheap schema
        // check that rejects unexpected shapes up front.
        _ = try arguments.decode(MCPStatusInput.self)

        let snapshot: SystemStatusSnapshot
        do {
            snapshot = try snapshotProvider()
        } catch let error as MCPToolError {
            throw error
        } catch {
            log?("status handler error: \(error)")
            return .failure("Status failed: \(MCPEncoding.clientFacingMessage(for: error))")
        }

        let output = Self.makeOutput(from: snapshot)
        let payload = try MCPEncoding.encodeAsJSONAny(output)
        return .structured(payload, summary: Self.summary(for: output))
    }

    // MARK: - Helpers

    static func makeOutput(from snapshot: SystemStatusSnapshot) -> MCPStatusOutput {
        let metrics = snapshot.metrics
        return MCPStatusOutput(
            healthScore: metrics.healthScore,
            cpu: MCPStatusCPU(
                usage: Self.toPercent(metrics.cpuUsage),
                cores: snapshot.coreCount
            ),
            memory: MCPStatusMemory(
                used: AlertItem.formatBytes(Int64(clamping: metrics.memoryUsed)),
                total: AlertItem.formatBytes(Int64(clamping: metrics.memoryTotal)),
                percent: Self.toPercent(metrics.memoryPressure)
            ),
            disk: MCPStatusDisk(
                used: AlertItem.formatBytes(Int64(clamping: metrics.diskUsed)),
                total: AlertItem.formatBytes(Int64(clamping: metrics.diskTotal)),
                percent: Self.toPercent(metrics.diskUsage)
            ),
            uptime: Self.formatUptime(snapshot.uptime)
        )
    }

    /// Converts a 0.0–1.0 fraction to a 0–100 percent value rounded to one
    /// decimal place. `0.452` → `45.2`.
    static func toPercent(_ fraction: Double) -> Double {
        let clamped = min(max(fraction, 0), 1)
        return (clamped * 1000.0).rounded() / 10.0
    }

    /// Human-readable uptime formatting matching the PRD §7.3 example
    /// (`"6d 12h"`). Falls back to `"Hh Mm"` for sub-day uptimes and
    /// `"Mm"` for sub-hour uptimes so very short uptimes still round-trip
    /// something useful (tests, CI).
    static func formatUptime(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private static func summary(for output: MCPStatusOutput) -> String {
        "Health \(output.healthScore)/100; "
            + "CPU \(output.cpu.usage)% "
            + "(\(output.cpu.cores) cores); "
            + "memory \(output.memory.percent)%; "
            + "disk \(output.disk.percent)%; "
            + "uptime \(output.uptime)."
    }
}
