import Foundation
import Testing
@testable import GargantuaCore

extension CleanupResultTests {
    @Test("delete cleanup method permanently removes existing file")
    @MainActor
    func deleteMethodRemovesFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-delete-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("delete-me.txt")
        try Data("delete".utf8).write(to: file)

        let item = makeItem(id: "delete", path: file.path, size: 6)
        let result = await CleanupEngine().clean([item], method: .delete)

        #expect(result.cleanupMethod == .delete)
        #expect(result.allSucceeded)
        #expect(result.totalFreed == 6)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("trash method uses injected Finder-first mover")
    @MainActor
    func trashMethodUsesInjectedMover() async {
        let item = makeItem(id: "finder-primary", path: "/tmp/gargantua-finder-primary", size: 12)
        let expectedTrashURL = URL(fileURLWithPath: "/Users/test/.Trash/gargantua-finder-primary")
        let mover = RecordingTrashMover(outcome: .success(expectedTrashURL))
        let engine = CleanupEngine(homeDirectoryForTesting: FileManager.default.homeDirectoryForCurrentUser, trashMover: mover)

        let result = await engine.clean([item], method: .trash)

        #expect(result.allSucceeded)
        #expect(result.totalFreed == 12)
        #expect(result.itemResults.first?.trashURL == expectedTrashURL)
        #expect(mover.movedURLs == [URL(fileURLWithPath: item.path)])
    }

    @Test("Finder Automation failure falls back to direct Trash mover")
    @MainActor
    func finderFailureFallsBackToDirectTrashMover() async throws {
        let item = makeItem(id: "finder-fallback", path: "/tmp/gargantua-finder-fallback", size: 34)
        let expectedTrashURL = URL(fileURLWithPath: "/Users/test/.Trash/gargantua-finder-fallback")
        let finder = RecordingTrashMover(outcome: .failure("Automation denied"))
        let direct = RecordingTrashMover(outcome: .success(expectedTrashURL))
        let mover = FinderFirstTrashMover(primary: finder, fallback: direct)
        let engine = CleanupEngine(homeDirectoryForTesting: FileManager.default.homeDirectoryForCurrentUser, trashMover: mover)

        let result = await engine.clean([item], method: .trash)

        #expect(result.allSucceeded)
        #expect(result.itemResults.first?.trashURL == expectedTrashURL)
        #expect(finder.movedURLs == [URL(fileURLWithPath: item.path)])
        #expect(direct.movedURLs == [URL(fileURLWithPath: item.path)])
    }

    @Test("Trash fallback failure preserves per-item result shape")
    @MainActor
    func trashFallbackFailurePreservesItemResult() async {
        let item = makeItem(id: "finder-fallback-failure", path: "/tmp/gargantua-finder-fallback-failure", size: 56)
        let finder = RecordingTrashMover(outcome: .failure("Automation denied"))
        let direct = RecordingTrashMover(outcome: .failure("No such file"))
        let mover = FinderFirstTrashMover(primary: finder, fallback: direct)
        let engine = CleanupEngine(homeDirectoryForTesting: FileManager.default.homeDirectoryForCurrentUser, trashMover: mover)

        let result = await engine.clean([item], method: .trash)

        #expect(result.cleanupMethod == .trash)
        #expect(result.itemResults.count == 1)
        #expect(result.failedItems.count == 1)
        let itemResult = result.itemResults[0]
        #expect(itemResult.succeeded == false)
        #expect(itemResult.trashURL == nil)
        #expect(itemResult.item.id == item.id)
        #expect(itemResult.error?.contains("Finder Automation failed: Automation denied") == true)
        #expect(itemResult.error?.contains("Direct Trash API fallback failed: No such file") == true)
    }
}
