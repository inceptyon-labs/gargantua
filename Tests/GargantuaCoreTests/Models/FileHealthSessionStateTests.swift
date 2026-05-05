import Foundation
import Testing
@testable import GargantuaCore

// MARK: - Fixture

private func makeCzkawkaResult(
    category: CzkawkaCategory,
    counter: Int,
    safety: SafetyLevel? = nil,
    size: Int64 = 1_024
) -> ScanResult {
    let entry = CzkawkaTrustDefaults.builtIn.entry(for: category)
    let resolvedSafety = safety ?? entry.safety
    let path = "/tmp/fixture/\(category.rawValue)/\(counter)"
    return ScanResult(
        id: "czkawka-\(category.rawValue)-\(counter)",
        name: (path as NSString).lastPathComponent,
        path: path,
        size: size,
        safety: resolvedSafety,
        confidence: entry.confidence,
        explanation: entry.explanation,
        source: SourceAttribution(name: "Czkawka"),
        category: category.resultCategory,
        tags: []
    )
}

// MARK: - FileHealthSessionState

@Suite("FileHealthSessionState")
struct FileHealthSessionStateTests {

    @Test("finishScan starts with an empty selection (no silent auto-preselect)")
    @MainActor
    func finishScanStartsEmpty() {
        // Regression: auto-preselecting every .safe item across all tabs
        // produced "Send 3024 items" surprises once the czkawka 11 parser
        // started returning real findings for empty-files / temp / symlinks.
        // Selection stays empty; bulk picks live behind explicit per-tab UI.
        let session = FileHealthSessionState()
        let results = [
            makeCzkawkaResult(category: .emptyFiles, counter: 0), // would have been auto-selected
            makeCzkawkaResult(category: .brokenSymlinks, counter: 1), // would have been auto-selected
            makeCzkawkaResult(category: .bigFiles, counter: 2),
            makeCzkawkaResult(category: .similarImages, counter: 3),
        ]

        session.finishScan(results: results)

        #expect(session.selectedResultIDs.isEmpty)
    }

    @Test("toggleSelection flips membership idempotently")
    @MainActor
    func toggleFlipsMembership() {
        let session = FileHealthSessionState()
        let results = [makeCzkawkaResult(category: .bigFiles, counter: 0)]
        let id = results[0].id

        session.finishScan(results: results)
        #expect(session.isSelected(id) == false)

        session.toggleSelection(for: id)
        #expect(session.isSelected(id) == true)

        session.toggleSelection(for: id)
        #expect(session.isSelected(id) == false)
    }

    @Test("Selections persist across tab switches (session state survives regrouping)")
    @MainActor
    func selectionsPersistAcrossTabSwitches() {
        let session = FileHealthSessionState()
        let results = [
            makeCzkawkaResult(category: .emptyFiles, counter: 0),
            makeCzkawkaResult(category: .bigFiles, counter: 1),
            makeCzkawkaResult(category: .similarImages, counter: 2),
        ]
        session.finishScan(results: results)

        // User explicitly opts items into selection in different tabs.
        session.toggleSelection(for: "czkawka-emptyFiles-0")
        session.toggleSelection(for: "czkawka-bigFiles-1")

        let regrouped = FileHealthGrouper.group(results)
        #expect(regrouped.count == 3)
        #expect(session.isSelected("czkawka-emptyFiles-0"))
        #expect(session.isSelected("czkawka-bigFiles-1"))
        #expect(!session.isSelected("czkawka-similarImages-2"))
    }

    @Test("selectAll unions ids; deselectAll subtracts them; both leave other tabs alone")
    @MainActor
    func tabScopedBulkHelpers() {
        let session = FileHealthSessionState()
        let bigFilesIDs = ["czkawka-bigFiles-0", "czkawka-bigFiles-1", "czkawka-bigFiles-2"]
        let emptyFilesIDs = ["czkawka-emptyFiles-0"]

        // Pre-existing selection in another tab.
        session.toggleSelection(for: emptyFilesIDs[0])

        session.selectAll(bigFilesIDs)
        #expect(session.selectedResultIDs == Set(bigFilesIDs + emptyFilesIDs))

        session.deselectAll(bigFilesIDs)
        // Big Files cleared, Empty Files selection in the other tab survives.
        #expect(session.selectedResultIDs == Set(emptyFilesIDs))
    }

    @Test("clear wipes selection (used when a new scan starts)")
    @MainActor
    func clearWipesSelection() {
        let session = FileHealthSessionState()
        session.toggleSelection(for: "czkawka-emptyFiles-0")
        session.toggleSelection(for: "czkawka-brokenSymlinks-1")
        #expect(!session.selectedResultIDs.isEmpty)

        session.clear()
        #expect(session.selectedResultIDs.isEmpty)
    }
}

// MARK: - FileHealthCategoryTab Aggregates

@Suite("FileHealthCategoryTab selection aggregates")
struct FileHealthCategoryTabSelectionTests {

    @Test("selectedCount counts only findings present in the selection set")
    func selectedCountFiltersByID() {
        let findings = [
            makeCzkawkaResult(category: .emptyFiles, counter: 0, size: 100),
            makeCzkawkaResult(category: .emptyFiles, counter: 1, size: 200),
            makeCzkawkaResult(category: .emptyFiles, counter: 2, size: 400),
        ]
        let tab = FileHealthCategoryTab(
            category: .emptyFiles,
            safety: .safe,
            findings: findings
        )

        let selection: Set<String> = [
            "czkawka-emptyFiles-0",
            "czkawka-emptyFiles-2",
            "ignored-id", // IDs outside the tab should not count
        ]

        #expect(tab.selectedCount(in: selection) == 2)
        #expect(tab.selectedCount(in: []) == 0)
    }

