import Foundation
import SwiftData

// MARK: - Persisted Profile

/// SwiftData model for persisting cleanup profiles across launches.
@Model
public final class PersistedProfile {
    /// Stable cleanup profile identifier.
    @Attribute(.unique) public var profileID: String
    /// Display name for the profile.
    public var name: String
    /// User-facing profile description.
    public var profileDescription: String
    /// JSON-encoded category identifiers enabled by the profile.
    public var categoriesData: Data
    /// JSON-encoded safety overrides associated with the profile.
    public var overridesData: Data
    /// Whether this profile was created by the user.
    public var isCustom: Bool

    /// Creates a persisted profile from the domain model.
    public init(from profile: CleanupProfile) {
        self.profileID = profile.id
        self.name = profile.name
        self.profileDescription = profile.description
        self.categoriesData = (try? JSONEncoder().encode(profile.categories)) ?? Data()
        self.overridesData = (try? JSONEncoder().encode(profile.safetyOverrides)) ?? Data()
        self.isCustom = profile.isCustom
    }

    /// Convert back to domain model.
    public func toDomain() -> CleanupProfile {
        let categories = (try? JSONDecoder().decode([String].self, from: categoriesData)) ?? []
        let overrides = (try? JSONDecoder().decode([SafetyOverride].self, from: overridesData)) ?? []
        return CleanupProfile(
            id: profileID,
            name: name,
            description: profileDescription,
            categories: categories,
            safetyOverrides: overrides,
            isCustom: isCustom
        )
    }

    /// Update from domain model.
    public func update(from profile: CleanupProfile) {
        self.name = profile.name
        self.profileDescription = profile.description
        self.categoriesData = (try? JSONEncoder().encode(profile.categories)) ?? Data()
        self.overridesData = (try? JSONEncoder().encode(profile.safetyOverrides)) ?? Data()
        self.isCustom = profile.isCustom
    }
}

// MARK: - Persisted Audit Entry

/// SwiftData model for queryable audit log entries.
@Model
public final class PersistedAuditEntry {
    /// Stable audit entry identifier.
    public var entryID: UUID
    /// Time when the audited action occurred.
    public var timestamp: Date
    /// Tool or subsystem that produced the audit entry.
    public var tool: String
    /// Command or action label recorded for the entry.
    public var command: String
    /// JSON-encoded list of files affected by the action.
    public var filesData: Data
    /// Raw safety level value captured with the entry.
    public var safetyLevel: String
    /// Raw confirmation method value captured with the entry.
    public var confirmationMethod: String
    /// Raw cleanup method value captured with the entry.
    public var cleanupMethod: String
    /// Number of bytes freed by the audited action.
    public var bytesFreed: Int64
    // Phase 3 additions: both default to nil to keep lightweight migration
    // compatible with rows written before the MCP destructive path landed.
    /// Optional transport label for MCP or agent-originated actions.
    public var transport: String?
    /// Optional client identifier for MCP or agent-originated actions.
    public var clientID: String?

    /// Creates a persisted audit entry from the domain model.
    public init(from entry: AuditEntry) {
        self.entryID = entry.id
        self.timestamp = entry.timestamp
        self.tool = entry.tool
        self.command = entry.command
        self.filesData = (try? JSONEncoder().encode(entry.files)) ?? Data()
        self.safetyLevel = entry.safetyLevel.rawValue
        self.confirmationMethod = entry.confirmationMethod.rawValue
        self.cleanupMethod = entry.cleanupMethod.rawValue
        self.bytesFreed = entry.bytesFreed
        self.transport = entry.transport
        self.clientID = entry.clientID
    }

    /// Convert back to domain model.
    public func toDomain() -> AuditEntry? {
        guard let safety = SafetyLevel(rawValue: safetyLevel),
              let confirmation = ConfirmationTier(rawValue: confirmationMethod),
              let cleanup = CleanupMethod(rawValue: cleanupMethod),
              let files = try? JSONDecoder().decode([AuditFile].self, from: filesData) else {
            return nil
        }
        return AuditEntry(
            id: entryID,
            timestamp: timestamp,
            tool: tool,
            command: command,
            files: files,
            safetyLevel: safety,
            confirmationMethod: confirmation,
            cleanupMethod: cleanup,
            bytesFreed: bytesFreed,
            transport: transport,
            clientID: clientID
        )
    }
}

// MARK: - Persisted Settings

