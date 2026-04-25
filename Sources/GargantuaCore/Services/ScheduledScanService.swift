import Foundation
#if os(macOS)
import IOKit.ps
@preconcurrency import ServiceManagement
@preconcurrency import UserNotifications
#endif

public enum ScheduledScanInterval: String, CaseIterable, Codable, Identifiable, Sendable {
    case daily
    case weekly
    case custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .custom: "Custom"
        }
    }

    public var detail: String {
        switch self {
        case .daily: "Runs once every 24 hours."
        case .weekly: "Runs once every 7 days."
        case .custom: "Uses a five-field cron-like schedule."
        }
    }
}

public struct ScheduledScanConfiguration: Equatable, Sendable {
    public var isEnabled: Bool
    public var interval: ScheduledScanInterval
    public var customSchedule: String
    public var profileID: String
    public var skipWhenOnBattery: Bool
    public var lastRunDate: Date?

    public init(
        isEnabled: Bool = false,
        interval: ScheduledScanInterval = .daily,
        customSchedule: String = "0 9 * * *",
        profileID: String = "light",
        skipWhenOnBattery: Bool = true,
        lastRunDate: Date? = nil
    ) {
        self.isEnabled = isEnabled
        self.interval = interval
        self.customSchedule = customSchedule
        self.profileID = profileID
        self.skipWhenOnBattery = skipWhenOnBattery
        self.lastRunDate = lastRunDate
    }

    public init(settings: PersistedSettings) {
        self.init(
            isEnabled: settings.autoScanEnabled,
            interval: ScheduledScanInterval(rawValue: settings.scheduledScanIntervalRaw) ?? .daily,
            customSchedule: settings.scheduledScanCustomSchedule,
            profileID: settings.scheduledScanProfileID,
            skipWhenOnBattery: settings.scheduledScanSkipWhenOnBattery,
            lastRunDate: settings.scheduledScanLastRunDate
        )
    }

    public var normalizedCustomSchedule: String {
        customSchedule.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isCustomScheduleValid: Bool {
        interval != .custom || ScheduledScanCronExpression(normalizedCustomSchedule) != nil
    }

    public var canSynchronizeLaunchAgent: Bool {
        !isEnabled || isCustomScheduleValid
    }

    public func isDue(
        now: Date,
        calendar: Calendar = .current,
        customScheduleLookbackSeconds: TimeInterval = TimeInterval(ScheduledScanLaunchAgentConfiguration.checkIntervalSeconds)
    ) -> Bool {
        guard isEnabled else { return false }

        switch interval {
        case .daily:
            return hasElapsed(now: now, seconds: 86_400)
        case .weekly:
            return hasElapsed(now: now, seconds: 604_800)
        case .custom:
            guard let expression = ScheduledScanCronExpression(normalizedCustomSchedule) else {
                return false
            }
            return expression.matchesSinceLastRun(
                now: now,
                lastRunDate: lastRunDate,
                lookbackSeconds: customScheduleLookbackSeconds,
                calendar: calendar
            )
        }
    }

    private func hasElapsed(now: Date, seconds: TimeInterval) -> Bool {
        guard let lastRunDate else { return true }
        return now.timeIntervalSince(lastRunDate) >= seconds
    }
}

public struct ScheduledScanCronExpression: Equatable, Sendable {
    private let minute: Int?
    private let hour: Int?
    private let dayOfMonth: Int?
    private let month: Int?
    private let weekday: Int?

    public init?(_ raw: String) {
        let parts = raw
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard parts.count == 5 else { return nil }

        guard let minute = Self.parse(parts[0], range: 0...59),
              let hour = Self.parse(parts[1], range: 0...23),
              let dayOfMonth = Self.parse(parts[2], range: 1...31),
              let month = Self.parse(parts[3], range: 1...12),
              let weekday = Self.parseWeekday(parts[4])
        else { return nil }

        self.minute = minute
        self.hour = hour
        self.dayOfMonth = dayOfMonth
        self.month = month
        self.weekday = weekday
    }

    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        return matches(minute, components.minute)
            && matches(hour, components.hour)
            && matches(dayOfMonth, components.day)
            && matches(month, components.month)
            && matches(weekday, components.weekday)
    }

