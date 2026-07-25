import Foundation
import GargantuaLicensing
import Testing
@testable import GargantuaCore

extension CleanupResultTests {
    @Test("macOS-managed var/folders bucket roots are skipped before Finder")
    @MainActor
    func macOSManagedVarFoldersBucketRootIsSkipped() async {
        let path = "/private/var/folders/tr/ch4z08nj67q9dnyl9fv3v9400000gn/C"
        let item = makeItem(id: "var-folders-c", path: path, size: 123)
        let mover = RecordingTrashMover(outcome: .success(URL(fileURLWithPath: "/Users/test/.Trash/C")))
        let engine = CleanupEngine(
            homeDirectoryForTesting: FileManager.default.homeDirectoryForCurrentUser,
            trashMover: mover
        )

        let result = await engine.clean([item], method: .trash, authorization: .unchecked(.deepClean))

        #expect(!result.allSucceeded)
        #expect(result.failedItems.count == 1)
        #expect(result.failedItems.first?.error?.contains("macOS-managed") == true)
        #expect(result.failedItems.first?.error?.contains(path) == true)
        #expect(mover.movedURLs.isEmpty)
    }

    @Test("protected Library roots are skipped before Finder")
    @MainActor
    func protectedLibraryRootsAreSkippedBeforeFinder() async {
        let home = URL(fileURLWithPath: "/Users/gargantua-test", isDirectory: true)
        let paths = [
            home.appendingPathComponent("Library", isDirectory: true).path,
            "/Library",
            "/System/Library",
            "/System/Volumes/Data/Library",
            "/System/Volumes/Data/Users/gargantua-test/Library",
        ]

        for path in paths {
            let item = makeItem(id: "library-root-\(path.hashValue)", path: path, size: 321)
            let mover = RecordingTrashMover(outcome: .success(URL(fileURLWithPath: "/Users/test/.Trash/Library")))
            let engine = CleanupEngine(homeDirectoryForTesting: home, trashMover: mover)

            let result = await engine.clean([item], method: .trash, authorization: .unchecked(.deepClean))

            #expect(!result.allSucceeded)
            #expect(result.failedItems.count == 1)
            #expect(result.failedItems.first?.error?.contains("Skipped") == true)
            #expect(result.failedItems.first?.error?.contains("Library root") == true)
            #expect(result.failedItems.first?.error?.contains(path) == true)
            #expect(mover.movedURLs.isEmpty)
        }
    }

    @Test("items under a symlinked scan root reach Finder when scan-time ancestry was recorded")
    @MainActor
    func symlinkedScanRootItemsStillReachFinder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanup-symlink-root-\(UUID().uuidString)", isDirectory: true)
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: real.appendingPathComponent("cache.bin"))
        let link = root.appendingPathComponent("dev")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: root) }

        // The scan walked through the symlinked root (~/dev -> elsewhere) and
        // recorded where the parent chain resolved at scan time.
        let throughLink = link.appendingPathComponent("cache.bin")
        var item = makeItem(id: "symlinked-root-cache", path: throughLink.path, size: 1)
        item.scanTimeResolvedParent = throughLink
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .path

        let expectedTrashURL = URL(fileURLWithPath: "/Users/test/.Trash/cache.bin")
        let mover = RecordingTrashMover(outcome: .success(expectedTrashURL))
        let engine = CleanupEngine(
            homeDirectoryForTesting: URL(fileURLWithPath: "/Users/gargantua-test", isDirectory: true),
            trashMover: mover
        )

        let result = await engine.clean([item], method: .trash, authorization: .unchecked(.deepClean))

        #expect(result.allSucceeded)
        #expect(mover.movedURLs == [URL(fileURLWithPath: throughLink.path)])

        // Without the recording, the same item is still refused — fail-safe.
        let unrecorded = makeItem(id: "symlinked-root-unrecorded", path: throughLink.path, size: 1)
        let refusedMover = RecordingTrashMover(outcome: .success(expectedTrashURL))
        let refusingEngine = CleanupEngine(
            homeDirectoryForTesting: URL(fileURLWithPath: "/Users/gargantua-test", isDirectory: true),
            trashMover: refusedMover
        )
        let refused = await refusingEngine.clean([unrecorded], method: .trash, authorization: .unchecked(.deepClean))
        #expect(!refused.allSucceeded)
        #expect(refused.failedItems.first?.error?.contains("symlink") == true)
        #expect(refusedMover.movedURLs.isEmpty)
    }

    @Test("nested Library cleanup targets still reach Finder")
    @MainActor
    func nestedLibraryCleanupTargetsStillReachFinder() async {
        let home = URL(fileURLWithPath: "/Users/gargantua-test", isDirectory: true)
        let path = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("com.example.app", isDirectory: true)
            .path
        let item = makeItem(id: "nested-library-cache", path: path, size: 456)
        let expectedTrashURL = URL(fileURLWithPath: "/Users/test/.Trash/com.example.app")
        let mover = RecordingTrashMover(outcome: .success(expectedTrashURL))
        let engine = CleanupEngine(homeDirectoryForTesting: home, trashMover: mover)

        let result = await engine.clean([item], method: .trash, authorization: .unchecked(.deepClean))

        #expect(result.allSucceeded)
        #expect(result.itemResults.first?.trashURL == expectedTrashURL)
        #expect(mover.movedURLs == [URL(fileURLWithPath: path)])
    }
}
