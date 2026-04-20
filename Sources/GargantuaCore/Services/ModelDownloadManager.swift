import CryptoKit
import Foundation

/// A single file that belongs to a HF-layout model directory.
///
/// SHA-256 pins are hex-lowercase (64 chars). For LFS files the pin comes
/// from the HF LFS pointer's `oid`; for non-LFS files it's computed directly
/// from the file bytes (see `Scripts/pin-model.sh`).
public struct ModelFile: Sendable, Equatable {
    /// File name inside the staged model directory (e.g., "config.json").
    public let name: String
    /// HF `resolve` URL that returns the raw file bytes.
    public let url: URL
    /// Expected SHA-256 of the downloaded bytes (hex, lowercase).
    public let sha256: String
    /// Expected size in bytes.
    public let size: Int64

    public init(name: String, url: URL, sha256: String, size: Int64) {
        self.name = name
        self.url = url
        self.sha256 = sha256.lowercased()
        self.size = size
    }
}

/// Configuration for an AI model that can be downloaded.
///
/// Models are staged as directories containing HF-layout files
/// (`config.json`, `tokenizer.json`, `*.safetensors`, …).
public struct ModelInfo: Sendable, Equatable {
    /// Stable identifier used as the on-disk directory name.
    public let id: String
    /// Display name shown in settings.
    public let name: String
    /// Files that make up the model, downloaded in order.
    public let files: [ModelFile]

    public init(id: String, name: String, files: [ModelFile]) {
        self.id = id
        self.name = name
        self.files = files
    }

    /// Sum of expected file sizes.
    public var expectedSize: Int64 {
        files.reduce(0) { $0 + $1.size }
    }
}

/// Current state of model availability and download progress.
public enum ModelState: Equatable {
    /// No model downloaded, ready to start.
    case notDownloaded
    /// Download in progress with fractional progress (0.0–1.0) and bytes received.
    case downloading(progress: Double, bytesReceived: Int64)
    /// Model is downloaded and ready to use. `path` is the staged directory.
    case downloaded(path: String, size: Int64)
    /// Download or verification failed.
    case failed(message: String)
}

/// Manages downloading, verifying, and staging HF-layout model directories.
///
/// Models are stored at `~/Library/Application Support/Gargantua/models/<id>/`.
/// Each file is fetched sequentially, SHA-256 verified against the manifest,
/// then moved into the model directory. Any failure rolls back the directory
/// so the next attempt starts clean.
@MainActor
public final class ModelDownloadManager: NSObject, ObservableObject {
    /// Current state of the model.
    @Published public private(set) var state: ModelState = .notDownloaded

    /// The model configuration.
    public let modelInfo: ModelInfo

