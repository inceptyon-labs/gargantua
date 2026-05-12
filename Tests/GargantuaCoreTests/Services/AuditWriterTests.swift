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
}
