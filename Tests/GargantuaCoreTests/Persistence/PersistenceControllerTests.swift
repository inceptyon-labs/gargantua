import Foundation
import Testing
@testable import GargantuaCore

@Suite("PersistenceController")
struct PersistenceControllerTests {

    @MainActor
    private func makeController() throws -> PersistenceController {
        try PersistenceController(inMemory: true)
    }

    // MARK: - Bootstrap

    @Test("Bootstrap seeds built-in profiles and default settings")
    @MainActor
    func bootstrap() throws {
        let ctrl = try makeController()
        try ctrl.bootstrap()

        let profiles = try ctrl.fetchProfiles()
        #expect(profiles.count == CleanupProfile.builtIn.count)
        #expect(profiles.contains(where: { $0.id == "developer" }))
        #expect(profiles.contains(where: { $0.id == "light" }))
        #expect(profiles.contains(where: { $0.id == "deep" }))

        let settings = try ctrl.fetchSettings()
        #expect(settings.activeProfileID == "developer")
        #expect(settings.retentionDays == 90)
    }

    @Test("Bootstrap is idempotent — does not duplicate data")
    @MainActor
    func bootstrapIdempotent() throws {
        let ctrl = try makeController()
        try ctrl.bootstrap()
        try ctrl.bootstrap()
        try ctrl.bootstrap()

        let profiles = try ctrl.fetchProfiles()
        #expect(profiles.count == CleanupProfile.builtIn.count)
    }

    // MARK: - Profiles

    @Test("Save and fetch a custom profile")
    @MainActor
    func saveAndFetchProfile() throws {
        let ctrl = try makeController()

        let custom = CleanupProfile(
            id: "custom",
            name: "My Profile",
            description: "Custom test profile",
            categories: ["browser_cache", "system_logs"],
            isCustom: true
        )
        try ctrl.saveProfile(custom)

        let profiles = try ctrl.fetchProfiles()
        #expect(profiles.count == 1)

        let fetched = profiles[0]
        #expect(fetched.id == "custom")
        #expect(fetched.name == "My Profile")
        #expect(fetched.categories == ["browser_cache", "system_logs"])
        #expect(fetched.isCustom == true)
    }

    @Test("Update existing profile preserves ID")
    @MainActor
    func updateProfile() throws {
        let ctrl = try makeController()

        let original = CleanupProfile(
            id: "custom",
            name: "Original",
            description: "V1",
            categories: ["browser_cache"],
            isCustom: true
        )
        try ctrl.saveProfile(original)

        let updated = CleanupProfile(
            id: "custom",
            name: "Updated",
            description: "V2",
            categories: ["browser_cache", "system_cache"],
            isCustom: true
        )
        try ctrl.saveProfile(updated)

        let profiles = try ctrl.fetchProfiles()
        #expect(profiles.count == 1)
        #expect(profiles[0].name == "Updated")
        #expect(profiles[0].categories.count == 2)
    }

    @Test("Delete profile by ID")
    @MainActor
    func deleteProfile() throws {
        let ctrl = try makeController()
        try ctrl.bootstrap()

        let beforeCount = try ctrl.fetchProfiles().count
        try ctrl.deleteProfile(id: "light")
        let afterCount = try ctrl.fetchProfiles().count

        #expect(afterCount == beforeCount - 1)
    }

    @Test("Profile with safety overrides round-trips correctly")
    @MainActor
    func profileOverridesRoundTrip() throws {
        let ctrl = try makeController()

        try ctrl.saveProfile(.developer)

        let fetched = try ctrl.fetchProfiles().first(where: { $0.id == "developer" })
        #expect(fetched != nil)
        #expect(fetched!.safetyOverrides.count == CleanupProfile.developer.safetyOverrides.count)
        #expect(fetched!.safetyOverrides[0].condition == "age > 30d")
    }

    // MARK: - Settings

    @Test("Default settings created on first fetch")
    @MainActor
    func defaultSettings() throws {
        let ctrl = try makeController()

        let settings = try ctrl.fetchSettings()
        #expect(settings.activeProfileID == "developer")
        #expect(settings.retentionDays == 90)
        #expect(settings.autoScanEnabled == false)
        #expect(settings.scheduledScanIntervalRaw == "daily")
        #expect(settings.scheduledScanProfileID == "light")
        #expect(settings.scheduledScanSkipWhenOnBattery == true)
        #expect(settings.scanRoots.isEmpty)
    }

    @Test("Update settings persists changes")
    @MainActor
    func updateSettings() throws {
        let ctrl = try makeController()

        try ctrl.updateSettings { settings in
            settings.activeProfileID = "deep"
            settings.retentionDays = 30
            settings.autoScanEnabled = true
            settings.scheduledScanIntervalRaw = "weekly"
            settings.scheduledScanProfileID = "deep"
            settings.scheduledScanSkipWhenOnBattery = false
            settings.scanRoots = ["~/Projects", "~/work"]
        }

        let settings = try ctrl.fetchSettings()
        #expect(settings.activeProfileID == "deep")
        #expect(settings.retentionDays == 30)
        #expect(settings.autoScanEnabled == true)
        #expect(settings.scheduledScanIntervalRaw == "weekly")
        #expect(settings.scheduledScanProfileID == "deep")
        #expect(settings.scheduledScanSkipWhenOnBattery == false)
        #expect(settings.scanRoots == ["~/Projects", "~/work"])
    }

