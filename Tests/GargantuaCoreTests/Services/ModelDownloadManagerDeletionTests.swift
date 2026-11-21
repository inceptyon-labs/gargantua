import Foundation
import Testing
@testable import GargantuaCore

/// Deleting the local model used to report success unconditionally, so a failed
/// removal left Settings claiming "Not downloaded" with ~680 MB still on disk —
/// in a disk-cleaning app.
///
/// Each test stages in a temporary folder: the default manager's folder holds
/// the model the user downloaded.
@Suite("ModelDownloadManager deletion", .serialized)
@MainActor
struct ModelDownloadManagerDeletionTests {

    private func makeManager() throws -> (ModelDownloadManager, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ModelDownloadManager(modelInfo: ModelDownloadManager.defaultModel, modelsRoot: root), root)
    }

    @Test("deleting an already-absent model still lands on .notDownloaded")
    func deletingAbsentModelSucceeds() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        // Never the user's models folder.
        #expect(manager.modelDirectory.deletingLastPathComponent() == root)

        manager.deleteModel()

        #expect(manager.state == .notDownloaded)
    }

    @Test("a removal that cannot complete surfaces .failed and leaves the files alone")
    func failedRemovalSurfacesFailure() throws {
        let (manager, root) = try makeManager()
        let directory = manager.modelDirectory
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("weights.bin")
        try Data("weights".utf8).write(to: file)

        // An immutable parent makes the removal fail the way a locked or
        // permission-denied directory does in the field.
        try fileManager.setAttributes([.immutable: true], ofItemAtPath: directory.path)
        defer {
            try? fileManager.setAttributes([.immutable: false], ofItemAtPath: directory.path)
            try? fileManager.removeItem(at: directory)
        }

        manager.deleteModel()

        guard case .failed(let message) = manager.state else {
            Issue.record("expected .failed, got \(manager.state)")
            return
        }
        #expect(message.contains("Could not remove the local model"))
        #expect(fileManager.fileExists(atPath: file.path))
    }
}
