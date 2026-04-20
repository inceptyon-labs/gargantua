import Foundation
import Testing
@testable import GargantuaCore

@Suite("ModelDownloadManager")
@MainActor
struct ModelDownloadManagerTests {

    // MARK: - ModelInfo / ModelFile

    @Test("ModelInfo.expectedSize sums file sizes")
    func expectedSizeSumsFiles() {
        let info = ModelInfo(
            id: "test",
            name: "Test",
            files: [
                ModelFile(name: "a", url: URL(string: "https://example.com/a")!, sha256: "00", size: 10),
                ModelFile(name: "b", url: URL(string: "https://example.com/b")!, sha256: "11", size: 25),
                ModelFile(name: "c", url: URL(string: "https://example.com/c")!, sha256: "22", size: 100),
            ]
        )
        #expect(info.expectedSize == 135)
    }

    @Test("ModelFile normalizes SHA-256 to lowercase")
    func sha256Lowercased() {
        let file = ModelFile(
            name: "x",
            url: URL(string: "https://example.com/x")!,
            sha256: "AABBCCDD",
            size: 1
        )
        #expect(file.sha256 == "aabbccdd")
    }

    @Test("Empty manifest transitions to failed on startDownload")
    func emptyManifestFails() {
        let info = ModelInfo(id: "empty", name: "Empty", files: [])
        let manager = ModelDownloadManager(modelInfo: info)

        manager.startDownload()

        guard case .failed = manager.state else {
            Issue.record("Expected .failed, got \(manager.state)")
            return
        }
    }

    // MARK: - Default model shape

