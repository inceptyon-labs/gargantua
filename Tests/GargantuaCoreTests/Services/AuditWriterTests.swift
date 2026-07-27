import Foundation
import Testing
@testable import GargantuaCore

// Serialized: appendsSurviveConcurrentPurges' purge loop is fully synchronous
// (no `await` inside), so under contention from sibling tests running in
// parallel it can monopolize a cooperative-pool thread and finish all 20
// rounds before any append Task ever gets scheduled — starving out the very
// overlap the test exists to exercise, rather than racing it.
@Suite("AuditWriter", .serialized)
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
