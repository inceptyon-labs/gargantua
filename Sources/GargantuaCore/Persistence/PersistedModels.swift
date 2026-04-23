import Foundation
import SwiftData

// MARK: - Persisted Profile

/// SwiftData model for persisting cleanup profiles across launches.
@Model
public final class PersistedProfile {
    @Attribute(.unique) public var profileID: String
    public var name: String
    public var profileDescription: String
    public var categoriesData: Data
    public var overridesData: Data
    public var isCustom: Bool

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
    public var entryID: UUID
    public var timestamp: Date
    public var tool: String
    public var command: String
    public var filesData: Data
    public var safetyLevel: String
    public var confirmationMethod: String
    public var cleanupMethod: String
    public var bytesFreed: Int64
    // Phase 3 additions: both default to nil to keep lightweight migration
    // compatible with rows written before the MCP destructive path landed.
    public var transport: String?
    public var clientID: String?

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
    @Attribute(.unique) public var key: String = "default"
    public var activeProfileID: String
    public var retentionDays: Int
    public var lastScanDate: Date?
    public var autoScanEnabled: Bool
    /// User-configurable project roots for Dev Purge scans (parity with `mo purge --paths`).
    /// Empty means "use `PathExpander.defaultScanRoots()`".
    public var scanRoots: [String] = []

    public init(
        activeProfileID: String = "developer",
        retentionDays: Int = 90,
        lastScanDate: Date? = nil,
        autoScanEnabled: Bool = false,
        scanRoots: [String] = []
    ) {
        self.key = "default"
        self.activeProfileID = activeProfileID
        self.retentionDays = retentionDays
        self.lastScanDate = lastScanDate
        self.autoScanEnabled = autoScanEnabled
        self.scanRoots = scanRoots
    }
}

// MARK: - Persisted Scan History

/// SwiftData model tracking scan results over time.
@Model
public final class PersistedScanHistory {
    public var scanDate: Date
    public var category: String
    public var itemCount: Int
    public var totalBytes: Int64
    public var bytesFreed: Int64
    public var profileID: String

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
    @Attribute(.unique) public var pattern: String
    public var note: String
    public var createdAt: Date

    public init(pattern: String, note: String = "", createdAt: Date = Date()) {
        self.pattern = pattern
        self.note = note
        self.createdAt = createdAt
    }
}
