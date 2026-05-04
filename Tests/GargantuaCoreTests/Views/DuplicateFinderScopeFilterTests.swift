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

@Suite("DuplicateFinderScopeFilter.apply")
struct DuplicateFinderScopeFilterApplyTests {

    @Test("Firehose mode (personalRoots nil + excludeManaged false) returns input unchanged")
    func firehosePassthrough() {
        let results = [
            makeFclonesResult(id: "a", groupID: 1, path: "/Users/jane/proj/node_modules/foo/index.js"),
            makeFclonesResult(id: "b", groupID: 1, path: "/Users/jane/proj2/node_modules/foo/index.js"),
        ]
        let kept = DuplicateFinderScopeFilter.apply(
            to: results,
            personalRoots: nil,
            excludeManaged: false,
            homeDirectory: testHome
        )
        #expect(kept.count == 2)
    }

    @Test("Personal duplicates inside whitelisted roots survive")
    func personalDuplicatesKept() {
        let results = [
            makeFclonesResult(id: "a", groupID: 1, path: "/Users/jane/Documents/photo.jpg"),
            makeFclonesResult(id: "b", groupID: 1, path: "/Users/jane/Pictures/photo.jpg"),
        ]
        let kept = DuplicateFinderScopeFilter.apply(
            to: results,
            personalRoots: defaultRoots,
            excludeManaged: true,
            homeDirectory: testHome
        )
        #expect(kept.count == 2)
    }

    @Test("All-managed groups (cross-project node_modules) are dropped")
    func allManagedDropped() {
        let results = [
            makeFclonesResult(id: "a", groupID: 1, path: "/Users/jane/Development/gemini-mcp/node_modules/typescript/lib/typescript.js"),
            makeFclonesResult(id: "b", groupID: 1, path: "/Users/jane/Development/googologyVM/node_modules/typescript/lib/typescript.js"),
        ]
        let kept = DuplicateFinderScopeFilter.apply(
            to: results,
            personalRoots: defaultRoots,
            excludeManaged: true,
            homeDirectory: testHome
        )
        #expect(kept.isEmpty)
    }

    @Test("Cross-boundary groups (one personal, one outside scope) are dropped by strict whitelist")
    func crossBoundaryDropped() {
        // Strict whitelist: ALL files must be inside a personal root. A
        // mixed group surfaces too much noise (the project file beside the
        // personal copy), so we drop it.
        let results = [
            makeFclonesResult(id: "a", groupID: 1, path: "/Users/jane/Documents/typescript.js"),
            makeFclonesResult(id: "b", groupID: 1, path: "/Users/jane/proj/node_modules/typescript/lib/typescript.js"),
        ]
        let kept = DuplicateFinderScopeFilter.apply(
            to: results,
            personalRoots: defaultRoots,
            excludeManaged: true,
            homeDirectory: testHome
        )
        #expect(kept.isEmpty)
    }

    @Test("Files in ~/Development/ are dropped (not in personal whitelist)")
    func developmentFolderDropped() {
        let results = [
            makeFclonesResult(id: "a", groupID: 1, path: "/Users/jane/Development/projectA/src/util.swift"),
            makeFclonesResult(id: "b", groupID: 1, path: "/Users/jane/Development/projectB/src/util.swift"),
        ]
        let kept = DuplicateFinderScopeFilter.apply(
            to: results,
            personalRoots: defaultRoots,
            excludeManaged: true,
            homeDirectory: testHome
        )
        #expect(kept.isEmpty)
    }

    @Test("Adobe Premiere auto-saves under ~/Documents/Adobe are dropped via vendor exclusion")
    func adobeAutoSavesDropped() {
        // Mirrors the user's screenshot: Premiere drops auto-saved project
        // files into ~/Documents/Adobe. The whitelist alone keeps them
        // (Documents is in scope), but the vendor blacklist drops them.
        let results = [
            makeFclonesResult(id: "a", groupID: 1, path: "/Users/jane/Documents/Adobe/Premiere Pro (Beta)/26.0/Adobe Premiere Pro (Beta) Auto-Save/2025-12-10_15-43-02 Masks/41c78784.prmf"),
            makeFclonesResult(id: "b", groupID: 1, path: "/Users/jane/Documents/Adobe/Premiere Pro (Beta)/26.0/Adobe Premiere Pro (Beta) Auto-Save/2025-12-10_20-35-04 Masks/41c78784.prmf"),
        ]
        let kept = DuplicateFinderScopeFilter.apply(
            to: results,
            personalRoots: defaultRoots,
            excludeManaged: true,
            homeDirectory: testHome
        )
        #expect(kept.isEmpty)
    }

    @Test("Microsoft Office swap files under ~/Documents/Microsoft are dropped")
    func microsoftDropped() {
        let results = [
            makeFclonesResult(id: "a", groupID: 1, path: "/Users/jane/Documents/Microsoft/Office Auto-Recovery/recover1.docx"),
            makeFclonesResult(id: "b", groupID: 1, path: "/Users/jane/Documents/Microsoft/Office Auto-Recovery/recover2.docx"),
        ]
        let kept = DuplicateFinderScopeFilter.apply(
            to: results,
            personalRoots: defaultRoots,
            excludeManaged: true,
            homeDirectory: testHome
        )
        #expect(kept.isEmpty)
    }

