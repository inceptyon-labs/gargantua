import Foundation
import SwiftData
import Testing
@testable import GargantuaCore

@MainActor
private func makeController() throws -> PersistenceController {
    try PersistenceController(inMemory: true)
}

@Suite("PersistenceController audit entries and scan history")
@MainActor
struct PersistenceControllerAuditTests {

    // MARK: - Audit Entries

    @Test("Record and query audit entries by date range")
    func auditEntryDateRange() throws {
        let ctrl = try makeController()
        let now = Date()

        // Entry from 5 days ago
        let recent = AuditEntry(
            id: UUID(),
            timestamp: now.addingTimeInterval(-5 * 86400),
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/recent", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100
        )
        try ctrl.recordAuditEntry(recent)

        // Entry from 60 days ago
        let old = AuditEntry(
            id: UUID(),
            timestamp: now.addingTimeInterval(-60 * 86400),
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/old", size: 200)],
            safetyLevel: .review,
            confirmationMethod: .summaryDialog,
            bytesFreed: 200
        )
        try ctrl.recordAuditEntry(old)

        // Query last 30 days
        let last30 = try ctrl.fetchAuditEntries(from: now.addingTimeInterval(-30 * 86400))
        #expect(last30.count == 1)
        #expect(last30[0].files[0].path == "/recent")

        // Query last 90 days
        let last90 = try ctrl.fetchAuditEntries(from: now.addingTimeInterval(-90 * 86400))
        #expect(last90.count == 2)
    }

    @Test("Purge old audit entries based on retention")
    func purgeAuditEntries() throws {
        let ctrl = try makeController()
        let now = Date()

        // Insert entries at various ages
        for days in [10, 50, 100, 200] {
            let entry = AuditEntry(
                id: UUID(),
                timestamp: now.addingTimeInterval(-Double(days) * 86400),
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/file-\(days)d", size: 100)],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                bytesFreed: 100
            )
            try ctrl.recordAuditEntry(entry)
        }

        let purged = try ctrl.purgeOldAuditEntries(retentionDays: 90)
        #expect(purged == 2) // 100d and 200d entries

        let remaining = try ctrl.fetchAuditEntries(from: Date.distantPast)
        #expect(remaining.count == 2)
    }

    @Test("fetchAuditEntries respects a row limit")
    func fetchAuditEntriesRespectsLimit() throws {
        let ctrl = try makeController()
        let now = Date()
        for offset in 0 ..< 20 {
            let entry = AuditEntry(
                id: UUID(),
                timestamp: now.addingTimeInterval(-Double(offset) * 60),
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/row-\(offset)", size: 1)],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                bytesFreed: 1
            )
            try ctrl.recordAuditEntry(entry)
        }

        let capped = try ctrl.fetchAuditEntries(from: Date.distantPast, limit: 5)
        #expect(capped.count == 5)

        let paged = try ctrl.fetchAuditEntries(from: Date.distantPast, limit: 5, offset: 5)
        #expect(paged.count == 5)
        #expect(paged.first?.files[0].path == "/row-5")
    }

    @Test("An attempted entry round-trips through SwiftData without becoming completed")
    func attemptedStatusSurvivesRoundTrip() throws {
        let ctrl = try makeController()
        let entry = AuditEntry(
            id: UUID(),
            timestamp: Date(),
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/attempted", size: 10)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 10,
            status: .attempted
        )
        try ctrl.recordAuditEntry(entry)

        let fetched = try ctrl.fetchAuditEntries(from: Date.distantPast)
        #expect(fetched.count == 1)
        #expect(fetched[0].status == .attempted)
    }

    @Test("A completed entry round-trips as completed")
    func completedStatusSurvivesRoundTrip() throws {
        let ctrl = try makeController()
        try ctrl.recordAuditEntry(
            AuditEntry(
                id: UUID(),
                timestamp: Date(),
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/completed", size: 10)],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                bytesFreed: 10,
                status: .completed
            )
        )

        let fetched = try ctrl.fetchAuditEntries(from: Date.distantPast)
        #expect(fetched[0].status == .completed)
    }

