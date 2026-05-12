import Foundation
import Testing
@testable import GargantuaCore

extension AuditWriterTests {
    @Test("purgeEntries removes entries older than retention period")
    func purgeOldEntries() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)
        let now = Date()

        // Write an old entry (100 days ago)
        let oldEntry = AuditEntry(
            id: UUID(),
            timestamp: now.addingTimeInterval(-100 * 86400),
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/old", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100
        )
        try writer.write(oldEntry)

        // Write a recent entry (5 days ago)
        let recentEntry = AuditEntry(
            id: UUID(),
            timestamp: now.addingTimeInterval(-5 * 86400),
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/recent", size: 200)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 200
        )
        try writer.write(recentEntry)

        let purged = try writer.purgeEntries(olderThanDays: 90, now: now)
        #expect(purged == 1)

        let remaining = try writer.readEntries()
        #expect(remaining.count == 1)
        #expect(remaining[0].files[0].path == "/recent")
    }

    @Test("purgeEntries with default 90-day retention")
    func purgeDefault90Days() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)
        let now = Date()

        // Write entry at 89 days (should be kept)
        let keepEntry = AuditEntry(
            id: UUID(),
            timestamp: now.addingTimeInterval(-89 * 86400),
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/keep", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100
        )
        try writer.write(keepEntry)

        // Write entry at 91 days (should be purged)
        let purgeEntry = AuditEntry(
            id: UUID(),
            timestamp: now.addingTimeInterval(-91 * 86400),
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/purge", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100
        )
        try writer.write(purgeEntry)

        let purged = try writer.purgeEntries(now: now)
        #expect(purged == 1)

        let remaining = try writer.readEntries()
        #expect(remaining.count == 1)
        #expect(remaining[0].files[0].path == "/keep")
    }

    @Test("purgeEntries returns 0 for nonexistent log")
    func purgeNonexistentLog() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir.appendingPathComponent("nope"))
        let purged = try writer.purgeEntries()
        #expect(purged == 0)
    }

    @Test("purgeEntries returns 0 when all entries are within retention")
    func purgeNothingToRemove() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)

        let entry = AuditEntry(
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/recent", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100
        )
        try writer.write(entry)

        let purged = try writer.purgeEntries()
        #expect(purged == 0)
    }

    @Test("purgeEntries with custom retention period")
    func purgeCustomRetention() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)
        let now = Date()

        // Entry from 10 days ago
        let entry = AuditEntry(
            id: UUID(),
            timestamp: now.addingTimeInterval(-10 * 86400),
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/test", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100
        )
        try writer.write(entry)

        // 7-day retention should purge it
        let purged = try writer.purgeEntries(olderThanDays: 7, now: now)
        #expect(purged == 1)

        let remaining = try writer.readEntries()
        #expect(remaining.isEmpty)
    }
}
