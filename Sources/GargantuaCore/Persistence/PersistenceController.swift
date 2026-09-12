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
        let existingProfiles = try context.fetch(FetchDescriptor<PersistedProfile>())
        if existingProfiles.isEmpty {
            // First launch: seed built-in profiles.
            for profile in CleanupProfile.builtIn {
                context.insert(PersistedProfile(from: profile))
            }
        } else {
            // Built-in profiles are code-owned; the persisted copy is just a cache.
            // Reconcile every non-custom profile with its current definition so a
            // change to a built-in (e.g. removing the black-box `age>Nd→safe`
            // override) reaches installs whose DB was seeded by an older build,
            // instead of being frozen forever. User-authored profiles are left as-is.
            let builtInByID = Dictionary(
                CleanupProfile.reconcilableBuiltIns.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for persisted in existingProfiles where !persisted.isCustom {
                if let current = builtInByID[persisted.profileID] {
                    persisted.update(from: current)
                }
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
        let isFailure = summary.errorMessage?.isEmpty == false
        try updateSettings { settings in
            // A failed run must not advance the schedule clock: doing so pushes
            // the next attempt a full interval out and surfaces the failure as
            // the menu bar's "Last Scan". Only a successful run moves these
            // forward; the summary fields below still record the failure so the
            // dashboard and notification can report it.
            if !isFailure {
                settings.scheduledScanLastRunDate = summary.date
                settings.lastScanDate = summary.date
            }
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
}
