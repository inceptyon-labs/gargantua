import Testing
import Foundation
@testable import GargantuaCore

// MARK: - Fixture Builders

private func makeFclonesResult(
    id: String,
    groupID: Int,
    shortHash: String = "deadbeef",
    path: String,
    size: Int64 = 1_000,
    safety: SafetyLevel = .review
) -> ScanResult {
    ScanResult(
        id: id,
        name: (path as NSString).lastPathComponent,
        path: path,
        size: size,
        safety: safety,
        confidence: 65,
        explanation: "Duplicate file content. Keep one, review the rest before removing.",
        source: SourceAttribution(name: "fclones"),
        category: "duplicate_files",
        tags: ["fclones_group_\(groupID)", "fclones_hash_\(shortHash)"]
    )
}

// MARK: - Grouping

@Suite("DuplicateGrouper.group")
struct DuplicateGrouperTests {
    @Test("Fclones-tagged results cluster by group id")
    func groupsByTag() {
        let results = [
            makeFclonesResult(id: "a1", groupID: 1, path: "/x/a1"),
            makeFclonesResult(id: "a2", groupID: 1, path: "/x/a2"),
            makeFclonesResult(id: "b1", groupID: 2, path: "/x/b1"),
        ]
        let groups = DuplicateGrouper.group(results)
        #expect(groups.count == 2)
        #expect(groups.first { $0.id == "fclones_group_1" }?.fileCount == 2)
        #expect(groups.first { $0.id == "fclones_group_2" }?.fileCount == 1)
    }

    @Test("Results without an fclones_group_ tag are dropped")
    func dropsUntaggedResults() {
        let tagged = makeFclonesResult(id: "a1", groupID: 1, path: "/x/a1")
        let untagged = ScanResult(
            id: "stray",
            name: "stray",
            path: "/x/stray",
            size: 42,
            safety: .review,
            confidence: 50,
            explanation: "",
            source: SourceAttribution(name: "other"),
            category: "other",
            tags: []
        )
        let groups = DuplicateGrouper.group([tagged, untagged])
        #expect(groups.count == 1)
        #expect(groups[0].files.map(\.id) == ["a1"])
    }

    @Test("Short hash is extracted from the fclones_hash_ tag")
    func extractsShortHash() {
        let results = [
            makeFclonesResult(id: "a1", groupID: 7, shortHash: "abc12345", path: "/x/a1"),
        ]
        let groups = DuplicateGrouper.group(results)
        #expect(groups[0].shortHash == "abc12345")
    }

    @Test("Short hash is empty string when the hash tag is missing")
    func missingHashTagFallsBackToEmpty() {
        let result = ScanResult(
            id: "a1",
            name: "a1",
            path: "/x/a1",
            size: 100,
            safety: .review,
            confidence: 65,
            explanation: "",
            source: SourceAttribution(name: "fclones"),
            category: "duplicate_files",
            tags: ["fclones_group_9"]
        )
        let groups = DuplicateGrouper.group([result])
        #expect(groups[0].shortHash == "")
    }

    @Test("Files within a group are sorted by path ascending")
    func filesSortedByPathAsc() {
        let results = [
            makeFclonesResult(id: "c", groupID: 1, path: "/x/c"),
            makeFclonesResult(id: "a", groupID: 1, path: "/x/a"),
            makeFclonesResult(id: "b", groupID: 1, path: "/x/b"),
        ]
        let groups = DuplicateGrouper.group(results)
        #expect(groups[0].files.map(\.id) == ["a", "b", "c"])
    }

    @Test("Groups are sorted by reclaimable ceiling bytes descending")
    func sortedByReclaimableCeiling() {
        // Group 1: 3 files × 100 bytes → ceiling 200
        // Group 2: 2 files × 10_000 bytes → ceiling 10_000
        let results = [
            makeFclonesResult(id: "g1a", groupID: 1, path: "/x/g1a", size: 100),
            makeFclonesResult(id: "g1b", groupID: 1, path: "/x/g1b", size: 100),
            makeFclonesResult(id: "g1c", groupID: 1, path: "/x/g1c", size: 100),
            makeFclonesResult(id: "g2a", groupID: 2, path: "/x/g2a", size: 10_000),
            makeFclonesResult(id: "g2b", groupID: 2, path: "/x/g2b", size: 10_000),
        ]
        let groups = DuplicateGrouper.group(results)
        #expect(groups.map(\.id) == ["fclones_group_2", "fclones_group_1"])
    }

    @Test("Empty input returns empty groups array")
    func emptyInput() {
        #expect(DuplicateGrouper.group([]).isEmpty)
    }
}

// MARK: - Reclaimable Bytes

@Suite("DuplicateGroup.reclaimableBytes")
struct DuplicateGroupBytesTests {
    @Test("Reclaimable ceiling is (count - 1) × per-file size")
    func reclaimableCeiling() {
        let results = [
            makeFclonesResult(id: "a", groupID: 1, path: "/x/a", size: 1_000),
            makeFclonesResult(id: "b", groupID: 1, path: "/x/b", size: 1_000),
            makeFclonesResult(id: "c", groupID: 1, path: "/x/c", size: 1_000),
        ]
        let group = DuplicateGrouper.group(results)[0]
        #expect(group.reclaimableCeilingBytes == 2_000)
    }

