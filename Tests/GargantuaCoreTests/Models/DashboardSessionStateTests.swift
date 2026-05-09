import Foundation
import Testing
@testable import GargantuaCore

@Suite("DashboardSessionState")
struct DashboardSessionStateTests {
    private func makeAlert(
        category: String,
        bytes: Int64,
        items: Int,
        destination: AlertDestination
    ) -> AlertItem {
        AlertItem(
            id: "alert_\(category)",
            reclaimableSize: bytes,
            itemCount: items,
            category: category,
            categoryLabel: category,
            destination: destination
        )
    }

    private func makeScanResult(id: String, category: String, size: Int64) -> ScanResult {
        ScanResult(
            id: id,
            name: id,
            path: "/tmp/\(id)",
            size: size,
            safety: .safe,
            confidence: 90,
            explanation: "test",
            source: SourceAttribution(name: "Test"),
            category: category
        )
    }

    private func makeCleanupResult(_ items: [ScanResult]) -> CleanupResult {
        CleanupResult(
            itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
            cleanupMethod: .trash
        )
    }

    @Test("applyCleanupDelta subtracts freed bytes and items from matching alert")
    @MainActor
    func subtractsFromMatchingAlert() {
        let session = DashboardSessionState()
        session.alerts = [
            makeAlert(category: "trash", bytes: 10_000_000_000, items: 300, destination: .deepClean),
            makeAlert(category: "dev_artifacts", bytes: 5_000_000_000, items: 50, destination: .devPurge),
        ]

        let cleared = makeCleanupResult([
            makeScanResult(id: "t1", category: "trash", size: 3_000_000_000),
            makeScanResult(id: "t2", category: "trash", size: 1_000_000_000),
        ])
        session.applyCleanupDelta(cleared)

        let trash = session.alerts.first { $0.category == "trash" }
        #expect(trash?.reclaimableSize == 6_000_000_000)
        #expect(trash?.itemCount == 298)

        let dev = session.alerts.first { $0.category == "dev_artifacts" }
        #expect(dev?.reclaimableSize == 5_000_000_000)
        #expect(dev?.itemCount == 50)
    }

    @Test("applyCleanupDelta drops alerts that are fully cleared")
    @MainActor
    func dropsFullyClearedAlerts() {
        let session = DashboardSessionState()
        session.alerts = [
            makeAlert(category: "trash", bytes: 4_000_000_000, items: 2, destination: .deepClean),
            makeAlert(category: "dev_artifacts", bytes: 5_000_000_000, items: 50, destination: .devPurge),
        ]

        let cleared = makeCleanupResult([
            makeScanResult(id: "t1", category: "trash", size: 2_000_000_000),
            makeScanResult(id: "t2", category: "trash", size: 2_000_000_000),
        ])
        session.applyCleanupDelta(cleared)

        #expect(session.alerts.count == 1)
        #expect(session.alerts.first?.category == "dev_artifacts")
    }

    @Test("applyCleanupDelta re-sorts remaining alerts by reclaimable size")
    @MainActor
    func reSortsBySize() {
        let session = DashboardSessionState()
        session.alerts = [
            makeAlert(category: "trash", bytes: 10_000_000_000, items: 300, destination: .deepClean),
            makeAlert(category: "dev_artifacts", bytes: 5_000_000_000, items: 50, destination: .devPurge),
        ]

        // Free 8 GB out of trash → trash drops to 2 GB, dev_artifacts (5 GB) should now lead.
        let cleared = makeCleanupResult([
            makeScanResult(id: "t1", category: "trash", size: 8_000_000_000),
        ])
        session.applyCleanupDelta(cleared)

        #expect(session.alerts.first?.category == "dev_artifacts")
        #expect(session.alerts.last?.category == "trash")
    }

    @Test("applyCleanupDelta ignores categories with no matching alert")
    @MainActor
    func ignoresUnmatchedCategories() {
        let session = DashboardSessionState()
        session.alerts = [
            makeAlert(category: "trash", bytes: 4_000_000_000, items: 2, destination: .deepClean),
        ]

        let cleared = makeCleanupResult([
            makeScanResult(id: "x", category: "uninstall_remnants", size: 1_000_000_000),
        ])
        session.applyCleanupDelta(cleared)

        #expect(session.alerts.count == 1)
        #expect(session.alerts.first?.reclaimableSize == 4_000_000_000)
    }

    @Test("applyCleanupDelta ignores failed cleanup items")
    @MainActor
    func ignoresFailedItems() {
        let session = DashboardSessionState()
        session.alerts = [
            makeAlert(category: "trash", bytes: 4_000_000_000, items: 2, destination: .deepClean),
        ]

        let result = CleanupResult(
            itemResults: [
                CleanupItemResult(
                    item: makeScanResult(id: "t1", category: "trash", size: 4_000_000_000),
                    succeeded: false,
                    error: "permission denied"
                ),
            ],
            cleanupMethod: .trash
        )
        session.applyCleanupDelta(result)

        #expect(session.alerts.first?.reclaimableSize == 4_000_000_000)
        #expect(session.alerts.first?.itemCount == 2)
    }
}
