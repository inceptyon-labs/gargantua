import Foundation
import Testing
@testable import GargantuaCore

@Suite("FileHealthGroupActions")
struct FileHealthGroupActionsTests {

    private static func result(
        id: String,
        size: Int64,
        lastAccessed: Date? = nil,
        groupID: Int? = nil
    ) -> ScanResult {
        ScanResult(
            id: id,
            name: "\(id).jpg",
            path: "/tmp/\(id).jpg",
            size: size,
            safety: .review,
            confidence: 90,
            explanation: "",
            source: SourceAttribution(name: "test", bundleID: "test"),
            lastAccessed: lastAccessed,
            category: "similar_images",
            tags: groupID.map { ["czkawka_group_\($0)"] } ?? []
        )
    }

    // MARK: - keepLargest

    @Test("keepLargest returns every member except the single largest")
    func keepLargestKeepsBiggest() {
        let group = [
            Self.result(id: "a", size: 100),
            Self.result(id: "b", size: 500),
            Self.result(id: "c", size: 200),
        ]
        #expect(FileHealthGroupActions.keepLargest(in: group) == ["a", "c"])
    }

    @Test("keepLargest with size ties picks the lowest-id member as keeper")
    func keepLargestStableOnSizeTies() {
        let group = [
            Self.result(id: "b", size: 500),
            Self.result(id: "a", size: 500),
            Self.result(id: "c", size: 500),
        ]
        // "a" is lowest id and wins the keeper slot deterministically.
        #expect(FileHealthGroupActions.keepLargest(in: group) == ["b", "c"])
    }

    @Test("keepLargest returns empty for groups of 0 or 1")
    func keepLargestRespectsKeepOneInvariant() {
        #expect(FileHealthGroupActions.keepLargest(in: []).isEmpty)
        #expect(FileHealthGroupActions.keepLargest(in: [Self.result(id: "x", size: 100)]).isEmpty)
    }

    // MARK: - keepNewest

    @Test("keepNewest returns every member except the most recently accessed")
    func keepNewestKeepsMostRecent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let group = [
            Self.result(id: "old", size: 100, lastAccessed: now.addingTimeInterval(-3600)),
            Self.result(id: "newest", size: 100, lastAccessed: now),
            Self.result(id: "older", size: 100, lastAccessed: now.addingTimeInterval(-7200)),
        ]
        #expect(FileHealthGroupActions.keepNewest(in: group) == ["old", "older"])
    }

    @Test("keepNewest treats nil lastAccessed as oldest")
    func keepNewestNilSortsOldest() {
        let recent = Date(timeIntervalSince1970: 1_700_000_000)
        let group = [
            Self.result(id: "no-stamp", size: 100, lastAccessed: nil),
            Self.result(id: "stamped", size: 100, lastAccessed: recent),
        ]
        #expect(FileHealthGroupActions.keepNewest(in: group) == ["no-stamp"])
    }

    @Test("keepNewest falls back to keepLargest when no member carries a timestamp")
    func keepNewestFallsBackToLargest() {
        let group = [
            Self.result(id: "small", size: 100, lastAccessed: nil),
            Self.result(id: "big", size: 800, lastAccessed: nil),
            Self.result(id: "medium", size: 400, lastAccessed: nil),
        ]
        // Without timestamps, fall through to size-based keeper so the action
        // never silently no-ops or queues every copy.
        #expect(FileHealthGroupActions.keepNewest(in: group) == ["small", "medium"])
    }

    @Test("keepNewest returns empty for groups of 0 or 1")
    func keepNewestRespectsKeepOneInvariant() {
        #expect(FileHealthGroupActions.keepNewest(in: []).isEmpty)
        let single = [Self.result(id: "only", size: 100, lastAccessed: Date())]
        #expect(FileHealthGroupActions.keepNewest(in: single).isEmpty)
    }

    // MARK: - trashAll

    @Test("trashAll selects every member of the group")
    func trashAllSelectsEverything() {
        let group = [
            Self.result(id: "a", size: 100),
            Self.result(id: "b", size: 200),
            Self.result(id: "c", size: 300),
        ]
        #expect(FileHealthGroupActions.trashAll(in: group) == ["a", "b", "c"])
    }

    @Test("trashAll on empty group returns empty set")
    func trashAllEmpty() {
        #expect(FileHealthGroupActions.trashAll(in: []).isEmpty)
    }

    // MARK: - groupedFindings

    @Test("groupedFindings segments findings by czkawka group preserving first-appearance order")
    func groupedFindingsPreservesOrder() {
        let findings = [
            Self.result(id: "a1", size: 100, groupID: 7),
            Self.result(id: "b1", size: 100, groupID: 3),
            Self.result(id: "a2", size: 100, groupID: 7),
            Self.result(id: "b2", size: 100, groupID: 3),
            Self.result(id: "c1", size: 100, groupID: 9),
        ]
        let tab = FileHealthCategoryTab(
            category: .similarImages,
            safety: .review,
            findings: findings
        )

        let sections = tab.groupedFindings(filteredBy: findings)
        // Group 7 appears first → display index 1, group 3 → 2, group 9 → 3.
        #expect(sections.map(\.context.index) == [1, 2, 3])
        #expect(sections[0].findings.map(\.id) == ["a1", "a2"])
        #expect(sections[1].findings.map(\.id) == ["b1", "b2"])
        #expect(sections[2].findings.map(\.id) == ["c1"])
    }

    @Test("groupedFindings drops findings without a czkawka group id")
    func groupedFindingsDropsUngrouped() {
        let findings = [
            Self.result(id: "ungrouped", size: 100, groupID: nil),
            Self.result(id: "grouped", size: 100, groupID: 1),
        ]
        let tab = FileHealthCategoryTab(
            category: .similarImages,
            safety: .review,
            findings: findings
        )
        let sections = tab.groupedFindings(filteredBy: findings)
        #expect(sections.count == 1)
        #expect(sections.first?.findings.map(\.id) == ["grouped"])
    }

    @Test("groupedFindings reflects the filtered subset count in section context")
    func groupedFindingsRespectsFilter() {
        let allFindings = [
            Self.result(id: "a1", size: 100, groupID: 1),
            Self.result(id: "a2", size: 100, groupID: 1),
            Self.result(id: "a3", size: 100, groupID: 1),
        ]
        let tab = FileHealthCategoryTab(
            category: .similarImages,
            safety: .review,
            findings: allFindings
        )

        let filteredSubset = Array(allFindings.prefix(2))
        let sections = tab.groupedFindings(filteredBy: filteredSubset)
        #expect(sections.count == 1)
        // Section context count reflects what's *visible* — the filter
        // narrowed the group from 3 to 2.
        #expect(sections.first?.context.count == 2)
        #expect(sections.first?.findings.map(\.id) == ["a1", "a2"])
    }

    @Test("GroupSection totalSize sums member sizes")
    func groupSectionTotalSize() throws {
        let findings = [
            Self.result(id: "a", size: 100, groupID: 1),
            Self.result(id: "b", size: 250, groupID: 1),
            Self.result(id: "c", size: 50, groupID: 1),
        ]
        let tab = FileHealthCategoryTab(
            category: .similarImages,
            safety: .review,
            findings: findings
        )
        let section = try #require(tab.groupedFindings(filteredBy: findings).first)
        #expect(section.totalSize == 400)
    }
}