    @Test("selectedBytes sums sizes only for selected IDs and saturates on overflow")
    func selectedBytesSumsAndSaturates() {
        let almostMax = Int64.max - 100
        let findings = [
            makeCzkawkaResult(category: .bigFiles, counter: 0, size: almostMax),
            makeCzkawkaResult(category: .bigFiles, counter: 1, size: 500),
            makeCzkawkaResult(category: .bigFiles, counter: 2, size: 1_000),
        ]
        let tab = FileHealthCategoryTab(
            category: .bigFiles,
            safety: .review,
            findings: findings
        )

        // Partial selection: first + second → overflows, must saturate.
        let overflowing: Set<String> = [
            "czkawka-bigFiles-0",
            "czkawka-bigFiles-1",
        ]
        #expect(tab.selectedBytes(in: overflowing) == Int64.max)

        // Non-overflowing partial selection returns the exact sum.
        let safe: Set<String> = ["czkawka-bigFiles-1", "czkawka-bigFiles-2"]
        #expect(tab.selectedBytes(in: safe) == 1_500)

        // Empty selection yields zero.
        #expect(tab.selectedBytes(in: []) == 0)
    }
}

// MARK: - FileHealthCleanupFlow

@Suite("FileHealthCleanupFlow")
struct FileHealthCleanupFlowTests {

    @Test("selectedResults preserves scan order and filters by selected ids")
    func selectedResultsFiltersBySelection() {
        let results = [
            makeCzkawkaResult(category: .emptyFiles, counter: 0),
            makeCzkawkaResult(category: .bigFiles, counter: 1),
            makeCzkawkaResult(category: .similarImages, counter: 2),
        ]

        let selected = FileHealthCleanupFlow.selectedResults(
            from: results,
            selectedIDs: ["czkawka-similarImages-2", "czkawka-emptyFiles-0"]
        )

        #expect(selected.map(\.id) == [
            "czkawka-emptyFiles-0",
            "czkawka-similarImages-2",
        ])
    }

    @Test("confirmation tier matches highest-risk selected File Health item")
    func confirmationTierMatchesSelectedRisk() {
        let results = [
            makeCzkawkaResult(category: .emptyFiles, counter: 0, safety: .safe),
            makeCzkawkaResult(category: .bigFiles, counter: 1, safety: .review),
            makeCzkawkaResult(category: .brokenFiles, counter: 2, safety: .protected_),
        ]

        #expect(FileHealthCleanupFlow.confirmationTier(
            for: results,
            selectedIDs: ["czkawka-emptyFiles-0"]
        ) == .singleButton)

        #expect(FileHealthCleanupFlow.confirmationTier(
            for: results,
            selectedIDs: ["czkawka-emptyFiles-0", "czkawka-bigFiles-1"]
        ) == .summaryDialog)

        #expect(FileHealthCleanupFlow.confirmationTier(
            for: results,
            selectedIDs: ["czkawka-bigFiles-1", "czkawka-brokenFiles-2"]
        ) == .fullModal)
    }

    @Test("remainingResults removes succeeded items and keeps failed items visible")
    func remainingResultsAfterPartialCleanup() {
        let safe = makeCzkawkaResult(category: .emptyFiles, counter: 0, safety: .safe)
        let denied = makeCzkawkaResult(category: .bigFiles, counter: 1, safety: .review)
        let diskFull = makeCzkawkaResult(category: .similarImages, counter: 2, safety: .review)
        let result = CleanupResult(itemResults: [
            CleanupItemResult(item: safe, succeeded: true),
            CleanupItemResult(item: denied, succeeded: false, error: "Permission denied"),
            CleanupItemResult(item: diskFull, succeeded: false, error: "No space left on device"),
        ])

        let remaining = FileHealthCleanupFlow.remainingResults(
            after: result,
            from: [safe, denied, diskFull]
        )
        let selection = FileHealthCleanupFlow.remainingSelection(
            after: result,
            from: [safe.id, denied.id, diskFull.id]
        )
        let warnings = FileHealthCleanupFlow.failureWarnings(from: result)

        #expect(remaining.map(\.id) == [denied.id, diskFull.id])
        #expect(selection == [denied.id, diskFull.id])
        #expect(warnings.contains("1: Permission denied"))
        #expect(warnings.contains("2: No space left on device"))
    }

    @Test("audit entry shape uses File Health tool, trash method, and selected tier")
    func fileHealthAuditEntryShape() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-file-health-audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let safe = makeCzkawkaResult(category: .emptyFiles, counter: 0, safety: .safe, size: 100)
        let review = makeCzkawkaResult(category: .bigFiles, counter: 1, safety: .review, size: 250)
        let protected = makeCzkawkaResult(category: .brokenFiles, counter: 2, safety: .protected_, size: 500)
        let cleanup = CleanupResult(
            itemResults: [
                CleanupItemResult(item: safe, succeeded: true),
                CleanupItemResult(item: review, succeeded: true),
                CleanupItemResult(item: protected, succeeded: false, error: "Permission denied"),
            ],
            cleanupMethod: .trash
        )

        let writer = AuditWriter(logDirectory: dir)
        try writer.record(
            result: cleanup,
            tool: "file-health",
            command: "send-to-trash",
            confirmationMethod: .fullModal
        )
        let entries = try writer.readEntries()

        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.tool == "file-health")
        #expect(entry.command == "send-to-trash")
        #expect(entry.cleanupMethod == .trash)
        #expect(entry.confirmationMethod == .fullModal)
        #expect(entry.safetyLevel == .review)
        #expect(entry.bytesFreed == 350)
        #expect(entry.files.map(\.path) == [safe.path, review.path])
    }
}
