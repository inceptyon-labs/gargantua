import Foundation

/// Shared validation and conversion for user-configured Dev Purge scan roots.
public enum ScanRootSettings {
    /// Normalize persisted scan-root strings while preserving the user's path style.
    ///
    /// Empty strings, relative paths, filesystem root, and the user's home directory
    /// are dropped so an invalid saved value falls back to default project-root detection.
    /// Duplicate roots are removed after tilde expansion and standardization.
    public static func normalizedStrings(from rawRoots: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for raw in rawRoots {
            guard let candidate = normalizedCandidate(from: raw),
                  seen.insert(candidate.key).inserted else {
                continue
            }
            normalized.append(candidate.value)
        }

        return normalized
    }

    /// Convert stored root strings to file URLs for `NativeScanAdapter`.
    public static func resolvedURLs(from rawRoots: [String]) -> [URL] {
        normalizedStrings(from: rawRoots).map { raw in
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
    }

    /// True when a typed value can be persisted as a scan root.
    public static func isValid(_ raw: String) -> Bool {
        normalizedCandidate(from: raw) != nil
    }

    private static func normalizedCandidate(from raw: String) -> (value: String, key: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed == "~" || trimmed.hasPrefix("~/") || trimmed.hasPrefix("/") else { return nil }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

        guard standardized != "/", standardized != home else { return nil }

        return (trimmed, standardized)
    }
}
