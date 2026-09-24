import Darwin
import Foundation
import Testing
@testable import GargantuaCore

extension DirectorySizeScannerTests {

    @Test("directorySize counts a hard-linked file once with explorer accounting, twice by default")
    func directorySizeCountsHardLinkOnceForExplorer() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dss-hardlink-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let original = root.appendingPathComponent("a.bin")
        let hardLink = root.appendingPathComponent("b.bin")
        try Data(count: 1_000_000).write(to: original)
        try fm.linkItem(at: original, to: hardLink)

        let explorerResult = DirectorySizeScanner.directorySize(at: root.path, explorerAccounting: true)
        let defaultResult = DirectorySizeScanner.directorySize(at: root.path)

        let originalAllocated = (try original.resourceValues(forKeys: [.totalFileAllocatedSizeKey])).totalFileAllocatedSize ?? 0
        #expect(explorerResult.totalSize == Int64(originalAllocated))
        #expect(defaultResult.totalSize == Int64(originalAllocated) * 2)
    }

    @Test("directorySize reports sharedCloneBytes for an APFS clone pair, opt-in only")
    func directorySizeReportsSharedCloneBytes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dss-clone-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let original = root.appendingPathComponent("orig.bin")
        let clone = root.appendingPathComponent("clone.bin")
        try Data(count: 1_000_000).write(to: original)

        let cloneStatus = copyfile(original.path, clone.path, nil, copyfile_flags_t(COPYFILE_CLONE))
        try #require(cloneStatus == 0, "clonefile via copyfile(COPYFILE_CLONE) must succeed on APFS for this test to be meaningful")

        let explorerResult = DirectorySizeScanner.directorySize(at: root.path, explorerAccounting: true)
        #expect(explorerResult.sharedCloneBytes > 0)

        let defaultResult = DirectorySizeScanner.directorySize(at: root.path)
        #expect(defaultResult.sharedCloneBytes == 0)
    }

    @Test("directorySize counts a cloned file's shared bytes once even when it also has a hard link")
    func directorySizeCountsSharedCloneBytesOncePerInodeDespiteHardLink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dss-clone-hardlink-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let original = root.appendingPathComponent("orig.bin")
        let clone = root.appendingPathComponent("clone.bin")
        let cloneLink = root.appendingPathComponent("clone_link.bin")
        try Data(count: 1_000_000).write(to: original)

        let cloneStatus = copyfile(original.path, clone.path, nil, copyfile_flags_t(COPYFILE_CLONE))
        try #require(cloneStatus == 0, "clonefile via copyfile(COPYFILE_CLONE) must succeed on APFS for this test to be meaningful")
        try fm.linkItem(at: clone, to: cloneLink)

        let result = DirectorySizeScanner.directorySize(at: root.path, explorerAccounting: true)

        let originalAllocated = (try original.resourceValues(forKeys: [.totalFileAllocatedSizeKey])).totalFileAllocatedSize ?? 0
        let cloneAllocated = (try clone.resourceValues(forKeys: [.totalFileAllocatedSizeKey])).totalFileAllocatedSize ?? 0

        // The clone/hard-link pair share one inode: its allocation is counted once, not twice.
        #expect(result.totalSize == Int64(originalAllocated) + Int64(cloneAllocated))
        // Shared-clone bytes are attributed once per inode, not once per hard link to it.
        #expect(result.sharedCloneBytes > 0)
        #expect(result.sharedCloneBytes <= result.totalSize)
    }

    @Test("directorySize reports zero sharedCloneBytes for a plain copy")
    func directorySizeReportsNoSharedCloneBytesForPlainCopy() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dss-plaincopy-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Two files with identical content but no clone relationship: writing bytes
        // directly (rather than `FileManager.copyItem`, which on APFS transparently
        // clones same-volume copies) is what makes this genuinely a "plain copy".
        try Data(count: 1_000_000).write(to: root.appendingPathComponent("orig.bin"))
        try Data(count: 1_000_000).write(to: root.appendingPathComponent("copy.bin"))

        let explorerResult = DirectorySizeScanner.directorySize(at: root.path, explorerAccounting: true)
        #expect(explorerResult.sharedCloneBytes == 0)
    }

    @Test("streamChildren carries sharedCloneBytes on a child directory containing a clone pair")
    func streamChildrenCarriesSharedCloneBytes() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dss-clone-child-\(UUID().uuidString)", isDirectory: true)
        let cloneDir = root.appendingPathComponent("cloned", isDirectory: true)
        try fm.createDirectory(at: cloneDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let original = cloneDir.appendingPathComponent("orig.bin")
        let clone = cloneDir.appendingPathComponent("clone.bin")
        try Data(count: 1_000_000).write(to: original)

        let cloneStatus = copyfile(original.path, clone.path, nil, copyfile_flags_t(COPYFILE_CLONE))
        try #require(cloneStatus == 0, "clonefile via copyfile(COPYFILE_CLONE) must succeed on APFS for this test to be meaningful")

        var finalRow: DirectoryItem?
        for await item in DirectorySizeScanner.streamChildren(of: root.path) where !item.isSizing && item.name == "cloned" {
            finalRow = item
        }

        let row = try #require(finalRow)
        #expect(row.sharedCloneBytes > 0)
    }

    @Test("streamChildren (Files) aggregate counts a hard-linked loose file pair once")
    func filesAggregateCountsHardLinkedLooseFilesOnce() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dss-files-hardlink-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let original = root.appendingPathComponent("a.bin")
        let hardLink = root.appendingPathComponent("b.bin")
        try Data(count: 1_000_000).write(to: original)
        try fm.linkItem(at: original, to: hardLink)

        var filesRow: DirectoryItem?
        for await item in DirectorySizeScanner.streamChildren(of: root.path) where item.isFilesAggregate {
            filesRow = item
        }

        let row = try #require(filesRow)
        let originalAllocated = (try original.resourceValues(forKeys: [.totalFileAllocatedSizeKey])).totalFileAllocatedSize ?? 0
        #expect(row.size == Int64(originalAllocated))
    }

    @Test("streamChildren (Files) aggregate reports sharedCloneBytes for a loose clone pair")
    func filesAggregateReportsSharedCloneBytesForLooseClonePair() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dss-files-clone-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let original = root.appendingPathComponent("orig.bin")
        let clone = root.appendingPathComponent("clone.bin")
        try Data(count: 1_000_000).write(to: original)

        let cloneStatus = copyfile(original.path, clone.path, nil, copyfile_flags_t(COPYFILE_CLONE))
        try #require(cloneStatus == 0, "clonefile via copyfile(COPYFILE_CLONE) must succeed on APFS for this test to be meaningful")

        var filesRow: DirectoryItem?
        for await item in DirectorySizeScanner.streamChildren(of: root.path) where item.isFilesAggregate {
            filesRow = item
        }

        let row = try #require(filesRow)
        #expect(row.sharedCloneBytes > 0)
        #expect(row.sharedCloneBytes <= row.size)
    }

    @Test("scanChildren sizes a child directory with two links to one file as one file")
    func scanChildrenDedupesHardLinkedChildDirectory() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dss-child-hardlink-\(UUID().uuidString)", isDirectory: true)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try fm.createDirectory(at: linked, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let original = linked.appendingPathComponent("a.bin")
        let hardLink = linked.appendingPathComponent("b.bin")
        try Data(count: 1_000_000).write(to: original)
        try fm.linkItem(at: original, to: hardLink)

        let items = await DirectorySizeScanner.scanChildren(of: root.path)
        let linkedRow = try #require(items.first { $0.name == "linked" })
        let originalAllocated = (try original.resourceValues(forKeys: [.totalFileAllocatedSizeKey])).totalFileAllocatedSize ?? 0
        #expect(linkedRow.size == Int64(originalAllocated))
    }
}
