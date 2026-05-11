import Foundation

/// Manages downloading, verifying, and staging HF-layout model directories.
///
/// Models are stored at `~/Library/Application Support/Gargantua/models/<id>/`.
/// Each file is fetched sequentially, SHA-256 verified against the manifest,
/// then moved into the model directory. Any failure rolls back the directory
/// so the next attempt starts clean.
@MainActor
public final class ModelDownloadManager: NSObject, ObservableObject {
    /// Current state of the model.
    @Published public internal(set) var state: ModelState = .notDownloaded

    /// The model configuration.
    public let modelInfo: ModelInfo

    /// Directory where staged model directories live.
    public nonisolated static let modelsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Gargantua/models", isDirectory: true)
    }()

    // Internal (not private) so URLSession peer file can read/mutate them.
    var session: URLSession?
    var activeTask: URLSessionDownloadTask?
    var currentFileIndex: Int = 0
    var completedBytes: Int64 = 0
    var didCancel: Bool = false

    /// Staged directory for this model.
    public nonisolated var modelDirectory: URL {
        Self.modelsDirectory.appendingPathComponent(modelInfo.id, isDirectory: true)
    }

    /// Constructs a manager. Traps on a manifest that can't be safely staged
    /// (path-traversal in `id`/`name`, duplicate filenames). The default model
    /// is vetted, so production callers can rely on the default argument.
    public init(modelInfo: ModelInfo = ModelDownloadManager.defaultModel) {
        do {
            try Self.validateManifest(modelInfo)
        } catch {
            preconditionFailure("Invalid ModelInfo: \(error.localizedDescription)")
        }
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

    // MARK: - Download orchestration

    private func createDirectoriesIfNeeded() {
        try? FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
    }

    func removeModelDirectory() {
        try? FileManager.default.removeItem(at: modelDirectory)
    }

    func startNextFileDownload() {
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

        // Drop the verified-marker last. `checkExistingModel` refuses to
        // trust a directory without it, so a partial/interrupted staging
        // cannot masquerade as a complete download on the next launch.
        let markerURL = modelDirectory.appendingPathComponent(Self.verifiedMarkerName)
        let markerData = Data(Self.buildVerifiedMarker(for: modelInfo).utf8)
        do {
            try markerData.write(to: markerURL, options: .atomic)
        } catch {
            removeModelDirectory()
            state = .failed(message: "Failed to write verification marker: \(error.localizedDescription)")
            return
        }

        // Use the manifest's expected size as the staged size: every file was
        // SHA-verified, so the directory content is exactly what we pinned.
        state = .downloaded(path: modelDirectory.path, size: modelInfo.expectedSize)
    }

    func failDownload(_ message: String) {
        // Swallow failure callbacks that arrive after the user cancelled —
        // cancel already set `.notDownloaded` and wiped the directory.
        guard !didCancel else {
            activeTask = nil
            session = nil
            return
        }
        activeTask = nil
        session?.invalidateAndCancel()
        session = nil
        removeModelDirectory()
        state = .failed(message: message)
    }
}
