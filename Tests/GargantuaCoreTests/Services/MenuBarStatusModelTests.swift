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

    @Test("refreshes reuse one store and still see summaries written after the first refresh")
    @MainActor
    func refreshReusesStoreAndSeesNewWrites() async throws {
        let persistence = try PersistenceController(inMemory: true)
        try persistence.bootstrap()
        var opens = 0
        let model = MenuBarStatusModel(
            scanner: StubMenuBarStatusScanner(results: []),
            makePersistence: {
                opens += 1
                return persistence
            },
            defaults: try makeDefaults(),
            now: { Date(timeIntervalSince1970: 5_100) }
        )

        await model.refresh()
        #expect(model.snapshot.pendingItemCount == 0)

        try persistence.freshReader().recordScheduledScanSummary(ScheduledScanSummary(
            date: Date(timeIntervalSince1970: 5_000),
            profileID: "light",
            itemCount: 3,
            reclaimableBytes: 9_000
        ))
        await model.refresh()
        await model.refresh()

        #expect(opens == 1)
        #expect(model.snapshot.pendingItemCount == 3)
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

    @Test("reopening the popover mid-scan keeps the scan state and blocks a second scan")
    @MainActor
    func refreshDuringQuickScanKeepsScanning() async throws {
        let persistence = try PersistenceController(inMemory: true)
        try persistence.bootstrap()
        let scanner = GatedMenuBarStatusScanner()
        let model = MenuBarStatusModel(
            scanner: scanner,
            makePersistence: { persistence },
            defaults: try makeDefaults()
        )

        let first = Task { await model.runQuickScan() }
        while scanner.callCount == 0 { await Task.yield() }

        await model.refresh()
        #expect(model.snapshot.isScanning)
        let second = Task { await model.runQuickScan() }
        for _ in 0 ..< 100 { await Task.yield() }
        #expect(scanner.callCount == 1)

        scanner.open()
        await first.value
        await second.value
        #expect(!model.snapshot.isScanning)
    }

    @Test("quick scan leaves excluded paths out of the totals")
    @MainActor
    func quickScanAppliesExclusions() async throws {
        let persistence = try PersistenceController(inMemory: true)
        try persistence.bootstrap()
        try persistence.addExclusionEntry(pattern: "/tmp/excluded")
        let model = MenuBarStatusModel(
            scanner: StubMenuBarStatusScanner(results: [
                makeResult(id: "cache", size: 10_000, safety: .safe, category: "system_cache"),
                makeResult(id: "excluded", size: 40_000, safety: .safe, category: "system_cache"),
            ]),
            makePersistence: { persistence },
            defaults: try makeDefaults(),
            now: { Date(timeIntervalSince1970: 8_000) }
        )

        await model.runQuickScan()

        #expect(model.snapshot.reclaimableBytes == 10_000)
        #expect(model.snapshot.pendingItemCount == 1)
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
        let defaults = TestDefaults.suite(suiteName)
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

/// Holds every scan until `open()`, so a test can act while one is running.
private final class GatedMenuBarStatusScanner: MenuBarStatusScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var callCount: Int { lock.withLock { calls } }

    func scan(profile: CleanupProfile, scanRoots: [URL]?) async throws -> [ScanResult] {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                calls += 1
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return []
    }

    func open() {
        let resumable = lock.withLock {
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        resumable.forEach { $0.resume() }
    }
}
