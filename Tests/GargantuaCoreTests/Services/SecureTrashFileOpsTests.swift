import Foundation
import Testing
@testable import GargantuaCore

@Suite("SecureTrashFileOps")
struct SecureTrashFileOpsTests {

    private func makeScratch() throws -> URL {
        // Use the fully symlink-resolved (real /private/...) path: macOS's /var
        // (where NSTemporaryDirectory lives) is itself a symlink, which the
        // O_NOFOLLOW walk in openDirectoryNoFollow correctly refuses. This mirrors
        // the helper, which firmlink-resolves source paths before the walk.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gtua-trashops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let real = dir.path.withCString({ realpath($0, nil) }) else { return dir }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    private func openDir(_ url: URL) -> Int32 {
        open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    }

    // MARK: - openTrashDirectory

    @Test("Opens an existing .Trash")
    func opensExistingTrash() throws {
        let home = try makeScratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".Trash"), withIntermediateDirectories: false)

        let fd = SecureTrashFileOps.openTrashDirectory(home: home.path)
        #expect(fd >= 0)
        if fd >= 0 { close(fd) }
    }

    @Test("Does not create .Trash and fails when absent (root must not fabricate a Trash)")
    func failsWhenTrashAbsent() throws {
        let home = try makeScratch()
        defer { try? FileManager.default.removeItem(at: home) }

        let fd = SecureTrashFileOps.openTrashDirectory(home: home.path)
        #expect(fd < 0)
        if fd >= 0 { close(fd) }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".Trash").path))
    }

    @Test("Refuses to open a symlinked .Trash")
    func refusesSymlinkedTrash() throws {
        let home = try makeScratch()
        let elsewhere = try makeScratch()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".Trash"),
            withDestinationURL: elsewhere
        )

        let fd = SecureTrashFileOps.openTrashDirectory(home: home.path)
        #expect(fd < 0)
        if fd >= 0 { close(fd) }
    }

    // MARK: - openDirectoryNoFollow

    @Test("openDirectoryNoFollow opens a real nested path and rejects a symlinked component")
    func openDirectoryNoFollowRejectsSymlinkComponent() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)

        // Real path resolves.
        let good = SecureTrashFileOps.openDirectoryNoFollow(path: real.path)
        #expect(good >= 0)
        if good >= 0 { close(good) }

        // A symlink standing in for an intermediate component is refused.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: root.appendingPathComponent("a")
        )
        let viaSymlink = SecureTrashFileOps.openDirectoryNoFollow(path: root.appendingPathComponent("link/b").path)
        #expect(viaSymlink < 0)
        if viaSymlink >= 0 { close(viaSymlink) }
    }

    // MARK: - moveIntoTrash

    @Test("moveIntoTrash relocates the leaf and numbers around a collision")
    func moveIntoTrashNamesAndMoves() throws {
        let source = try makeScratch()
        let trash = try makeScratch()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: trash)
        }
        try Data("one".utf8).write(to: source.appendingPathComponent("x.log"))

        let sfd = openDir(source)
        let tfd = openDir(trash)
        #expect(sfd >= 0 && tfd >= 0)
        defer { if sfd >= 0 { close(sfd) }; if tfd >= 0 { close(tfd) } }

        let first = SecureTrashFileOps.moveIntoTrash(sourceParentFd: sfd, leaf: "x.log", trashFd: tfd)
        #expect(first == "x.log")
        #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("x.log").path))
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("x.log").path))

        // A second item of the same name lands beside the first, not over it.
        try Data("two".utf8).write(to: source.appendingPathComponent("x.log"))
        let second = SecureTrashFileOps.moveIntoTrash(sourceParentFd: sfd, leaf: "x.log", trashFd: tfd)
        #expect(second == "x 1.log")
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("x 1.log").path))
        // The first file's contents are intact (no overwrite).
        let firstContents = try String(contentsOf: trash.appendingPathComponent("x.log"), encoding: .utf8)
        #expect(firstContents == "one")
    }

    @Test("moveIntoTrash rejects non-single-component names")
    func moveIntoTrashRejectsBadNames() throws {
        let source = try makeScratch()
        let trash = try makeScratch()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: trash)
        }
        let sfd = openDir(source)
        let tfd = openDir(trash)
        defer { if sfd >= 0 { close(sfd) }; if tfd >= 0 { close(tfd) } }
        #expect(SecureTrashFileOps.moveIntoTrash(sourceParentFd: sfd, leaf: "..", trashFd: tfd) == nil)
        #expect(SecureTrashFileOps.moveIntoTrash(sourceParentFd: sfd, leaf: "a/b", trashFd: tfd) == nil)
    }

    // MARK: - removeTree confinement

    @Test("removeTree unlinks a symlink entry without following it")
    func removeTreeDoesNotFollowSymlink() throws {
        let trash = try makeScratch()
        let outside = try makeScratch()
        defer {
            try? FileManager.default.removeItem(at: trash)
            try? FileManager.default.removeItem(at: outside)
        }
        let sentinel = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: trash.appendingPathComponent("sub"),
            withDestinationURL: outside
        )

        let fd = openDir(trash)
        #expect(fd >= 0)
        defer { if fd >= 0 { close(fd) } }

        #expect(SecureTrashFileOps.removeTree(inDirFd: fd, name: "sub"))
        #expect(!FileManager.default.fileExists(atPath: trash.appendingPathComponent("sub").path))
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test("removeTree removes a nested directory tree within the pinned dir")
    func removeTreeRemovesNestedTree() throws {
        let trash = try makeScratch()
        defer { try? FileManager.default.removeItem(at: trash) }
        let nested = trash.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nested.appendingPathComponent("f.txt"))

        let fd = openDir(trash)
        #expect(fd >= 0)
        defer { if fd >= 0 { close(fd) } }

        #expect(SecureTrashFileOps.removeTree(inDirFd: fd, name: "a"))
        #expect(!FileManager.default.fileExists(atPath: trash.appendingPathComponent("a").path))
        #expect(FileManager.default.fileExists(atPath: trash.path))
    }

    @Test("removeTree rejects non-single-component names")
    func removeTreeRejectsBadNames() throws {
        let trash = try makeScratch()
        defer { try? FileManager.default.removeItem(at: trash) }
        let fd = openDir(trash)
        defer { if fd >= 0 { close(fd) } }
        #expect(!SecureTrashFileOps.removeTree(inDirFd: fd, name: ".."))
        #expect(!SecureTrashFileOps.removeTree(inDirFd: fd, name: "a/b"))
    }
}