    public func matchesSinceLastRun(
        now: Date,
        lastRunDate: Date?,
        lookbackSeconds: TimeInterval,
        calendar: Calendar = .current
    ) -> Bool {
        let nowMinute = calendar.dateInterval(of: .minute, for: now)?.start ?? now
        let lookbackStart = nowMinute.addingTimeInterval(-max(lookbackSeconds, 60))
        let earliestStart: Date
        if let lastRunDate {
            earliestStart = max(lastRunDate.addingTimeInterval(60), lookbackStart)
        } else {
            earliestStart = lookbackStart
        }

        var cursor = calendar.dateInterval(of: .minute, for: earliestStart)?.start ?? earliestStart
        while cursor <= nowMinute {
            if matches(cursor, calendar: calendar) {
                return true
            }
            guard let next = calendar.date(byAdding: .minute, value: 1, to: cursor) else {
                return false
            }
            cursor = next
        }
        return false
    }

    private func matches(_ expected: Int?, _ actual: Int?) -> Bool {
        guard let expected else { return true }
        return actual == expected
    }

    private static func parse(_ value: String, range: ClosedRange<Int>) -> Int?? {
        if value == "*" { return .some(nil) }
        guard let intValue = Int(value), range.contains(intValue) else { return nil }
        return .some(intValue)
    }

    private static func parseWeekday(_ value: String) -> Int?? {
        if value == "*" { return .some(nil) }
        guard let intValue = Int(value), (0...7).contains(intValue) else { return nil }
        return .some((intValue == 0 || intValue == 7) ? 1 : intValue + 1)
    }
}

public enum ScheduledScanLaunchAgentConfiguration {
    public static let label = "com.inceptyonlabs.gargantua.scheduler"
    public static let plistName = "\(label).plist"
    public static let bundleProgram = "Contents/MacOS/GargantuaScheduler"
    public static let checkIntervalSeconds = 900
}

public enum ScheduledScanLaunchAgentPlist {
    public static func makeDictionary(
        label: String = ScheduledScanLaunchAgentConfiguration.label,
        bundleProgram: String = ScheduledScanLaunchAgentConfiguration.bundleProgram,
        checkIntervalSeconds: Int = ScheduledScanLaunchAgentConfiguration.checkIntervalSeconds
    ) -> [String: Any] {
        [
            "Label": label,
            "BundleProgram": bundleProgram,
            "StartInterval": checkIntervalSeconds,
            "RunAtLoad": false,
            "StandardOutPath": "/tmp/gargantua-scheduler.log",
            "StandardErrorPath": "/tmp/gargantua-scheduler.log",
        ]
    }

    public static func makeData(
        label: String = ScheduledScanLaunchAgentConfiguration.label,
        bundleProgram: String = ScheduledScanLaunchAgentConfiguration.bundleProgram,
        checkIntervalSeconds: Int = ScheduledScanLaunchAgentConfiguration.checkIntervalSeconds
    ) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: makeDictionary(
                label: label,
                bundleProgram: bundleProgram,
                checkIntervalSeconds: checkIntervalSeconds
            ),
            format: .xml,
            options: 0
        )
    }
}

public enum ScheduledScanAgentStatus: Sendable, Equatable, CustomStringConvertible {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unavailable
    case unknown(Int)

    #if os(macOS)
    public init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .unknown(status.rawValue)
        }
    }
    #endif

    public var description: String {
        switch self {
        case .notRegistered: "Not registered"
        case .enabled: "Enabled"
        case .requiresApproval: "Requires approval"
        case .notFound: "LaunchAgent not found in app bundle"
        case .unavailable: "Unavailable"
        case .unknown(let rawValue): "Unknown (\(rawValue))"
        }
    }
}

public protocol ScheduledScanAgentInstalling: Sendable {
    func status() -> ScheduledScanAgentStatus
    func register() throws -> ScheduledScanAgentStatus
    func unregister() throws -> ScheduledScanAgentStatus
}

