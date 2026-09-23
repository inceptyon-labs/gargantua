import Foundation
import Testing
@testable import GargantuaCore

@Suite("Disk Explorer trash policy")
struct DiskExplorerTrashPolicyTests {
    /// A scratch root under the system temp directory, standing in for both
    /// "Home" and the outside world so tests don't depend on the real Home.
    /// macOS temp dirs resolve through a `/var` → `/private/var` symlink, so
    /// this is pre-resolved the same way the policy resolves paths, keeping
    /// both sides of every comparison consistent.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskExplorerTrashPolicyTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Home itself is not trashable; descendants are")
    func homeAndDescendants() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let file = home.appendingPathComponent("file.txt")
        let nested = home.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data())

        #expect(!DiskExplorerTrashPolicy.canTrash(path: home.path, home: home.path))
        #expect(DiskExplorerTrashPolicy.canTrash(path: file.path, home: home.path))
        #expect(DiskExplorerTrashPolicy.canTrash(path: nested.path, home: home.path))
    }

    @Test("A sibling that shares Home's name as a prefix is not inside Home")
    func prefixSiblingIsNotInsideHome() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let siblingFile = root.appendingPathComponent("homeX/file.txt")
        try FileManager.default.createDirectory(
            at: siblingFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: siblingFile.path, contents: Data())

        #expect(!DiskExplorerTrashPolicy.canTrash(path: siblingFile.path, home: home.path))
    }

    @Test("Root and other paths outside Home are not trashable")
    func rootAndOutsidePaths() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        #expect(!DiskExplorerTrashPolicy.canTrash(path: "/", home: home.path))
        #expect(!DiskExplorerTrashPolicy.canTrash(path: root.path, home: home.path))
    }

    @Test("A symlink outside Home pointing into Home is not trashable")
    func symlinkOutsideHomePointingIn() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let outsideLink = root.appendingPathComponent("outsideLink")
        try FileManager.default.createSymbolicLink(at: outsideLink, withDestinationURL: home)

        #expect(!DiskExplorerTrashPolicy.canTrash(path: outsideLink.path, home: home.path))
    }

    @Test("A symlink inside Home pointing out of Home is trashable (the link itself)")
    func symlinkInsideHomePointingOut() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let outsideTarget = root.appendingPathComponent("outsideTarget")
        try FileManager.default.createDirectory(at: outsideTarget, withIntermediateDirectories: true)
        let insideLink = home.appendingPathComponent("insideLink")
        try FileManager.default.createSymbolicLink(at: insideLink, withDestinationURL: outsideTarget)

        #expect(DiskExplorerTrashPolicy.canTrash(path: insideLink.path, home: home.path))
    }

    @Test("A parent-chain symlink outside Home that resolves into Home is trashable")
    func parentChainSymlinkResolvesIntoHome() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let dir = home.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("file.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: dir)
        let target = alias.appendingPathComponent("file.txt")

        #expect(DiskExplorerTrashPolicy.canTrash(path: target.path, home: home.path))
    }

    @Test("A mount root under Home, and anything under it, is not trashable")
    func mountRootUnderHome() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let mount = home.appendingPathComponent("mnt")
        let nested = mount.appendingPathComponent("a/b")
        let other = home.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let isMountRoot: (URL) -> Bool? = { url in
            url.resolvingSymlinksInPath().path == mount.path ? true : false
        }

        #expect(!DiskExplorerTrashPolicy.canTrash(path: mount.path, home: home.path, isMountRoot: isMountRoot))
        #expect(!DiskExplorerTrashPolicy.canTrash(path: nested.path, home: home.path, isMountRoot: isMountRoot))
        #expect(DiskExplorerTrashPolicy.canTrash(path: other.path, home: home.path, isMountRoot: isMountRoot))
    }

    @Test("An unreadable mount check fails closed")
    func unreadableMountCheckFailsClosed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let file = home.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data())

        #expect(!DiskExplorerTrashPolicy.canTrash(path: file.path, home: home.path, isMountRoot: { _ in nil }))
    }

    @Test("isInsideHome covers Home, descendants, prefix siblings, and root")
    func isInsideHome() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let descendant = home.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: descendant, withIntermediateDirectories: true)
        let prefixSibling = root.appendingPathComponent("homeX/file.txt")
        try FileManager.default.createDirectory(
            at: prefixSibling.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: prefixSibling.path, contents: Data())

        #expect(DiskExplorerTrashPolicy.isInsideHome(home.path, home: home.path))
        #expect(DiskExplorerTrashPolicy.isInsideHome(descendant.path, home: home.path))
        #expect(!DiskExplorerTrashPolicy.isInsideHome(prefixSibling.path, home: home.path))
        #expect(!DiskExplorerTrashPolicy.isInsideHome("/", home: home.path))
    }
}