    @Test("A two-phase pair fetches back as one row carrying the outcome")
    func twoPhasePairCollapsesToOneRow() throws {
        let ctrl = try makeController()
        let id = UUID()
        let start = Date().addingTimeInterval(-60)

        try ctrl.recordAuditEntry(
            AuditEntry(
                id: id,
                timestamp: start,
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/pair", size: 100)],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                bytesFreed: 0,
                status: .attempted
            )
        )
        try ctrl.recordAuditEntry(
            AuditEntry(
                id: id,
                timestamp: start.addingTimeInterval(5),
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/pair", size: 100)],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                bytesFreed: 100,
                status: .completed
            )
        )

        let fetched = try ctrl.fetchAuditEntries(from: Date.distantPast)
        #expect(fetched.count == 1)
        #expect(fetched[0].status == .completed)
        #expect(fetched[0].bytesFreed == 100)
    }

    @Test("Recording the outcome updates every field of the intent row in place")
    func outcomeUpsertsRatherThanInsertingASecondRow() throws {
        let ctrl = try makeController()
        let id = UUID()
        let start = Date().addingTimeInterval(-60)
        let outcomeStamp = start.addingTimeInterval(5)

        try ctrl.recordAuditEntry(
            AuditEntry(
                id: id,
                timestamp: start,
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/intent", size: 1)],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                cleanupMethod: .trash,
                bytesFreed: 0,
                transport: nil,
                clientID: nil,
                kind: .path,
                commandToolVersion: nil,
                commandExitCode: nil,
                commandArguments: nil,
                status: .attempted
            )
        )
        let afterIntent = try ctrl.context.fetch(FetchDescriptor<PersistedAuditEntry>())
        #expect(afterIntent.count == 1)
        #expect(afterIntent.first?.statusRaw == "attempted")

        // Every field differs from the intent line, so a missing assignment in
        // update(from:) leaves an observable stale value.
        try ctrl.recordAuditEntry(
            AuditEntry(
                id: id,
                timestamp: outcomeStamp,
                tool: "xcodebuild",
                command: "purge",
                files: [AuditFile(path: "/outcome", size: 2)],
                safetyLevel: .review,
                confirmationMethod: .summaryDialog,
                cleanupMethod: .toolNative,
                bytesFreed: 100,
                transport: "mcp",
                clientID: "test-client",
                kind: .command,
                commandToolVersion: "Xcode 16.2",
                commandExitCode: 3,
                commandArguments: ["simctl", "delete"],
                status: .completed
            )
        )

        let rows = try ctrl.context.fetch(FetchDescriptor<PersistedAuditEntry>())
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.entryID == id)
        #expect(abs(row.timestamp.timeIntervalSince(outcomeStamp)) < 0.001)
        #expect(row.tool == "xcodebuild")
        #expect(row.command == "purge")
        #expect(row.safetyLevel == "review")
        #expect(row.confirmationMethod == "summaryDialog")
        #expect(row.cleanupMethod == "tool_native")
        #expect(row.bytesFreed == 100)
        #expect(row.transport == "mcp")
        #expect(row.clientID == "test-client")
        #expect(row.kindRaw == "command")
        #expect(row.commandToolVersion == "Xcode 16.2")
        #expect(row.commandExitCode == 3)
        #expect(row.statusRaw == "completed")

        // filesData and commandArgumentsData are JSON blobs — assert through the
        // domain round-trip so the encoding is exercised too.
        let domain = try #require(row.toDomain())
        #expect(domain.files.map(\.path) == ["/outcome"])
        #expect(domain.commandArguments == ["simctl", "delete"])
    }

    @Test("An orphaned attempted entry survives collapse")
    func orphanedAttemptedEntrySurvives() throws {
        let ctrl = try makeController()
        let crashed = UUID()
        let finished = UUID()
        let start = Date().addingTimeInterval(-120)

        try ctrl.recordAuditEntry(
            AuditEntry(
                id: crashed,
                timestamp: start,
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/crashed", size: 50)],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                bytesFreed: 0,
                status: .attempted
            )
        )
        try ctrl.recordAuditEntry(
            AuditEntry(
                id: finished,
                timestamp: start.addingTimeInterval(8),
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/finished", size: 50)],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                bytesFreed: 0,
                status: .attempted
            )
        )
        try ctrl.recordAuditEntry(
            AuditEntry(
                id: finished,
                timestamp: start.addingTimeInterval(10),
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/finished", size: 50)],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                bytesFreed: 50,
                status: .completed
            )
        )

        let fetched = try ctrl.fetchAuditEntries(from: Date.distantPast)
        #expect(fetched.count == 2)
        #expect(fetched.first { $0.id == crashed }?.status == .attempted)
        #expect(fetched.first { $0.id == finished }?.status == .completed)
    }
}