#if os(macOS)
public struct SMAppServiceScheduledScanAgentInstaller: ScheduledScanAgentInstalling, @unchecked Sendable {
    private let service: SMAppService

    public init(plistName: String = ScheduledScanLaunchAgentConfiguration.plistName) {
        self.service = SMAppService.agent(plistName: plistName)
    }

    public func status() -> ScheduledScanAgentStatus {
        ScheduledScanAgentStatus(service.status)
    }

    public func register() throws -> ScheduledScanAgentStatus {
        try service.register()
        return status()
    }

    public func unregister() throws -> ScheduledScanAgentStatus {
        try service.unregister()
        return status()
    }
}
#endif

public final class ScheduledScanController: @unchecked Sendable {
    private let installer: any ScheduledScanAgentInstalling

    public init() {
        self.installer = defaultScheduledScanInstaller()
    }

    public init(installer: any ScheduledScanAgentInstalling) {
        self.installer = installer
    }

    public func status() -> ScheduledScanAgentStatus {
        installer.status()
    }

    @discardableResult
    public func synchronize(configuration: ScheduledScanConfiguration) throws -> ScheduledScanAgentStatus {
        if configuration.isEnabled {
            let current = installer.status()
            switch current {
            case .enabled, .requiresApproval:
                return current
            case .notRegistered, .notFound, .unavailable, .unknown:
                return try installer.register()
            }
        } else {
            let current = installer.status()
            guard current != .notRegistered else { return current }
            return try installer.unregister()
        }
    }
}

private func defaultScheduledScanInstaller() -> any ScheduledScanAgentInstalling {
    #if os(macOS)
    return SMAppServiceScheduledScanAgentInstaller()
    #else
    return UnavailableScheduledScanAgentInstaller()
    #endif
}

private struct UnavailableScheduledScanAgentInstaller: ScheduledScanAgentInstalling {
    func status() -> ScheduledScanAgentStatus { .unavailable }
    func register() throws -> ScheduledScanAgentStatus { .unavailable }
    func unregister() throws -> ScheduledScanAgentStatus { .unavailable }
}

public struct ScheduledScanSummary: Equatable, Sendable, Identifiable {
    public let id: String
    public let date: Date
    public let profileID: String
    public let itemCount: Int
    public let reclaimableBytes: Int64
    public let errorMessage: String?

    public init(
        date: Date,
        profileID: String,
        itemCount: Int,
        reclaimableBytes: Int64,
        errorMessage: String? = nil
    ) {
        self.id = "scheduled-scan-\(Int(date.timeIntervalSince1970))"
        self.date = date
        self.profileID = profileID
        self.itemCount = itemCount
        self.reclaimableBytes = reclaimableBytes
        self.errorMessage = errorMessage
    }

    public var headline: String {
        if let errorMessage, !errorMessage.isEmpty {
            return "Scheduled scan needs attention"
        }
        return "\(AlertItem.formatBytes(reclaimableBytes)) found by scheduled scan"
    }

    public var detail: String {
        if let errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        let count = itemCount == 1 ? "1 item" : "\(itemCount) items"
        return "\(count) using \(profileID) profile"
    }
}

public protocol ScheduledScanScanning: Sendable {
    func scan(profile: CleanupProfile, scanRoots: [URL]?) async throws -> [ScanResult]
}

public struct NativeScheduledScanScanner: ScheduledScanScanning {
    public init() {}

    public func scan(profile: CleanupProfile, scanRoots: [URL]?) async throws -> [ScanResult] {
        let adapter = try NativeScanAdapter.loadDefaults(profile: profile, scanRoots: scanRoots)
        return try await adapter.scan(progress: nil)
    }
}

public protocol ScheduledScanPowerStateProviding: Sendable {
    func isOnBatteryPower() -> Bool
}

public struct SystemScheduledScanPowerStateProvider: ScheduledScanPowerStateProviding {
    public init() {}

