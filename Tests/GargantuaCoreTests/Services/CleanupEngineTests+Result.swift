import Foundation
import Testing
@testable import GargantuaCore

extension CleanupResultTests {
    @Test("totalFreed sums only succeeded items")
    func totalFreedSumsSucceeded() {
        let result = CleanupResult(itemResults: [
            CleanupItemResult(item: makeItem(id: "a", size: 500), succeeded: true),
            CleanupItemResult(item: makeItem(id: "b", size: 300), succeeded: true),
            CleanupItemResult(item: makeItem(id: "c", size: 200), succeeded: false, error: "Permission denied"),
        ])

        #expect(result.totalFreed == 800)
        #expect(result.cleanupMethod == .trash)
        #expect(result.succeededItems.count == 2)
        #expect(result.failedItems.count == 1)
        #expect(!result.allSucceeded)
    }

    @Test("allSucceeded is true when no failures")
    func allSucceededWhenNoFailures() {
        let result = CleanupResult(itemResults: [
            CleanupItemResult(item: makeItem(id: "a", size: 100), succeeded: true),
            CleanupItemResult(item: makeItem(id: "b", size: 200), succeeded: true),
        ])

        #expect(result.allSucceeded)
        #expect(result.totalFreed == 300)
    }

    @Test("empty result has zero freed and allSucceeded")
    func emptyResult() {
        let result = CleanupResult(itemResults: [])

        #expect(result.totalFreed == 0)
        #expect(result.allSucceeded)
        #expect(result.succeededItems.isEmpty)
        #expect(result.failedItems.isEmpty)
    }

    @Test("all failed returns zero freed")
    func allFailed() {
        let result = CleanupResult(itemResults: [
            CleanupItemResult(item: makeItem(id: "a", size: 500), succeeded: false, error: "E1"),
            CleanupItemResult(item: makeItem(id: "b", size: 300), succeeded: false, error: "E2"),
        ])

        #expect(result.totalFreed == 0)
        #expect(!result.allSucceeded)
        #expect(result.failedItems.count == 2)
    }

    @Test("CleanupItemResult stores trash URL on success")
    func itemResultTrashURL() {
        let url = URL(fileURLWithPath: "/Users/test/.Trash/file.txt")
        let itemResult = CleanupItemResult(
            item: makeItem(),
            succeeded: true,
            trashURL: url
        )

        #expect(itemResult.trashURL == url)
        #expect(itemResult.error == nil)
    }

    @Test("CleanupItemResult stores error on failure")
    func itemResultError() {
        let itemResult = CleanupItemResult(
            item: makeItem(),
            succeeded: false,
            error: "Permission denied"
        )

        #expect(itemResult.trashURL == nil)
        #expect(itemResult.error == "Permission denied")
    }
}
