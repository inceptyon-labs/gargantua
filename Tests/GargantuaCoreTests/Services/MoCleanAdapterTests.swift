import Foundation
import Testing
@testable import GargantuaCore

// MARK: - Test Fixtures

private let cleanOutputJSON = """
{
    "items": [
        {
            "id": "chrome_cache_001",
            "name": "Chrome Browser Cache",
            "path": "/Users/dev/Library/Caches/Google/Chrome",
            "size": 1500000000,
            "category": "browser_cache",
            "confidence": 98,
            "explanation": "Chrome browser cache",
            "source": "Google Chrome",
            "source_bundle_id": "com.google.Chrome",
            "tags": ["browser", "cache"],
            "regenerates": true
        },
        {
            "id": "sys_logs_001",
            "name": "System Logs",
            "path": "/var/log/system.log",
            "size": 50000000,
            "category": "system_logs",
            "confidence": 95,
            "explanation": "Rotated system logs",
            "source": "macOS"
        },
        {
            "id": "node_modules_001",
            "name": "node_modules",
            "path": "/Users/dev/project/node_modules",
            "size": 800000000,
            "category": "dev_artifacts",
            "confidence": 90,
            "explanation": "Node.js dependencies — regenerate with npm install",
            "source": "npm",
            "regenerates": true,
            "regenerate_command": "npm install"
        }
    ],
    "scan_duration": 2.1,
    "total_size": 2350000000
}
"""

private let emptyOutputJSON = """
{ "items": [] }
"""

// MARK: - Mock Binary Helper

/// Creates a temporary executable script that outputs the given string to stdout.
private func createMockBinary(output: String, exitCode: Int = 0) throws -> String {
    // Escape single quotes in output for bash
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

@Suite("MoCleanAdapter")
struct MoCleanAdapterTests {

    @Test("scan returns ScanResult array with Trust Layer metadata")
    func scanReturnsScanResults() async throws {
        let binaryPath = try createMockBinary(output: cleanOutputJSON)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoCleanAdapter(runner: runner)
        let results = try await adapter.scan()

        #expect(results.count == 3)

        // Chrome cache → safe
        #expect(results[0].id == "chrome_cache_001")
        #expect(results[0].safety == .safe)
        #expect(results[0].category == "browser_cache")
        #expect(results[0].confidence == 98)

        // System logs → safe
        #expect(results[1].id == "sys_logs_001")
        #expect(results[1].safety == .safe)

        // Dev artifacts → review
        #expect(results[2].id == "node_modules_001")
        #expect(results[2].safety == .review)
        #expect(results[2].regenerates == true)
        #expect(results[2].regenerateCommand == "npm install")
    }

    @MainActor @Test("scan updates ScanProgress lifecycle")
    func scanUpdatesProgress() async throws {
        let binaryPath = try createMockBinary(output: cleanOutputJSON)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoCleanAdapter(runner: runner)
        let progress = ScanProgress()

        #expect(!progress.isScanning)
        #expect(progress.itemsFound == 0)

        let results = try await adapter.scan(progress: progress)

        #expect(!progress.isScanning)
        #expect(progress.itemsFound == results.count)
        #expect(progress.fractionCompleted == 1.0)
        #expect(progress.errors.isEmpty)
    }

    @Test("scan with empty results returns empty array")
    func scanEmptyResults() async throws {
        let binaryPath = try createMockBinary(output: emptyOutputJSON)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoCleanAdapter(runner: runner)
        let results = try await adapter.scan()

        #expect(results.isEmpty)
    }

    @MainActor @Test("scan propagates MoleError on process failure")
    func scanPropagatesMoleError() async throws {
        let binaryPath = try createMockBinary(output: "error output", exitCode: 1)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoCleanAdapter(runner: runner)
        let progress = ScanProgress()

        do {
            _ = try await adapter.scan(progress: progress)
            Issue.record("Expected MoleError")
        } catch is MoleError {
            // Expected
        }

        #expect(!progress.isScanning)
        #expect(!progress.errors.isEmpty)
    }

    @MainActor @Test("scan propagates parse error on invalid JSON")
    func scanPropagatesParseError() async throws {
        let binaryPath = try createMockBinary(output: "not json")
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoCleanAdapter(runner: runner)
        let progress = ScanProgress()

        do {
            _ = try await adapter.scan(progress: progress)
            Issue.record("Expected MoleParseError")
        } catch is MoleParseError {
            // Expected
        }

        #expect(!progress.isScanning)
        #expect(!progress.errors.isEmpty)
    }

    @Test("scan without progress observer does not crash")
    func scanWithoutProgress() async throws {
        let binaryPath = try createMockBinary(output: cleanOutputJSON)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoCleanAdapter(runner: runner)
        let results = try await adapter.scan(progress: nil)

        #expect(results.count == 3)
    }

    @Test("dry-run is the default mode")
    func dryRunIsDefault() async throws {
        // The mock binary ignores arguments, but we verify the adapter doesn't crash
        // in default (dry-run) mode. Argument verification would require inspecting
        // the process args, which MoleRunner doesn't expose.
        let binaryPath = try createMockBinary(output: emptyOutputJSON)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoCleanAdapter(runner: runner)
        let results = try await adapter.scan() // dryRun defaults to true
        #expect(results.isEmpty)
    }
}
