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

/// Errors raised when a `ModelInfo` cannot be used safely — e.g., a manifest
/// whose `id` or file names would escape the models directory, or contain
/// path separators.
public enum ModelManifestError: Error, LocalizedError, Equatable {
    case invalidModelID(String)
    case invalidFileName(String)
    case duplicateFileName(String)

    public var errorDescription: String? {
        switch self {
        case .invalidModelID(let id):
            return "Invalid ModelInfo.id '\(id)': must be a single path component with no slashes or '..'."
        case .invalidFileName(let name):
            return "Invalid ModelFile.name '\(name)': must be a single filename with no slashes or '..'."
        case .duplicateFileName(let name):
            return "Duplicate ModelFile.name '\(name)' in manifest."
        }
    }
}
