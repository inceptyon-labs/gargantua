import Foundation
import Testing
@testable import GargantuaCore

extension AuditWriterTests {
    @Test("readEntries returns all written entries")
    func readEntries() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)

        for i in 1 ... 3 {
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

        let entries = try writer.readEntries()
        #expect(entries.count == 3)
        #expect(entries[0].files[0].path == "/tmp/file1.txt")
        #expect(entries[2].files[0].path == "/tmp/file3.txt")
    }

    @Test("readEntries returns empty array for nonexistent log")
    func readEntriesNoFile() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir.appendingPathComponent("nope"))
        let entries = try writer.readEntries()
        #expect(entries.isEmpty)
    }
}
