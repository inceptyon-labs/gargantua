import Foundation
import Testing
@testable import GargantuaCore

// MARK: - Fixture Builder

private func makeCzkawkaResult(
    category: CzkawkaCategory,
    counter: Int,
    safety: SafetyLevel? = nil,
    path: String? = nil,
    size: Int64 = 1_024,
    groupID: Int? = nil
) -> ScanResult {
    let entry = CzkawkaTrustDefaults.builtIn.entry(for: category)
    let resolvedSafety = safety ?? entry.safety
    let resolvedPath = path ?? "/tmp/fixture/\(category.rawValue)/\(counter)"
    let tags = groupID.map { ["czkawka_group_\($0)"] } ?? []
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
        tags: tags
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
            makeCzkawkaResult(category: .bigFiles, counter: 0), // review
            makeCzkawkaResult(category: .emptyFiles, counter: 0), // safe
            makeCzkawkaResult(category: .similarImages, counter: 0), // review
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

// MARK: - Group Context

@Suite("FileHealthCategoryTab group context")
struct FileHealthGroupContextTests {

    @Test("Findings without a czkawka_group_N tag yield no group context")
    func noGroupForUntaggedFindings() {
        let results = [
            makeCzkawkaResult(category: .bigFiles, counter: 0),
            makeCzkawkaResult(category: .bigFiles, counter: 1),
        ]
        let tab = FileHealthGrouper.group(results).first!
        for finding in tab.findings {
            #expect(tab.groupContext(for: finding) == nil)
        }
    }

    @Test("ScanResult.czkawkaGroupID parses the group ID out of tags")
    func parsesGroupIDFromTags() {
        let result = makeCzkawkaResult(category: .similarImages, counter: 0, groupID: 42)
        #expect(result.czkawkaGroupID == 42)

        let untagged = makeCzkawkaResult(category: .similarImages, counter: 1)
        #expect(untagged.czkawkaGroupID == nil)
    }

    @Test("Sparse czkawka group IDs are renumbered to compact 1-based display indices")
    func renumbersSparseGroupIDs() {
        // czkawka may emit groups 7, 19, 88 — the user should see Group 1, 2, 3
        // in first-appearance order.
        let results = [
            makeCzkawkaResult(category: .similarImages, counter: 0, groupID: 7),
            makeCzkawkaResult(category: .similarImages, counter: 1, groupID: 7),
            makeCzkawkaResult(category: .similarImages, counter: 2, groupID: 19),
            makeCzkawkaResult(category: .similarImages, counter: 3, groupID: 88),
            makeCzkawkaResult(category: .similarImages, counter: 4, groupID: 88),
            makeCzkawkaResult(category: .similarImages, counter: 5, groupID: 88),
        ]
        let tab = FileHealthGrouper.group(results).first!

        let context0 = tab.groupContext(for: tab.findings[0])
        let context1 = tab.groupContext(for: tab.findings[1])
        let context2 = tab.groupContext(for: tab.findings[2])
        let context3 = tab.groupContext(for: tab.findings[3])
        let context5 = tab.groupContext(for: tab.findings[5])

        #expect(context0?.index == 1)
        #expect(context0?.count == 2)
        #expect(context1?.index == 1)
        #expect(context1?.count == 2)
        #expect(context2?.index == 2)
        #expect(context2?.count == 1)
        #expect(context3?.index == 3)
        #expect(context3?.count == 3)
        #expect(context5?.index == 3)
        #expect(context5?.count == 3)
    }

    @Test("Mixing grouped and ungrouped findings only surfaces context for grouped ones")
    func mixedGroupedAndUngrouped() {
        let results = [
            makeCzkawkaResult(category: .similarImages, counter: 0, groupID: 1),
            makeCzkawkaResult(category: .similarImages, counter: 1),  // no group
            makeCzkawkaResult(category: .similarImages, counter: 2, groupID: 1),
        ]
        let tab = FileHealthGrouper.group(results).first!

        #expect(tab.groupContext(for: tab.findings[0])?.count == 2)
        #expect(tab.groupContext(for: tab.findings[1]) == nil)
        #expect(tab.groupContext(for: tab.findings[2])?.count == 2)
    }
}
