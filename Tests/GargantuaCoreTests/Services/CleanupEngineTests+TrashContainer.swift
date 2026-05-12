import Foundation
import Testing
@testable import GargantuaCore

extension CleanupResultTests {
    @Test("delete on Trash container empties contents but keeps the directory")
    @MainActor
    func deleteTrashContainer() async throws {
        let fixture = try makeFakeTrash(children: [
            "file1.txt": Data("aaa".utf8),
            "file2.log": Data("bbbbb".utf8),
            ".hidden": Data("c".utf8),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let item = makeItem(id: "trash", path: fixture.trash.path, size: fixture.totalBytes)
        let engine = CleanupEngine(homeDirectoryForTesting: fixture.home)
        let result = await engine.clean([item], method: .delete)

        #expect(result.allSucceeded)
        #expect(result.totalFreed == fixture.totalBytes)
        // Trash directory preserved, children gone
        #expect(FileManager.default.fileExists(atPath: fixture.trash.path))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path)
        #expect(remaining.isEmpty)
    }

    @Test("trash method on Trash container also empties contents (auto-promote)")
    @MainActor
    func trashMethodOnTrashContainerEmpties() async throws {
        let fixture = try makeFakeTrash(children: [
            "a.txt": Data("x".utf8),
            "b.txt": Data("y".utf8),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let item = makeItem(id: "trash", path: fixture.trash.path, size: fixture.totalBytes)
        let engine = CleanupEngine(homeDirectoryForTesting: fixture.home)
        let result = await engine.clean([item], method: .trash)

        #expect(result.allSucceeded)
        #expect(FileManager.default.fileExists(atPath: fixture.trash.path))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path)
        #expect(remaining.isEmpty)
    }

    @Test("empty Trash container reports success with zero work")
    @MainActor
    func emptyTrashContainerNoOp() async throws {
        let fixture = try makeFakeTrash(children: [:])
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let item = makeItem(id: "trash", path: fixture.trash.path, size: 0)
        let engine = CleanupEngine(homeDirectoryForTesting: fixture.home)
        let result = await engine.clean([item], method: .delete)

        #expect(result.allSucceeded)
        #expect(FileManager.default.fileExists(atPath: fixture.trash.path))
    }

    @Test("Trash path with trailing slash is treated as container")
    @MainActor
    func trashContainerTrailingSlash() async throws {
        let fixture = try makeFakeTrash(children: [
            "f.txt": Data("z".utf8),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        // ScanResult path with trailing slash
        let pathWithSlash = fixture.trash.path + "/"
        let item = makeItem(id: "trash", path: pathWithSlash, size: fixture.totalBytes)
        let engine = CleanupEngine(homeDirectoryForTesting: fixture.home)
        let result = await engine.clean([item], method: .delete)

        #expect(result.allSucceeded)
        #expect(FileManager.default.fileExists(atPath: fixture.trash.path))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path)
        #expect(remaining.isEmpty)
    }

    @Test("Partial failure on Trash empty reports a summary error")
    @MainActor
    func trashContainerPartialFailure() async throws {
        let fixture = try makeFakeTrash(children: [
            "removable.txt": Data("ok".utf8),
            "stuck-dir": Data("ignored".utf8),
        ])
        defer {
            // Restore writability before cleanup
            let stuck = fixture.trash.appendingPathComponent("stuck-dir")
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.trash.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stuck.path)
            try? FileManager.default.removeItem(at: fixture.home)
        }

        // Replace one file with a subdirectory whose parent we'll make
        // read-only, so removeItem on the child fails with EACCES.
        let stuck = fixture.trash.appendingPathComponent("stuck-dir")
        try FileManager.default.removeItem(at: stuck) // was a file
        try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: stuck.appendingPathComponent("inner.txt"))
        // Remove write permission from Trash so children can't be unlinked.
        // Actually removeItem unlinks by child, parent needs write perms.
        // Revoke write on Trash itself:
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.trash.path)

        let item = makeItem(id: "trash", path: fixture.trash.path, size: fixture.totalBytes)
        let engine = CleanupEngine(homeDirectoryForTesting: fixture.home)
        let result = await engine.clean([item], method: .delete)

        #expect(!result.allSucceeded)
        #expect(result.failedItems.count == 1)
        let error = result.failedItems.first?.error ?? ""
        #expect(!error.isEmpty)
    }
}
