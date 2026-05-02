import Foundation

/// User-managed additions to the global protected-root policy.
///
/// Bundled policy remains source-controlled and read-only. User entries live
/// in UserDefaults so they can be added/removed from Settings without a
/// SwiftData migration.
public final class ProtectedRootUserStore: @unchecked Sendable {
    public static let defaultsKey = "protectedRootUserEntries"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadEntries() -> [ProtectedRootEntry] {
        lock.lock()
        defer { lock.unlock() }

        guard let data = defaults.data(forKey: Self.defaultsKey),
              let entries = try? JSONDecoder().decode([StoredProtectedRootEntry].self, from: data) else {
            return []
        }
        return entries.map {
            ProtectedRootEntry(
                path: $0.path,
                reason: $0.reason,
                source: .user
            )
        }
    }

    @discardableResult
    public func add(path: String, reason: String = "User-added protected root") -> Bool {
        let entry = StoredProtectedRootEntry(
            path: path.trimmingCharacters(in: .whitespacesAndNewlines),
            reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !entry.path.isEmpty else { return false }

        lock.lock()
        var entries = loadStoredEntriesLocked()
        guard !entries.contains(where: { $0.path == entry.path }) else {
            lock.unlock()
            return false
        }
        entries.append(entry)
        saveStoredEntriesLocked(entries)
        lock.unlock()
        return true
    }

    public func remove(path: String) {
        lock.lock()
        var entries = loadStoredEntriesLocked()
        entries.removeAll { $0.path == path }
        saveStoredEntriesLocked(entries)
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        defaults.removeObject(forKey: Self.defaultsKey)
        lock.unlock()
    }

    private func loadStoredEntriesLocked() -> [StoredProtectedRootEntry] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let entries = try? JSONDecoder().decode([StoredProtectedRootEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private func saveStoredEntriesLocked(_ entries: [StoredProtectedRootEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

private struct StoredProtectedRootEntry: Codable, Sendable, Equatable {
    let path: String
    let reason: String
}
