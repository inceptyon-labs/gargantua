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

    /// Save or update a profile.
    public func saveProfile(_ profile: CleanupProfile) throws {
        let predicate = #Predicate<PersistedProfile> { $0.profileID == profile.id }
        let descriptor = FetchDescriptor(predicate: predicate)
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
        let descriptor = FetchDescriptor(predicate: predicate)
        if let existing = try context.fetch(descriptor).first {
            context.delete(existing)
            try context.save()
        }
    }

    // MARK: - Settings

    /// Fetch the current settings, or return defaults if none exist.
    public func fetchSettings() throws -> PersistedSettings {
        let descriptor = FetchDescriptor<PersistedSettings>()
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

    // MARK: - Audit Entries

    /// Record an audit entry to the SwiftData store.
    public func recordAuditEntry(_ entry: AuditEntry) throws {
        context.insert(PersistedAuditEntry(from: entry))
        try context.save()
    }

    /// Fetch audit entries within a date range.
    public func fetchAuditEntries(from startDate: Date, to endDate: Date = Date()) throws -> [AuditEntry] {
        let predicate = #Predicate<PersistedAuditEntry> {
            $0.timestamp >= startDate && $0.timestamp <= endDate
        }
        let descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
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

    // MARK: - Whitelist

    /// Fetch all whitelist entries, sorted by creation date.
    public func fetchWhitelistEntries() throws -> [PersistedWhitelistEntry] {
        let descriptor = FetchDescriptor<PersistedWhitelistEntry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Add a whitelist entry. No-op if the pattern already exists.
    @discardableResult
    public func addWhitelistEntry(pattern: String, note: String = "") throws -> PersistedWhitelistEntry? {
        let predicate = #Predicate<PersistedWhitelistEntry> { $0.pattern == pattern }
        let descriptor = FetchDescriptor(predicate: predicate)
        guard try context.fetch(descriptor).isEmpty else { return nil }

        let entry = PersistedWhitelistEntry(pattern: pattern, note: note)
        context.insert(entry)
        try context.save()
        return entry
    }

    /// Remove a whitelist entry by pattern.
    public func removeWhitelistEntry(pattern: String) throws {
        let predicate = #Predicate<PersistedWhitelistEntry> { $0.pattern == pattern }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let existing = try context.fetch(descriptor).first {
            context.delete(existing)
            try context.save()
        }
    }
}
