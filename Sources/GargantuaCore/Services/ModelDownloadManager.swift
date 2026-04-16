import Foundation
import Combine

/// Configuration for an AI model that can be downloaded.
public struct ModelInfo: Sendable {
    /// Display name shown in settings.
    public let name: String

    /// Download URL for the quantized model file.
    public let url: URL

    /// Expected file name on disk (e.g., "model-q4.mlx").
    public let fileName: String

    /// Expected size in bytes (for display before download).
    public let expectedSize: Int64

    public init(name: String, url: URL, fileName: String, expectedSize: Int64) {
        self.name = name
        self.url = url
        self.fileName = fileName
        self.expectedSize = expectedSize
    }
}

/// Current state of model availability and download progress.
public enum ModelState: Equatable {
    /// No model downloaded, ready to start.
    case notDownloaded
    /// Download in progress with fractional progress (0.0–1.0) and bytes received.
    case downloading(progress: Double, bytesReceived: Int64)
    /// Model is downloaded and ready to use.
    case downloaded(path: String, size: Int64)
    /// Download or verification failed.
    case failed(message: String)
}

/// Manages downloading, storing, and tracking AI model files.
///
/// Models are stored at `~/Library/Application Support/Gargantua/models/`.
/// Supports progress observation, cancellation with partial file cleanup,
/// and checking for existing downloads.
@MainActor
public final class ModelDownloadManager: NSObject, ObservableObject {
    /// Current state of the model.
    @Published public private(set) var state: ModelState = .notDownloaded

    /// The model configuration.
    public let modelInfo: ModelInfo

    /// Directory where models are stored.
    public nonisolated static let modelsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Gargantua/models", isDirectory: true)
    }()

    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private var destinationURL: URL {
        Self.modelsDirectory.appendingPathComponent(modelInfo.fileName)
    }

    /// Default model configuration.
    ///
    /// Uses a placeholder URL — replace with actual model hosting when available.
    public nonisolated static let defaultModel = ModelInfo(
        name: "Gargantua Q4 (MLX)",
        url: URL(string: "https://models.gargantua.dev/gargantua-q4.mlx")!,
        fileName: "gargantua-q4.mlx",
        expectedSize: 2_000_000_000 // ~2 GB
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
            break // proceed
        case .downloading, .downloaded:
            return
        }

        createModelsDirectoryIfNeeded()

        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        let task = session!.downloadTask(with: modelInfo.url)
        downloadTask = task
        state = .downloading(progress: 0, bytesReceived: 0)
        task.resume()
    }

    /// Cancel an in-progress download and clean up partial files.
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        session?.invalidateAndCancel()
        session = nil
        cleanupPartialFile()
        state = .notDownloaded
    }

    /// Delete the downloaded model.
    public func deleteModel() {
        try? FileManager.default.removeItem(at: destinationURL)
        state = .notDownloaded
    }

    /// Formatted string for the expected model size (e.g., "2.0 GB").
    public var formattedExpectedSize: String {
        ByteCountFormatter.string(fromByteCount: modelInfo.expectedSize, countStyle: .file)
    }

    /// Formatted string for the actual downloaded model size.
    public var formattedDownloadedSize: String? {
        guard case .downloaded(_, let size) = state else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    // MARK: - Private

    private func checkExistingModel() {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            if let attrs = try? fm.attributesOfItem(atPath: destinationURL.path),
               let size = attrs[.size] as? Int64 {
                state = .downloaded(path: destinationURL.path, size: size)
            } else {
                state = .downloaded(path: destinationURL.path, size: 0)
            }
        }
    }

    private func createModelsDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(
            at: Self.modelsDirectory,
            withIntermediateDirectories: true
        )
    }

    private func cleanupPartialFile() {
        // URLSession manages its own temp files, but clean destination if exists partially
        try? FileManager.default.removeItem(at: destinationURL)
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloadManager: URLSessionDownloadDelegate {
    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let dest = Self.modelsDirectory.appendingPathComponent(modelInfo.fileName)
        do {
            let fm = FileManager.default
            // Remove existing file if present (e.g., from a previous partial)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: location, to: dest)

            let attrs = try fm.attributesOfItem(atPath: dest.path)
            let size = attrs[.size] as? Int64 ?? 0

            MainActor.assumeIsolated {
                self.state = .downloaded(path: dest.path, size: size)
                self.downloadTask = nil
                self.session?.finishTasksAndInvalidate()
                self.session = nil
            }
        } catch {
            MainActor.assumeIsolated {
                self.state = .failed(message: error.localizedDescription)
                self.downloadTask = nil
                self.session?.invalidateAndCancel()
                self.session = nil
            }
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : modelInfo.expectedSize
        let progress = total > 0 ? Double(totalBytesWritten) / Double(total) : 0

        MainActor.assumeIsolated {
            self.state = .downloading(progress: min(progress, 1.0), bytesReceived: totalBytesWritten)
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }

        // Don't report cancellation as failure
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }

        MainActor.assumeIsolated {
            self.state = .failed(message: error.localizedDescription)
            self.downloadTask = nil
            self.session?.invalidateAndCancel()
            self.session = nil
        }
    }
}
