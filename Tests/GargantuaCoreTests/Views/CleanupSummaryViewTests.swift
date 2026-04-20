import Foundation
import Testing
@testable import GargantuaCore

private func makeScanResult(
    id: String = "item_\(UUID().uuidString.prefix(4))",
    name: String = "Test Item",
    size: Int64 = 1_000_000
) -> ScanResult {
    ScanResult(
        id: id,
        name: name,
        path: "/tmp/\(id)",
        size: size,
        safety: .safe,
        confidence: 90,
        explanation: "Test item",
        source: SourceAttribution(name: "Test"),
        category: "test"
    )
}

private func makeItem(id: String, succeeded: Bool, error: String? = nil) -> CleanupItemResult {
    CleanupItemResult(
        item: makeScanResult(id: id, name: id),
        succeeded: succeeded,
        trashURL: succeeded ? URL(fileURLWithPath: "/tmp/\(id)") : nil,
        error: succeeded ? nil : (error ?? "boom")
    )
}

@Suite("CleanupSummaryView outcome classification")
struct CleanupSummaryViewOutcomeTests {
    @Test("All succeeded → .complete")
    func allSucceeded() {
        let result = CleanupResult(itemResults: [
            makeItem(id: "a", succeeded: true),
            makeItem(id: "b", succeeded: true),
        ])
        #expect(CleanupSummaryView.outcome(for: result) == .complete)
    }

    @Test("Mixed succeeded + failed → .partial")
    func mixedPartial() {
        let result = CleanupResult(itemResults: [
            makeItem(id: "a", succeeded: true),
            makeItem(id: "b", succeeded: false),
        ])
        #expect(CleanupSummaryView.outcome(for: result) == .partial)
    }

    @Test("Zero succeeded + >0 failed → .failed (distinct from .partial)")
    func totalFailure() {
        let result = CleanupResult(itemResults: [
            makeItem(id: "a", succeeded: false),
            makeItem(id: "b", succeeded: false, error: "permission denied"),
        ])
        #expect(CleanupSummaryView.outcome(for: result) == .failed)
    }

    @Test("Single failed item → .failed, not .partial")
    func singleFailed() {
        let result = CleanupResult(itemResults: [
            makeItem(id: "only", succeeded: false),
        ])
        #expect(CleanupSummaryView.outcome(for: result) == .failed)
    }

    @Test("Empty result → .complete (nothing failed)")
    func emptyResult() {
        let result = CleanupResult(itemResults: [])
        #expect(CleanupSummaryView.outcome(for: result) == .complete)
    }
}
