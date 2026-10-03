import Foundation
import Testing
@testable import GargantuaCore

@Suite("ScanBucketListState")
@MainActor
struct ScanBucketListStateTests {
    @Test("The grouping mode is remembered per screen across instances")
    func groupingIsRememberedPerKey() throws {
        let suite = "ScanBucketListStateTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = ScanBucketListState(groupingDefaultsKey: "deepClean", defaults: defaults)
        #expect(first.groupingMode == .safety)
        first.groupingMode = .category

        #expect(ScanBucketListState(groupingDefaultsKey: "deepClean", defaults: defaults).groupingMode == .category)
        #expect(ScanBucketListState(groupingDefaultsKey: "aiModels", defaultGrouping: .folder, defaults: defaults).groupingMode == .folder)
    }

    @Test("A new scan clears search and collapsed groups but keeps the grouping")
    func newScanResetsSearchNotGrouping() {
        let session = DeepCleanSessionState()
        let state = session.listState
        let grouping = state.groupingMode
        state.collapsedGroupIDs = ["safety-review"]
        state.naturalLanguageQuery = "older than 90 days"
        state.activeFilter = ScanFilterSet(safetyLevels: [.review])
        state.selectionHiddenByFilter = ["a"]

        session.finishScan(results: [], duration: 1, precomputedRemovability: [:])

        #expect(session.listState === state)
        #expect(state.collapsedGroupIDs.isEmpty)
        #expect(state.naturalLanguageQuery.isEmpty)
        #expect(state.activeFilter == nil)
        #expect(state.selectionHiddenByFilter.isEmpty)
        #expect(state.groupingMode == grouping)
    }
}
