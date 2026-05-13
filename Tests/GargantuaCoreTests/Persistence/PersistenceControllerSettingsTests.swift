import Foundation
import Testing
@testable import GargantuaCore

@MainActor
private func makeController() throws -> PersistenceController {
    try PersistenceController(inMemory: true)
}

@Suite("PersistenceController settings and scheduled scan summary")
@MainActor
struct PersistenceControllerSettingsTests {

    // MARK: - Settings

    @Test("Default settings created on first fetch")
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
}