    public func isOnBatteryPower() -> Bool {
        #if os(macOS)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                let state = description[kIOPSPowerSourceStateKey] as? String
            else { continue }

            if state == kIOPSBatteryPowerValue {
                return true
            }
        }
        #endif
        return false
    }
}

public protocol ScheduledScanNotificationDelivering: Sendable {
    func deliver(summary: ScheduledScanSummary) async
}

public struct NoopScheduledScanNotifier: ScheduledScanNotificationDelivering {
    public init() {}
    public func deliver(summary: ScheduledScanSummary) async {}
}

#if os(macOS)
public struct UserNotificationScheduledScanNotifier: ScheduledScanNotificationDelivering {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func deliver(summary: ScheduledScanSummary) async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "Gargantua scheduled scan complete"
            content.body = summary.detail
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: summary.id,
                content: content,
                trigger: nil
            )
            try await center.add(request)
        } catch {
            return
        }
    }
}
#endif

public enum ScheduledScanRunResult: Equatable, Sendable {
    case disabled
    case notDue
    case skippedOnBattery
    case completed(ScheduledScanSummary)
    case failed(ScheduledScanSummary)
}

@MainActor
public final class ScheduledScanRunner {
    private let persistence: PersistenceController
    private let scanner: any ScheduledScanScanning
    private let notifier: any ScheduledScanNotificationDelivering
    private let powerStateProvider: any ScheduledScanPowerStateProviding
    private let now: () -> Date

    public convenience init(persistence: PersistenceController) {
        self.init(
            persistence: persistence,
            scanner: NativeScheduledScanScanner(),
            notifier: defaultScheduledScanNotifier(),
            powerStateProvider: SystemScheduledScanPowerStateProvider(),
            now: Date.init
        )
    }

    public init(
        persistence: PersistenceController,
        scanner: any ScheduledScanScanning,
        notifier: any ScheduledScanNotificationDelivering,
        powerStateProvider: any ScheduledScanPowerStateProviding,
        now: @escaping () -> Date
    ) {
        self.persistence = persistence
        self.scanner = scanner
        self.notifier = notifier
        self.powerStateProvider = powerStateProvider
        self.now = now
    }

    public func runIfDue() async -> ScheduledScanRunResult {
        do {
            try persistence.bootstrap()
            let settings = try persistence.fetchSettings()
            let configuration = ScheduledScanConfiguration(settings: settings)
            let runDate = now()

            guard configuration.isEnabled else { return .disabled }
            guard configuration.isDue(now: runDate) else { return .notDue }

            if configuration.skipWhenOnBattery, powerStateProvider.isOnBatteryPower() {
                return .skippedOnBattery
            }

            let profiles = try persistence.fetchProfiles()
            let profile = CleanupProfile.resolve(
                activeProfileID: configuration.profileID,
                persisted: profiles,
                fallback: .light
            )
            let roots = ScanRootSettings.resolvedURLs(from: settings.scanRoots)
            let results = try await scanner.scan(
                profile: profile,
                scanRoots: roots.isEmpty ? nil : roots
            )
            let actionable = results.filter(\.safety.isActionable)
            let reclaimableBytes = actionable.reduce(Int64(0)) { $0 + $1.size }
            let summary = ScheduledScanSummary(
                date: runDate,
                profileID: profile.id,
                itemCount: actionable.count,
                reclaimableBytes: reclaimableBytes
            )
            try persistence.recordScheduledScanSummary(summary)
            await notifier.deliver(summary: summary)
            return .completed(summary)
        } catch {
            let runDate = now()
            let summary = ScheduledScanSummary(
                date: runDate,
                profileID: "unknown",
                itemCount: 0,
                reclaimableBytes: 0,
                errorMessage: error.localizedDescription
            )
            try? persistence.recordScheduledScanSummary(summary)
            await notifier.deliver(summary: summary)
            return .failed(summary)
        }
    }
}

private func defaultScheduledScanNotifier() -> any ScheduledScanNotificationDelivering {
    #if os(macOS)
    return UserNotificationScheduledScanNotifier()
    #else
    return NoopScheduledScanNotifier()
    #endif
}
