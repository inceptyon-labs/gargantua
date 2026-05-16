import Foundation

/// Persisted list of user-added folder paths for the file organizer.
/// Stored as a JSON-encoded array of standardized file paths under
/// `organizer.customFolders` in `UserDefaults`. Kept independent of
/// `OrganizerBackendPreference` so the two settings don't share a
/// failure mode.
public struct OrganizerCustomFolderStore: @unchecked Sendable {
    public static let userDefaultsKey = "organizer.customFolders"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [URL] {
        guard let data = defaults.data(forKey: Self.userDefaultsKey),
              let paths = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public func save(_ urls: [URL]) {
        let paths = urls.map { $0.standardizedFileURL.path }
        guard let data = try? JSONEncoder().encode(paths) else { return }
        defaults.set(data, forKey: Self.userDefaultsKey)
    }

    public func add(_ url: URL) {
        var current = load()
        let targetPath = url.standardizedFileURL.path
        // De-dupe by path string — URL equality is sensitive to
        // isDirectory and trailing-slash differences even when the
        // underlying path is identical.
        guard !current.contains(where: { $0.standardizedFileURL.path == targetPath }) else { return }
        current.append(url.standardizedFileURL)
        save(current)
    }

    public func remove(_ url: URL) {
        let targetPath = url.standardizedFileURL.path
        let filtered = load().filter { $0.standardizedFileURL.path != targetPath }
        save(filtered)
    }
}
