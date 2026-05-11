import CryptoKit
import Foundation

extension ModelDownloadManager {
    /// Marker file dropped into the model directory after every file's SHA
    /// has been verified. Its contents are the manifest pins; `checkExistingModel`
    /// only trusts the directory if this marker matches the current manifest.
    /// Without the marker, the directory is treated as not-downloaded — a
    /// prior corruption, tampering, or abort path gets a clean retry instead
    /// of silently loading unverified bytes.
    static let verifiedMarkerName = ".gargantua-verified"

    enum PathComponentKind { case id, fileName }

    /// Validates that `modelInfo.id` and every `files[i].name` is a single
    /// path component (no slashes, no '..', non-empty, no leading dot-dot).
    /// Throws rather than trapping so tests can exercise the failure path.
    static func validateManifest(_ modelInfo: ModelInfo) throws {
        try validatePathComponent(modelInfo.id, kind: .id)
        var seen = Set<String>()
        for file in modelInfo.files {
            try validatePathComponent(file.name, kind: .fileName)
            if !seen.insert(file.name).inserted {
                throw ModelManifestError.duplicateFileName(file.name)
            }
        }
    }

    static func validatePathComponent(_ component: String, kind: PathComponentKind) throws {
        let invalid: Bool = {
            if component.isEmpty { return true }
            if component == "." || component == ".." { return true }
            if component.contains("/") || component.contains("\\") { return true }
            if component.hasPrefix(".") { return true }
            // Path APIs treat embedded NUL as end-of-string — reject defensively.
            if component.contains("\0") { return true }
            return false
        }()
        guard !invalid else {
            throw kind == .id
                ? ModelManifestError.invalidModelID(component)
                : ModelManifestError.invalidFileName(component)
        }
    }

    /// Returns the SHA-256 of the bytes at `url`, hex-encoded lowercase.
    /// Streams the file so large safetensors don't sit in RAM. `nonisolated`
    /// so the detached hashing task can call it off the main actor.
    nonisolated static func sha256Hex(of url: URL) throws -> String {
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

    static func buildVerifiedMarker(for modelInfo: ModelInfo) -> String {
        modelInfo.files
            .map { "\($0.name)\t\($0.sha256)" }
            .joined(separator: "\n") + "\n"
    }

    func checkExistingModel() {
        // Empty manifest is a misconfiguration, not a downloaded model —
        // `startDownload` will surface it.
        guard !modelInfo.files.isEmpty else { return }
        let directory = modelDirectory
        guard Self.isModelDirectoryComplete(directory, files: modelInfo.files) else {
            return
        }
        let markerURL = directory.appendingPathComponent(Self.verifiedMarkerName)
        guard let markerData = try? Data(contentsOf: markerURL),
              let markerText = String(data: markerData, encoding: .utf8),
              markerText == Self.buildVerifiedMarker(for: modelInfo) else {
            return
        }
        state = .downloaded(path: directory.path, size: modelInfo.expectedSize)
    }
}
