import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "MoStatusAdapter")

/// Adapter for the `mo status` command (system health metrics).
///
/// Executes `mo status --json` via `MoleRunner` and maps the output to
/// `SystemMetrics` for use in the health score gauge and system info bar.
///
/// Unlike `SystemMetricCollector` (which uses native Mach APIs with `mo status`
/// as fallback), this adapter always goes through `mo status` — useful when
/// native APIs are unavailable or when you want the Mole CLI's view of the system.
///
/// Usage:
/// ```swift
/// let adapter = MoStatusAdapter(runner: MoleRunner())
/// let metrics = try await adapter.status()
/// print("Health: \(metrics.healthScore)")
/// ```
public struct MoStatusAdapter: Sendable {
    private let runner: MoleRunner

    public init(runner: MoleRunner) {
        self.runner = runner
    }

    /// Collect system metrics via `mo status --json`.
    ///
    /// - Returns: A `SystemMetrics` snapshot.
    public func status() async throws -> SystemMetrics {
        logger.info("Starting mo status")

        let runResult: MoleRunResult
        do {
            runResult = try await runner.run(command: "status", arguments: ["--json"])
        } catch {
            logger.error("mo status failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        let metrics: SystemMetrics
        do {
            metrics = try parseStatusOutput(runResult.stdout)
        } catch {
            logger.error("Failed to parse mo status output: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        let cpuStr = String(format: "%.0f", metrics.cpuUsage * 100)
        let memStr = String(format: "%.0f", metrics.memoryPressure * 100)
        let diskStr = String(format: "%.0f", metrics.diskUsage * 100)
        logger.info("mo status: health=\(metrics.healthScore) cpu=\(cpuStr)% mem=\(memStr)% disk=\(diskStr)%")
        return metrics
    }

    // MARK: - Parsing

    /// Parse `mo status --json` output into SystemMetrics.
    ///
    /// Handles partial output gracefully — missing fields default to 0.
    /// CPU is expected as a percentage (0–100) and converted to a 0.0–1.0 fraction.
    private func parseStatusOutput(_ data: Data) throws -> SystemMetrics {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MoleParseError.invalidJSON(detail: error.localizedDescription)
        }

        guard let json = parsed as? [String: Any] else {
            throw MoleParseError.invalidJSON(detail: "mo status output is not a JSON object")
        }

        // CPU: percentage (0–100) → fraction (0.0–1.0)
        let cpuPercent = (json["cpu_usage"] as? NSNumber).map { $0.doubleValue } ?? 0
        let cpuUsage = cpuPercent / 100.0

        // Memory
        let memTotal = (json["memory_total"] as? NSNumber).map { UInt64($0.uint64Value) } ?? 0
        let memUsed = (json["memory_used"] as? NSNumber).map { UInt64($0.uint64Value) } ?? 0
        let memPressure = memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0

        // Disk
        let diskTotal = (json["disk_total"] as? NSNumber).map { UInt64($0.uint64Value) } ?? 0
        let diskFree = (json["disk_free"] as? NSNumber).map { UInt64($0.uint64Value) } ?? 0
        let diskUsed = diskTotal > diskFree ? diskTotal - diskFree : 0
        let diskUsage = diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) : 0

        // Thermal
        let thermalString = json["thermal"] as? String ?? "nominal"
        let thermal = ThermalLevel(rawValue: thermalString) ?? .nominal

        return SystemMetrics(
            cpuUsage: cpuUsage,
            memoryPressure: memPressure,
            memoryTotal: memTotal,
            memoryUsed: memUsed,
            diskUsage: diskUsage,
            diskTotal: diskTotal,
            diskUsed: diskUsed,
            diskFree: diskFree,
            thermalLevel: thermal
        )
    }
}
