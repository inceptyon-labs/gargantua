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
