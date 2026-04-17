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

    @Test("dismissSummary clears stale scan warnings")
    @MainActor
    func dismissSummaryClearsWarnings() {
        let session = DeepCleanSessionState()
        session.finishScan(results: [makeItem(id: "safe", safety: .safe)], duration: 0.5)
        session.scanProgress.recordError("Stopped scanning Cargo Target Directories")
        session.finishCleanup(result: CleanupResult(itemResults: []))

        session.dismissSummary()

        #expect(session.scanResults == nil)
        #expect(session.scanDuration == 0)
        #expect(session.scanProgress.errors.isEmpty)
        #expect(session.cleanupResult == nil)
    }
}
