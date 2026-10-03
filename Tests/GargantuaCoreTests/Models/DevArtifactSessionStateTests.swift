import Testing
@testable import GargantuaCore

@Suite("DevArtifactSessionState")
struct DevArtifactSessionStateTests {
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

    @Test("finishScan stores results, estimates, and preselects safe items")
    @MainActor
    func finishScanStoresResults() {
        let session = DevArtifactSessionState()
        let results = [
            makeItem(id: "safe", safety: .safe),
            makeItem(id: "review", safety: .review),
        ]

        session.prepareForScan()
        #expect(session.isScanRequested)
        #expect(session.phase == .scanning)

        session.finishScan(results: results, duration: 1.25, estimates: ["node": 100])

        #expect(session.phase == .results)
        #expect(session.scanResults?.count == 2)
        #expect(session.scanDuration == 1.25)
        #expect(session.selectedResultIDs == Set(["safe"]))
        #expect(session.bucketEstimates == ["node": 100])
        #expect(!session.isScanRequested)
    }

    @Test("mid-clean state survives outside the view: cleaning phase holds until finishCleanup lands the summary")
    @MainActor
    func cleanupCompletionLandsInSession() {
        let session = DevArtifactSessionState()
        let item = makeItem(id: "safe", safety: .safe)
        session.finishScan(results: [item], duration: 0.5, estimates: [:])
        session.showConfirmation = true

        session.beginCleanup(method: .trash)

        // While the clean runs, the session renders the cleaning console —
        // a nav away-and-back cannot reach the idle screen to start a
        // second overlapping clean.
        #expect(session.phase == .cleaning)
        #expect(session.isCleaning)
        #expect(!session.showConfirmation)

        let result = CleanupResult(itemResults: [
            CleanupItemResult(item: item, succeeded: true)
        ])
        session.finishCleanup(result: result)

        #expect(session.phase == .summary)
        #expect(!session.isCleaning)
        #expect(session.cleanupResult != nil)
    }

    @Test("severTether cancels the in-flight task and rewinds to idle")
    @MainActor
    func severTetherCancelsAndResets() async {
        let session = DevArtifactSessionState()
        session.finishScan(
            results: [makeItem(id: "safe", safety: .safe)],
            duration: 0.5,
            estimates: [:]
        )
        session.beginCleanup(method: .delete)
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                await Task.yield()
            }
        }
        session.activeTask = task

        session.severTether()
        await task.value

        #expect(task.isCancelled)
        #expect(session.activeTask == nil)
        #expect(session.phase == .idle)
        #expect(!session.isCleaning)
        #expect(session.scanResults == nil)
        #expect(session.cleanupResult == nil)
        #expect(session.activeCleanupMethod == .trash)
    }

    @Test("prepareForScan cancels a superseded scan task")
    @MainActor
    func prepareForScanCancelsPriorTask() async {
        let session = DevArtifactSessionState()
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                await Task.yield()
            }
        }
        session.activeTask = task

        session.prepareForScan()
        await task.value

        #expect(task.isCancelled)
    }

    @Test("returnToIdle and dismissSummary keep bucket selection and detection state")
    @MainActor
    func navigationBackKeepsBucketState() {
        let session = DevArtifactSessionState()
        session.detectionState = .complete
        session.detectedEcosystemIDs = ["node"]
        session.selectedBucketIDs = ["node", "logs"]
        session.finishScan(
            results: [makeItem(id: "safe", safety: .safe)],
            duration: 0.5,
            estimates: ["node": 100]
        )
        session.showConfirmation = true

        session.returnToIdle()

        #expect(session.phase == .idle)
        #expect(session.scanResults == nil)
        // A stale confirmation flag would replay the modal over the next
        // scan's fresh results.
        #expect(!session.showConfirmation)
        #expect(session.detectionState == .complete)
        #expect(session.selectedBucketIDs == ["node", "logs"])
        #expect(session.bucketEstimates == ["node": 100])

        session.finishScan(results: [], duration: 0.1, estimates: [:])
        session.showConfirmation = true
        session.finishCleanup(result: CleanupResult(itemResults: []))
        session.dismissSummary()

        #expect(session.phase == .idle)
        #expect(session.cleanupResult == nil)
        #expect(!session.showConfirmation)
        #expect(session.detectedEcosystemIDs == ["node"])
        #expect(session.selectedBucketIDs == ["node", "logs"])
    }

    @Test("After a cleanup, Done returns to the remaining results")
    @MainActor
    func dismissSummaryKeepsRemainingResults() {
        let session = DevArtifactSessionState()
        let cleaned = makeItem(id: "cleaned", safety: .safe)
        let remaining = makeItem(id: "remaining", safety: .review)
        session.finishScan(results: [cleaned, remaining], duration: 0.5, estimates: [:])
        session.selectedResultIDs = [cleaned.id]

        session.finishCleanup(result: CleanupResult(itemResults: [CleanupItemResult(item: cleaned, succeeded: true)]))
        session.dismissSummary()

        #expect(session.phase == .results)
        #expect(session.scanResults?.map(\.id) == [remaining.id])
        #expect(session.selectedResultIDs.isEmpty)
    }

    @Test("prepareForScan clears a lingering confirmation flag")
    @MainActor
    func prepareForScanClearsConfirmation() {
        let session = DevArtifactSessionState()
        session.finishScan(
            results: [makeItem(id: "safe", safety: .safe)],
            duration: 0.5,
            estimates: [:]
        )
        session.showConfirmation = true

        session.prepareForScan()

        #expect(!session.showConfirmation)
        #expect(session.phase == .scanning)
    }

    @Test("failScan records the error and returns to idle")
    @MainActor
    func failScanRecordsError() {
        let session = DevArtifactSessionState()
        session.prepareForScan()

        session.failScan("boom")

        #expect(session.phase == .idle)
        #expect(!session.isScanRequested)
        #expect(session.scanProgress.errors == ["boom"])
    }
}