    @Test("Scheduled scan summary persists until acknowledged")
    @MainActor
    func scheduledScanSummary() throws {
        let ctrl = try makeController()
        let date = Date(timeIntervalSince1970: 1_800)
        let summary = ScheduledScanSummary(
            date: date,
            profileID: "light",
            itemCount: 3,
            reclaimableBytes: 42_000
        )

        try ctrl.recordScheduledScanSummary(summary)

        let pending = try ctrl.fetchPendingScheduledScanSummary()
        #expect(pending == summary)
        #expect(try ctrl.fetchSettings().lastScanDate == date)

        try ctrl.acknowledgeScheduledScanSummary()
        #expect(try ctrl.fetchPendingScheduledScanSummary() == nil)
    }

    // MARK: - Audit Entries

    @Test("Record and query audit entries by date range")
    @MainActor
    func auditEntryDateRange() throws {
        let ctrl = try makeController()
        let now = Date()

        // Entry from 5 days ago
        let recent = AuditEntry(
            id: UUID(),
            timestamp: now.addingTimeInterval(-5 * 86400),
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/recent", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100
        )
        try ctrl.recordAuditEntry(recent)

        // Entry from 60 days ago
        let old = AuditEntry(
            id: UUID(),
            timestamp: now.addingTimeInterval(-60 * 86400),
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/old", size: 200)],
            safetyLevel: .review,
            confirmationMethod: .summaryDialog,
            bytesFreed: 200
        )
        try ctrl.recordAuditEntry(old)

        // Query last 30 days
        let last30 = try ctrl.fetchAuditEntries(from: now.addingTimeInterval(-30 * 86400))
        #expect(last30.count == 1)
        #expect(last30[0].files[0].path == "/recent")

        // Query last 90 days
        let last90 = try ctrl.fetchAuditEntries(from: now.addingTimeInterval(-90 * 86400))
        #expect(last90.count == 2)
    }

    @Test("Purge old audit entries based on retention")
    @MainActor
    func purgeAuditEntries() throws {
        let ctrl = try makeController()
        let now = Date()

        // Insert entries at various ages
        for days in [10, 50, 100, 200] {
            let entry = AuditEntry(
                id: UUID(),
                timestamp: now.addingTimeInterval(-Double(days) * 86400),
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/file-\(days)d", size: 100)],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                bytesFreed: 100
            )
            try ctrl.recordAuditEntry(entry)
        }

        let purged = try ctrl.purgeOldAuditEntries(retentionDays: 90)
        #expect(purged == 2) // 100d and 200d entries

        let remaining = try ctrl.fetchAuditEntries(from: Date.distantPast)
        #expect(remaining.count == 2)
    }

    @Test("fetchAuditEntries respects a row limit")
    @MainActor
    func fetchAuditEntriesRespectsLimit() throws {
        let ctrl = try makeController()
        let now = Date()
        for offset in 0 ..< 20 {
            let entry = AuditEntry(
                id: UUID(),
                timestamp: now.addingTimeInterval(-Double(offset) * 60),
                tool: "native",
                command: "clean",
                files: [AuditFile(path: "/row-\(offset)", size: 1)],
                safetyLevel: .safe,
                confirmationMethod: .singleButton,
                bytesFreed: 1
            )
            try ctrl.recordAuditEntry(entry)
        }

        let capped = try ctrl.fetchAuditEntries(from: Date.distantPast, limit: 5)
        #expect(capped.count == 5)

        let paged = try ctrl.fetchAuditEntries(from: Date.distantPast, limit: 5, offset: 5)
        #expect(paged.count == 5)
        #expect(paged.first?.files[0].path == "/row-5")
    }

    // MARK: - Scan History

    @Test("Record and fetch scan history")
    @MainActor
    func scanHistory() throws {
        let ctrl = try makeController()

        try ctrl.recordScanHistory(
            category: "browser_cache",
            itemCount: 15,
            totalBytes: 500_000_000,
            bytesFreed: 450_000_000,
            profileID: "developer"
        )

        try ctrl.recordScanHistory(
            category: "dev_artifacts",
            itemCount: 8,
            totalBytes: 2_000_000_000,
            bytesFreed: 1_800_000_000,
            profileID: "developer"
        )

        let all = try ctrl.fetchScanHistory()
        #expect(all.count == 2)

        let browserOnly = try ctrl.fetchScanHistory(category: "browser_cache")
        #expect(browserOnly.count == 1)
        #expect(browserOnly[0].itemCount == 15)
    }

    @Test("Last scan date returns most recent")
    @MainActor
    func lastScanDate() throws {
        let ctrl = try makeController()

        let earlier = Date().addingTimeInterval(-3600)
        let later = Date()

        let hist1 = PersistedScanHistory(
            scanDate: earlier,
            category: "browser_cache",
            itemCount: 5,
            totalBytes: 100,
            profileID: "dev"
        )
        ctrl.context.insert(hist1)

        let hist2 = PersistedScanHistory(
            scanDate: later,
            category: "dev_artifacts",
            itemCount: 3,
            totalBytes: 200,
            profileID: "dev"
        )
        ctrl.context.insert(hist2)
        try ctrl.context.save()

        let lastDate = try ctrl.lastScanDate()
        #expect(lastDate != nil)
        // Should be the later date (within 1 second tolerance)
        #expect(abs(lastDate!.timeIntervalSince(later)) < 1)
    }

    @Test("Last scan date returns nil when no history")
    @MainActor
    func lastScanDateEmpty() throws {
        let ctrl = try makeController()
        let lastDate = try ctrl.lastScanDate()
        #expect(lastDate == nil)
    }
}
