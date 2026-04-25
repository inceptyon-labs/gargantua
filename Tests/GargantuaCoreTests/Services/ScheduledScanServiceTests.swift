import Foundation
import Testing
@testable import GargantuaCore

@Suite("ScheduledScanService")
struct ScheduledScanServiceTests {
    @Test("LaunchAgent plist uses SMAppService bundle program and polling interval")
    func launchAgentPlistGeneration() throws {
        let data = try ScheduledScanLaunchAgentPlist.makeData(
            label: "com.example.scheduler",
            bundleProgram: "Contents/MacOS/TestScheduler",
            checkIntervalSeconds: 600
        )
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect(plist["Label"] as? String == "com.example.scheduler")
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/TestScheduler")
        #expect(plist["StartInterval"] as? Int == 600)
        #expect(plist["RunAtLoad"] as? Bool == false)
    }

    @Test("daily and weekly schedules become due after their interval")
    func fixedIntervalDueCalculation() {
        let now = Date(timeIntervalSince1970: 200_000)
        let yesterday = now.addingTimeInterval(-86_401)
        let recent = now.addingTimeInterval(-60)

        #expect(ScheduledScanConfiguration(isEnabled: true, interval: .daily, lastRunDate: nil).isDue(now: now))
        #expect(ScheduledScanConfiguration(isEnabled: true, interval: .daily, lastRunDate: yesterday).isDue(now: now))
        #expect(!ScheduledScanConfiguration(isEnabled: true, interval: .daily, lastRunDate: recent).isDue(now: now))
        #expect(!ScheduledScanConfiguration(isEnabled: false, interval: .weekly, lastRunDate: nil).isDue(now: now))
    }

