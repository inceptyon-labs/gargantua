import Foundation
import Testing
@testable import GargantuaCore

@Suite("ModelDownloadManager manifest shape and validation")
@MainActor
struct ModelDownloadManagerManifestTests {

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
}