// Split from the main suite body to stay under SwiftLint's type_body_length
// threshold; Swift Testing still discovers @Test methods in this extension
// as part of the same "PersistenceController audit entries and scan history"
// suite.
extension PersistenceControllerAuditTests {

    @Test("A reused id cannot downgrade a completed record back to attempted")
    func completedRecordIsNotDowngradedByAReusedID() throws {
        let ctrl = try makeController()
        let id = UUID()
        let start = Date().addingTimeInterval(-60)

        try ctrl.recordAuditEntry(
            AuditEntry(
                id: id,
                timestamp: start,
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/finished", size: 100)],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                bytesFreed: 100,
                status: .completed
            )
        )
        // Same id reused for a fresh operation's intent line.
        try ctrl.recordAuditEntry(
            AuditEntry(
                id: id,
                timestamp: start.addingTimeInterval(30),
                tool: "native",
                command: "purge",
                files: [AuditFile(path: "/reused", size: 7)],
                safetyLevel: .review,
                confirmationMethod: .summaryDialog,
                bytesFreed: 0,
                status: .attempted
            )
        )

        let fetched = try ctrl.fetchAuditEntries(from: Date.distantPast)
        #expect(fetched.count == 1)
        #expect(fetched[0].status == .completed)
        #expect(fetched[0].command == "clean")
        #expect(fetched[0].bytesFreed == 100)
        #expect(fetched[0].files.first?.path == "/finished")
    }

    @Test("Paging across a stored pair skips no entries")
    func pagingAcrossAPairSkipsNoEntries() throws {
        let ctrl = try makeController()
        let now = Date()
        let pairID = UUID()

        // Nine operations, newest first: row-0 … row-3, the pair, row-5 … row-8.
        for index in 0 ..< 4 {
            try ctrl.recordAuditEntry(
                AuditEntry(
                    id: UUID(),
                    timestamp: now.addingTimeInterval(-Double(index) * 60),
                    tool: "native",
                    command: "clean",
                    files: [AuditFile(path: "/row-\(index)", size: 1)],
                    safetyLevel: .safe,
                    confirmationMethod: .singleButton,
                    bytesFreed: 1
                )
            )
        }
        // A two-phase pair recorded as intent then outcome under one id.
        try ctrl.recordAuditEntry(
            AuditEntry(
                id: pairID,
                timestamp: now.addingTimeInterval(-4 * 60 - 30),
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/pair", size: 100)],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                bytesFreed: 0,
                status: .attempted
            )
        )
        try ctrl.recordAuditEntry(
            AuditEntry(
                id: pairID,
                timestamp: now.addingTimeInterval(-4 * 60 - 20),
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/pair", size: 100)],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                bytesFreed: 100,
                status: .completed
            )
        )
        for index in 5 ..< 9 {
            try ctrl.recordAuditEntry(
                AuditEntry(
                    id: UUID(),
                    timestamp: now.addingTimeInterval(-Double(index) * 60),
                    tool: "native",
                    command: "clean",
                    files: [AuditFile(path: "/row-\(index)", size: 1)],
                    safetyLevel: .safe,
                    confirmationMethod: .singleButton,
                    bytesFreed: 1
                )
            )
        }

        // Walk every page and prove the union is the whole store, with no
        // duplicates and nothing skipped.
        var paged: [AuditEntry] = []
        for offset in stride(from: 0, to: 9, by: 3) {
            paged += try ctrl.fetchAuditEntries(from: Date.distantPast, limit: 3, offset: offset)
        }

        #expect(paged.count == 9)
        #expect(Set(paged.map(\.id)).count == 9)

        let allAtOnce = try ctrl.fetchAuditEntries(from: Date.distantPast)
        #expect(allAtOnce.count == 9)
        #expect(paged.map(\.id) == allAtOnce.map(\.id))

        let pairRow = allAtOnce.first { $0.id == pairID }
        #expect(pairRow?.status == .completed)
        #expect(pairRow?.bytesFreed == 100)
    }

