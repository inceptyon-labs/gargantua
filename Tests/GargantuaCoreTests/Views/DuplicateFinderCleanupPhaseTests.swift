import Foundation
import Testing
@testable import GargantuaCore

/// The Duplicate Finder consumed only `succeededItems` and dropped straight
/// back into the list, so a failed delete produced no summary, no banner, and a
/// row that silently reappeared unchanged. This is the surface where deleting
/// the wrong copy is unrecoverable, so silence is the worst possible outcome.
@Suite("Duplicate Finder cleanup phases")
@MainActor
struct DuplicateFinderCleanupPhaseTests {

    private func makeResult(id: String) -> ScanResult {
        ScanResult(
            id: id,
            name: "name-\(id)",
            path: "/tmp/\(id)",
            size: 1_000,
            safety: .safe,
            confidence: 95,
            explanation: "test",
            source: SourceAttribution(name: "TestApp"),
            category: "duplicates"
        )
    }

    @Test("a confirmed delete enters a busy phase and remembers the list")
    func beginCleanupEntersBusyPhase() {
        let state = DuplicateFinderContainerState()
        let items = [makeResult(id: "a"), makeResult(id: "b")]
        state.scanState = .results(items)

        let remembered = state.beginCleanup()

        #expect(remembered?.map(\.id) == ["a", "b"])
        guard case .cleaning = state.scanState else {
            Issue.record("Expected .cleaning, got \(state.scanState)")
            return
        }
    }

    @Test("a delete requested outside the results screen is refused")
    func beginCleanupRefusedOffResults() {
        let state = DuplicateFinderContainerState()
        state.scanState = .idle

        #expect(state.beginCleanup() == nil)
        guard case .idle = state.scanState else {
            Issue.record("Expected .idle to be preserved, got \(state.scanState)")
            return
        }
    }

    @Test("a result carrying a failure lands on the summary, not back on the list")
    func failedDeleteDrivesSummary() {
        let state = DuplicateFinderContainerState()
        let items = [makeResult(id: "a"), makeResult(id: "b")]
        state.scanState = .results(items)
        let remembered = state.beginCleanup() ?? []

        let result = CleanupResult(
            itemResults: [
                CleanupItemResult(item: items[0], succeeded: true),
                CleanupItemResult(item: items[1], succeeded: false, error: "Permission denied"),
            ],
            cleanupMethod: .trash
        )
        state.finishCleanup(result: result, returningTo: remembered)

        guard case .summary(let shown, let returningTo) = state.scanState else {
            Issue.record("Expected .summary, got \(state.scanState)")
            return
        }
        #expect(shown.failedItems.count == 1)
        #expect(shown.failedItems.first?.error == "Permission denied")
        #expect(returningTo.map(\.id) == ["a", "b"])
    }

    @Test("dismissing the summary returns to the remembered list and refreshes the cache")
    func dismissSummaryReturnsToList() {
        let state = DuplicateFinderContainerState()
        let items = [makeResult(id: "a")]
        state.scanState = .results(items)
        let remembered = state.beginCleanup() ?? []
        state.finishCleanup(
            result: CleanupResult(itemResults: [], cleanupMethod: .trash),
            returningTo: remembered
        )

        state.dismissSummary(showing: remembered)

        guard case .results(let shown) = state.scanState else {
            Issue.record("Expected .results, got \(state.scanState)")
            return
        }
        #expect(shown.map(\.id) == ["a"])
        #expect(state.cachedResults?.map(\.id) == ["a"])
    }
}