    @Test("defaultModel targets the pinned Llama 3.2 1B 4-bit directory")
    func defaultModelIsLlama32_1B4bit() {
        let model = ModelDownloadManager.defaultModel
        #expect(model.id == "Llama-3.2-1B-Instruct-4bit")
        #expect(model.files.map(\.name).contains("config.json"))
        #expect(model.files.map(\.name).contains("tokenizer.json"))
        #expect(model.files.map(\.name).contains("model.safetensors"))
        // Every file has a 64-char lowercase hex SHA pin
        for file in model.files {
            #expect(file.sha256.count == 64, "SHA must be 64 hex chars for \(file.name)")
            #expect(file.sha256.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) },
                    "SHA must be lowercase hex for \(file.name)")
            #expect(file.size > 0, "Size must be positive for \(file.name)")
            #expect(file.url.host == "huggingface.co", "HF URL expected for \(file.name)")
        }
    }

    // MARK: - SHA-256 helper

    @Test("sha256Hex matches known vectors")
    func sha256HexKnownVectors() throws {
        // Empty string
        let emptyURL = try writeTempFile(bytes: Data())
        defer { try? FileManager.default.removeItem(at: emptyURL) }
        #expect(
            try ModelDownloadManager.sha256Hex(of: emptyURL) ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )

        // "abc"
        let abcURL = try writeTempFile(bytes: Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: abcURL) }
        #expect(
            try ModelDownloadManager.sha256Hex(of: abcURL) ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test("sha256Hex streams chunks larger than 1 MB")
    func sha256HexLargeFile() throws {
        // 2.5 MB of 0x41 bytes — must agree with openssl/shasum output.
        let chunk = Data(repeating: 0x41, count: 1024 * 1024)
        var buffer = Data()
        buffer.append(chunk)
        buffer.append(chunk)
        buffer.append(Data(repeating: 0x41, count: 512 * 1024))

        let url = try writeTempFile(bytes: buffer)
        defer { try? FileManager.default.removeItem(at: url) }

        let hex = try ModelDownloadManager.sha256Hex(of: url)
        #expect(hex.count == 64)
        // Sanity: hashing the same bytes twice gives the same digest.
        let hex2 = try ModelDownloadManager.sha256Hex(of: url)
        #expect(hex == hex2)
    }

    // MARK: - Directory completeness

    @Test("isModelDirectoryComplete returns false when files are missing")
    func directoryCompleteMissingFiles() throws {
        let dir = try makeEmptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let files = [
            ModelFile(name: "a.json", url: URL(string: "https://x/a")!, sha256: "00", size: 3),
            ModelFile(name: "b.bin", url: URL(string: "https://x/b")!, sha256: "11", size: 5),
        ]
        #expect(!ModelDownloadManager.isModelDirectoryComplete(dir, files: files))

        // One file present, one missing
        try Data("abc".utf8).write(to: dir.appendingPathComponent("a.json"))
        #expect(!ModelDownloadManager.isModelDirectoryComplete(dir, files: files))
    }

    @Test("isModelDirectoryComplete returns true when all files match sizes")
    func directoryCompleteAllPresent() throws {
        let dir = try makeEmptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let files = [
            ModelFile(name: "a.json", url: URL(string: "https://x/a")!, sha256: "00", size: 3),
            ModelFile(name: "b.bin", url: URL(string: "https://x/b")!, sha256: "11", size: 5),
        ]
        try Data("abc".utf8).write(to: dir.appendingPathComponent("a.json"))
        try Data("hello".utf8).write(to: dir.appendingPathComponent("b.bin"))

        #expect(ModelDownloadManager.isModelDirectoryComplete(dir, files: files))
    }

    @Test("isModelDirectoryComplete returns false when a file size mismatches")
    func directoryCompleteSizeMismatch() throws {
        let dir = try makeEmptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let files = [
            ModelFile(name: "a.json", url: URL(string: "https://x/a")!, sha256: "00", size: 10),
        ]
        try Data("abc".utf8).write(to: dir.appendingPathComponent("a.json")) // 3 bytes, not 10
        #expect(!ModelDownloadManager.isModelDirectoryComplete(dir, files: files))
    }

    @Test("isModelDirectoryComplete rejects a subdirectory masquerading as a file")
    func directoryCompleteRejectsSubdir() throws {
        let dir = try makeEmptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let files = [
            ModelFile(name: "a.json", url: URL(string: "https://x/a")!, sha256: "00", size: 0),
        ]
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("a.json"),
            withIntermediateDirectories: false
        )
        #expect(!ModelDownloadManager.isModelDirectoryComplete(dir, files: files))
    }

    // MARK: - Manifest validation (path traversal etc.)

    @Test("validateManifest rejects path separators in id")
    func rejectsSlashInID() {
        let info = ModelInfo(
            id: "../evil",
            name: "x",
            files: [ModelFile(name: "a", url: URL(string: "https://x/a")!, sha256: "0", size: 1)]
        )
        #expect(throws: ModelManifestError.self) {
            try ModelDownloadManager.validateManifest(info)
        }
    }

    @Test("validateManifest rejects dot-dot filenames")
    func rejectsDotDotFileName() {
        let info = ModelInfo(
            id: "m",
            name: "x",
            files: [ModelFile(name: "..", url: URL(string: "https://x/a")!, sha256: "0", size: 1)]
        )
        #expect(throws: ModelManifestError.self) {
            try ModelDownloadManager.validateManifest(info)
        }
    }

    @Test("validateManifest rejects slash in filename")
    func rejectsSlashInFileName() {
        let info = ModelInfo(
            id: "m",
            name: "x",
            files: [ModelFile(name: "sub/file.bin", url: URL(string: "https://x/a")!, sha256: "0", size: 1)]
        )
        #expect(throws: ModelManifestError.self) {
            try ModelDownloadManager.validateManifest(info)
        }
    }

    @Test("validateManifest rejects empty id and empty filename")
    func rejectsEmptyComponents() {
        let emptyID = ModelInfo(
            id: "",
            name: "x",
            files: [ModelFile(name: "a", url: URL(string: "https://x/a")!, sha256: "0", size: 1)]
        )
        #expect(throws: ModelManifestError.self) {
            try ModelDownloadManager.validateManifest(emptyID)
        }

        let emptyName = ModelInfo(
            id: "m",
            name: "x",
            files: [ModelFile(name: "", url: URL(string: "https://x/a")!, sha256: "0", size: 1)]
        )
        #expect(throws: ModelManifestError.self) {
            try ModelDownloadManager.validateManifest(emptyName)
        }
    }

    @Test("validateManifest rejects leading-dot names")
    func rejectsLeadingDot() {
        let info = ModelInfo(
            id: "m",
            name: "x",
            files: [ModelFile(name: ".hidden", url: URL(string: "https://x/a")!, sha256: "0", size: 1)]
        )
        #expect(throws: ModelManifestError.self) {
            try ModelDownloadManager.validateManifest(info)
        }
    }

    @Test("validateManifest rejects duplicate filenames")
    func rejectsDuplicateFileNames() {
        let info = ModelInfo(
            id: "m",
            name: "x",
            files: [
                ModelFile(name: "a.bin", url: URL(string: "https://x/a")!, sha256: "0", size: 1),
                ModelFile(name: "a.bin", url: URL(string: "https://x/b")!, sha256: "1", size: 2),
            ]
        )
        #expect(throws: ModelManifestError.self) {
            try ModelDownloadManager.validateManifest(info)
        }
    }

    @Test("validateManifest accepts the pinned default model")
    func acceptsDefaultModel() throws {
        try ModelDownloadManager.validateManifest(ModelDownloadManager.defaultModel)
    }

    // MARK: - Verified marker

    @Test("checkExistingModel ignores a sized-but-unverified directory")
    func existingDirectoryNeedsMarker() throws {
        let files = [
            ModelFile(name: "a.json", url: URL(string: "https://x/a")!, sha256: "00", size: 3),
        ]
        let info = ModelInfo(id: "marker-test-\(UUID().uuidString)", name: "X", files: files)

        // Seed the exact directory the manager would use, but *without* the marker.
        let dir = ModelDownloadManager.modelsDirectory.appendingPathComponent(info.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("abc".utf8).write(to: dir.appendingPathComponent("a.json"))

        let manager = ModelDownloadManager(modelInfo: info)
        #expect(manager.state == .notDownloaded, "Missing marker → not trusted")
    }

    @Test("checkExistingModel trusts a directory with a matching marker")
    func existingDirectoryWithMarker() throws {
        let files = [
            ModelFile(name: "a.json", url: URL(string: "https://x/a")!, sha256: "00", size: 3),
        ]
        let info = ModelInfo(id: "marker-test-\(UUID().uuidString)", name: "X", files: files)

        let dir = ModelDownloadManager.modelsDirectory.appendingPathComponent(info.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("abc".utf8).write(to: dir.appendingPathComponent("a.json"))
        try Data(ModelDownloadManager.buildVerifiedMarker(for: info).utf8)
            .write(to: dir.appendingPathComponent(ModelDownloadManager.verifiedMarkerName))

        let manager = ModelDownloadManager(modelInfo: info)
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

        let dir = ModelDownloadManager.modelsDirectory.appendingPathComponent(info.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("abc".utf8).write(to: dir.appendingPathComponent("a.json"))
        try Data(ModelDownloadManager.buildVerifiedMarker(for: staleInfo).utf8)
            .write(to: dir.appendingPathComponent(ModelDownloadManager.verifiedMarkerName))

        let manager = ModelDownloadManager(modelInfo: info)
        #expect(manager.state == .notDownloaded, "Marker SHAs differ → not trusted")
    }

    // MARK: - Test helpers

    private func writeTempFile(bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-shatest-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        return url
    }

    private func makeEmptyDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-dirtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
