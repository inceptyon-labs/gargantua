import Foundation
import Testing
@testable import GargantuaCore

@Suite("AuditWriter")
struct AuditWriterTests {
    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeEntry(path: String, age: TimeInterval = 0, now: Date = Date()) -> AuditEntry {
        AuditEntry(
            id: UUID(),
            timestamp: now.addingTimeInterval(age),
            tool: "native",
            command: "clean",
            files: [AuditFile(path: path, size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100
        )
    }
}
