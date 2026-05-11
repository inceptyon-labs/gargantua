import Foundation
#if os(macOS)
    @preconcurrency import ServiceManagement
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