    /// Directory where staged model directories live.
    public nonisolated static let modelsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Gargantua/models", isDirectory: true)
    }()

    private var session: URLSession?
    private var activeTask: URLSessionDownloadTask?
    private var currentFileIndex: Int = 0
    private var completedBytes: Int64 = 0
    private var didCancel: Bool = false

    /// Staged directory for this model.
    public nonisolated var modelDirectory: URL {
        Self.modelsDirectory.appendingPathComponent(modelInfo.id, isDirectory: true)
    }

    /// `mlx-community/Llama-3.2-1B-Instruct-4bit` — per PRD §6.2 and the xuz6
    /// design doc. File SHAs are pinned from the HF LFS pointers (safetensors +
    /// tokenizer.json) and direct content hashes (small JSON files); regenerate
    /// via `Scripts/pin-model.sh` if the upstream repo is ever bumped.
    public nonisolated static let defaultModel = ModelInfo(
        id: "Llama-3.2-1B-Instruct-4bit",
        name: "Llama 3.2 1B Instruct (4-bit MLX)",
        files: [
            ModelFile(
                name: "config.json",
                url: URL(string: "https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit/resolve/main/config.json")!,
                sha256: "73bfb89e5a43c76ada2d7a9609862139578a71cfbb43e30bf5d4571026dd3741",
                size: 1_121
            ),
            ModelFile(
                name: "tokenizer_config.json",
                url: URL(string: "https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit/resolve/main/tokenizer_config.json")!,
                sha256: "022d5ae3df4737998ab97d8f31ac2bcb4c06dd8ebe5a8aba2b4aceef1e5ea7d3",
                size: 54_558
            ),
            ModelFile(
                name: "special_tokens_map.json",
                url: URL(string: "https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit/resolve/main/special_tokens_map.json")!,
                sha256: "6f38c73729248f6c127296386e3cdde96e254636cc58b4169d3fd32328d9a8ec",
                size: 296
            ),
            ModelFile(
                name: "tokenizer.json",
                url: URL(string: "https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit/resolve/main/tokenizer.json")!,
                sha256: "6b9e4e7fb171f92fd137b777cc2714bf87d11576700a1dcd7a399e7bbe39537b",
                size: 17_209_920
            ),
            ModelFile(
                name: "model.safetensors",
                url: URL(string: "https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit/resolve/main/model.safetensors")!,
                sha256: "35e396644bca888eec399f9c0f843ec7fa78b8f8c5e06841661be62b4edf96dd",
                size: 695_283_921
            ),
        ]
    )

    public init(modelInfo: ModelInfo = ModelDownloadManager.defaultModel) {
        self.modelInfo = modelInfo
        super.init()
        checkExistingModel()
    }

    // MARK: - Public API

    /// Start downloading the model. No-op if already downloading or downloaded.
    public func startDownload() {
        switch state {
        case .notDownloaded, .failed:
            break
        case .downloading, .downloaded:
            return
        }

        guard !modelInfo.files.isEmpty else {
            state = .failed(message: "Model manifest is empty.")
            return
        }

        createDirectoriesIfNeeded()

        didCancel = false
        currentFileIndex = 0
        completedBytes = 0
        state = .downloading(progress: 0, bytesReceived: 0)

        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        startNextFileDownload()
    }

    /// Cancel an in-progress download and clean up the staged directory.
    public func cancelDownload() {
        didCancel = true
        activeTask?.cancel()
        activeTask = nil
        session?.invalidateAndCancel()
        session = nil
        removeModelDirectory()
        state = .notDownloaded
    }

    /// Delete the staged model directory.
    public func deleteModel() {
        removeModelDirectory()
        state = .notDownloaded
    }

    /// Formatted string for the expected model size (e.g., "680 MB").
    public var formattedExpectedSize: String {
        ByteCountFormatter.string(fromByteCount: modelInfo.expectedSize, countStyle: .file)
    }

    /// Formatted string for the actual staged model size.
    public var formattedDownloadedSize: String? {
        guard case .downloaded(_, let size) = state else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    // MARK: - Internal hooks

    /// Test-only seam: override the state directly. Not for production use.
    internal func _setStateForTesting(_ newState: ModelState) {
        self.state = newState
    }

    /// Returns the SHA-256 of the bytes at `url`, hex-encoded lowercase.
    /// Streams the file so large safetensors don't sit in RAM.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1024 * 1024 // 1 MB
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns true iff the staged directory already contains every file in
    /// `modelInfo.files` with the expected size. Cheap to run at init — does
    /// not re-verify SHAs (that would cost seconds for a ~700 MB model).
    static func isModelDirectoryComplete(_ directory: URL, files: [ModelFile]) -> Bool {
        let fm = FileManager.default
        for file in files {
            let path = directory.appendingPathComponent(file.name).path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
                return false
            }
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int64,
                  size == file.size else {
                return false
            }
        }
        return true
    }

    // MARK: - Private

    private func checkExistingModel() {
        // Empty manifest is a misconfiguration, not a downloaded model —
        // `startDownload` will surface it.
        guard !modelInfo.files.isEmpty else { return }
        let directory = modelDirectory
        guard Self.isModelDirectoryComplete(directory, files: modelInfo.files) else {
            return
        }
        state = .downloaded(path: directory.path, size: modelInfo.expectedSize)
    }

    private func createDirectoriesIfNeeded() {
        try? FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
    }

    private func removeModelDirectory() {
        try? FileManager.default.removeItem(at: modelDirectory)
    }

    private func startNextFileDownload() {
        guard currentFileIndex < modelInfo.files.count else {
            finishDownload()
            return
        }
        guard let session else { return }

        let file = modelInfo.files[currentFileIndex]
        let task = session.downloadTask(with: file.url)
        activeTask = task
        task.resume()
    }

    private func finishDownload() {
        activeTask = nil
        session?.finishTasksAndInvalidate()
        session = nil

        // Use the manifest's expected size as the staged size: every file was
        // SHA-verified, so the directory content is exactly what we pinned.
        state = .downloaded(path: modelDirectory.path, size: modelInfo.expectedSize)
    }

    private func failDownload(_ message: String) {
        activeTask = nil
        session?.invalidateAndCancel()
        session = nil
        removeModelDirectory()
        state = .failed(message: message)
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloadManager: URLSessionDownloadDelegate {
    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temp file at `location` is deleted when this delegate call
        // returns, so either move it synchronously or copy out the bytes we
        // need before hopping actors. We move it to a sibling tmp path first,
        // then hand the URL off to the main actor for SHA verification.
        let tmpDir = FileManager.default.temporaryDirectory
        let scratch = tmpDir.appendingPathComponent("gargantua-model-\(UUID().uuidString).part")
        do {
            try FileManager.default.moveItem(at: location, to: scratch)
        } catch {
            MainActor.assumeIsolated {
                self.failDownload("Failed to stage downloaded file: \(error.localizedDescription)")
            }
            return
        }

        MainActor.assumeIsolated {
            self.handleDownloadedFile(at: scratch)
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        MainActor.assumeIsolated {
            self.handleProgress(currentFileBytes: totalBytesWritten)
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }

        MainActor.assumeIsolated {
            self.failDownload(error.localizedDescription)
        }
    }

    // MARK: Main-actor handlers

    private func handleProgress(currentFileBytes: Int64) {
        let total = modelInfo.expectedSize
        let bytesReceived = completedBytes + max(0, currentFileBytes)
        let progress = total > 0 ? Double(bytesReceived) / Double(total) : 0
        state = .downloading(progress: min(progress, 1.0), bytesReceived: bytesReceived)
    }

    private func handleDownloadedFile(at scratch: URL) {
        defer { try? FileManager.default.removeItem(at: scratch) }

        guard !didCancel else { return }
        guard currentFileIndex < modelInfo.files.count else { return }
        let file = modelInfo.files[currentFileIndex]

        // SHA-256 verify
        let actualSha: String
        do {
            actualSha = try Self.sha256Hex(of: scratch)
        } catch {
            failDownload("Failed to hash \(file.name): \(error.localizedDescription)")
            return
        }
        guard actualSha == file.sha256 else {
            failDownload("Checksum mismatch for \(file.name): expected \(file.sha256), got \(actualSha).")
            return
        }

        // Move into staged directory (overwriting a stale copy from a partial run).
        let destination = modelDirectory.appendingPathComponent(file.name)
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: scratch, to: destination)
        } catch {
            failDownload("Failed to stage \(file.name): \(error.localizedDescription)")
            return
        }

        completedBytes += file.size
        currentFileIndex += 1
        startNextFileDownload()
    }
}
