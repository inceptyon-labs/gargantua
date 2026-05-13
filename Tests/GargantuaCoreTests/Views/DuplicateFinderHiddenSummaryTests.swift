import Testing
import Foundation
@testable import GargantuaCore

private func makeFclonesResult(
    id: String,
    groupID: Int,
    path: String,
    size: Int64 = 1_000
) -> ScanResult {
    ScanResult(
        id: id,
        name: (path as NSString).lastPathComponent,
        path: path,
        size: size,
        safety: .review,
        confidence: 65,
        explanation: "",
        source: SourceAttribution(name: "fclones"),
        category: "duplicate_files",
        tags: ["fclones_group_\(groupID)", "fclones_hash_deadbeef"]
    )
}

private let testHome = URL(fileURLWithPath: "/Users/jane")
private let defaultRoots = DuplicateFinderScopeFilter.defaultPersonalRoots(homeDirectory: testHome)

@Suite("DuplicateFinderScopeFilter.hiddenSummary")
struct DuplicateFinderHiddenSummaryTests {

    @Test("Counts hidden groups, files, and reclaimable bytes")
    func hiddenCounts() {
        let results = [
            // Visible: 2-file personal group
            makeFclonesResult(id: "p1", groupID: 1, path: "/Users/jane/Documents/A/file.bin", size: 100),
            makeFclonesResult(id: "p2", groupID: 1, path: "/Users/jane/Pictures/file.bin", size: 100),
            // Hidden: ~/Development/ group (outside personal scope)
            makeFclonesResult(id: "d1", groupID: 2, path: "/Users/jane/Development/proj1/node_modules/foo/lib.js", size: 500),
            makeFclonesResult(id: "d2", groupID: 2, path: "/Users/jane/Development/proj2/node_modules/foo/lib.js", size: 500),
            makeFclonesResult(id: "d3", groupID: 2, path: "/Users/jane/Development/proj3/node_modules/foo/lib.js", size: 500),
        ]
        let summary = DuplicateFinderScopeFilter.hiddenSummary(
            for: results,
            personalRoots: defaultRoots,
            excludeManaged: true,
            homeDirectory: testHome
        )
        #expect(summary.groups == 1)
        #expect(summary.files == 3)
        // 3-file group at 500 bytes each = (3-1) * 500 = 1000 reclaimable
        #expect(summary.reclaimableBytes == 1_000)
    }

    @Test("Empty when nothing is hidden")
    func nothingHidden() {
        let results = [
            makeFclonesResult(id: "p1", groupID: 1, path: "/Users/jane/Documents/file.bin"),
            makeFclonesResult(id: "p2", groupID: 1, path: "/Users/jane/Pictures/file.bin"),
        ]
        let summary = DuplicateFinderScopeFilter.hiddenSummary(
            for: results,
            personalRoots: defaultRoots,
            excludeManaged: true,
            homeDirectory: testHome
        )
        #expect(summary.groups == 0)
        #expect(summary.files == 0)
        #expect(summary.reclaimableBytes == 0)
    }
}
