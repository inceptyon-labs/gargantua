import Testing
@testable import GargantuaCore

@Suite("DeepCleanSessionState")
struct DeepCleanSessionStateTests {
    private func makeItem(id: String, safety: SafetyLevel) -> ScanResult {
        ScanResult(
            id: id,
            name: id,
            path: "/tmp/\(id)",
            size: 100,
            safety: safety,
            confidence: 90,
            explanation: "test",
            source: SourceAttribution(name: "Test"),
            category: "test"
        )
    }

    @Test("finishScan stores results and preselects safe items")
    @MainActor
    func finishScanStoresResults() {
        let session = DeepCleanSessionState()
        let results = [
            makeItem(id: "safe", safety: .safe),
            makeItem(id: "review", safety: .review),
            makeItem(id: "protected", safety: .protected_),
        ]

        session.prepareForScan()
        session.finishScan(results: results, duration: 1.25)

        #expect(session.scanResults?.count == 3)
        #expect(session.scanDuration == 1.25)
        #expect(session.selectedResultIDs == Set(["safe"]))
        #expect(!session.isScanning)
    }

    @Test("clearResults keeps the session reusable")
    @MainActor
    func clearResultsResetsResultState() {
        let session = DeepCleanSessionState()
        session.finishScan(results: [makeItem(id: "safe", safety: .safe)], duration: 0.5)
        session.scanProgress.recordError("Stopped scanning Cargo Target Directories")
        session.showConfirmation = true

        session.clearResults()

        #expect(session.scanResults == nil)
        #expect(session.scanDuration == 0)
        #expect(session.scanProgress.errors.isEmpty)
        #expect(session.selectedResultIDs.isEmpty)
        #expect(session.cleanupResult == nil)
        #expect(!session.showConfirmation)
        #expect(session.activeCleanupMethod == .trash)
    }

    @Test("dismissSummary returns to idle when nothing remains after cleanup")
    @MainActor
    func dismissSummaryReturnsToIdleWhenEmpty() {
        let session = DeepCleanSessionState()
        let item = makeItem(id: "safe", safety: .safe)
        session.finishScan(results: [item], duration: 0.5)
        session.scanProgress.recordError("Stopped scanning Cargo Target Directories")
        session.finishCleanup(result: CleanupResult(itemResults: [
            CleanupItemResult(item: item, succeeded: true)
        ]))

        session.dismissSummary()

        #expect(session.phase == .idle)
        #expect(session.scanResults == nil)
        #expect(session.scanDuration == 0)
        #expect(session.scanProgress.errors.isEmpty)
        #expect(session.cleanupResult == nil)
    }

    @Test("finishCleanup drops succeeded items from scanResults")
    @MainActor
    func finishCleanupRemovesCleanedItems() {
        let session = DeepCleanSessionState()
        let cleaned = makeItem(id: "safe", safety: .safe)
        let untouched = makeItem(id: "review", safety: .review)
        session.finishScan(results: [cleaned, untouched], duration: 0.5)
        session.selectedResultIDs = [cleaned.id, untouched.id]

        session.finishCleanup(result: CleanupResult(itemResults: [
            CleanupItemResult(item: cleaned, succeeded: true)
        ]))

        #expect(session.phase == .summary)
        #expect(session.scanResults?.map(\.id) == [untouched.id])
        #expect(session.selectedResultIDs == [untouched.id])
    }

    @Test("dismissSummary returns to results when items remain")
    @MainActor
    func dismissSummaryReturnsToResultsWhenSomeRemain() {
        let session = DeepCleanSessionState()
        let cleaned = makeItem(id: "safe", safety: .safe)
        let untouched = makeItem(id: "review", safety: .review)
        session.finishScan(results: [cleaned, untouched], duration: 1.0)

        session.finishCleanup(result: CleanupResult(itemResults: [
            CleanupItemResult(item: cleaned, succeeded: true)
        ]))
        session.dismissSummary()

        #expect(session.phase == .results)
        #expect(session.scanResults?.map(\.id) == [untouched.id])
        #expect(session.cleanupResult == nil)
        // Scan duration is preserved so the results header still shows
        // when the user resumes triaging the remaining items.
        #expect(session.scanDuration == 1.0)
    }
}
