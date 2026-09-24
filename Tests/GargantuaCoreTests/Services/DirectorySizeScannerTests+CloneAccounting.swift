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
}
