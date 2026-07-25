import Foundation
import GargantuaLicensing
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
        let result = await CleanupEngine().clean([item], method: .delete, authorization: .unchecked(.deepClean))

        #expect(result.cleanupMethod == .delete)
        #expect(result.allSucceeded)
        #expect(result.totalFreed == 6)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("trash method uses injected mover")
    @MainActor
    func trashMethodUsesInjectedMover() async {
        let item = makeItem(id: "trash-primary", path: "/tmp/gargantua-trash-primary", size: 12)
        let expectedTrashURL = URL(fileURLWithPath: "/Users/test/.Trash/gargantua-trash-primary")
        let mover = RecordingTrashMover(outcome: .success(expectedTrashURL))
        let engine = CleanupEngine(homeDirectoryForTesting: FileManager.default.homeDirectoryForCurrentUser, trashMover: mover)

        let result = await engine.clean([item], method: .trash, authorization: .unchecked(.deepClean))

        #expect(result.allSucceeded)
        #expect(result.totalFreed == 12)
        #expect(result.itemResults.first?.trashURL == expectedTrashURL)
        #expect(mover.movedURLs == [URL(fileURLWithPath: item.path)])
    }

    @Test("primary trash failure falls back to the secondary mover")
    @MainActor
    func primaryFailureFallsBackToSecondaryMover() async throws {
        let item = makeItem(id: "trash-fallback", path: "/tmp/gargantua-trash-fallback", size: 34)
        let expectedTrashURL = URL(fileURLWithPath: "/Users/test/.Trash/gargantua-trash-fallback")
        let primary = RecordingTrashMover(outcome: .failure("Trash API failed"))
        let fallback = RecordingTrashMover(outcome: .success(expectedTrashURL))
        let mover = FallbackTrashMover(primary: primary, fallback: fallback)
        let engine = CleanupEngine(homeDirectoryForTesting: FileManager.default.homeDirectoryForCurrentUser, trashMover: mover)

        let result = await engine.clean([item], method: .trash, authorization: .unchecked(.deepClean))

        #expect(result.allSucceeded)
        #expect(result.itemResults.first?.trashURL == expectedTrashURL)
        #expect(primary.movedURLs == [URL(fileURLWithPath: item.path)])
        #expect(fallback.movedURLs == [URL(fileURLWithPath: item.path)])
    }

    @Test("Trash fallback failure preserves per-item result shape")
    @MainActor
    func trashFallbackFailurePreservesItemResult() async {
        let item = makeItem(id: "trash-fallback-failure", path: "/tmp/gargantua-trash-fallback-failure", size: 56)
        let primary = RecordingTrashMover(outcome: .failure("Trash API failed"))
        let fallback = RecordingTrashMover(outcome: .failure("No such file"))
        let mover = FallbackTrashMover(primary: primary, fallback: fallback)
        let engine = CleanupEngine(homeDirectoryForTesting: FileManager.default.homeDirectoryForCurrentUser, trashMover: mover)

        let result = await engine.clean([item], method: .trash, authorization: .unchecked(.deepClean))

        #expect(result.cleanupMethod == .trash)
        #expect(result.itemResults.count == 1)
        #expect(result.failedItems.count == 1)
        let itemResult = result.itemResults[0]
        #expect(itemResult.succeeded == false)
        #expect(itemResult.trashURL == nil)
        #expect(itemResult.item.id == item.id)
        #expect(itemResult.error?.contains("Trash move failed: Trash API failed") == true)
        #expect(itemResult.error?.contains("Fallback also failed: No such file") == true)
    }
}
