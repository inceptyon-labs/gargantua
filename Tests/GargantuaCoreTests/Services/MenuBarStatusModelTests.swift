import Foundation
import Testing
@testable import GargantuaCore

@Suite("MenuBarStatusModel")
struct MenuBarStatusModelTests {
    @Test("pending scheduled summary is reflected in menu bar snapshot")
    @MainActor
    func pendingScheduledSummarySnapshot() async throws {
        let persistence = try PersistenceController(inMemory: true)
        try persistence.bootstrap()
        let date = Date(timeIntervalSince1970: 5_000)
        try persistence.recordScheduledScanSummary(ScheduledScanSummary(
            date: date,
            profileID: "light",
            itemCount: 4,
            reclaimableBytes: 42_000
        ))

        let model = MenuBarStatusModel(
            scanner: StubMenuBarStatusScanner(results: []),
            makePersistence: { persistence },
            defaults: try makeDefaults(),
            now: { Date(timeIntervalSince1970: 5_100) }
        )

        await model.refresh()

        #expect(model.snapshot.lastScanDate == date)
        #expect(model.snapshot.reclaimableBytes == 42_000)
        #expect(model.snapshot.pendingAlertCount == 1)
        #expect(model.snapshot.pendingItemCount == 4)
    }

    @Test("pending scheduled alert is not hidden by newer timestamp-only scan date")
    @MainActor
    func scheduledSummaryOutranksPlainLastScanDate() async throws {
        let persistence = try PersistenceController(inMemory: true)
        try persistence.bootstrap()
        let summaryDate = Date(timeIntervalSince1970: 5_000)
        try persistence.recordScheduledScanSummary(ScheduledScanSummary(
            date: summaryDate,
            profileID: "light",
            itemCount: 2,
            reclaimableBytes: 24_000
        ))
        try persistence.updateSettings { settings in
            settings.lastScanDate = Date(timeIntervalSince1970: 6_000)
        }

        let model = MenuBarStatusModel(
            scanner: StubMenuBarStatusScanner(results: []),
            makePersistence: { persistence },
            defaults: try makeDefaults(),
            now: { Date(timeIntervalSince1970: 6_100) }
        )

        await model.refresh()

        #expect(model.snapshot.lastScanDate == summaryDate)
        #expect(model.snapshot.reclaimableBytes == 24_000)
        #expect(model.snapshot.pendingAlertCount == 1)
    }

    @Test("quick scan aggregates actionable alerts and records last scan date")
    @MainActor
    func quickScanAggregatesAlerts() async throws {
        let persistence = try PersistenceController(inMemory: true)
        try persistence.bootstrap()
        let runDate = Date(timeIntervalSince1970: 8_000)
        let model = MenuBarStatusModel(
            scanner: StubMenuBarStatusScanner(results: [
                makeResult(id: "cache", size: 10_000, safety: .safe, category: "system_cache"),
                makeResult(id: "logs", size: 20_000, safety: .review, category: "system_logs"),
                makeResult(id: "protected", size: 1_000_000, safety: .protected_, category: "system_cache"),
            ]),
            makePersistence: { persistence },
            defaults: try makeDefaults(),
            now: { runDate }
        )

        await model.runQuickScan()

        #expect(model.snapshot.isScanning == false)
        #expect(model.snapshot.lastScanDate == runDate)
        #expect(model.snapshot.reclaimableBytes == 30_000)
        #expect(model.snapshot.pendingAlertCount == 2)
        #expect(model.snapshot.pendingItemCount == 2)
        #expect(try persistence.fetchSettings().lastScanDate == runDate)
    }

    @Test("snoozing alerts hides pending count until refresh")
    @MainActor
    func snoozeAlerts() async throws {
        let persistence = try PersistenceController(inMemory: true)
        try persistence.bootstrap()
        let runDate = Date(timeIntervalSince1970: 9_000)
        let defaults = try makeDefaults()
        let model = MenuBarStatusModel(
            scanner: StubMenuBarStatusScanner(results: [
                makeResult(id: "cache", size: 12_000, safety: .safe, category: "system_cache"),
            ]),
            makePersistence: { persistence },
            defaults: defaults,
            now: { runDate },
            snoozeInterval: 3_600
        )

        await model.runQuickScan()
        model.snoozeAlerts()

        #expect(model.snapshot.reclaimableBytes == 12_000)
        #expect(model.snapshot.pendingAlertCount == 0)
        #expect(model.snapshot.snoozedUntil == runDate.addingTimeInterval(3_600))

        await model.refresh()
        #expect(model.snapshot.pendingAlertCount == 0)
        #expect(model.snapshot.snoozedUntil == runDate.addingTimeInterval(3_600))
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "MenuBarStatusModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeResult(
        id: String,
        size: Int64,
        safety: SafetyLevel,
        category: String
    ) -> ScanResult {
        ScanResult(
            id: id,
            name: id,
            path: "/tmp/\(id)",
            size: size,
            safety: safety,
            confidence: 90,
            explanation: "menu bar test",
            source: SourceAttribution(name: "test"),
            category: category
        )
    }
}

private struct StubMenuBarStatusScanner: MenuBarStatusScanning {
    let results: [ScanResult]

    func scan(profile: CleanupProfile, scanRoots: [URL]?) async throws -> [ScanResult] {
        results
    }
}
