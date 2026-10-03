import Foundation
import Testing
@testable import GargantuaCore

@Suite("SQLiteDatabaseFiles")
struct SQLiteDatabaseFilesTests {
    @Test("isDatabase matches database suffixes case-insensitively")
    func isDatabase() {
        for path in ["a.sqlite", "A.SQLITE3", "x.db", "state.vscdb"] {
            #expect(SQLiteDatabaseFiles.isDatabase(path))
        }
        for path in ["a.sqlite-wal", "notes.txt"] {
            #expect(!SQLiteDatabaseFiles.isDatabase(path))
        }
    }

    @Test("existingSidecars returns only sidecars that exist")
    func existingSidecars() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-sidecars-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("x.sqlite").path
        try Data([1]).write(to: URL(fileURLWithPath: db))
        try Data([1]).write(to: URL(fileURLWithPath: db + "-wal"))
        try Data([1]).write(to: URL(fileURLWithPath: db + "-journal"))
        #expect(SQLiteDatabaseFiles.existingSidecars(of: db) == [db + "-wal", db + "-journal"])
    }
}
