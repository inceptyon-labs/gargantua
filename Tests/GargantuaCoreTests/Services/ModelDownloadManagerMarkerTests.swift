import Foundation
import Testing
@testable import GargantuaCore

@Suite("ModelDownloadManager verified marker")
@MainActor
struct ModelDownloadManagerMarkerTests {
    /// A temporary models folder, so nothing lands beside the user's models.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Verified marker

    @Test("checkExistingModel ignores a sized-but-unverified directory")
    func existingDirectoryNeedsMarker() throws {
        let files = [
            ModelFile(name: "a.json", url: URL(string: "https://x/a")!, sha256: "00", size: 3),
        ]
        let info = ModelInfo(id: "marker-test-\(UUID().uuidString)", name: "X", files: files)

        // Seed the exact directory the manager would use, but *without* the marker.
        let root = try makeRoot()
        let dir = root.appendingPathComponent(info.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("abc".utf8).write(to: dir.appendingPathComponent("a.json"))

        let manager = ModelDownloadManager(modelInfo: info, modelsRoot: root)
        #expect(manager.state == .notDownloaded, "Missing marker → not trusted")
    }

    @Test("checkExistingModel trusts a directory with a matching marker")
    func existingDirectoryWithMarker() throws {
        let files = [
            ModelFile(name: "a.json", url: URL(string: "https://x/a")!, sha256: "00", size: 3),
        ]
        let info = ModelInfo(id: "marker-test-\(UUID().uuidString)", name: "X", files: files)

        let root = try makeRoot()
        let dir = root.appendingPathComponent(info.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("abc".utf8).write(to: dir.appendingPathComponent("a.json"))
        try Data(ModelDownloadManager.buildVerifiedMarker(for: info).utf8)
            .write(to: dir.appendingPathComponent(ModelDownloadManager.verifiedMarkerName))

        let manager = ModelDownloadManager(modelInfo: info, modelsRoot: root)
        #expect(manager.state == .downloaded(path: dir.path, size: info.expectedSize))
    }

    @Test("checkExistingModel rejects a stale marker from a prior manifest")
    func existingDirectoryStaleMarker() throws {
        let files = [
            ModelFile(name: "a.json", url: URL(string: "https://x/a")!, sha256: "00", size: 3),
        ]
        let staleFiles = [
            ModelFile(name: "a.json", url: URL(string: "https://x/a")!, sha256: "ff", size: 3),
        ]
        let info = ModelInfo(id: "marker-test-\(UUID().uuidString)", name: "X", files: files)
        let staleInfo = ModelInfo(id: info.id, name: "X", files: staleFiles)

        let root = try makeRoot()
        let dir = root.appendingPathComponent(info.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("abc".utf8).write(to: dir.appendingPathComponent("a.json"))
        try Data(ModelDownloadManager.buildVerifiedMarker(for: staleInfo).utf8)
            .write(to: dir.appendingPathComponent(ModelDownloadManager.verifiedMarkerName))

        let manager = ModelDownloadManager(modelInfo: info, modelsRoot: root)
        #expect(manager.state == .notDownloaded, "Marker SHAs differ → not trusted")
    }
}
