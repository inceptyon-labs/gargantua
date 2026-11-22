import Foundation
import GargantuaLicensing
import Testing
@testable import GargantuaCore

extension CleanupResultTests {
    /// Go's module cache layout: files 0444, module directories 0555.
    private func makeReadOnlyModuleTree(in parent: URL) throws -> (root: URL, module: URL) {
        let root = parent.appendingPathComponent("mod")
        let module = root.appendingPathComponent("golang.org/x/sys@v0.42.0")
        let package = module.appendingPathComponent("unix")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appendingPathComponent("syscall.go")
        try Data("package unix".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        return (root, module)
    }

    private func lockDirectories(_ urls: [URL]) throws {
        for url in urls {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        }
    }

    private func removeFixture(_ dir: URL) {
        CleanupEngine.restoreOwnerAccessOnDirectories(under: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("delete removes a tree whose directories are read-only, like Go's module cache")
    @MainActor
    func deleteRemovesReadOnlyTree() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-readonly-test-\(UUID().uuidString)")
        defer { removeFixture(dir) }
        let tree = try makeReadOnlyModuleTree(in: dir)
        try lockDirectories([tree.module.appendingPathComponent("unix"), tree.module])

        let item = makeItem(id: "gomod", path: tree.root.path, size: 12)
        let result = await CleanupEngine().clean([item], method: .delete, authorization: .unchecked(.deepClean))

        #expect(result.allSucceeded)
        #expect(!FileManager.default.fileExists(atPath: tree.root.path))
    }

    @Test("emptying the Trash removes a read-only tree inside it")
    @MainActor
    func emptyTrashRemovesReadOnlyTree() async throws {
        let fixture = try makeFakeTrash(children: [:])
        defer { removeFixture(fixture.home) }
        let tree = try makeReadOnlyModuleTree(in: fixture.trash)
        try lockDirectories([tree.module.appendingPathComponent("unix"), tree.module])

        let item = makeItem(id: "trash", path: fixture.trash.path, size: 12)
        let engine = CleanupEngine(homeDirectoryForTesting: fixture.home)
        let result = await engine.clean([item], method: .delete, authorization: .unchecked(.deepClean))

        #expect(result.allSucceeded)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    }

    @Test("restoring owner access doesn't follow a symlink out of the tree")
    @MainActor
    func ownerAccessDoesNotFollowSymlinks() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-readonly-symlink-test-\(UUID().uuidString)")
        defer { removeFixture(dir) }
        let outside = dir.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let tree = try makeReadOnlyModuleTree(in: dir)
        // Inside a read-only directory, so the first delete pass can't unlink
        // it and the permission walk sees it.
        try FileManager.default.createSymbolicLink(
            at: tree.module.appendingPathComponent("link"),
            withDestinationURL: outside
        )
        try lockDirectories([tree.module.appendingPathComponent("unix"), tree.module, outside])

        let item = makeItem(id: "gomod", path: tree.root.path, size: 12)
        let result = await CleanupEngine().clean([item], method: .delete, authorization: .unchecked(.deepClean))

        #expect(result.allSucceeded)
        let mode = try FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions] as? Int
        #expect(mode == 0o555)
    }

    @Test("only EACCES counts as access denied; EPERM does not")
    func accessDeniedMatchesEACCESOnly() {
        let eacces = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let eperm = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        func cocoa(_ underlying: NSError) -> NSError {
            NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteNoPermissionError,
                userInfo: [NSUnderlyingErrorKey: underlying]
            )
        }
        #expect(CleanupEngine.isAccessDenied(eacces))
        #expect(CleanupEngine.isAccessDenied(cocoa(eacces)))
        #expect(!CleanupEngine.isAccessDenied(eperm))
        #expect(!CleanupEngine.isAccessDenied(cocoa(eperm)))
    }
}
