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

    @Test("finishScan preselects only safe-tier findings")
    @MainActor
    func finishScanPreselectsSafeOnly() {
        let session = FileHealthSessionState()
        let results = [
            makeCzkawkaResult(category: .emptyFiles, counter: 0),     // safe
            makeCzkawkaResult(category: .brokenSymlinks, counter: 1), // safe
            makeCzkawkaResult(category: .bigFiles, counter: 2),       // review
            makeCzkawkaResult(category: .similarImages, counter: 3),  // review
        ]

        session.finishScan(results: results)

        #expect(session.selectedResultIDs == Set([
            "czkawka-emptyFiles-0",
            "czkawka-brokenSymlinks-1",
        ]))
    }

    @Test("SafetyClassifier downgrade to .review excludes the finding from defaults")
    @MainActor
    func defaultsFollowActualSafetyLevel() {
        // If an emptyFiles result is overridden to .review via profile policy,
        // default selection should respect the runtime safety — not the
        // CzkawkaTrustDefaults category default.
        let session = FileHealthSessionState()
        let results = [
            makeCzkawkaResult(category: .emptyFiles, counter: 0, safety: .review),
            makeCzkawkaResult(category: .emptyFiles, counter: 1, safety: .safe),
        ]

        session.finishScan(results: results)

        #expect(session.selectedResultIDs == Set(["czkawka-emptyFiles-1"]))
    }

    @Test("toggleSelection flips membership idempotently")
    @MainActor
    func toggleFlipsMembership() {
        let session = FileHealthSessionState()
        let results = [makeCzkawkaResult(category: .bigFiles, counter: 0)]
        let id = results[0].id

        session.finishScan(results: results) // review -> nothing preselected
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
            makeCzkawkaResult(category: .emptyFiles, counter: 0),    // safe
            makeCzkawkaResult(category: .bigFiles, counter: 1),      // review, manually opt-in
            makeCzkawkaResult(category: .similarImages, counter: 2), // review
        ]
        session.finishScan(results: results)

        // User opts a review-tier big file into selection in its tab.
        session.toggleSelection(for: "czkawka-bigFiles-1")

        // Simulate switching tabs by regrouping — tabs are derived from
        // results, but the session (source of truth) doesn't change.
        let regrouped = FileHealthGrouper.group(results)
        #expect(regrouped.count == 3)
        #expect(session.isSelected("czkawka-emptyFiles-0"))
        #expect(session.isSelected("czkawka-bigFiles-1"))
        #expect(!session.isSelected("czkawka-similarImages-2"))
    }

    @Test("clear wipes selection (used when a new scan starts)")
    @MainActor
    func clearWipesSelection() {
        let session = FileHealthSessionState()
        session.finishScan(results: [
            makeCzkawkaResult(category: .emptyFiles, counter: 0),
            makeCzkawkaResult(category: .brokenSymlinks, counter: 1),
        ])
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
