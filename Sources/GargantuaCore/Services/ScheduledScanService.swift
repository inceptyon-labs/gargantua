import Foundation
#if os(macOS)
    import IOKit.ps
    @preconcurrency import ServiceManagement
    @preconcurrency import UserNotifications
#endif

/// Built-in cadence choices for automatic scheduled scans.
public enum ScheduledScanInterval: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Runs roughly once per day.
    case daily
    /// Runs roughly once per week.
    case weekly
    /// Runs according to a five-field cron-like expression.
    case custom

    /// Stable identifier used by SwiftUI lists and pickers.
    public var id: String { rawValue }

    /// Short user-facing interval name.
    public var label: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .custom: "Custom"
        }
    }

    /// User-facing description of the interval behavior.
    public var detail: String {
        switch self {
        case .daily: "Runs once every 24 hours."
        case .weekly: "Runs once every 7 days."
        case .custom: "Uses a five-field cron-like schedule."
        }
    }
}

/// Persistable settings that control the scheduled scan runner and launch agent.
public struct ScheduledScanConfiguration: Equatable, Sendable {
    /// Whether scheduled scans are enabled.
    public var isEnabled: Bool
    /// Interval used when determining whether a scan is due.
    public var interval: ScheduledScanInterval
    /// Five-field cron-like expression used for custom schedules.
    public var customSchedule: String
    /// Cleanup profile identifier used for scheduled scans.
    public var profileID: String
    /// Whether scheduled scans should be skipped while on battery power.
    public var skipWhenOnBattery: Bool
    /// Timestamp of the most recent scheduled scan.
    public var lastRunDate: Date?

    /// Creates a scheduled scan configuration.
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

    /// Builds a scheduled scan configuration from persisted application settings.
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

    /// Custom schedule trimmed for validation and parsing.
    public var normalizedCustomSchedule: String {
        customSchedule.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the selected interval has a valid schedule expression.
    public var isCustomScheduleValid: Bool {
        interval != .custom || ScheduledScanCronExpression(normalizedCustomSchedule) != nil
    }

    /// Whether the launch agent can be synchronized for the current settings.
    public var canSynchronizeLaunchAgent: Bool {
        !isEnabled || isCustomScheduleValid
    }

    /// Returns whether a scan should run at the supplied time.
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

/// Minimal five-field cron-like expression used by scheduled scans.
public struct ScheduledScanCronExpression: Equatable, Sendable {
    private let minute: Int?
    private let hour: Int?
    private let dayOfMonth: Int?
    private let month: Int?
    private let weekday: Int?

    /// Parses a five-field expression containing integers or `*` wildcards.
    public init?(_ raw: String) {
        let parts = raw
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard parts.count == 5 else { return nil }

        guard let minute = Self.parse(parts[0], range: 0 ... 59),
              let hour = Self.parse(parts[1], range: 0 ... 23),
              let dayOfMonth = Self.parse(parts[2], range: 1 ... 31),
              let month = Self.parse(parts[3], range: 1 ... 12),
              let weekday = Self.parseWeekday(parts[4])
        else { return nil }

        self.minute = minute
        self.hour = hour
        self.dayOfMonth = dayOfMonth
        self.month = month
        self.weekday = weekday
    }

    /// Returns whether the expression matches the given date components.
    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        return matches(minute, components.minute)
            && matches(hour, components.hour)
            && matches(dayOfMonth, components.day)
            && matches(month, components.month)
            && matches(weekday, components.weekday)
    }

    /// Returns whether a matching scheduled minute occurred since the previous run.
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
        guard let intValue = Int(value), (0 ... 7).contains(intValue) else { return nil }
        return .some((intValue == 0 || intValue == 7) ? 1 : intValue + 1)
    }
}

/// Static launch-agent identifiers and timing constants for scheduled scans.
public enum ScheduledScanLaunchAgentConfiguration {
    /// Bundle service label for the scheduler launch agent.
    public static let label = "com.inceptyonlabs.gargantua.scheduler"
    /// Launch-agent plist file name embedded in the app bundle.
    public static let plistName = "\(label).plist"
    /// Relative app-bundle executable path for the scheduler.
    public static let bundleProgram = "Contents/MacOS/GargantuaScheduler"
    /// Polling interval used by the scheduler launch agent.
    public static let checkIntervalSeconds = 900
}

/// Factory for the property-list payload used by the scheduler launch agent.
public enum ScheduledScanLaunchAgentPlist {
    /// Builds the launch-agent dictionary before serialization.
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

