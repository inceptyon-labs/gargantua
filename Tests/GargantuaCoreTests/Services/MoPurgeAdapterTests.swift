import Foundation
import Testing
@testable import GargantuaCore

// MARK: - Test Fixtures

/// Output containing a mix of dev artifact and non-dev-artifact categories.
private let purgeOutputMixedJSON = """
{
    "items": [
        {
            "id": "node_modules_001",
            "name": "node_modules",
            "path": "/Users/dev/project/node_modules",
            "size": 800000000,
            "category": "dev_artifacts",
            "confidence": 90,
            "explanation": "Node.js dependencies",
            "source": "npm",
            "regenerates": true,
            "regenerate_command": "npm install"
        },
        {
            "id": "docker_001",
            "name": "Docker Images",
            "path": "/Users/dev/.docker/images",
            "size": 5000000000,
            "category": "docker",
            "confidence": 85,
            "explanation": "Docker images and layers",
            "source": "Docker Desktop"
        },
        {
            "id": "homebrew_001",
            "name": "Homebrew Cache",
            "path": "/Users/dev/Library/Caches/Homebrew",
            "size": 2000000000,
            "category": "homebrew",
            "confidence": 92,
            "explanation": "Homebrew package cache",
            "source": "Homebrew"
        },
        {
            "id": "browser_cache_unexpected",
            "name": "Chrome Cache",
            "path": "/Users/dev/Library/Caches/Google/Chrome",
            "size": 1500000000,
            "category": "browser_cache",
            "confidence": 98,
            "explanation": "Should be filtered out",
            "source": "Google Chrome"
        }
    ],
    "scan_duration": 1.8,
    "total_size": 9300000000
}
"""

/// Output containing only dev artifact categories.
private let purgeOutputCleanJSON = """
{
    "items": [
        {
            "id": "gradle_001",
            "name": ".gradle",
            "path": "/Users/dev/.gradle/caches",
            "size": 3000000000,
            "category": "dev_artifacts",
            "confidence": 88,
            "explanation": "Gradle build cache",
            "source": "Gradle"
        }
    ],
    "scan_duration": 0.9,
    "total_size": 3000000000
}
"""

private let emptyOutputJSON = """
{ "items": [] }
"""

// MARK: - Mock Binary Helper

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

@Suite("MoPurgeAdapter")
struct MoPurgeAdapterTests {

    @Test("scan returns only dev artifact categories")
    func scanReturnsOnlyDevArtifacts() async throws {
        let binaryPath = try createMockBinary(output: purgeOutputMixedJSON)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoPurgeAdapter(runner: runner)
        let results = try await adapter.scan()

        // browser_cache item should be filtered out
        #expect(results.count == 3)
        for result in results {
            #expect(MoPurgeAdapter.purgeCategories.contains(result.category),
                    "Unexpected category: \(result.category)")
        }
    }

    @Test("scan preserves Trust Layer metadata on dev artifacts")
    func scanPreservesTrustLayerMetadata() async throws {
        let binaryPath = try createMockBinary(output: purgeOutputCleanJSON)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoPurgeAdapter(runner: runner)
        let results = try await adapter.scan()

        #expect(results.count == 1)
        let gradle = results[0]
        #expect(gradle.id == "gradle_001")
        #expect(gradle.category == "dev_artifacts")
        #expect(gradle.safety == .review) // dev_artifacts → review
        #expect(gradle.confidence == 88)
        #expect(gradle.size == 3_000_000_000)
    }

    @MainActor @Test("scan updates ScanProgress lifecycle")
    func scanUpdatesProgress() async throws {
        let binaryPath = try createMockBinary(output: purgeOutputCleanJSON)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoPurgeAdapter(runner: runner)
        let progress = ScanProgress()

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
        let adapter = MoPurgeAdapter(runner: runner)
        let results = try await adapter.scan()

        #expect(results.isEmpty)
    }

    @MainActor @Test("scan propagates MoleError on process failure")
    func scanPropagatesMoleError() async throws {
        let binaryPath = try createMockBinary(output: "error", exitCode: 1)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoPurgeAdapter(runner: runner)
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

    @Test("purgeCategories contains expected categories")
    func purgeCategories() {
        #expect(MoPurgeAdapter.purgeCategories.contains("dev_artifacts"))
        #expect(MoPurgeAdapter.purgeCategories.contains("docker"))
        #expect(MoPurgeAdapter.purgeCategories.contains("homebrew"))
        #expect(!MoPurgeAdapter.purgeCategories.contains("browser_cache"))
        #expect(!MoPurgeAdapter.purgeCategories.contains("browser_data"))
    }

    @Test("scan without progress observer does not crash")
    func scanWithoutProgress() async throws {
        let binaryPath = try createMockBinary(output: purgeOutputCleanJSON)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoPurgeAdapter(runner: runner)
        let results = try await adapter.scan(progress: nil)

        #expect(results.count == 1)
    }
}
