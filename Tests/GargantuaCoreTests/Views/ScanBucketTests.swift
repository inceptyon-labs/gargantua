import Testing
@testable import GargantuaCore

// MARK: - Test Helpers

private func makeScanResult(
    id: String = "test",
    safety: SafetyLevel,
    size: Int64 = 1000,
    path: String? = nil,
    category: String = "test"
) -> ScanResult {
    ScanResult(
        id: id,
        name: "Item \(id)",
        path: path ?? "/path/\(id)",
        size: size,
        safety: safety,
        confidence: 90,
        explanation: "Test item",
        source: SourceAttribution(name: "Test"),
        category: category
    )
}

// MARK: - Safety Grouping

@Suite("ScanGrouper.safety")
struct ScanGrouperSafetyTests {
    @Test("Group returns three groups in order: safe, review, protected")
    func groupOrder() {
        let results = [
            makeScanResult(id: "r1", safety: .review),
            makeScanResult(id: "s1", safety: .safe),
            makeScanResult(id: "p1", safety: .protected_),
        ]
        let groups = ScanGrouper.group(results, mode: .safety)
        #expect(groups.count == 3)
        #expect(groups[0].id == "safety:safe")
        #expect(groups[1].id == "safety:review")
        #expect(groups[2].id == "safety:protected_")
    }

    @Test("Group includes empty groups when no items for a level")
    func emptyGroups() {
        let results = [makeScanResult(id: "s1", safety: .safe)]
        let groups = ScanGrouper.group(results, mode: .safety)
        #expect(groups.count == 3)
        #expect(groups[0].count == 1)
        #expect(groups[1].items.isEmpty)
        #expect(groups[2].items.isEmpty)
    }

    @Test("Group with empty input returns three empty groups")
    func emptyInput() {
        let groups = ScanGrouper.group([], mode: .safety)
        #expect(groups.count == 3)
        #expect(groups.allSatisfy { $0.items.isEmpty })
    }

    @Test("Total size sums item sizes correctly")
    func totalSize() {
        let results = [
            makeScanResult(id: "s1", safety: .safe, size: 1000),
            makeScanResult(id: "s2", safety: .safe, size: 2500),
        ]
        let groups = ScanGrouper.group(results, mode: .safety)
        #expect(groups[0].totalSize == 3500)
    }

    @Test("Titles match expected labels")
    func titles() {
        // Need items so subjects aren't empty for comparison; empty still returns all three.
        let groups = ScanGrouper.group([], mode: .safety)
        #expect(groups[0].title == "Safe to Clean")
        #expect(groups[1].title == "Review Required")
        #expect(groups[2].title == "Protected")
    }

    @Test("Items within each safety group match their safety level")
    func itemSafetyMatches() {
        let results = [
            makeScanResult(id: "s1", safety: .safe),
            makeScanResult(id: "r1", safety: .review),
            makeScanResult(id: "p1", safety: .protected_),
        ]
        let groups = ScanGrouper.group(results, mode: .safety)
        for group in groups {
            guard case .safety(let level) = group.kind else {
                Issue.record("Expected safety kind"); return
            }
            for item in group.items { #expect(item.safety == level) }
        }
    }

    @Test("Items within a safety group are sorted by size desc")
    func safetySortBySize() {
        let results = [
            makeScanResult(id: "s1", safety: .safe, size: 100),
            makeScanResult(id: "s2", safety: .safe, size: 5_000),
            makeScanResult(id: "s3", safety: .safe, size: 500),
        ]
        let groups = ScanGrouper.group(results, mode: .safety)
        #expect(groups[0].items.map(\.size) == [5_000, 500, 100])
    }
}

// MARK: - Folder Grouping

@Suite("ScanGrouper.folder")
struct ScanGrouperFolderTests {
    @Test("Items with the same parent folder collapse into one group")
    func groupsByParent() {
        let results = [
            makeScanResult(id: "a", safety: .safe, path: "/Users/x/Library/Caches/com.apple.Safari"),
            makeScanResult(id: "b", safety: .safe, path: "/Users/x/Library/Caches/com.google.Chrome"),
            makeScanResult(id: "c", safety: .safe, path: "/Users/x/Downloads/stale.dmg"),
        ]
        let groups = ScanGrouper.group(results, mode: .folder)
        #expect(groups.count == 2)
        let caches = groups.first { $0.title == "Caches" }
        #expect(caches?.count == 2)
        let downloads = groups.first { $0.title == "Downloads" }
        #expect(downloads?.count == 1)
    }

    @Test("Groups are sorted by total size desc")
    func folderSortBySize() {
        let results = [
            makeScanResult(id: "small", safety: .safe, size: 100, path: "/a/small/f"),
            makeScanResult(id: "big1", safety: .safe, size: 10_000, path: "/a/big/f1"),
            makeScanResult(id: "big2", safety: .safe, size: 5_000, path: "/a/big/f2"),
        ]
        let groups = ScanGrouper.group(results, mode: .folder)
        #expect(groups.count == 2)
        #expect(groups[0].title == "big")
        #expect(groups[0].totalSize == 15_000)
        #expect(groups[1].title == "small")
    }

    @Test("Items within a folder group are sorted by size desc")
    func folderItemsSorted() {
        let results = [
            makeScanResult(id: "a", safety: .safe, size: 100, path: "/x/y/a"),
            makeScanResult(id: "b", safety: .safe, size: 9_000, path: "/x/y/b"),
            makeScanResult(id: "c", safety: .safe, size: 500, path: "/x/y/c"),
        ]
        let groups = ScanGrouper.group(results, mode: .folder)
        #expect(groups[0].items.map(\.id) == ["b", "c", "a"])
    }

    @Test("Subtitle shows the abbreviated parent path")
    func folderSubtitle() {
        let results = [makeScanResult(id: "a", safety: .safe, path: "/Users/x/Downloads/f")]
        let groups = ScanGrouper.group(results, mode: .folder)
        // abbreviateHomePath replaces $HOME with ~; in a test process $HOME may differ,
        // so only assert the subtitle exists and is absolute-or-abbreviated.
        #expect(groups[0].subtitle?.hasSuffix("/Downloads") == true)
    }
}

// MARK: - Category Grouping

@Suite("ScanGrouper.category")
struct ScanGrouperCategoryTests {
    @Test("Items with the same category collapse into one group")
    func groupsByCategory() {
        let results = [
            makeScanResult(id: "a", safety: .safe, category: "browser_cache"),
            makeScanResult(id: "b", safety: .safe, category: "browser_cache"),
            makeScanResult(id: "c", safety: .safe, category: "system_logs"),
        ]
        let groups = ScanGrouper.group(results, mode: .category)
        #expect(groups.count == 2)
    }

    @Test("Category titles are prettified from snake_case")
    func categoryTitle() {
        let results = [makeScanResult(id: "a", safety: .safe, category: "browser_cache")]
        let groups = ScanGrouper.group(results, mode: .category)
        #expect(groups[0].title == "Browser Cache")
    }

    @Test("Category groups are sorted by total size desc")
    func categorySortBySize() {
        let results = [
            makeScanResult(id: "a", safety: .safe, size: 100, category: "small_cat"),
            makeScanResult(id: "b", safety: .safe, size: 10_000, category: "big_cat"),
        ]
        let groups = ScanGrouper.group(results, mode: .category)
        #expect(groups[0].title == "Big Cat")
        #expect(groups[1].title == "Small Cat")
    }
}
