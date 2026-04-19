import Foundation
import Testing
@testable import GargantuaCore

// MARK: - Fixture Builder

private func makeCzkawkaResult(
    category: CzkawkaCategory,
    counter: Int,
    safety: SafetyLevel? = nil,
    path: String? = nil,
    size: Int64 = 1_024
) -> ScanResult {
    let entry = CzkawkaTrustDefaults.builtIn.entry(for: category)
    let resolvedSafety = safety ?? entry.safety
    let resolvedPath = path ?? "/tmp/fixture/\(category.rawValue)/\(counter)"
    return ScanResult(
        id: "czkawka-\(category.rawValue)-\(counter)",
        name: (resolvedPath as NSString).lastPathComponent,
        path: resolvedPath,
        size: size,
        safety: resolvedSafety,
        confidence: entry.confidence,
        explanation: entry.explanation,
        source: SourceAttribution(name: "Czkawka"),
        category: category.resultCategory,
        tags: []
    )
}

// MARK: - Grouping

@Suite("FileHealthGrouper.group")
struct FileHealthGrouperTests {

    @Test("Empty input yields no tabs")
    func emptyInput() {
        #expect(FileHealthGrouper.group([]).isEmpty)
    }

    @Test("Groups results by czkawka category and preserves counts")
    func groupsByCategory() {
        let results = [
            makeCzkawkaResult(category: .emptyFiles, counter: 0),
            makeCzkawkaResult(category: .emptyFiles, counter: 1),
            makeCzkawkaResult(category: .bigFiles, counter: 0, size: 1_000_000),
        ]
        let tabs = FileHealthGrouper.group(results)

        #expect(tabs.count == 2)
        #expect(tabs.first(where: { $0.category == .emptyFiles })?.count == 2)
        #expect(tabs.first(where: { $0.category == .bigFiles })?.count == 1)
    }

    @Test("Tabs are ordered safe categories first, then review")
    func ordersSafeBeforeReview() {
        // Interleave one safe and one review category to catch naive
        // "declaration order" fallback regressions.
        let results = [
            makeCzkawkaResult(category: .bigFiles, counter: 0),       // review
            makeCzkawkaResult(category: .emptyFiles, counter: 0),     // safe
            makeCzkawkaResult(category: .similarImages, counter: 0),  // review
            makeCzkawkaResult(category: .brokenSymlinks, counter: 0), // safe
        ]
        let tabs = FileHealthGrouper.group(results)

        let safeCategories = tabs.prefix(while: { $0.safety == .safe }).map(\.category)
        let reviewCategories = tabs.drop(while: { $0.safety == .safe }).map(\.category)

        #expect(safeCategories.contains(.emptyFiles))
        #expect(safeCategories.contains(.brokenSymlinks))
        #expect(reviewCategories.contains(.bigFiles))
        #expect(reviewCategories.contains(.similarImages))
        #expect(safeCategories.count == 2)
        #expect(reviewCategories.count == 2)
    }

    @Test("Tab label, icon, and safety match CzkawkaTrustDefaults for the built-in mapping")
    func tabMetadata() {
        let results = CzkawkaCategory.allCases.enumerated().map { index, category in
            makeCzkawkaResult(category: category, counter: index)
        }
        let tabs = FileHealthGrouper.group(results)

        #expect(tabs.count == CzkawkaCategory.allCases.count)

        for tab in tabs {
            let expected = CzkawkaTrustDefaults.builtIn.entry(for: tab.category)
            #expect(tab.safety == expected.safety, "mismatch for \(tab.category)")
            #expect(!tab.label.isEmpty)
            #expect(!tab.iconName.isEmpty)
        }
    }

    @Test("Scan results whose category string isn't a czkawka category are dropped")
    func dropsNonCzkawkaResults() {
        let nonCzkawka = ScanResult(
            id: "native-0",
            name: "dev-artifact",
            path: "/tmp/foo",
            size: 1,
            safety: .safe,
            confidence: 95,
            explanation: "",
            source: SourceAttribution(name: "native"),
            category: "dev_artifacts",
            tags: []
        )
        let czkawka = makeCzkawkaResult(category: .emptyFiles, counter: 0)

        let tabs = FileHealthGrouper.group([nonCzkawka, czkawka])
        #expect(tabs.count == 1)
        #expect(tabs.first?.category == .emptyFiles)
    }

    @Test("Tab total size sums its findings and saturates on overflow")
    func totalSizeSaturates() {
        let almostMax = Int64.max - 100
        let results = [
            makeCzkawkaResult(category: .bigFiles, counter: 0, size: almostMax),
            makeCzkawkaResult(category: .bigFiles, counter: 1, size: 500),
        ]
        let tabs = FileHealthGrouper.group(results)
        #expect(tabs.first?.totalSize == Int64.max)
    }

    @Test("Tab safety escalates to the least-safe level present across findings")
    func safetyEscalatesOnMixedFindings() {
        // If a future SafetyClassifier downgrades an emptyFiles finding to
        // .review, the tab should surface the escalation rather than pretend
        // everything is still safe.
        let results = [
            makeCzkawkaResult(category: .emptyFiles, counter: 0, safety: .safe),
            makeCzkawkaResult(category: .emptyFiles, counter: 1, safety: .review),
        ]
        let tab = FileHealthGrouper.group(results).first
        #expect(tab?.safety == .review)
    }

    @Test("category(for:) maps resultCategory strings back to the enum")
    func reverseLookup() {
        for category in CzkawkaCategory.allCases {
            #expect(FileHealthGrouper.category(for: category.resultCategory) == category)
        }
        #expect(FileHealthGrouper.category(for: "nonsense") == nil)
    }
}