/// SwiftData model for app settings that persist across launches.
@Model
public final class PersistedSettings {
    /// Unique row key for the singleton settings record.
    @Attribute(.unique) public var key: String = "default"
    /// Active cleanup profile identifier.
    public var activeProfileID: String
    /// Retention threshold used by cleanup rules, in days.
    public var retentionDays: Int
    /// Date of the most recent manual or scheduled scan.
    public var lastScanDate: Date?
    /// Whether automatic scheduled scans are enabled.
    public var autoScanEnabled: Bool
    // Defaults keep lightweight migration compatible with settings rows written before scheduling existed.
    /// Raw value for the scheduled scan interval.
    public var scheduledScanIntervalRaw: String = "daily"
    /// Cron-like expression used for custom scheduled scans.
    public var scheduledScanCustomSchedule: String = "0 9 * * *"
    /// Cleanup profile identifier used by scheduled scans.
    public var scheduledScanProfileID: String = "light"
    /// Whether scheduled scans should be skipped while on battery power.
    public var scheduledScanSkipWhenOnBattery: Bool = true
    /// Date of the most recent scheduled scan run.
    public var scheduledScanLastRunDate: Date?
    /// Date of the most recent scheduled scan summary.
    public var scheduledScanLastSummaryDate: Date?
    /// Item count from the most recent scheduled scan summary.
    public var scheduledScanLastSummaryItemCount: Int = 0
    /// Reclaimable bytes from the most recent scheduled scan summary.
    public var scheduledScanLastSummaryReclaimableBytes: Int64 = 0
    /// Profile identifier used by the most recent scheduled scan summary.
    public var scheduledScanLastSummaryProfileID: String = "light"
    /// Error message from the most recent failed scheduled scan summary.
    public var scheduledScanLastSummaryError: String?
    /// Whether the most recent scheduled scan summary has been acknowledged.
    public var scheduledScanLastSummaryAcknowledged: Bool = true
    /// User-configurable project roots for Dev Purge scans (parity with `mo purge --paths`).
    /// Empty means "use `PathExpander.defaultScanRoots()`".
    public var scanRoots: [String] = []

    /// Creates the singleton persisted settings record.
    public init(
        activeProfileID: String = "developer",
        retentionDays: Int = 90,
        lastScanDate: Date? = nil,
        autoScanEnabled: Bool = false,
        scheduledScanIntervalRaw: String = "daily",
        scheduledScanCustomSchedule: String = "0 9 * * *",
        scheduledScanProfileID: String = "light",
        scheduledScanSkipWhenOnBattery: Bool = true,
        scheduledScanLastRunDate: Date? = nil,
        scheduledScanLastSummaryDate: Date? = nil,
        scheduledScanLastSummaryItemCount: Int = 0,
        scheduledScanLastSummaryReclaimableBytes: Int64 = 0,
        scheduledScanLastSummaryProfileID: String = "light",
        scheduledScanLastSummaryError: String? = nil,
        scheduledScanLastSummaryAcknowledged: Bool = true,
        scanRoots: [String] = []
    ) {
        self.key = "default"
        self.activeProfileID = activeProfileID
        self.retentionDays = retentionDays
        self.lastScanDate = lastScanDate
        self.autoScanEnabled = autoScanEnabled
        self.scheduledScanIntervalRaw = scheduledScanIntervalRaw
        self.scheduledScanCustomSchedule = scheduledScanCustomSchedule
        self.scheduledScanProfileID = scheduledScanProfileID
        self.scheduledScanSkipWhenOnBattery = scheduledScanSkipWhenOnBattery
        self.scheduledScanLastRunDate = scheduledScanLastRunDate
        self.scheduledScanLastSummaryDate = scheduledScanLastSummaryDate
        self.scheduledScanLastSummaryItemCount = scheduledScanLastSummaryItemCount
        self.scheduledScanLastSummaryReclaimableBytes = scheduledScanLastSummaryReclaimableBytes
        self.scheduledScanLastSummaryProfileID = scheduledScanLastSummaryProfileID
        self.scheduledScanLastSummaryError = scheduledScanLastSummaryError
        self.scheduledScanLastSummaryAcknowledged = scheduledScanLastSummaryAcknowledged
        self.scanRoots = scanRoots
    }
}

// MARK: - Persisted Scan History

/// SwiftData model tracking scan results over time.
@Model
public final class PersistedScanHistory {
    /// Date when the scan history row was recorded.
    public var scanDate: Date
    /// Category represented by this history row.
    public var category: String
    /// Number of items found for the category.
    public var itemCount: Int
    /// Total bytes found for the category.
    public var totalBytes: Int64
    /// Bytes freed from this scan category.
    public var bytesFreed: Int64
    /// Cleanup profile used for the scan.
    public var profileID: String

    /// Creates a persisted scan history row.
    public init(
        scanDate: Date = Date(),
        category: String,
        itemCount: Int,
        totalBytes: Int64,
        bytesFreed: Int64 = 0,
        profileID: String
    ) {
        self.scanDate = scanDate
        self.category = category
        self.itemCount = itemCount
        self.totalBytes = totalBytes
        self.bytesFreed = bytesFreed
        self.profileID = profileID
    }
}

// MARK: - Persisted Whitelist Entry

/// SwiftData model for persisting path whitelist entries.
///
/// Whitelisted paths are excluded from cleanup scans.
@Model
public final class PersistedWhitelistEntry {
    /// Unique path or glob-like pattern to exclude from scans.
    @Attribute(.unique) public var pattern: String
    /// Optional user note explaining the whitelist entry.
    public var note: String
    /// Date when the whitelist entry was created.
    public var createdAt: Date

    /// Creates a persisted whitelist entry.
    public init(pattern: String, note: String = "", createdAt: Date = Date()) {
        self.pattern = pattern
        self.note = note
        self.createdAt = createdAt
    }
}
