import Testing
import Foundation
@testable import GargantuaCore

@Suite("AlertItem")
struct AlertItemTests {
    // Fixed reference date: 2026-04-14
    static let referenceDate = Date(timeIntervalSince1970: 1_776_326_400)
    // 45 days before reference
    static let staleDate = Calendar.current.date(byAdding: .day, value: -45, to: referenceDate)!
    // 3 days before reference
    static let freshDate = Calendar.current.date(byAdding: .day, value: -3, to: referenceDate)!

    static func makeScanResult(
        id: String = "item_001",
        category: String = "dev_artifacts",
        size: Int64 = 5_000_000_000,
        safety: SafetyLevel = .safe,
        lastAccessed: Date? = nil
    ) -> ScanResult {
        ScanResult(
            id: id,
            name: "Test Item",
            path: "/tmp/test",
            size: size,
            safety: safety,
            confidence: 95,
            explanation: "Test item.",
            source: SourceAttribution(name: "Test"),
            lastAccessed: lastAccessed,
            category: category
        )
    }

    // MARK: - Size Formatting

    @Test("formatBytes: zero bytes")
    func formatZero() {
        #expect(AlertItem.formatBytes(0) == "0 bytes")
    }

    @Test("formatBytes: small bytes")
    func formatSmallBytes() {
        #expect(AlertItem.formatBytes(512) == "512 bytes")
    }

    @Test("formatBytes: kilobytes")
    func formatKilobytes() {
        #expect(AlertItem.formatBytes(4_200) == "4.2 KB")
        #expect(AlertItem.formatBytes(15_000) == "15 KB")
    }

    @Test("formatBytes: megabytes")
    func formatMegabytes() {
        #expect(AlertItem.formatBytes(5_500_000) == "5.5 MB")
        #expect(AlertItem.formatBytes(128_000_000) == "128 MB")
    }

    @Test("formatBytes: gigabytes")
    func formatGigabytes() {
        #expect(AlertItem.formatBytes(23_400_000_000) == "23 GB")
        #expect(AlertItem.formatBytes(1_500_000_000) == "1.5 GB")
    }

    @Test("formatBytes: terabytes")
    func formatTerabytes() {
        #expect(AlertItem.formatBytes(2_500_000_000_000) == "2.5 TB")
    }

    // MARK: - Headline

    @Test("headline with staleness qualifier")
    func headlineWithStaleness() {
        let alert = AlertItem(
            id: "alert_dev",
            reclaimableSize: 23_000_000_000,
            itemCount: 15,
            category: "dev_artifacts",
            categoryLabel: "stale dev artifacts",
            staleness: ">30 days",
            destination: .devPurge
        )
        #expect(alert.headline == "23 GB of stale dev artifacts (>30 days)")
    }

    @Test("headline without staleness")
    func headlineWithoutStaleness() {
        let alert = AlertItem(
            id: "alert_cache",
            reclaimableSize: 1_500_000_000,
            itemCount: 3,
            category: "browser_cache",
            categoryLabel: "browser cache",
            destination: .deepClean
        )
        #expect(alert.headline == "1.5 GB of browser cache")
    }

    @Test("detail singular and plural")
    func detailText() {
        let single = AlertItem(
            id: "a", reclaimableSize: 100, itemCount: 1,
            category: "test", categoryLabel: "test", destination: .deepClean
        )
        let multiple = AlertItem(
            id: "b", reclaimableSize: 100, itemCount: 45,
            category: "test", categoryLabel: "test", destination: .deepClean
        )
        #expect(single.detail == "1 item")
        #expect(multiple.detail == "45 items")
    }

    // MARK: - Aggregation

    @Test("aggregate groups by category")
    func aggregateGroupsByCategory() {
        let results = [
            Self.makeScanResult(id: "a", category: "browser_cache", size: 1_000_000_000),
            Self.makeScanResult(id: "b", category: "browser_cache", size: 2_000_000_000),
            Self.makeScanResult(id: "c", category: "dev_artifacts", size: 5_000_000_000),
        ]
        let alerts = AlertItem.aggregate(from: results, referenceDate: Self.referenceDate)

        #expect(alerts.count == 2)
        // Sorted by size descending — dev_artifacts (5 GB) first
        #expect(alerts[0].category == "dev_artifacts")
        #expect(alerts[0].reclaimableSize == 5_000_000_000)
        #expect(alerts[0].itemCount == 1)
        #expect(alerts[1].category == "browser_cache")
        #expect(alerts[1].reclaimableSize == 3_000_000_000)
        #expect(alerts[1].itemCount == 2)
    }

    @Test("aggregate excludes protected items")
    func aggregateExcludesProtected() {
        let results = [
            Self.makeScanResult(id: "a", category: "system_cache", size: 1_000_000_000, safety: .safe),
            Self.makeScanResult(id: "b", category: "system_cache", size: 2_000_000_000, safety: .protected_),
        ]
        let alerts = AlertItem.aggregate(from: results, referenceDate: Self.referenceDate)

        #expect(alerts.count == 1)
        #expect(alerts[0].reclaimableSize == 1_000_000_000)
        #expect(alerts[0].itemCount == 1)
    }

