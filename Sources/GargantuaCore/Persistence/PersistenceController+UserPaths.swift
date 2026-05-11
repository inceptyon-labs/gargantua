import Foundation
import SwiftData

extension PersistenceController {
    // MARK: - Path Exclusions

    /// Fetch all path exclusion entries, sorted by creation date.
    public func fetchExclusionEntries() throws -> [PersistedWhitelistEntry] {
        let descriptor = FetchDescriptor<PersistedWhitelistEntry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Add a path exclusion entry. No-op if the pattern already exists.
    @discardableResult
    public func addExclusionEntry(pattern: String, note: String = "") throws -> PersistedWhitelistEntry? {
        let predicate = #Predicate<PersistedWhitelistEntry> { $0.pattern == pattern }
        let descriptor = FetchDescriptor(predicate: predicate)
        guard try context.fetch(descriptor).isEmpty else { return nil }

        let entry = PersistedWhitelistEntry(pattern: pattern, note: note)
        context.insert(entry)
        try context.save()
        return entry
    }

    /// Remove a path exclusion entry by pattern.
    public func removeExclusionEntry(pattern: String) throws {
        let predicate = #Predicate<PersistedWhitelistEntry> { $0.pattern == pattern }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            context.delete(existing)
            try context.save()
        }
    }

    @available(*, deprecated, renamed: "fetchExclusionEntries")
    // swiftlint:disable:next inclusive_language
    public func fetchWhitelistEntries() throws -> [PersistedWhitelistEntry] {
        try fetchExclusionEntries()
    }

    @available(*, deprecated, renamed: "addExclusionEntry")
    @discardableResult
    // swiftlint:disable:next inclusive_language
    public func addWhitelistEntry(pattern: String, note: String = "") throws -> PersistedWhitelistEntry? {
        try addExclusionEntry(pattern: pattern, note: note)
    }

    @available(*, deprecated, renamed: "removeExclusionEntry")
    // swiftlint:disable:next inclusive_language
    public func removeWhitelistEntry(pattern: String) throws {
        try removeExclusionEntry(pattern: pattern)
    }

    // MARK: - Personal Scope Roots

    /// Built-in defaults used by `seedDefaultPersonalScopeRootsIfEmpty`.
    /// Stored as `~/...` style so they migrate cleanly across user accounts.
    public static let defaultPersonalScopeRootPatterns: [String] = [
        "~/Documents",
        "~/Downloads",
        "~/Desktop",
        "~/Pictures",
        "~/Movies",
        "~/Music",
    ]

    /// Fetch all personal-scope root entries, sorted by creation date.
    public func fetchPersonalScopeRoots() throws -> [PersistedPersonalScopeRoot] {
        let descriptor = FetchDescriptor<PersistedPersonalScopeRoot>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Add a personal-scope root by path. No-op if the path already exists.
    @discardableResult
    public func addPersonalScopeRoot(path: String) throws -> PersistedPersonalScopeRoot? {
        let predicate = #Predicate<PersistedPersonalScopeRoot> { $0.pattern == path }
        let descriptor = FetchDescriptor(predicate: predicate)
        guard try context.fetch(descriptor).isEmpty else { return nil }

        let entry = PersistedPersonalScopeRoot(pattern: path)
        context.insert(entry)
        try context.save()
        return entry
    }

    /// Remove a personal-scope root by path.
    public func removePersonalScopeRoot(path: String) throws {
        let predicate = #Predicate<PersistedPersonalScopeRoot> { $0.pattern == path }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            context.delete(existing)
            try context.save()
        }
    }

    /// Seed the built-in personal-scope roots if no entries exist yet.
    /// Idempotent: a no-op when any entries are present (so a user who
    /// removed every default doesn't get them silently restored).
    public func seedDefaultPersonalScopeRootsIfEmpty() throws {
        guard try fetchPersonalScopeRoots().isEmpty else { return }
        for pattern in Self.defaultPersonalScopeRootPatterns {
            try addPersonalScopeRoot(path: pattern)
        }
    }
}