    /// Serializes the scheduler launch-agent property list as XML data.
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

/// Normalized status values for the scheduled scan launch agent.
public enum ScheduledScanAgentStatus: Sendable, Equatable, CustomStringConvertible {
    /// The launch agent is not registered with ServiceManagement.
    case notRegistered
    /// The launch agent is registered and enabled.
    case enabled
    /// macOS requires user approval before enabling the agent.
    case requiresApproval
    /// The launch-agent plist could not be found.
    case notFound
    /// The platform does not support this launch-agent API.
    case unavailable
    /// An unknown ServiceManagement status value.
    case unknown(Int)

    #if os(macOS)
        /// Converts an `SMAppService.Status` into the app's normalized status.
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

    /// User-facing status description.
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

/// ServiceManagement operations required by the scheduled scan controller.
public protocol ScheduledScanAgentInstalling: Sendable {
    /// Returns the current launch-agent status.
    func status() -> ScheduledScanAgentStatus
    /// Registers the launch agent and returns the resulting status.
    func register() throws -> ScheduledScanAgentStatus
    /// Unregisters the launch agent and returns the resulting status.
    func unregister() throws -> ScheduledScanAgentStatus
}

#if os(macOS)
    /// `SMAppService`-backed installer for the scheduled scan launch agent.
    public struct SMAppServiceScheduledScanAgentInstaller: ScheduledScanAgentInstalling, @unchecked Sendable {
        private let service: SMAppService

        /// Creates an installer for the named launch-agent plist.
        public init(plistName: String = ScheduledScanLaunchAgentConfiguration.plistName) {
            self.service = SMAppService.agent(plistName: plistName)
        }

        /// Returns the current normalized launch-agent status.
        public func status() -> ScheduledScanAgentStatus {
            ScheduledScanAgentStatus(service.status)
        }

        /// Registers the launch agent and returns the resulting status.
        public func register() throws -> ScheduledScanAgentStatus {
            try service.register()
            return status()
        }

        /// Unregisters the launch agent and returns the resulting status.
        public func unregister() throws -> ScheduledScanAgentStatus {
            try service.unregister()
            return status()
        }
    }
#endif

/// Coordinates scheduler launch-agent registration with user configuration.
public final class ScheduledScanController: @unchecked Sendable {
    private let installer: any ScheduledScanAgentInstalling

    /// Creates a controller using the platform default launch-agent installer.
    public init() {
        self.installer = defaultScheduledScanInstaller()
    }

    /// Creates a controller with an injected installer for testing or alternate backends.
    public init(installer: any ScheduledScanAgentInstalling) {
        self.installer = installer
    }

    /// Returns the current scheduler launch-agent status.
    public func status() -> ScheduledScanAgentStatus {
        installer.status()
    }

