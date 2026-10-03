import Testing
@testable import GargantuaCore

@Suite("AIModelsState")
struct AIModelsStateTests {
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

    @Test("cancelScan stops the scan and returns to idle")
    @MainActor
    func cancelScanReturnsToIdle() {
        let state = AIModelsState()
        state.prepareForScan()
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        state.activeScanTask = task

        state.cancelScan()

        #expect(state.phase == .idle)
        #expect(!state.isScanning)
        #expect(task.isCancelled)
    }

    @Test("prepareForScan moves to scanning and clears prior results")
    @MainActor
    func prepareForScanResetsState() {
        let state = AIModelsState()
        state.finishScan(results: [makeItem(id: "a", safety: .safe)], duration: 1.0)
        state.selectedResultIDs = ["a"]
        state.showConfirmation = true

        state.prepareForScan()

        #expect(state.phase == .scanning)
        #expect(state.isScanning)
        #expect(state.scanResults == nil)
        #expect(state.selectedResultIDs.isEmpty)
        #expect(state.cleanupResult == nil)
        #expect(!state.showConfirmation)
    }

    @Test("finishScan stores results and preselects safe items")
    @MainActor
    func finishScanPreselectsSafe() {
        let state = AIModelsState()
        let results = [
            makeItem(id: "safe", safety: .safe),
            makeItem(id: "review", safety: .review),
            makeItem(id: "protected", safety: .protected_),
        ]

        state.prepareForScan()
        state.finishScan(results: results, duration: 2.5)

        #expect(state.scanResults?.count == 3)
        #expect(state.scanDuration == 2.5)
        #expect(state.selectedResultIDs == Set(["safe"]))
        #expect(!state.isScanning)
        #expect(state.phase == .results)
    }

    @Test("failScan records the error and returns to idle")
    @MainActor
    func failScanReturnsToIdle() {
        let state = AIModelsState()
        state.prepareForScan()

        state.failScan("model probe failed")

        #expect(!state.isScanning)
        #expect(state.phase == .idle)
        #expect(state.scanProgress.errors.contains("model probe failed"))
    }

    @Test("beginCleanup transitions to cleaning with the chosen method")
    @MainActor
    func beginCleanupSetsMethod() {
        let state = AIModelsState()
        state.showConfirmation = true

        state.beginCleanup(method: .delete)

        #expect(state.isCleaning)
        #expect(state.phase == .cleaning)
        #expect(state.activeCleanupMethod == .delete)
        #expect(!state.showConfirmation)
    }

    @Test("finishCleanup stores the result and shows the summary")
    @MainActor
    func finishCleanupShowsSummary() {
        let state = AIModelsState()
        let item = makeItem(id: "safe", safety: .safe)
        state.beginCleanup(method: .trash)

        let result = CleanupResult(itemResults: [CleanupItemResult(item: item, succeeded: true)])
        state.finishCleanup(result: result)

        #expect(!state.isCleaning)
        #expect(state.phase == .summary)
        #expect(state.cleanupResult != nil)
    }

    @Test("clearResults returns the state to a reusable idle baseline")
    @MainActor
    func clearResultsResets() {
        let state = AIModelsState()
        state.finishScan(results: [makeItem(id: "safe", safety: .safe)], duration: 3.0)
        state.scanProgress.recordError("boom")
        state.showConfirmation = true
        state.activeCleanupMethod = .delete

        state.clearResults()

        #expect(state.scanResults == nil)
        #expect(state.scanDuration == 0)
        #expect(state.selectedResultIDs.isEmpty)
        #expect(state.cleanupResult == nil)
        #expect(!state.showConfirmation)
        #expect(state.activeCleanupMethod == .trash)
        #expect(state.phase == .idle)
    }

    @Test("cleanup drops only succeeded items and dismiss returns to results when some remain")
    @MainActor
    func cleanupFiltersInPlaceAndReturnsToResults() {
        let state = AIModelsState()
        let kept = makeItem(id: "kept", safety: .review)
        let removed = makeItem(id: "removed", safety: .safe)
        state.finishScan(results: [kept, removed], duration: 1.0)
        state.selectedResultIDs = ["removed"]
        state.beginCleanup(method: .trash)
        state.finishCleanup(result: CleanupResult(itemResults: [
            CleanupItemResult(item: removed, succeeded: true),
        ]))

        // Cleaned item is gone from the list immediately; selection cleared.
        #expect(state.scanResults?.map(\.id) == ["kept"])
        #expect(!state.selectedResultIDs.contains("removed"))
        #expect(state.phase == .summary)

        state.dismissSummary()

        // Back to the results list, not the idle screen, with the row removed.
        #expect(state.phase == .results)
        #expect(state.scanResults?.map(\.id) == ["kept"])
        #expect(state.cleanupResult == nil)
    }

    @Test("pruneCleaned (retry path) removes recovered items without leaving the summary")
    @MainActor
    func pruneCleanedKeepsSummaryPhase() {
        let state = AIModelsState()
        let kept = makeItem(id: "kept", safety: .review)
        let stillFailed = makeItem(id: "stuck", safety: .safe)
        let recovered = makeItem(id: "recovered", safety: .safe)
        state.finishScan(results: [kept, stillFailed, recovered], duration: 1.0)
        // Simulate a partial clean that left two items failed, then showed the summary.
        state.finishCleanup(result: CleanupResult(itemResults: [
            CleanupItemResult(item: stillFailed, succeeded: false, error: "Operation not permitted"),
            CleanupItemResult(item: recovered, succeeded: false, error: "Operation not permitted"),
        ]))
        #expect(state.phase == .summary)
        #expect(state.scanResults?.map(\.id) == ["kept", "stuck", "recovered"])

        // A retry recovers "recovered" — onRetried calls pruneCleaned.
        state.pruneCleaned(CleanupResult(itemResults: [
            CleanupItemResult(item: recovered, succeeded: true),
        ]))

        #expect(state.scanResults?.map(\.id) == ["kept", "stuck"]) // pruned in place
        #expect(state.phase == .summary) // still on the summary, not bounced away
    }

    @Test("dismissSummary clears everything back to idle when nothing remains")
    @MainActor
    func dismissSummaryReturnsToIdle() {
        let state = AIModelsState()
        let item = makeItem(id: "safe", safety: .safe)
        state.finishScan(results: [item], duration: 1.0)
        state.beginCleanup(method: .trash)
        state.finishCleanup(result: CleanupResult(itemResults: [
            CleanupItemResult(item: item, succeeded: true)
        ]))

        state.dismissSummary()

        #expect(state.phase == .idle)
        #expect(state.scanResults == nil)
        #expect(state.scanDuration == 0)
        #expect(state.cleanupResult == nil)
        #expect(state.selectedResultIDs.isEmpty)
        #expect(state.activeCleanupMethod == .trash)
    }
}
