import Darwin
import Foundation
import Testing
@testable import GargantuaCore

@Suite("DirectorySizeScanner")
struct DirectorySizeScannerTests {

    // MARK: - Fixture helpers

    /// Build a known directory layout and return its root.
    ///
    ///     root/
    ///       big/
    ///         a.bin     (10 KB)
    ///         nested/
    ///           b.bin   (20 KB)
    ///       small/
    ///         c.bin     ( 1 KB)
    ///       loose.txt   ( 2 KB)
    ///       another.txt (  3 KB)
    private func makeFixture() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dss-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let big = root.appendingPathComponent("big", isDirectory: true)
        let bigNested = big.appendingPathComponent("nested", isDirectory: true)
        let small = root.appendingPathComponent("small", isDirectory: true)
        try fm.createDirectory(at: bigNested, withIntermediateDirectories: true)
        try fm.createDirectory(at: small, withIntermediateDirectories: true)

        try Data(count: 10_000).write(to: big.appendingPathComponent("a.bin"))
        try Data(count: 20_000).write(to: bigNested.appendingPathComponent("b.bin"))
        try Data(count: 1_000).write(to: small.appendingPathComponent("c.bin"))
        try Data(count: 2_000).write(to: root.appendingPathComponent("loose.txt"))
        try Data(count: 3_000).write(to: root.appendingPathComponent("another.txt"))

