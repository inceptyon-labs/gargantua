import Foundation
import Testing
@testable import GargantuaCore

extension AuditWriterTests {
    @Test("readEntries collapses an intent+outcome pair into one completed entry")
    func readEntriesCollapsesIntentAndOutcome() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)
        let id = UUID()

        let intent = AuditEntry(
            id: id,
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/tmp/two-phase.txt", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 0,
            status: .attempted
        )
        try writer.write(intent)

        let outcome = AuditEntry(
            id: id,
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/tmp/two-phase.txt", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100,
            status: .completed
        )
        try writer.write(outcome)

        let entries = try writer.readEntries()
        #expect(entries.count == 1)
        #expect(entries[0].status == .completed)
        #expect(entries[0].bytesFreed == 100)
    }

    @Test("readEntries surfaces an orphaned attempted entry")
    func readEntriesSurfacesOrphanedAttempt() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)

        let intent = AuditEntry(
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/tmp/orphan.txt", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 0,
            status: .attempted
        )
        try writer.write(intent)

        let entries = try writer.readEntries()
        #expect(entries.count == 1)
        #expect(entries[0].status == .attempted)
    }

    @Test("readEntries keeps collapsed order matching write order by surviving line")
    func readEntriesPreservesOrderAcrossCollapse() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)

        let first = AuditEntry(
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/tmp/first.txt", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100
        )
        try writer.write(first)

        let middleID = UUID()
        let middleIntent = AuditEntry(
            id: middleID,
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/tmp/middle.txt", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 0,
            status: .attempted
        )
        try writer.write(middleIntent)

        let middleOutcome = AuditEntry(
            id: middleID,
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/tmp/middle.txt", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100,
            status: .completed
        )
        try writer.write(middleOutcome)

        let last = AuditEntry(
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/tmp/last.txt", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100
        )
        try writer.write(last)

        let entries = try writer.readEntries()
        let paths = entries.map { $0.files[0].path }
        #expect(paths == ["/tmp/first.txt", "/tmp/middle.txt", "/tmp/last.txt"])
    }

    @Test("readEntries collapses an interleaved pair by the outcome's position, not the intent's")
    func readEntriesCollapsesInterleavedPairByLastOccurrence() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)
        let pairID = UUID()

        // A_intent, then B, then A_outcome: an implementation that took
        // position from the FIRST occurrence of a collapsed id would place A
        // before B. Only taking position from the LAST occurrence produces
        // [B, A].
        let aIntent = AuditEntry(
            id: pairID,
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/tmp/a.txt", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 0,
            status: .attempted
        )
        try writer.write(aIntent)

        let bEntry = AuditEntry(
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/tmp/b.txt", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100
        )
        try writer.write(bEntry)

        let aOutcome = AuditEntry(
            id: pairID,
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/tmp/a.txt", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100,
            status: .completed
        )
        try writer.write(aOutcome)

        let entries = try writer.readEntries()
        let paths = entries.map { $0.files[0].path }
        #expect(paths == ["/tmp/b.txt", "/tmp/a.txt"])
    }

    @Test("readEntries decodes a line with no status key as completed")
    func readEntriesDefaultsMissingStatusToCompleted() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let id = UUID().uuidString
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let rawLine = """
        {"id":"\(id)","timestamp":"\(timestamp)","tool":"native","command":"clean",\
        "files":[{"path":"/tmp/legacy.txt","size":100}],"safetyLevel":"safe",\
        "confirmationMethod":"singleButton","cleanupMethod":"trash","bytesFreed":100}\n
        """
        try Data(rawLine.utf8).write(to: writer.logFile)

        let entries = try writer.readEntries()
        #expect(entries.count == 1)
        #expect(entries[0].status == .completed)
    }

    @Test("purgeEntries leaves an intent+outcome pair uncompacted on disk when nothing aged out")
    func purgeEntriesCollapsesWithinRetention() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)
        let id = UUID()

        let intent = AuditEntry(
            id: id,
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/tmp/pair.txt", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 0,
            status: .attempted
        )
        try writer.write(intent)

        let outcome = AuditEntry(
            id: id,
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/tmp/pair.txt", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100,
            status: .completed
        )
        try writer.write(outcome)

        let purged = try writer.purgeEntries()
        #expect(purged == 0)

        // Nothing aged out, so purgeEntries does not rewrite the file — the
        // superseded intent line is left on disk rather than opening a
        // read-modify-write window on every call. The reader still collapses
        // it in memory.
        let content = try String(contentsOf: writer.logFile, encoding: .utf8)
        let lines = content.split(separator: "\n")
        #expect(lines.count == 2)

        let entries = try writer.readEntries()
        #expect(entries.count == 1)
        #expect(entries[0].status == .completed)
    }

    @Test("purgeEntries removes both lines of a pair whose surviving outcome is older than the cutoff")
    func purgeEntriesRemovesAgedOutPairByOutcomeTimestamp() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)
        let id = UUID()
        let now = Date()
        let old = now.addingTimeInterval(-100 * 86400)

        let intent = AuditEntry(
            id: id,
            timestamp: old,
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/tmp/aged-pair.txt", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 0,
            status: .attempted
        )
        try writer.write(intent)

        let outcome = AuditEntry(
            id: id,
            timestamp: old,
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/tmp/aged-pair.txt", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100,
            status: .completed
        )
        try writer.write(outcome)

        let purged = try writer.purgeEntries(olderThanDays: 90, now: now)
        #expect(purged == 1)

        let content = try String(contentsOf: writer.logFile, encoding: .utf8)
        let lines = content.split(separator: "\n")
        #expect(lines.isEmpty)

        let entries = try writer.readEntries()
        #expect(entries.isEmpty)
    }

    @Test("purgeEntries keeps an orphaned attempted entry within retention")
    func purgeEntriesKeepsOrphanedAttempt() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)

        let intent = AuditEntry(
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/tmp/orphan-purge.txt", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 0,
            status: .attempted
        )
        try writer.write(intent)

        let purged = try writer.purgeEntries()
        #expect(purged == 0)

        let entries = try writer.readEntries()
        #expect(entries.count == 1)
        #expect(entries[0].status == .attempted)
    }
}