    @Test("aggregate includes review items")
    func aggregateIncludesReview() {
        let results = [
            Self.makeScanResult(id: "a", category: "dev_artifacts", size: 1_000_000_000, safety: .review),
        ]
        let alerts = AlertItem.aggregate(from: results, referenceDate: Self.referenceDate)

        #expect(alerts.count == 1)
        #expect(alerts[0].reclaimableSize == 1_000_000_000)
    }

    @Test("aggregate returns empty for no actionable results")
    func aggregateEmptyForProtectedOnly() {
        let results = [
            Self.makeScanResult(id: "a", safety: .protected_),
        ]
        let alerts = AlertItem.aggregate(from: results, referenceDate: Self.referenceDate)
        #expect(alerts.isEmpty)
    }

    @Test("aggregate returns empty for empty input")
    func aggregateEmptyInput() {
        let alerts = AlertItem.aggregate(from: [], referenceDate: Self.referenceDate)
        #expect(alerts.isEmpty)
    }

    // MARK: - Staleness

    @Test("staleness computed for items older than 7 days")
    func stalenessComputed() {
        let results = [
            Self.makeScanResult(id: "a", category: "dev_artifacts", size: 5_000_000_000,
                                lastAccessed: Self.staleDate),
        ]
        let alerts = AlertItem.aggregate(from: results, referenceDate: Self.referenceDate)

        #expect(alerts.count == 1)
        #expect(alerts[0].staleness == ">1 month")
        #expect(alerts[0].categoryLabel.hasPrefix("stale"))
    }

    @Test("no staleness for fresh items")
    func noStalenessForFreshItems() {
        let results = [
            Self.makeScanResult(id: "a", category: "dev_artifacts", size: 5_000_000_000,
                                lastAccessed: Self.freshDate),
        ]
        let alerts = AlertItem.aggregate(from: results, referenceDate: Self.referenceDate)

        #expect(alerts.count == 1)
        #expect(alerts[0].staleness == nil)
        #expect(!alerts[0].categoryLabel.hasPrefix("stale"))
    }

    @Test("no staleness when lastAccessed is nil")
    func noStalenessWhenNoDate() {
        let results = [
            Self.makeScanResult(id: "a", category: "dev_artifacts", size: 5_000_000_000,
                                lastAccessed: nil),
        ]
        let alerts = AlertItem.aggregate(from: results, referenceDate: Self.referenceDate)

        #expect(alerts.count == 1)
        #expect(alerts[0].staleness == nil)
    }

    @Test("staleness uses most recent access date in group")
    func stalenessUsesNewest() {
        let results = [
            Self.makeScanResult(id: "a", category: "dev_artifacts", size: 1_000_000_000,
                                lastAccessed: Self.staleDate),
            Self.makeScanResult(id: "b", category: "dev_artifacts", size: 1_000_000_000,
                                lastAccessed: Self.freshDate),
        ]
        let alerts = AlertItem.aggregate(from: results, referenceDate: Self.referenceDate)

        // Fresh item (3 days) pulls the group below the 7-day threshold
        #expect(alerts[0].staleness == nil)
    }

    // MARK: - Destinations

    @Test("category-to-destination mapping")
    func categoryDestinationMapping() {
        let categories: [(String, AlertDestination)] = [
            ("browser_cache", .deepClean),
            ("dev_artifacts", .devPurge),
            ("docker", .devPurge),
            ("homebrew", .devPurge),
            ("system_logs", .deepClean),
            ("trash", .deepClean),
        ]

        for (category, expectedDest) in categories {
            let results = [Self.makeScanResult(id: category, category: category, size: 1_000)]
            let alerts = AlertItem.aggregate(from: results, referenceDate: Self.referenceDate)
            #expect(alerts.first?.destination == expectedDest,
                    "Expected \(category) → \(expectedDest)")
        }
    }

    @Test("unknown category defaults to deepClean")
    func unknownCategoryDefaults() {
        let results = [Self.makeScanResult(id: "x", category: "exotic_stuff", size: 1_000)]
        let alerts = AlertItem.aggregate(from: results, referenceDate: Self.referenceDate)
        #expect(alerts.first?.destination == .deepClean)
        #expect(alerts.first?.categoryLabel == "exotic stuff")
    }

    // MARK: - Sort Order

    @Test("alerts sorted by reclaimable size descending")
    func sortOrder() {
        let results = [
            Self.makeScanResult(id: "a", category: "browser_cache", size: 1_000_000_000),
            Self.makeScanResult(id: "b", category: "dev_artifacts", size: 10_000_000_000),
            Self.makeScanResult(id: "c", category: "system_logs", size: 500_000_000),
        ]
        let alerts = AlertItem.aggregate(from: results, referenceDate: Self.referenceDate)

        #expect(alerts.map(\.category) == ["dev_artifacts", "browser_cache", "system_logs"])
    }
}
