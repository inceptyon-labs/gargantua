import Foundation
import Testing
@testable import GargantuaCore

// MARK: - Test Fixtures

private let analyzeOutputJSON = """
{
    "entries": [
        {
            "name": "Library",
            "path": "/Users/dev/Library",
            "size": 5000000000,
            "children": [
                {
                    "name": "Caches",
                    "path": "/Users/dev/Library/Caches",
                    "size": 3000000000,
                    "children": [
                        {
                            "name": "Google",
                            "path": "/Users/dev/Library/Caches/Google",
                            "size": 1500000000
                        }
                    ]
                },
                {
                    "name": "Application Support",
                    "path": "/Users/dev/Library/Application Support",
                    "size": 2000000000
                }
            ]
        },
        {
            "name": "Documents",
            "path": "/Users/dev/Documents",
            "size": 10000000000
        }
    ]
}
"""

private let permissionDeniedJSON = """
{
    "entries": [
        {
            "name": "private",
            "path": "/private/var",
            "size": 0,
            "permission_denied": true
        }
    ]
}
"""

private let emptyAnalyzeJSON = """
{ "entries": [] }
"""

private let partialEntryJSON = """
{
    "entries": [
        {
            "path": "/Users/dev/Downloads"
        }
    ]
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

@Suite("MoAnalyzeAdapter")
struct MoAnalyzeAdapterTests {

    @Test("analyze returns nested DirectoryItem tree")
    func analyzeReturnsTree() async throws {
        let binaryPath = try createMockBinary(output: analyzeOutputJSON)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoAnalyzeAdapter(runner: runner)
        let items = try await adapter.analyze()

        #expect(items.count == 2)

        // Library with children
        let library = items[0]
        #expect(library.name == "Library")
        #expect(library.path == "/Users/dev/Library")
        #expect(library.size == 5_000_000_000)
        #expect(library.children?.count == 2)

        // Nested: Library/Caches/Google
        let caches = library.children?[0]
        #expect(caches?.name == "Caches")
        #expect(caches?.children?.count == 1)
        #expect(caches?.children?[0].name == "Google")
        #expect(caches?.children?[0].size == 1_500_000_000)

        // Documents (no children)
        let docs = items[1]
        #expect(docs.name == "Documents")
        #expect(docs.children == nil)
    }

    @Test("analyze handles permission denied entries")
    func analyzePermissionDenied() async throws {
        let binaryPath = try createMockBinary(output: permissionDeniedJSON)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoAnalyzeAdapter(runner: runner)
        let items = try await adapter.analyze()

        #expect(items.count == 1)
        #expect(items[0].isPermissionDenied == true)
        #expect(items[0].size == 0)
    }

    @Test("analyze with empty results returns empty array")
    func analyzeEmpty() async throws {
        let binaryPath = try createMockBinary(output: emptyAnalyzeJSON)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoAnalyzeAdapter(runner: runner)
        let items = try await adapter.analyze()

        #expect(items.isEmpty)
    }

    @Test("analyze handles partial entries with missing fields")
    func analyzePartialEntry() async throws {
        let binaryPath = try createMockBinary(output: partialEntryJSON)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoAnalyzeAdapter(runner: runner)
        let items = try await adapter.analyze()

        #expect(items.count == 1)
        #expect(items[0].name == "Downloads") // derived from path
        #expect(items[0].size == 0) // default
    }

    @Test("analyze propagates MoleError on process failure")
    func analyzePropagatesMoleError() async throws {
        let binaryPath = try createMockBinary(output: "error", exitCode: 1)
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoAnalyzeAdapter(runner: runner)

        do {
            _ = try await adapter.analyze()
            Issue.record("Expected MoleError")
        } catch is MoleError {
            // Expected
        }
    }

    @Test("analyze propagates parse error on invalid JSON")
    func analyzePropagatesParseError() async throws {
        let binaryPath = try createMockBinary(output: "not json")
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }

        let runner = MoleRunner(config: MoleRunnerConfig(binaryPath: binaryPath))
        let adapter = MoAnalyzeAdapter(runner: runner)

        do {
            _ = try await adapter.analyze()
            Issue.record("Expected MoleParseError")
        } catch is MoleParseError {
            // Expected
        }
    }
}
