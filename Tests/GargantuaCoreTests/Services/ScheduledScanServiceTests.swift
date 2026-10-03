import Foundation
import Testing
@testable import GargantuaCore

@Suite("ScheduledScanService")
// swiftlint:disable:next type_body_length
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

    @Test("controller registers from notFound (the agent pre-registration state)")
    func controllerRegistersWhenAgentNotFound() throws {
        let installer = SpyScheduledScanAgentInstaller(initialStatus: .notFound)
        let controller = ScheduledScanController(installer: installer)

        // `.notFound` is SMAppService's normal pre-registration state for an agent,
        // not a missing plist — enabling must register rather than bail.
        #expect(try controller.synchronize(configuration: ScheduledScanConfiguration(isEnabled: true)) == .enabled)
        #expect(installer.registerCount == 1)

        // Disabling from notFound has nothing registered to tear down.
        let installer2 = SpyScheduledScanAgentInstaller(initialStatus: .notFound)
        let controller2 = ScheduledScanController(installer: installer2)
        #expect(try controller2.synchronize(configuration: ScheduledScanConfiguration(isEnabled: false)) == .notFound)
        #expect(installer2.unregisterCount == 0)
    }

    @Test("controller skips register when platform is unavailable")
    func controllerSkipsRegisterWhenUnavailable() throws {
        let installer = SpyScheduledScanAgentInstaller(initialStatus: .unavailable)
        let controller = ScheduledScanController(installer: installer)

        #expect(try controller.synchronize(configuration: ScheduledScanConfiguration(isEnabled: true)) == .unavailable)
        #expect(installer.registerCount == 0)
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

    @Test("runner leaves excluded paths out of the summary")
    @MainActor
    func runnerAppliesExclusions() async throws {
        let persistence = try PersistenceController(inMemory: true)
        try persistence.bootstrap()
        try persistence.updateSettings { settings in
            settings.autoScanEnabled = true
            settings.scheduledScanIntervalRaw = "daily"
            settings.scheduledScanLastRunDate = Date(timeIntervalSince1970: 0)
        }
        try persistence.addExclusionEntry(pattern: "/tmp/excluded")
        let runner = ScheduledScanRunner(
            persistence: persistence,
            scanner: StubScheduledScanScanner(results: [
                makeResult(id: "kept", size: 10_000, safety: .safe),
                makeResult(id: "excluded", size: 50_000, safety: .safe),
            ]),
            notifier: SpyScheduledScanNotifier(),
            powerStateProvider: FixedScheduledScanPowerStateProvider(isOnBattery: false),
            now: { Date(timeIntervalSince1970: 200_000) }
        )

        guard case .completed(let summary) = await runner.runIfDue() else {
            Issue.record("expected completed result")
            return
        }

        #expect(summary.itemCount == 1)
        #expect(summary.reclaimableBytes == 10_000)
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

    @Test("runner invokes agent audit hook after completed scheduled scan")
    @MainActor
    func runnerInvokesAgentAuditHook() async throws {
        let persistence = try PersistenceController(inMemory: true)
        try persistence.bootstrap()
        try persistence.updateSettings { settings in
            settings.autoScanEnabled = true
            settings.scheduledScanIntervalRaw = "daily"
            settings.scheduledScanProfileID = "light"
            settings.scheduledScanLastRunDate = Date(timeIntervalSince1970: 0)
        }

        let hook = SpyScheduledAgentAuditHook()
        let runDate = Date(timeIntervalSince1970: 200_000)
        let runner = ScheduledScanRunner(
            persistence: persistence,
            scanner: StubScheduledScanScanner(results: [
                makeResult(id: "safe", size: 10_000, safety: .safe),
            ]),
            notifier: SpyScheduledScanNotifier(),
            powerStateProvider: FixedScheduledScanPowerStateProvider(isOnBattery: false),
            agentAuditHook: hook,
            now: { runDate }
        )

        let result = await runner.runIfDue()
        guard case .completed(let summary) = result else {
            Issue.record("expected completed result")
            return
        }

        #expect(hook.summaries == [summary])
    }

    @Test("custom schedule still fires after the Mac sleeps across the scheduled minute")
    func customScheduleSurvivesLongSleep() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func at(day: Int, hour: Int, minute: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(
                timeZone: calendar.timeZone,
                year: 2026, month: 4, day: day, hour: hour, minute: minute
            )))
        }

        // Ran yesterday at 09:00. Today the Mac woke at 09:30 — 30 min past the
        // 900s poll interval — so launchd's coalesced fire is the only check
        // covering today's 09:00 occurrence. It must still be due.
        let lastRun = try at(day: 26, hour: 9, minute: 0)
        let wokeLate = try at(day: 27, hour: 9, minute: 30)
        #expect(ScheduledScanConfiguration(
            isEnabled: true,
            interval: .custom,
            customSchedule: "0 9 * * *",
            lastRunDate: lastRun
        ).isDue(now: wokeLate, calendar: calendar, customScheduleLookbackSeconds: 900))

        // Once today's run is recorded, the next poll must not re-fire it.
        let ranToday = try at(day: 27, hour: 9, minute: 30)
        #expect(!ScheduledScanConfiguration(
            isEnabled: true,
            interval: .custom,
            customSchedule: "0 9 * * *",
            lastRunDate: ranToday
        ).isDue(now: try at(day: 27, hour: 9, minute: 45), calendar: calendar, customScheduleLookbackSeconds: 900))
    }

    @Test("failed scheduled summary records the error without advancing the schedule clock")
    @MainActor
    func failedSummaryDoesNotAdvanceLastRun() throws {
        let persistence = try PersistenceController(inMemory: true)
        try persistence.bootstrap()
        let baseline = Date(timeIntervalSince1970: 0)
        try persistence.updateSettings { settings in
            settings.scheduledScanLastRunDate = baseline
            settings.lastScanDate = baseline
        }

        let failure = ScheduledScanSummary(
            date: Date(timeIntervalSince1970: 200_000),
            profileID: "light",
            itemCount: 0,
            reclaimableBytes: 0,
            errorMessage: "disk unavailable"
        )
        try persistence.recordScheduledScanSummary(failure)

        let afterFailure = try persistence.fetchSettings()
        #expect(afterFailure.scheduledScanLastRunDate == baseline)
        #expect(afterFailure.lastScanDate == baseline)
        // The failure is still surfaced to the dashboard / notification.
        #expect(try persistence.fetchPendingScheduledScanSummary() == failure)

        // A subsequent successful run does advance the clock.
        let success = ScheduledScanSummary(
            date: Date(timeIntervalSince1970: 300_000),
            profileID: "light",
            itemCount: 3,
            reclaimableBytes: 4_096
        )
        try persistence.recordScheduledScanSummary(success)
        let afterSuccess = try persistence.fetchSettings()
        #expect(afterSuccess.scheduledScanLastRunDate == success.date)
        #expect(afterSuccess.lastScanDate == success.date)
    }

    @Test("a persistent identical failure notifies once, then suppresses the repeat")
    @MainActor
    func failedRunSuppressesRepeatNotification() async throws {
        let persistence = try PersistenceController(inMemory: true)
        try persistence.bootstrap()
        try persistence.updateSettings { settings in
            settings.autoScanEnabled = true
            settings.scheduledScanIntervalRaw = "daily"
            settings.scheduledScanProfileID = "light"
            settings.scheduledScanLastRunDate = Date(timeIntervalSince1970: 0)
        }

        let notifier = SpyScheduledScanNotifier()
        func runFailure(at seconds: TimeInterval) async -> ScheduledScanRunResult {
            await ScheduledScanRunner(
                persistence: persistence,
                scanner: ThrowingScheduledScanScanner(),
                notifier: notifier,
                powerStateProvider: FixedScheduledScanPowerStateProvider(isOnBattery: false),
                now: { Date(timeIntervalSince1970: seconds) }
            ).runIfDue()
        }

        // First failure: user is notified, summary recorded, clock not advanced.
        guard case .failed = await runFailure(at: 200_000) else {
            Issue.record("expected failed result")
            return
        }
        #expect(notifier.delivered.count == 1)
        #expect(try persistence.fetchSettings().scheduledScanLastRunDate == Date(timeIntervalSince1970: 0))

        // Same error on the next poll (clock never advanced, so it's still due):
        // suppressed — no second notification — but the failure is still recorded.
        guard case .failed = await runFailure(at: 201_000) else {
            Issue.record("expected failed result")
            return
        }
        #expect(notifier.delivered.count == 1)
        #expect(try persistence.fetchPendingScheduledScanSummary()?.date == Date(timeIntervalSince1970: 201_000))
    }

    @Test("a failure with an empty error description is still treated as a failure")
    @MainActor
    func emptyErrorDescriptionStillCountsAsFailure() async throws {
        let persistence = try PersistenceController(inMemory: true)
        try persistence.bootstrap()
        let baseline = Date(timeIntervalSince1970: 0)
        try persistence.updateSettings { settings in
            settings.autoScanEnabled = true
            settings.scheduledScanIntervalRaw = "daily"
            settings.scheduledScanProfileID = "light"
            settings.scheduledScanLastRunDate = baseline
        }

        let result = await ScheduledScanRunner(
            persistence: persistence,
            scanner: EmptyMessageThrowingScanner(),
            notifier: SpyScheduledScanNotifier(),
            powerStateProvider: FixedScheduledScanPowerStateProvider(isOnBattery: false),
            now: { Date(timeIntervalSince1970: 200_000) }
        ).runIfDue()

        guard case .failed = result else {
            Issue.record("expected failed result")
            return
        }
        // The clock must not advance and the recorded summary must read as a
        // failure — never misclassified as success on an empty description.
        #expect(try persistence.fetchSettings().scheduledScanLastRunDate == baseline)
        #expect(try persistence.fetchPendingScheduledScanSummary()?.errorMessage?.isEmpty == false)
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
    private var currentStatus: ScheduledScanAgentStatus

    init(initialStatus: ScheduledScanAgentStatus = .notRegistered) {
        self.currentStatus = initialStatus
    }

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

private struct ThrowingScheduledScanScanner: ScheduledScanScanning {
    struct Failure: LocalizedError {
        var errorDescription: String? { "scan failed" }
    }

    func scan(profile: CleanupProfile, scanRoots: [URL]?) async throws -> [ScanResult] {
        throw Failure()
    }
}

private struct EmptyMessageThrowingScanner: ScheduledScanScanning {
    struct Failure: LocalizedError {
        var errorDescription: String? { "" }
    }

    func scan(profile: CleanupProfile, scanRoots: [URL]?) async throws -> [ScanResult] {
        throw Failure()
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

private final class SpyScheduledAgentAuditHook: ScheduledScanAgentAuditHook, @unchecked Sendable {
    var summaries: [ScheduledScanSummary] = []

    func run(summary: ScheduledScanSummary) async {
        summaries.append(summary)
    }
}
