import Foundation
import SwiftData

/// Manages SwiftData persistence for Gargantua.
///
/// Provides the ModelContainer, and CRUD operations for profiles, settings,
/// audit entries, and scan history. Call `bootstrap()` on first launch to
/// seed built-in profiles and default settings.
@MainActor
public final class PersistenceController {
    public let container: ModelContainer
    public let context: ModelContext

    /// All persisted model types registered with the container.
    public static let modelTypes: [any PersistentModel.Type] = [
        PersistedProfile.self,
        PersistedAuditEntry.self,
        PersistedSettings.self,
        PersistedScanHistory.self,
        PersistedWhitelistEntry.self,
        PersistedPersonalScopeRoot.self,
    ]

    /// Create a persistence controller with an on-disk store.
    public init() throws {
        let schema = Schema(Self.modelTypes)
        let config = ModelConfiguration("Gargantua", schema: schema)
        self.container = try ModelContainer(for: schema, configurations: [config])
        self.context = container.mainContext
    }

    /// Create a persistence controller with an in-memory store (for testing).
    public init(inMemory: Bool) throws {
        let schema = Schema(Self.modelTypes)
        let config = ModelConfiguration("GargantuaTest", schema: schema, isStoredInMemoryOnly: true)
        self.container = try ModelContainer(for: schema, configurations: [config])
        self.context = container.mainContext
    }

    // MARK: - Bootstrap

    /// Seed built-in profiles and default settings on first launch.
    ///
    /// Safe to call multiple times — existing data is not overwritten.
    public func bootstrap() throws {
        // Seed built-in profiles if none exist
        let profileCount = try context.fetchCount(FetchDescriptor<PersistedProfile>())
        if profileCount == 0 {
            for profile in CleanupProfile.builtIn {
                context.insert(PersistedProfile(from: profile))
            }
        }

        // Seed default settings if none exist
        let settingsCount = try context.fetchCount(FetchDescriptor<PersistedSettings>())
        if settingsCount == 0 {
            context.insert(PersistedSettings())
        }

        try context.save()
    }

    // MARK: - Profiles

    /// Fetch all persisted profiles as domain models.
    public func fetchProfiles() throws -> [CleanupProfile] {
        let descriptor = FetchDescriptor<PersistedProfile>(sortBy: [SortDescriptor(\.name)])
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    /// Build the MCP profile catalog from the same persisted profiles and
    /// active-profile setting used by the GUI.
    public func fetchMCPProfileCatalog(
        fallbackProfileID: String = "light"
    ) throws -> MCPProfileCatalog {
        try bootstrap()
        let settings = try fetchSettings()
        return MCPProfileCatalog(
            profiles: try fetchProfiles(),
            activeProfileID: settings.activeProfileID,
            fallbackProfileID: fallbackProfileID
        )
    }

    /// Save or update a profile.
    public func saveProfile(_ profile: CleanupProfile) throws {
        let predicate = #Predicate<PersistedProfile> { $0.profileID == profile.id }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            existing.update(from: profile)
        } else {
            context.insert(PersistedProfile(from: profile))
        }
        try context.save()
    }