    @Test("A legacy row with no status reads back as completed")
    func legacyRowWithoutStatusReadsAsCompleted() throws {
        let ctrl = try makeController()
        let row = PersistedAuditEntry(
            from: AuditEntry(
                id: UUID(),
                timestamp: Date(),
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/legacy", size: 10)],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                bytesFreed: 10,
                status: .attempted
            )
        )
        // Simulate a row written before the two-phase shape existed.
        row.statusRaw = nil
        ctrl.context.insert(row)
        try ctrl.context.save()

        let fetched = try ctrl.fetchAuditEntries(from: Date.distantPast)
        #expect(fetched.count == 1)
        #expect(fetched[0].status == .completed)
    }

    @Test("A row with an unrecognized status reads back as completed rather than dropping")
    func unknownStatusRawReadsAsCompleted() throws {
        let ctrl = try makeController()
        let row = PersistedAuditEntry(
            from: AuditEntry(
                id: UUID(),
                timestamp: Date(),
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/unknown", size: 10)],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                bytesFreed: 10,
                status: .attempted
            )
        )
        row.statusRaw = "not-a-real-status"
        ctrl.context.insert(row)
        try ctrl.context.save()

        let fetched = try ctrl.fetchAuditEntries(from: Date.distantPast)
        #expect(fetched.count == 1)
        #expect(fetched[0].status == .completed)
    }

    @Test("The store itself keeps one row per entryID, not just recordAuditEntry")
    func entryIDUniquenessIsEnforcedByTheStore() throws {
        let ctrl = try makeController()
        let id = UUID()

        func makeRow(path: String, bytes: Int64, status: AuditEntryStatus) -> PersistedAuditEntry {
            PersistedAuditEntry(
                from: AuditEntry(
                    id: id,
                    timestamp: Date(),
                    tool: "native",
                    command: "clean",
                    files: [AuditFile(path: path, size: 10)],
                    safetyLevel: .safe,
                    confirmationMethod: .singleButton,
                    bytesFreed: bytes,
                    status: status
                )
            )
        }

        // Bypass recordAuditEntry's upsert entirely — insert two raw rows.
        ctrl.context.insert(makeRow(path: "/first", bytes: 0, status: .attempted))
        try ctrl.context.save()
        ctrl.context.insert(makeRow(path: "/second", bytes: 100, status: .completed))
        try ctrl.context.save()

        let rows = try ctrl.context.fetch(FetchDescriptor<PersistedAuditEntry>())
        #expect(rows.count == 1)
        #expect(rows.first?.statusRaw == "completed")
        #expect(rows.first?.bytesFreed == 100)
    }

    // MARK: - Scan History

    @Test("Record and fetch scan history")
    func scanHistory() throws {
        let ctrl = try makeController()

        try ctrl.recordScanHistory(
            category: "browser_cache",
            itemCount: 15,
            totalBytes: 500_000_000,
            bytesFreed: 450_000_000,
            profileID: "developer"
        )

        try ctrl.recordScanHistory(
            category: "dev_artifacts",
            itemCount: 8,
            totalBytes: 2_000_000_000,
            bytesFreed: 1_800_000_000,
            profileID: "developer"
        )

        let all = try ctrl.fetchScanHistory()
        #expect(all.count == 2)

        let browserOnly = try ctrl.fetchScanHistory(category: "browser_cache")
        #expect(browserOnly.count == 1)
        #expect(browserOnly[0].itemCount == 15)
    }

    @Test("Last scan date returns most recent")
    func lastScanDate() throws {
        let ctrl = try makeController()

        let earlier = Date().addingTimeInterval(-3600)
        let later = Date()

        let hist1 = PersistedScanHistory(
            scanDate: earlier,
            category: "browser_cache",
            itemCount: 5,
            totalBytes: 100,
            profileID: "dev"
        )
        ctrl.context.insert(hist1)

        let hist2 = PersistedScanHistory(
            scanDate: later,
            category: "dev_artifacts",
            itemCount: 3,
            totalBytes: 200,
            profileID: "dev"
        )
        ctrl.context.insert(hist2)
        try ctrl.context.save()

        let lastDate = try ctrl.lastScanDate()
        #expect(lastDate != nil)
        // Should be the later date (within 1 second tolerance)
        #expect(abs(lastDate!.timeIntervalSince(later)) < 1)
    }

    @Test("Last scan date returns nil when no history")
    func lastScanDateEmpty() throws {
        let ctrl = try makeController()
        let lastDate = try ctrl.lastScanDate()
        #expect(lastDate == nil)
    }
}
