import Foundation
import Testing
@testable import GargantuaCore

@Suite("CleanupResult")
struct CleanupResultTests {
    private func makeItem(
        id: String = "test",
        path: String? = nil,
        size: Int64 = 1000,
        safety: SafetyLevel = .safe
    ) -> ScanResult {
        ScanResult(
            id: id,
            name: "Test Item \(id)",
            path: path ?? "/tmp/test/\(id)",
            size: size,
            safety: safety,
            confidence: 95,
            explanation: "Test item",
            source: SourceAttribution(name: "Test"),
            category: "test"
        )
    }

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

    // MARK: - Trash Container Special Case

    /// Build a fake home directory with a `.Trash` subdirectory populated
    /// by `children`. Returns (home URL, trash URL, sizes) for assertions.
    @discardableResult
    private func makeFakeTrash(children: [String: Data]) throws -> (home: URL, trash: URL, totalBytes: Int64) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-trash-test-\(UUID().uuidString)", isDirectory: true)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var total: Int64 = 0
        for (name, data) in children {
            try data.write(to: trash.appendingPathComponent(name))
            total += Int64(data.count)
        }
        return (home, trash, total)
    }

    @Test("delete on Trash container empties contents but keeps the directory")
    @MainActor
    func deleteTrashContainer() async throws {
        let (home, trash, total) = try makeFakeTrash(children: [
            "file1.txt": Data("aaa".utf8),
            "file2.log": Data("bbbbb".utf8),
            ".hidden": Data("c".utf8),
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let item = makeItem(id: "trash", path: trash.path, size: total)
        let engine = CleanupEngine(homeDirectoryForTesting: home)
        let result = await engine.clean([item], method: .delete)

        #expect(result.allSucceeded)
        #expect(result.totalFreed == total)
        // Trash directory preserved, children gone
        #expect(FileManager.default.fileExists(atPath: trash.path))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        #expect(remaining.isEmpty)
    }

    @Test("trash method on Trash container also empties contents (auto-promote)")
    @MainActor
    func trashMethodOnTrashContainerEmpties() async throws {
        let (home, trash, total) = try makeFakeTrash(children: [
            "a.txt": Data("x".utf8),
            "b.txt": Data("y".utf8),
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let item = makeItem(id: "trash", path: trash.path, size: total)
        let engine = CleanupEngine(homeDirectoryForTesting: home)
        let result = await engine.clean([item], method: .trash)

        #expect(result.allSucceeded)
        #expect(FileManager.default.fileExists(atPath: trash.path))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        #expect(remaining.isEmpty)
    }

    @Test("empty Trash container reports success with zero work")
    @MainActor
    func emptyTrashContainerNoOp() async throws {
        let (home, trash, _) = try makeFakeTrash(children: [:])
        defer { try? FileManager.default.removeItem(at: home) }

        let item = makeItem(id: "trash", path: trash.path, size: 0)
        let engine = CleanupEngine(homeDirectoryForTesting: home)
        let result = await engine.clean([item], method: .delete)

        #expect(result.allSucceeded)
        #expect(FileManager.default.fileExists(atPath: trash.path))
    }

    @Test("Trash path with trailing slash is treated as container")
    @MainActor
    func trashContainerTrailingSlash() async throws {
        let (home, trash, total) = try makeFakeTrash(children: [
            "f.txt": Data("z".utf8),
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        // ScanResult path with trailing slash
        let pathWithSlash = trash.path + "/"
        let item = makeItem(id: "trash", path: pathWithSlash, size: total)
        let engine = CleanupEngine(homeDirectoryForTesting: home)
        let result = await engine.clean([item], method: .delete)

        #expect(result.allSucceeded)
        #expect(FileManager.default.fileExists(atPath: trash.path))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        #expect(remaining.isEmpty)
    }

    @Test("Partial failure on Trash empty reports a summary error")
    @MainActor
    func trashContainerPartialFailure() async throws {
        let (home, trash, total) = try makeFakeTrash(children: [
            "removable.txt": Data("ok".utf8),
            "stuck-dir": Data("ignored".utf8),
        ])
        defer {
            // Restore writability before cleanup
            let stuck = trash.appendingPathComponent("stuck-dir")
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: trash.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stuck.path)
            try? FileManager.default.removeItem(at: home)
        }

        // Replace one file with a subdirectory whose parent we'll make
        // read-only, so removeItem on the child fails with EACCES.
        let stuck = trash.appendingPathComponent("stuck-dir")
        try FileManager.default.removeItem(at: stuck) // was a file
        try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: stuck.appendingPathComponent("inner.txt"))
        // Remove write permission from Trash so children can't be unlinked.
        // Actually removeItem unlinks by child, parent needs write perms.
        // Revoke write on Trash itself:
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: trash.path)

        let item = makeItem(id: "trash", path: trash.path, size: total)
        let engine = CleanupEngine(homeDirectoryForTesting: home)
        let result = await engine.clean([item], method: .delete)

        #expect(!result.allSucceeded)
        #expect(result.failedItems.count == 1)
        let error = result.failedItems.first?.error ?? ""
        #expect(!error.isEmpty)
    }
}

@MainActor
private final class RecordingTrashMover: TrashMoving {
    enum Outcome {
        case success(URL?)
        case failure(String)
    }

    private let outcome: Outcome
    private(set) var movedURLs: [URL] = []

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func moveToTrash(_ url: URL) async throws -> URL? {
        movedURLs.append(url)
        switch outcome {
        case .success(let trashURL):
            return trashURL
        case .failure(let message):
            throw TrashMoveFailure(message: message)
        }
    }
}