    /// Delete a profile by ID.
    public func deleteProfile(id: String) throws {
        let predicate = #Predicate<PersistedProfile> { $0.profileID == id }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            context.delete(existing)
            try context.save()
        }
    }

    // MARK: - Settings

    /// Fetch the current settings, or return defaults if none exist.
    public func fetchSettings() throws -> PersistedSettings {
        var descriptor = FetchDescriptor<PersistedSettings>()
        descriptor.fetchLimit = 1
        if let settings = try context.fetch(descriptor).first {
            return settings
        }
        let settings = PersistedSettings()
        context.insert(settings)
        try context.save()
        return settings
    }

    /// Update settings. The passed closure receives the current settings for mutation.
    public func updateSettings(_ update: (PersistedSettings) -> Void) throws {
        let settings = try fetchSettings()
        update(settings)
        try context.save()
    }

    /// Persist the latest background scheduled-scan summary for the next dashboard launch.
    public func recordScheduledScanSummary(_ summary: ScheduledScanSummary) throws {
        try updateSettings { settings in
            settings.scheduledScanLastRunDate = summary.date
            settings.lastScanDate = summary.date
            settings.scheduledScanLastSummaryDate = summary.date
            settings.scheduledScanLastSummaryItemCount = summary.itemCount
            settings.scheduledScanLastSummaryReclaimableBytes = summary.reclaimableBytes
            settings.scheduledScanLastSummaryProfileID = summary.profileID
            settings.scheduledScanLastSummaryError = summary.errorMessage
            settings.scheduledScanLastSummaryAcknowledged = false
        }
    }

    /// Return the latest unacknowledged scheduled-scan summary, if any.
    public func fetchPendingScheduledScanSummary() throws -> ScheduledScanSummary? {
        let settings = try fetchSettings()
        guard settings.scheduledScanLastSummaryAcknowledged == false,
              let date = settings.scheduledScanLastSummaryDate
        else { return nil }

        return ScheduledScanSummary(
            date: date,
            profileID: settings.scheduledScanLastSummaryProfileID,
            itemCount: settings.scheduledScanLastSummaryItemCount,
            reclaimableBytes: settings.scheduledScanLastSummaryReclaimableBytes,
            errorMessage: settings.scheduledScanLastSummaryError
        )
    }

    public func acknowledgeScheduledScanSummary() throws {
        try updateSettings { settings in
            settings.scheduledScanLastSummaryAcknowledged = true
        }
    }

    // MARK: - Audit Entries

    /// Record an audit entry to the SwiftData store.
    public func recordAuditEntry(_ entry: AuditEntry) throws {
        context.insert(PersistedAuditEntry(from: entry))
        try context.save()
    }

    /// Fetch audit entries within a date range.
    ///
    /// `limit` caps the number of rows returned (default 1000) so a wide
    /// date window on a populated audit log can't stall an interactive
    /// query. `offset` lets callers paginate when they need a sliding view
    /// instead of the most-recent batch.
    public func fetchAuditEntries(
        from startDate: Date,
        to endDate: Date = Date(),
        limit: Int = 1000,
        offset: Int = 0
    ) throws -> [AuditEntry] {
        let predicate = #Predicate<PersistedAuditEntry> {
            $0.timestamp >= startDate && $0.timestamp <= endDate
        }
        var descriptor = FetchDescriptor(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        return try context.fetch(descriptor).compactMap { $0.toDomain() }
    }

    /// Purge audit entries older than the configured retention period.
    ///
    /// - Returns: The number of entries purged.
    @discardableResult
    public func purgeOldAuditEntries(retentionDays: Int? = nil) throws -> Int {
        let settings = try fetchSettings()
        let days = retentionDays ?? settings.retentionDays
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)

        let predicate = #Predicate<PersistedAuditEntry> { $0.timestamp < cutoff }
        let descriptor = FetchDescriptor(predicate: predicate)
        let old = try context.fetch(descriptor)
        let count = old.count

        for entry in old {
            context.delete(entry)
        }
        if count > 0 {
            try context.save()
        }
        return count
    }

    // MARK: - Scan History

    /// Record a scan result for history tracking.
    public func recordScanHistory(
        category: String,
        itemCount: Int,
        totalBytes: Int64,
        bytesFreed: Int64 = 0,
        profileID: String
    ) throws {
        let record = PersistedScanHistory(
            category: category,
            itemCount: itemCount,
            totalBytes: totalBytes,
            bytesFreed: bytesFreed,
            profileID: profileID
        )
        context.insert(record)
        try context.save()
    }

    /// Fetch scan history, optionally filtered by category.
    public func fetchScanHistory(category: String? = nil, limit: Int = 50) throws -> [PersistedScanHistory] {
        var descriptor: FetchDescriptor<PersistedScanHistory>
        if let category {
            let predicate = #Predicate<PersistedScanHistory> { $0.category == category }
            descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.scanDate, order: .reverse)])
        } else {
            descriptor = FetchDescriptor(sortBy: [SortDescriptor(\.scanDate, order: .reverse)])
        }
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    /// Get the most recent scan date across all categories.
    public func lastScanDate() throws -> Date? {
        var descriptor = FetchDescriptor<PersistedScanHistory>(sortBy: [SortDescriptor(\.scanDate, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.scanDate
    }

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
