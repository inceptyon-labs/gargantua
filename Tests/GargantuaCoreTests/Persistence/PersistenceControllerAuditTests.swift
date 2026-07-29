import Foundation
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

    @Test("A pair straddling a page boundary does not surface on both pages")
    func pairStraddlingPageBoundaryAppearsOnce() throws {
        let ctrl = try makeController()
        let now = Date()
        let pairID = UUID()

        // Rows newest-first: row-0 … row-3, then the pair, then row-6 … row-9.
        for offset in 0 ..< 4 {
            try ctrl.recordAuditEntry(
                AuditEntry(
                    id: UUID(),
                    timestamp: now.addingTimeInterval(-Double(offset) * 60),
                    tool: "native",
                    command: "clean",
                    files: [AuditFile(path: "/row-\(offset)", size: 1)],
                    safetyLevel: .safe,
                    confirmationMethod: .singleButton,
                    bytesFreed: 1
                )
            )
        }
        try ctrl.recordAuditEntry(
            AuditEntry(
                id: pairID,
                timestamp: now.addingTimeInterval(-5 * 60),
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
                timestamp: now.addingTimeInterval(-4 * 60),
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/pair", size: 100)],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                bytesFreed: 100,
                status: .completed
            )
        )
        for offset in 6 ..< 10 {
            try ctrl.recordAuditEntry(
                AuditEntry(
                    id: UUID(),
                    timestamp: now.addingTimeInterval(-Double(offset) * 60),
                    tool: "native",
                    command: "clean",
                    files: [AuditFile(path: "/row-\(offset)", size: 1)],
                    safetyLevel: .safe,
                    confirmationMethod: .singleButton,
                    bytesFreed: 1
                )
            )
        }

        let page1 = try ctrl.fetchAuditEntries(from: Date.distantPast, limit: 5, offset: 0)
        let page2 = try ctrl.fetchAuditEntries(from: Date.distantPast, limit: 5, offset: 5)

        let pairOccurrences = (page1 + page2).filter { $0.id == pairID }
        #expect(pairOccurrences.count == 1)
        #expect(pairOccurrences.first?.status == .completed)
        #expect(pairOccurrences.first?.bytesFreed == 100)
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

    @Test("A pair with identical timestamps still collapses to the outcome line")
    func pairWithTiedTimestampsKeepsOutcome() throws {
        let ctrl = try makeController()
        let id = UUID()
        let stamp = Date()

        try ctrl.recordAuditEntry(
            AuditEntry(
                id: id,
                timestamp: stamp,
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/tied", size: 100)],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                bytesFreed: 0,
                status: .attempted
            )
        )
        try ctrl.recordAuditEntry(
            AuditEntry(
                id: id,
                timestamp: stamp,
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/tied", size: 100)],
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