    @Test("Single-file group has zero reclaimable ceiling")
    func singleFileZeroCeiling() {
        let results = [makeFclonesResult(id: "a", groupID: 1, path: "/x/a", size: 500)]
        let group = DuplicateGrouper.group(results)[0]
        #expect(group.reclaimableCeilingBytes == 0)
    }

    @Test("Reclaimable bytes sum selected files")
    func reclaimableFromSelection() {
        let results = [
            makeFclonesResult(id: "a", groupID: 1, path: "/x/a", size: 1_000),
            makeFclonesResult(id: "b", groupID: 1, path: "/x/b", size: 1_000),
            makeFclonesResult(id: "c", groupID: 1, path: "/x/c", size: 1_000),
        ]
        let group = DuplicateGrouper.group(results)[0]
        #expect(group.reclaimableBytes(selectedIDs: ["a"]) == 1_000)
        #expect(group.reclaimableBytes(selectedIDs: ["a", "b"]) == 2_000)
        #expect(group.reclaimableBytes(selectedIDs: []) == 0)
    }

    @Test("Total reclaimable bytes sum across groups")
    func totalReclaimable() {
        let results = [
            makeFclonesResult(id: "g1a", groupID: 1, path: "/x/g1a", size: 500),
            makeFclonesResult(id: "g1b", groupID: 1, path: "/x/g1b", size: 500),
            makeFclonesResult(id: "g2a", groupID: 2, path: "/x/g2a", size: 3_000),
            makeFclonesResult(id: "g2b", groupID: 2, path: "/x/g2b", size: 3_000),
        ]
        let groups = DuplicateGrouper.group(results)
        let total = DuplicateFinderSelection.totalReclaimableBytes(
            groups: groups,
            selectedIDs: ["g1a", "g2b"]
        )
        #expect(total == 3_500)
    }

    @Test("Reclaimable ceiling clamps at Int64.max on overflow")
    func ceilingOverflowClamps() {
        // Three files at Int64.max / 2 + 10: (3 - 1) × size overflows.
        let huge = Int64.max / 2 + 10
        let results = [
            makeFclonesResult(id: "a", groupID: 1, path: "/x/a", size: huge),
            makeFclonesResult(id: "b", groupID: 1, path: "/x/b", size: huge),
            makeFclonesResult(id: "c", groupID: 1, path: "/x/c", size: huge),
        ]
        let group = DuplicateGrouper.group(results)[0]
        #expect(group.reclaimableCeilingBytes == Int64.max)
    }
}

// MARK: - Selection State

@Suite("DuplicateGroup.selectionState")
struct DuplicateGroupSelectionStateTests {
    private func twoFileGroup() -> DuplicateGroup {
        let results = [
            makeFclonesResult(id: "a", groupID: 1, path: "/x/a"),
            makeFclonesResult(id: "b", groupID: 1, path: "/x/b"),
        ]
        return DuplicateGrouper.group(results)[0]
    }

    @Test("No selection returns .none")
    func noneSelected() {
        #expect(twoFileGroup().selectionState(selectedIDs: []) == .none)
    }

    @Test("Every selectable id selected returns .all")
    func allSelected() {
        #expect(twoFileGroup().selectionState(selectedIDs: ["a", "b"]) == .all)
    }

    @Test("Subset selected returns .partial")
    func partial() {
        #expect(twoFileGroup().selectionState(selectedIDs: ["a"]) == .partial)
    }

    @Test("All-protected group returns .allProtected")
    func allProtected() {
        let results = [
            makeFclonesResult(id: "p1", groupID: 1, path: "/x/p1", safety: .protected_),
            makeFclonesResult(id: "p2", groupID: 1, path: "/x/p2", safety: .protected_),
        ]
        let group = DuplicateGrouper.group(results)[0]
        #expect(group.selectionState(selectedIDs: []) == .allProtected)
    }

    @Test("Selectable ids skip protected files")
    func selectableSkipsProtected() {
        let results = [
            makeFclonesResult(id: "s1", groupID: 1, path: "/x/s1", safety: .review),
            makeFclonesResult(id: "p1", groupID: 1, path: "/x/p1", safety: .protected_),
        ]
        let group = DuplicateGrouper.group(results)[0]
        #expect(group.selectableIDs == ["s1"])
        #expect(group.selectionState(selectedIDs: ["s1"]) == .all)
    }
}

// MARK: - Keep-One Helper

@Suite("DuplicateFinderSelection.selectAllButFirst")
struct SelectAllButFirstTests {
    @Test("Selects every file except the first sorted path")
    func selectsAllButFirst() {
        let results = [
            makeFclonesResult(id: "c", groupID: 1, path: "/x/c"),
            makeFclonesResult(id: "a", groupID: 1, path: "/x/a"),
            makeFclonesResult(id: "b", groupID: 1, path: "/x/b"),
        ]
        let group = DuplicateGrouper.group(results)[0]
        let picked = DuplicateFinderSelection.selectAllButFirst(in: group)
        #expect(picked == Set(["b", "c"]))
    }

    @Test("Single-file group picks nothing")
    func singleFilePicksNothing() {
        let results = [makeFclonesResult(id: "only", groupID: 1, path: "/x/only")]
        let group = DuplicateGrouper.group(results)[0]
        #expect(DuplicateFinderSelection.selectAllButFirst(in: group).isEmpty)
    }
}
