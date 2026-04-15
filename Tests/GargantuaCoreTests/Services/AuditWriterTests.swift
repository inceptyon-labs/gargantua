import Foundation
import Testing
@testable import GargantuaCore

@Suite("AuditWriter")
struct AuditWriterTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("Creates log directory and writes JSONL")
    func writesJSONL() throws {
        let dir = try makeTempDir()
        // Use a subdirectory that doesn't exist yet
        let logDir = dir.appendingPathComponent("nested/logs")
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: logDir)

        let entry = AuditEntry(
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/tmp/test.txt", size: 1024)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 1024
        )

        try writer.write(entry)

        let content = try String(contentsOf: writer.logFile, encoding: .utf8)
        let lines = content.split(separator: "\n")
        #expect(lines.count == 1)

        // Verify it's valid JSON
        let data = Data(lines[0].utf8)
        let decoded = try JSONDecoder.auditDecoder.decode(AuditEntry.self, from: data)
        #expect(decoded.tool == "native")
        #expect(decoded.command == "clean")
        #expect(decoded.files.count == 1)
        #expect(decoded.bytesFreed == 1024)
    }

    @Test("Appends multiple entries as separate lines")
    func appendsMultipleLines() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)

        for i in 1...3 {
            let entry = AuditEntry(
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/tmp/file\(i).txt", size: Int64(i * 100))],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                bytesFreed: Int64(i * 100)
            )
            try writer.write(entry)
        }

        let content = try String(contentsOf: writer.logFile, encoding: .utf8)
        let lines = content.split(separator: "\n")
        #expect(lines.count == 3)

        // Each line should be independently decodable
        for line in lines {
            let data = Data(line.utf8)
            let decoded = try JSONDecoder.auditDecoder.decode(AuditEntry.self, from: data)
            #expect(decoded.tool == "native")
        }
    }

    @Test("record skips writing when no items succeeded")
    func recordSkipsEmptyResults() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)
        let result = CleanupResult(itemResults: [])

        try writer.record(result: result)

        #expect(!FileManager.default.fileExists(atPath: writer.logFile.path))
    }

    @Test("record computes highest safety level")
    func recordComputesSafetyLevel() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)

        let items = [
            CleanupItemResult(
                item: ScanResult(
                    id: "a", name: "A", path: "/a", size: 100,
                    safety: .safe, confidence: 95, explanation: "",
                    source: SourceAttribution(name: "Test"), category: "test"
                ),
                succeeded: true
            ),
            CleanupItemResult(
                item: ScanResult(
                    id: "b", name: "B", path: "/b", size: 200,
                    safety: .review, confidence: 80, explanation: "",
                    source: SourceAttribution(name: "Test"), category: "test"
                ),
                succeeded: true
            ),
        ]

        let result = CleanupResult(itemResults: items)
        try writer.record(result: result)

        let content = try String(contentsOf: writer.logFile, encoding: .utf8)
        let data = Data(content.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let decoded = try JSONDecoder.auditDecoder.decode(AuditEntry.self, from: data)
        #expect(decoded.safetyLevel == .review)
        #expect(decoded.bytesFreed == 300)
    }

    @Test("Default log directory is ~/Library/Logs/Gargantua")
    func defaultLogDirectory() {
        let writer = AuditWriter()
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Gargantua")
        #expect(writer.logDirectory == expected)
        #expect(writer.logFile == expected.appendingPathComponent("audit.json"))
    }

    @Test("Concurrent writes produce correct number of lines")
    func concurrentWrites() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)
        let count = 50

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let entry = AuditEntry(
                        tool: "native",
                        command: "clean",
                        files: [AuditFile(path: "/tmp/file\(i).txt", size: Int64(i * 10))],
                        safetyLevel: .safe,
                        confirmationMethod: .singleButton,
                        bytesFreed: Int64(i * 10)
                    )
                    try writer.write(entry)
                }
            }
            try await group.waitForAll()
        }

        let content = try String(contentsOf: writer.logFile, encoding: .utf8)
        let lines = content.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == count, "Expected \(count) lines, got \(lines.count)")

        // Each line must be valid JSON
        for (index, line) in lines.enumerated() {
            let data = Data(line.utf8)
            #expect(throws: Never.self) {
                _ = try JSONDecoder.auditDecoder.decode(AuditEntry.self, from: data)
            }
            _ = index  // suppress unused warning
        }
    }
}

// MARK: - JSONDecoder helper for tests

private extension JSONDecoder {
    static let auditDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