    @discardableResult
    /// Registers or unregisters the launch agent to match the supplied configuration.
    public func synchronize(configuration: ScheduledScanConfiguration) throws -> ScheduledScanAgentStatus {
        let current = installer.status()
        if configuration.isEnabled {
            switch current {
            case .enabled, .requiresApproval:
                return current
            case .notFound, .unavailable:
                // Plist missing from bundle (unsigned dev build) or platform unsupported.
                // Surface status without throwing a confusing -67028 codesign error.
                return current
            case .notRegistered, .unknown:
                return try installer.register()
            }
        } else {
            switch current {
            case .notRegistered, .notFound, .unavailable:
                return current
            case .enabled, .requiresApproval, .unknown:
                return try installer.unregister()
            }
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

/// Summary of one scheduled scan result, including errors.
public struct ScheduledScanSummary: Equatable, Sendable, Identifiable {
    /// Stable identifier derived from the scan timestamp.
    public let id: String
    /// Date when the scheduled scan ran.
    public let date: Date
    /// Cleanup profile used for the scheduled scan.
    public let profileID: String
    /// Number of actionable items found.
    public let itemCount: Int
    /// Total reclaimable bytes found.
    public let reclaimableBytes: Int64
    /// Error message captured for failed scheduled scans.
    public let errorMessage: String?

    /// Creates a scheduled scan summary.
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

    /// Short notification headline for the scan outcome.
    public var headline: String {
        if let errorMessage, !errorMessage.isEmpty {
            return "Scheduled scan needs attention"
        }
        return "\(AlertItem.formatBytes(reclaimableBytes)) found by scheduled scan"
    }

    /// Detail text shown in notifications and recent-scan UI.
    public var detail: String {
        if let errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        let count = itemCount == 1 ? "1 item" : "\(itemCount) items"
        return "\(count) using \(profileID) profile"
    }
}

/// Scanner abstraction used by scheduled scans.
public protocol ScheduledScanScanning: Sendable {
    /// Runs a scan for the supplied profile and optional root URLs.
    func scan(profile: CleanupProfile, scanRoots: [URL]?) async throws -> [ScanResult]
}

/// Scheduled scan backend that delegates to `NativeScanAdapter`.
public struct NativeScheduledScanScanner: ScheduledScanScanning {
    /// Creates a native scheduled scan backend.
    public init() {}

    /// Runs a scan for the supplied profile and optional root URLs.
    public func scan(profile: CleanupProfile, scanRoots: [URL]?) async throws -> [ScanResult] {
        let adapter = try NativeScanAdapter.loadDefaults(profile: profile, scanRoots: scanRoots)
        return try await adapter.scan(progress: nil)
    }
}

/// Supplies whether the system is currently using battery power.
public protocol ScheduledScanPowerStateProviding: Sendable {
    /// Returns whether the system is currently running on battery power.
    func isOnBatteryPower() -> Bool
}

/// Power-state provider backed by macOS IOKit power source APIs.
public struct SystemScheduledScanPowerStateProvider: ScheduledScanPowerStateProviding {
    /// Creates the default system power-state provider.
    public init() {}

    /// Returns whether any active power source reports battery power.
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

/// Delivers user-visible notifications for scheduled scan results.
public protocol ScheduledScanNotificationDelivering: Sendable {
    /// Posts a user-visible notification for the supplied scheduled scan summary.
    func deliver(summary: ScheduledScanSummary) async
}

/// Notification backend that intentionally drops scheduled scan summaries.
public struct NoopScheduledScanNotifier: ScheduledScanNotificationDelivering {
    /// Creates a no-op notifier.
    public init() {}
    /// Ignores the supplied scheduled scan summary.
    public func deliver(summary: ScheduledScanSummary) async {}
}

#if os(macOS)
    /// User notification backend for scheduled scan results.
    public struct UserNotificationScheduledScanNotifier: ScheduledScanNotificationDelivering {
        private let center: UNUserNotificationCenter

        /// Creates a notifier using the supplied notification center.
        public init(center: UNUserNotificationCenter = .current()) {
            self.center = center
        }

        /// Requests notification permission and posts the scheduled scan summary.
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

/// Outcome of a scheduled scan runner invocation.
public enum ScheduledScanRunResult: Equatable, Sendable {
    /// Scheduled scans are disabled in settings.
    case disabled
    /// The configured schedule is not due yet.
    case notDue
    /// The scan was skipped because the device is on battery power.
    case skippedOnBattery
    /// The scan completed with a summary.
    case completed(ScheduledScanSummary)
    /// The scan failed and persisted an error summary.
    case failed(ScheduledScanSummary)
}

@MainActor
/// Runs scheduled scans, records summaries, and dispatches notifications.
public final class ScheduledScanRunner {
    private let persistence: PersistenceController
    private let scanner: any ScheduledScanScanning
    private let notifier: any ScheduledScanNotificationDelivering
    private let powerStateProvider: any ScheduledScanPowerStateProviding
    private let agentAuditHook: any ScheduledScanAgentAuditHook
    private let now: () -> Date

    /// Creates a runner with production scanner, notifier, power, and audit dependencies.
    public convenience init(persistence: PersistenceController) {
        self.init(
            persistence: persistence,
            scanner: NativeScheduledScanScanner(),
            notifier: defaultScheduledScanNotifier(),
            powerStateProvider: SystemScheduledScanPowerStateProvider(),
            agentAuditHook: ClaudeCodeScheduledAgentAuditHook(),
            now: Date.init
        )
    }

    /// Creates a runner with injected dependencies for tests or alternate schedulers.
    public init(
        persistence: PersistenceController,
        scanner: any ScheduledScanScanning,
        notifier: any ScheduledScanNotificationDelivering,
        powerStateProvider: any ScheduledScanPowerStateProviding,
        agentAuditHook: any ScheduledScanAgentAuditHook = NoopScheduledScanAgentAuditHook(),
        now: @escaping () -> Date
    ) {
        self.persistence = persistence
        self.scanner = scanner
        self.notifier = notifier
        self.powerStateProvider = powerStateProvider
        self.agentAuditHook = agentAuditHook
        self.now = now
    }

    /// Runs a scheduled scan when enabled, due, and permitted by power settings.
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
            await agentAuditHook.run(summary: summary)
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
            do {
                try persistence.recordScheduledScanSummary(summary)
            } catch {
                PersistenceDiagnostics.logFailure("recordScheduledScanSummary", error: error)
            }
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
