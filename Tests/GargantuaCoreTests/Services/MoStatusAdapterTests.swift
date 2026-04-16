import Foundation
import Testing
@testable import GargantuaCore

// MARK: - Test Fixtures

private let statusOutputJSON = """
{
    "cpu_usage": 42.5,
    "memory_total": 34359738368,
    "memory_used": 17179869184,
    "disk_total": 1000000000000,
    "disk_free": 400000000000,
    "thermal": "fair"
}
"""

private let minimalStatusJSON = """
{
    "cpu_usage": 10.0
}
"""

private let criticalThermalJSON = """
{
    "cpu_usage": 95.0,
    "memory_total": 16000000000,
    "memory_used": 15000000000,
    "disk_total": 500000000000,
    "disk_free": 25000000000,
    "thermal": "critical"
}
"""

/// Creates a temporary executable script that outputs the given string to stdout.
private func createMockBinary(output: String, exitCode: Int = 0) throws -> String {
    let escaped = output.replacingOccurrences(of: "'", with: "'\\''")
    let script = """
    #!/bin/bash
    echo '\(escaped)'
    exit \(exitCode)
    """
    let path = NSTemporaryDirectory() + "mock_mo_\(UUID().uuidString)"
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
}

// MARK: - Tests

@Suite("MoStatusAdapter")
struct MoStatusAdapterTests {

    @Test("status returns SystemMetrics with correct values")
    func statusReturnsMetrics() async throws {
        let binaryPath = try createMockBinary(output: statusOutputJSON)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoStatusAdapter(runner: runner)
        let metrics = try await adapter.status()

        // CPU: 42.5% → 0.425
        #expect(abs(metrics.cpuUsage - 0.425) < 0.001)

        // Memory: 17GB / 34GB = ~0.5
        #expect(metrics.memoryTotal == 34_359_738_368)
        #expect(metrics.memoryUsed == 17_179_869_184)
        #expect(abs(metrics.memoryPressure - 0.5) < 0.001)

        // Disk: 600GB used / 1TB total = 0.6
        #expect(metrics.diskTotal == 1_000_000_000_000)
        #expect(metrics.diskFree == 400_000_000_000)
        #expect(metrics.diskUsed == 600_000_000_000)
        #expect(abs(metrics.diskUsage - 0.6) < 0.001)

        // Thermal
        #expect(metrics.thermalLevel == .fair)
    }

    @Test("status handles partial output with safe defaults")
    func statusPartialOutput() async throws {
        let binaryPath = try createMockBinary(output: minimalStatusJSON)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoStatusAdapter(runner: runner)
        let metrics = try await adapter.status()

        #expect(abs(metrics.cpuUsage - 0.1) < 0.001)
        #expect(metrics.memoryTotal == 0)
        #expect(metrics.memoryUsed == 0)
        #expect(metrics.memoryPressure == 0)
        #expect(metrics.diskTotal == 0)
        #expect(metrics.diskFree == 0)
        #expect(metrics.diskUsed == 0)
        #expect(metrics.diskUsage == 0)
        #expect(metrics.thermalLevel == .nominal) // default
    }

    @Test("status computes health score correctly for critical state")
    func statusCriticalHealthScore() async throws {
        let binaryPath = try createMockBinary(output: criticalThermalJSON)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoStatusAdapter(runner: runner)
        let metrics = try await adapter.status()

        #expect(metrics.thermalLevel == .critical)
        // High CPU (95%), high memory (93.75%), high disk (95%), critical thermal
        // Health score should be low
        #expect(metrics.healthScore < 20)
    }

    @Test("status propagates MoleError on process failure")
    func statusPropagatesMoleError() async throws {
        let binaryPath = try createMockBinary(output: "error", exitCode: 1)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoStatusAdapter(runner: runner)

        do {
            _ = try await adapter.status()
            Issue.record("Expected MoleError")
        } catch is MoleError {
            // Expected
        }
    }

    @Test("status propagates parse error on invalid JSON")
    func statusPropagatesParseError() async throws {
        let binaryPath = try createMockBinary(output: "not json")
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoStatusAdapter(runner: runner)

        do {
            _ = try await adapter.status()
            Issue.record("Expected MoleParseError")
        } catch is MoleParseError {
            // Expected
        }
    }

    @Test("status unknown thermal level defaults to nominal")
    func statusUnknownThermal() async throws {
        let json = """
        {
            "cpu_usage": 20.0,
            "thermal": "unknown_state"
        }
        """
        let binaryPath = try createMockBinary(output: json)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoStatusAdapter(runner: runner)
        let metrics = try await adapter.status()

        #expect(metrics.thermalLevel == .nominal)
    }
}