    @Test("Intra-archive groups in ~/Documents are still dropped via deeply-colocated rule")
    func intraArchiveDropped() {
        // The cpsppp installer-payload case from the user's earlier screenshot.
        let results = [
            makeFclonesResult(id: "a", groupID: 1, path: "/Users/jane/Documents/cpsppp/update_file/2.6.1.s/PPP_UPDATE_TO_2.6.1.s_mac/Resources/lib/resources/fonts/msjh.ttf"),
            makeFclonesResult(id: "b", groupID: 1, path: "/Users/jane/Documents/cpsppp/update_file/2.6.1.s/PPP_UPDATE_TO_2.6.1.s_mac/Resources/resources/fonts/msjh.ttf"),
        ]
        let kept = DuplicateFinderScopeFilter.apply(
            to: results,
            personalRoots: defaultRoots,
            excludeManaged: true,
            homeDirectory: testHome
        )
        #expect(kept.isEmpty)
    }

    @Test("Shallow personal duplicates (Documents/Photos/A vs B) are kept")
    func shallowPersonalKept() {
        let results = [
            makeFclonesResult(id: "a", groupID: 1, path: "/Users/jane/Documents/Photos/A/IMG_001.jpg"),
            makeFclonesResult(id: "b", groupID: 1, path: "/Users/jane/Documents/Photos/B/IMG_001.jpg"),
        ]
        let kept = DuplicateFinderScopeFilter.apply(
            to: results,
            personalRoots: defaultRoots,
            excludeManaged: true,
            homeDirectory: testHome
        )
        #expect(kept.count == 2)
    }

    @Test("Untagged rows survive the filter")
    func untaggedKept() {
        let untagged = ScanResult(
            id: "stray",
            name: "stray",
            path: "/Users/jane/Documents/stray.bin",
            size: 100,
            safety: .review,
            confidence: 50,
            explanation: "",
            source: SourceAttribution(name: "other"),
            category: "other",
            tags: []
        )
        let kept = DuplicateFinderScopeFilter.apply(
            to: [untagged],
            personalRoots: defaultRoots,
            excludeManaged: true,
            homeDirectory: testHome
        )
        #expect(kept.count == 1)
    }

    @Test("Show-everything mode bypasses both filters")
    func showEverythingBypasses() {
        let results = [
            // Would be dropped by both filters normally
            makeFclonesResult(id: "a", groupID: 1, path: "/Users/jane/Development/proj/node_modules/foo.js"),
            makeFclonesResult(id: "b", groupID: 1, path: "/Users/jane/Development/proj2/node_modules/foo.js"),
        ]
        let kept = DuplicateFinderScopeFilter.apply(
            to: results,
            personalRoots: nil,
            excludeManaged: false,
            homeDirectory: testHome
        )
        #expect(kept.count == 2)
    }
}

@Suite("DuplicateFinderScopeFilter.defaultPersonalRoots")
struct DuplicateFinderScopeFilterDefaultsTests {

    @Test("Default roots cover the standard user-document folders")
    func defaultsCoverage() {
        let roots = DuplicateFinderScopeFilter.defaultPersonalRoots(homeDirectory: testHome)
        let paths = roots.map(\.path)
        #expect(paths.contains("/Users/jane/Documents"))
        #expect(paths.contains("/Users/jane/Downloads"))
        #expect(paths.contains("/Users/jane/Desktop"))
        #expect(paths.contains("/Users/jane/Pictures"))
        #expect(paths.contains("/Users/jane/Movies"))
        #expect(paths.contains("/Users/jane/Music"))
    }
}

@Suite("DuplicateFinderScopeFilter.isDeeplyColocated")
struct DuplicateFinderScopeFilterColocatedTests {

    @Test("Deep common ancestor below home triggers the rule")
    func deepCommonAncestor() {
        let homeDepth = 2 // /Users/jane
        let paths = [
            "/Users/jane/Documents/cpsppp/update_file/2.6.1.s/PPP_UPDATE_TO_2.6.1.s_mac/Resources/lib/fonts/msjh.ttf",
            "/Users/jane/Documents/cpsppp/update_file/2.6.1.s/PPP_UPDATE_TO_2.6.1.s_mac/Resources/resources/fonts/msjh.ttf",
        ]
        #expect(DuplicateFinderScopeFilter.isDeeplyColocated(paths: paths, homeDepth: homeDepth))
    }

    @Test("Shallow common ancestor does NOT trigger the rule")
    func shallowCommonAncestor() {
        let homeDepth = 2
        let paths = [
            "/Users/jane/Documents/photo.jpg",
            "/Users/jane/Pictures/photo.jpg",
        ]
        #expect(!DuplicateFinderScopeFilter.isDeeplyColocated(paths: paths, homeDepth: homeDepth))
    }

    @Test("Single-element path list never triggers")
    func singlePath() {
        #expect(!DuplicateFinderScopeFilter.isDeeplyColocated(paths: ["/a/b/c/d/e/f/g/h"], homeDepth: 2))
    }

    @Test("Threshold is exactly home + 5 segments")
    func thresholdBoundary() {
        let homeDepth = 2 // /Users/jane
        let belowThreshold = [
            "/Users/jane/a/b/c/d/x/file.txt",
            "/Users/jane/a/b/c/d/y/file.txt",
        ]
        #expect(!DuplicateFinderScopeFilter.isDeeplyColocated(paths: belowThreshold, homeDepth: homeDepth))

        let atThreshold = [
            "/Users/jane/a/b/c/d/e/x/file.txt",
            "/Users/jane/a/b/c/d/e/y/file.txt",
        ]
        #expect(DuplicateFinderScopeFilter.isDeeplyColocated(paths: atThreshold, homeDepth: homeDepth))
    }
}

@Suite("DuplicateFinderScopeFilter.hiddenSummary")
struct DuplicateFinderScopeFilterHiddenSummaryTests {

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