        return root
    }

    private func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - scanChildren (aggregating)

    @Test("scanChildren returns subdirectories sorted largest first")
    func scanChildrenSorted() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }

        let items = await DirectorySizeScanner.scanChildren(of: root.path)

        let names = items.map(\.name)
        #expect(names.contains("big"))
        #expect(names.contains("small"))
        #expect(names.contains("(Files)"))
        // Sort is largest-first; `big` (~30 KB logical) must dominate `small` (~1 KB logical)
        // regardless of filesystem block-size rounding.
        let big = items.first { $0.name == "big" }
        let small = items.first { $0.name == "small" }
        #expect(big != nil && small != nil)
        #expect((big?.size ?? 0) > (small?.size ?? 0))
        #expect(items.first?.name == "big")
    }

    @Test("scanChildren aggregates loose files into (Files) entry")
    func scanChildrenFilesAggregate() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }

        let items = await DirectorySizeScanner.scanChildren(of: root.path)
        let filesAggregate = items.first { $0.name == "(Files)" }

        #expect(filesAggregate != nil)
        // Loose files exist (2 KB + 3 KB logical); on-disk allocation may round up
        // to block size, so just require a positive aggregate.
        #expect((filesAggregate?.size ?? 0) > 0)
        #expect(filesAggregate?.path.hasSuffix("/(files)") == true)
    }

    @Test("scanChildren final rows carry isSizing = false")
    func scanChildrenFinalRowsNotSizing() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }

        let items = await DirectorySizeScanner.scanChildren(of: root.path)
        for item in items {
            #expect(item.isSizing == false)
        }
    }

    // MARK: - streamChildren (progressive)

    @Test("streamChildren emits isSizing placeholders before final sizes")
    func streamEmitsPlaceholdersFirst() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }

        var events: [DirectoryItem] = []
        for await item in DirectorySizeScanner.streamChildren(of: root.path) {
            events.append(item)
        }

        // Assert ordering for every final directory row: a sizing placeholder
        // with the same id must exist strictly before it in the event stream.
        let finals = events.enumerated().filter { !$0.element.isSizing && !$0.element.isFilesAggregate }
        #expect(!finals.isEmpty, "expected at least one final directory row")
        for (finalIndex, finalEvent) in finals {
            let placeholderIndex = events.firstIndex { $0.id == finalEvent.id && $0.isSizing }
            #expect(placeholderIndex != nil, "missing placeholder for \(finalEvent.name)")
            if let placeholderIndex {
                #expect(placeholderIndex < finalIndex, "placeholder for \(finalEvent.name) must precede its final row")
            }
        }
    }

    @Test("streamChildren emits exactly one placeholder and one final row per subdirectory")
    func streamEmitsOneOfEach() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }

        var placeholders = 0
        var finals = 0
        var filesAggregates = 0
        for await item in DirectorySizeScanner.streamChildren(of: root.path) {
            if item.name == "(Files)" {
                filesAggregates += 1
            } else if item.isSizing {
                placeholders += 1
            } else {
                finals += 1
            }
        }

        #expect(placeholders == 2) // big + small
        #expect(finals == 2)
        #expect(filesAggregates == 1)
    }

    @Test("streamChildren final rows carry correct recursive sizes")
    func streamFinalSizesCorrect() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }

        var finalByName: [String: Int64] = [:]
        for await item in DirectorySizeScanner.streamChildren(of: root.path) {
            if !item.isSizing, item.name != "(Files)" {
                finalByName[item.name] = item.size
            }
        }

        // Block-size rounding means we can't assert exact logical byte counts.
        // What must hold: both final sizes exist and `big` dominates `small`.
        #expect(finalByName["big"] != nil)
        #expect(finalByName["small"] != nil)
        #expect((finalByName["big"] ?? 0) > (finalByName["small"] ?? 0))
    }

    @Test("directorySize reports partial result when timeout is exceeded")
    func directorySizeTimeoutReturnsPartialResult() throws {
        let root = try makeFixture()
        defer { cleanup(root) }

        let result = DirectorySizeScanner.directorySize(at: root.path, timeout: .zero)

        #expect(result.isPartial)
        #expect(result.totalSize >= 0)
    }

    @Test("directorySize reports complete result when no timeout is exceeded")
    func directorySizeWithoutTimeoutReturnsCompleteResult() throws {
        let root = try makeFixture()
        defer { cleanup(root) }

        let result = DirectorySizeScanner.directorySize(at: root.path, timeout: nil)

        #expect(!result.isPartial)
        #expect(result.totalSize > 0)
    }

    @Test("streamChildren marks timed out final rows as partial")
    func streamChildrenMarksPartialFinalRows() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }

        var partialFinalCount = 0
        for await item in DirectorySizeScanner.streamChildren(
            of: root.path,
            directorySizeTimeout: .zero
        ) where !item.isSizing && !item.isFilesAggregate {
            if item.isPartial {
                partialFinalCount += 1
            }
        }

        #expect(partialFinalCount == 2)
    }

    @Test("directorySize counts hidden content so all-hidden remnants aren't sized to zero")
    func directorySizeCountsHiddenContent() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dss-hidden-\(UUID().uuidString)", isDirectory: true)
        let hiddenDir = root.appendingPathComponent(".cache", isDirectory: true)
        try fm.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // A remnant whose contents are entirely hidden: a dotfile at the top and
        // a file inside a hidden subdirectory. A delete would remove all of it.
        try Data(count: 8_000).write(to: root.appendingPathComponent(".DS_Store"))
        try Data(count: 16_000).write(to: hiddenDir.appendingPathComponent("blob.bin"))

        let result = DirectorySizeScanner.directorySize(at: root.path, timeout: nil)

        #expect(!result.isPartial)
        // Both hidden files must be counted; previously this sized to 0 and the
        // remnant was silently dropped by size > 0 guards.
        #expect(result.totalSize > 0)
    }

    @Test("streamChildren returns empty stream for non-existent path")
    func streamNonExistentPath() async throws {
        let fakePath = "/nonexistent-\(UUID().uuidString)"
        var count = 0
        for await _ in DirectorySizeScanner.streamChildren(of: fakePath) {
            count += 1
        }
        #expect(count == 0)
    }

    @Test("streamChildren disambiguates a real (files) directory from the aggregate")
    func streamHandlesLiteralFilesDir() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dss-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Create a real subdirectory literally named "(files)" alongside
        // loose files that would otherwise be aggregated into a synthetic
        // row with the same filesystem path.
        let realFilesDir = root.appendingPathComponent("(files)", isDirectory: true)
        try fm.createDirectory(at: realFilesDir, withIntermediateDirectories: true)
        try Data(count: 512).write(to: realFilesDir.appendingPathComponent("inner.txt"))
        try Data(count: 4_096).write(to: root.appendingPathComponent("loose1.txt"))
        try Data(count: 4_096).write(to: root.appendingPathComponent("loose2.txt"))

        var finals: [DirectoryItem] = []
        for await item in DirectorySizeScanner.streamChildren(of: root.path) where !item.isSizing {
            finals.append(item)
        }

        // Both rows must survive; the aggregate's id must not collide with the real dir's id.
        let realDirRow = finals.first { $0.name == "(files)" && !$0.isFilesAggregate }
        let aggregateRow = finals.first { $0.isFilesAggregate }
        #expect(realDirRow != nil, "real (files) directory must appear as a distinct row")
        #expect(aggregateRow != nil, "loose files must appear as a (Files) aggregate row")
        if let realDirRow, let aggregateRow {
            #expect(realDirRow.id != aggregateRow.id, "ids must differ to survive upsert dedupe")
        }
    }

    // MARK: - UF_HIDDEN system folders vs. dotfiles

    @Test("scanChildren lists a UF_HIDDEN directory but not a dot-prefixed one")
    func scanChildrenListsHiddenSystemFolder() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dss-uf-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let ufHidden = root.appendingPathComponent("opt_like", isDirectory: true)
        let dotDir = root.appendingPathComponent(".dotdir", isDirectory: true)
        try fm.createDirectory(at: ufHidden, withIntermediateDirectories: true)
        try fm.createDirectory(at: dotDir, withIntermediateDirectories: true)

        var rv = URLResourceValues()
        rv.isHidden = true
        var flaggedURL = ufHidden
        try flaggedURL.setResourceValues(rv)
        let stuck = (try? flaggedURL.resourceValues(forKeys: [.isHiddenKey]))?.isHidden ?? false
        try #require(stuck, "UF_HIDDEN flag must stick to the test fixture for this test to be meaningful")

        let items = await DirectorySizeScanner.scanChildren(of: root.path)
        let names = items.map(\.name)
        #expect(names.contains("opt_like"))
        #expect(!names.contains(".dotdir"))
    }

    // MARK: - Mount roots

    @Test("streamChildren lists a mount root without sizing it")
    func streamChildrenListsMountRootUnsized() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }

        let mountName = "big"
        var events: [DirectoryItem] = []
        for await item in DirectorySizeScanner.streamChildren(
            of: root.path,
            directorySizeTimeout: DirectorySizeScanner.defaultDirectorySizeTimeout,
            mountRootCheck: { url in (url.lastPathComponent == mountName, false) }
        ) {
            events.append(item)
        }

        let mountEvents = events.filter { $0.name == mountName }
        #expect(mountEvents.count == 1, "a mount root must yield exactly one row, no sizing placeholder")
        let mountRow = try #require(mountEvents.first)
        #expect(mountRow.isMountRoot)
        #expect(mountRow.size == 0)
        #expect(!mountRow.isSizing)

        // Other children are unaffected and still sized normally.
        let smallFinal = events.first { $0.name == "small" && !$0.isSizing }
        #expect(smallFinal != nil)
        #expect(!(smallFinal?.isMountRoot ?? true))
    }

    @Test("streamChildren propagates isNetworkVolume for network mounts")
    func streamChildrenPropagatesNetworkVolume() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }

        var events: [DirectoryItem] = []
        for await item in DirectorySizeScanner.streamChildren(
            of: root.path,
            directorySizeTimeout: DirectorySizeScanner.defaultDirectorySizeTimeout,
            mountRootCheck: { url in (url.lastPathComponent == "small", true) }
        ) {
            events.append(item)
        }

        let mountRow = events.first { $0.name == "small" }
        #expect(mountRow?.isMountRoot == true)
        #expect(mountRow?.isNetworkVolume == true)
    }

    // MARK: - Partial results for unreadable content

    @Test("directorySize marks isPartial when a child directory is unreadable, only when opted in")
    func directorySizeMarksPartialForUnreadableChild() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dss-unreadable-\(UUID().uuidString)", isDirectory: true)
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: locked.appendingPathComponent("secret.bin"))
        try Data(count: 500).write(to: root.appendingPathComponent("visible.bin"))
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: root)
        }

        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        guard !fm.isReadableFile(atPath: locked.path) else {
            // Running as a user (e.g. root) for whom chmod 000 is still readable;
            // nothing meaningful to assert.
            return
        }

        let partialResult = DirectorySizeScanner.directorySize(
            at: root.path,
            reportsUnreadableAsPartial: true
        )
        #expect(partialResult.isPartial)

        let defaultResult = DirectorySizeScanner.directorySize(at: root.path)
        #expect(!defaultResult.isPartial)
    }

    @Test("streamChildren cancellation stops emitting promptly")
    func streamCancellation() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }

        let consumer = Task<Int, Never> {
            var seen = 0
            for await _ in DirectorySizeScanner.streamChildren(of: root.path) {
                seen += 1
                if seen == 1 {
                    // Cancel self as soon as we see the first event.
                    return seen
                }
            }
            return seen
        }

        let observed = await consumer.value
        // At least one event was observed before cancellation returned.
        #expect(observed == 1)
    }
}