    @Test("custom cron-like schedules match exact minute, hour, and weekday")
    func customScheduleMatching() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let mondayNineThirty = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 4,
            day: 27,
            hour: 9,
            minute: 30
        )))

        let expression = try #require(ScheduledScanCronExpression("30 9 * * 1"))

        #expect(expression.matches(mondayNineThirty, calendar: calendar))
        #expect(!expression.matches(mondayNineThirty.addingTimeInterval(60), calendar: calendar))
        #expect(ScheduledScanCronExpression("bad schedule") == nil)
    }

    @Test("custom schedules tolerate launchd polling drift")
    func customScheduleDueWithinPollingWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let nineTen = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 4,
            day: 27,
            hour: 9,
            minute: 10
        )))
        let nineOne = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 4,
            day: 27,
            hour: 9,
            minute: 1
        )))

        let configuration = ScheduledScanConfiguration(
            isEnabled: true,
            interval: .custom,
            customSchedule: "0 9 * * *",
            lastRunDate: nil
        )

        #expect(configuration.isDue(now: nineTen, calendar: calendar, customScheduleLookbackSeconds: 900))
        #expect(!ScheduledScanConfiguration(
            isEnabled: true,
            interval: .custom,
            customSchedule: "0 9 * * *",
            lastRunDate: nineOne
        ).isDue(now: nineTen, calendar: calendar, customScheduleLookbackSeconds: 900))
    }

    @Test("custom weekday 0 and 7 both mean Sunday")
    func customScheduleSundayAliases() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let sundayNoon = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 3,
            hour: 12,
            minute: 0
        )))

        #expect(try #require(ScheduledScanCronExpression("0 12 * * 0")).matches(sundayNoon, calendar: calendar))
        #expect(try #require(ScheduledScanCronExpression("0 12 * * 7")).matches(sundayNoon, calendar: calendar))
    }

    @Test("invalid custom schedule does not block launch agent uninstall")
    func disabledInvalidCustomScheduleCanSynchronizeLaunchAgent() {
        #expect(!ScheduledScanConfiguration(
            isEnabled: true,
            interval: .custom,
            customSchedule: "bad schedule"
        ).canSynchronizeLaunchAgent)
        #expect(ScheduledScanConfiguration(
            isEnabled: false,
            interval: .custom,
            customSchedule: "bad schedule"
        ).canSynchronizeLaunchAgent)
    }

    @Test("controller registers when enabled and unregisters when disabled")
    func controllerSynchronizesInstaller() throws {
        let installer = SpyScheduledScanAgentInstaller()
        let controller = ScheduledScanController(installer: installer)

        let enabled = ScheduledScanConfiguration(isEnabled: true)
        let disabled = ScheduledScanConfiguration(isEnabled: false)

        #expect(try controller.synchronize(configuration: enabled) == .enabled)
        #expect(installer.registerCount == 1)

        #expect(try controller.synchronize(configuration: disabled) == .notRegistered)
        #expect(installer.unregisterCount == 1)
    }

    @Test("runner records a pending summary and notifies when due")
    @MainActor
    func runnerRecordsSummary() async throws {
        let persistence = try PersistenceController(inMemory: true)
        try persistence.bootstrap()
        try persistence.updateSettings { settings in
            settings.autoScanEnabled = true
            settings.scheduledScanIntervalRaw = "daily"
            settings.scheduledScanProfileID = "light"
            settings.scheduledScanLastRunDate = Date(timeIntervalSince1970: 0)
        }

        let runDate = Date(timeIntervalSince1970: 200_000)
        let notifier = SpyScheduledScanNotifier()
        let runner = ScheduledScanRunner(
            persistence: persistence,
            scanner: StubScheduledScanScanner(results: [
                makeResult(id: "safe", size: 10_000, safety: .safe),
                makeResult(id: "review", size: 20_000, safety: .review),
                makeResult(id: "protected", size: 1_000_000, safety: .protected_),
            ]),
            notifier: notifier,
            powerStateProvider: FixedScheduledScanPowerStateProvider(isOnBattery: false),
            now: { runDate }
        )

        let result = await runner.runIfDue()
        guard case .completed(let summary) = result else {
            Issue.record("expected completed result")
            return
        }

        #expect(summary.itemCount == 2)
        #expect(summary.reclaimableBytes == 30_000)
        #expect(try persistence.fetchPendingScheduledScanSummary() == summary)
        #expect(notifier.delivered == [summary])
    }

    @Test("runner skips due scan on battery when configured")
    @MainActor
    func runnerSkipsBattery() async throws {
        let persistence = try PersistenceController(inMemory: true)
        try persistence.bootstrap()
        try persistence.updateSettings { settings in
            settings.autoScanEnabled = true
            settings.scheduledScanSkipWhenOnBattery = true
            settings.scheduledScanLastRunDate = Date(timeIntervalSince1970: 0)
        }

        let notifier = SpyScheduledScanNotifier()
        let runner = ScheduledScanRunner(
            persistence: persistence,
            scanner: StubScheduledScanScanner(results: [makeResult(id: "safe", size: 10_000, safety: .safe)]),
            notifier: notifier,
            powerStateProvider: FixedScheduledScanPowerStateProvider(isOnBattery: true),
            now: { Date(timeIntervalSince1970: 200_000) }
        )

        #expect(await runner.runIfDue() == .skippedOnBattery)
        #expect(try persistence.fetchPendingScheduledScanSummary() == nil)
        #expect(notifier.delivered.isEmpty)
    }

    private func makeResult(id: String, size: Int64, safety: SafetyLevel) -> ScanResult {
        ScanResult(
            id: id,
            name: id,
            path: "/tmp/\(id)",
            size: size,
            safety: safety,
            confidence: 90,
            explanation: "scheduled scan test",
            source: SourceAttribution(name: "test"),
            category: "system_cache"
        )
    }
}

private final class SpyScheduledScanAgentInstaller: ScheduledScanAgentInstalling, @unchecked Sendable {
    var registerCount = 0
    var unregisterCount = 0
    private var currentStatus: ScheduledScanAgentStatus = .notRegistered

    func status() -> ScheduledScanAgentStatus {
        currentStatus
    }

    func register() throws -> ScheduledScanAgentStatus {
        registerCount += 1
        currentStatus = .enabled
        return currentStatus
    }

    func unregister() throws -> ScheduledScanAgentStatus {
        unregisterCount += 1
        currentStatus = .notRegistered
        return currentStatus
    }
}

private struct StubScheduledScanScanner: ScheduledScanScanning {
    let results: [ScanResult]

    func scan(profile: CleanupProfile, scanRoots: [URL]?) async throws -> [ScanResult] {
        results
    }
}

private struct FixedScheduledScanPowerStateProvider: ScheduledScanPowerStateProviding {
    let isOnBattery: Bool

    func isOnBatteryPower() -> Bool {
        isOnBattery
    }
}

private final class SpyScheduledScanNotifier: ScheduledScanNotificationDelivering, @unchecked Sendable {
    var delivered: [ScheduledScanSummary] = []

    func deliver(summary: ScheduledScanSummary) async {
        delivered.append(summary)
    }
}
