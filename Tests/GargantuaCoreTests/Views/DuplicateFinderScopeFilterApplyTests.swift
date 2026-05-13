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
