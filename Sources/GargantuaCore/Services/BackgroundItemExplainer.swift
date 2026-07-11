import Foundation

/// Generates the one-line deterministic explanation for a `BackgroundItem`.
///
/// Composition:
///   `<source kind> · signed by <vendor> · ships with <bundle> · <trigger> · <impact>`
///
/// Pieces are dropped when their input is unavailable so the line never reads
/// "signed by Unknown" or "triggered by nothing." AI fallback runs on top of
/// this string for unsigned/unknown binaries.
public struct BackgroundItemExplainer: Sendable {

    public init() {}

    public func explain(
        source: BackgroundItemSource,
        plist: LaunchdPlist?,
        identity: BinaryIdentity?,
        executableExists: Bool,
        reasons: Set<BackgroundItemReason> = []
    ) -> String {
        var parts: [String] = []

        parts.append(sourcePart(source))

        if let signer = signerPart(identity: identity) {
            parts.append(signer)
        }

        if let bundle = bundlePart(identity: identity, executablePath: plist?.executablePath) {
            parts.append(bundle)
        }

        if !executableExists, plist?.executablePath != nil || identity?.bundlePath != nil {
            parts.append("target binary missing")
        }

        if let trigger = triggerPart(plist: plist, source: source) {
            parts.append(trigger)
        }

        if let impact = impactPart(identity: identity, plist: plist, reasons: reasons) {
            parts.append(impact)
        }

        return parts.joined(separator: " · ")
    }

    // MARK: - Pieces

    private func sourcePart(_ source: BackgroundItemSource) -> String {
        switch source {
        case .userLaunchAgent: "User LaunchAgent"
        case .systemLaunchAgent: "System LaunchAgent"
        case .launchDaemon: "LaunchDaemon (root)"
        case .startupItem: "StartupItem (legacy)"
        case .loginItem: "Login Item"
        }
    }

    private func signerPart(identity: BinaryIdentity?) -> String? {
        guard let identity else { return nil }
        switch identity.vendor {
        case .apple:
            return "signed by Apple"
        case .thirdPartyKnown:
            if let display = identity.vendorDisplayName, !display.isEmpty {
                return "signed by \(display)"
            }
            if let team = identity.teamIdentifier, !team.isEmpty {
                return "signed by team \(team)"
            }
            return "signed (Developer ID)"
        case .thirdPartyUnknown:
            if let team = identity.teamIdentifier, !team.isEmpty {
                return "signed by unknown team \(team)"
            }
            return "signed by unknown developer"
        case .unsigned:
            return "unsigned"
        }
    }

    private func bundlePart(identity: BinaryIdentity?, executablePath: String?) -> String? {
        if let identity, let bundleName = identity.bundleName, !bundleName.isEmpty {
            return "ships with \(bundleName)"
        }
        if let executablePath {
            let exe = (executablePath as NSString).lastPathComponent
            if !exe.isEmpty {
                return "runs \(exe)"
            }
        }
        return nil
    }

    private func triggerPart(plist: LaunchdPlist?, source: BackgroundItemSource) -> String? {
        guard let plist else { return nil }

        var triggers: [String] = []

        if plist.runAtLoad {
            triggers.append(runAtLoadPhrase(for: source))
        }
        if plist.keepAlive {
            triggers.append("restarts whenever it exits")
        }
        if let interval = plist.startInterval {
            triggers.append("every \(formatInterval(interval))")
        }
        if let calendar = Self.calendarPart(plist.startCalendarInterval) {
            triggers.append(calendar)
        }
        if !plist.watchPaths.isEmpty {
            triggers.append("runs when watched paths change")
        }
        if !plist.queueDirectories.isEmpty {
            triggers.append("on queue")
        }
        if listensForOtherProcesses(plist) {
            triggers.append("started on demand by other processes")
        }

        if triggers.isEmpty { return nil }
        return triggers.joined(separator: ", ")
    }

    private func runAtLoadPhrase(for source: BackgroundItemSource) -> String {
        switch source {
        case .userLaunchAgent, .systemLaunchAgent:
            return "starts at login"
        case .launchDaemon:
            return "starts at boot"
        case .startupItem, .loginItem:
            return "runs at load"
        }
    }

    private func formatInterval(_ seconds: Int) -> String {
        if seconds % 86400 == 0 {
            let d = seconds / 86400
            return "\(d) day\(d == 1 ? "" : "s")"
        }
        if seconds % 3600 == 0 {
            let h = seconds / 3600
            return "\(h) hour\(h == 1 ? "" : "s")"
        }
        if seconds % 60 == 0 {
            let m = seconds / 60
            return "\(m) min"
        }
        return "\(seconds)s"
    }

    // MARK: - Calendar formatting

    /// "daily at 02:00" / "weekly on Monday at 12:15" / "monthly on day 1 at 12:15" /
    /// "hourly at :30" / fallback "on schedule". Multiple intervals: first + " (+N more)".
    static func calendarPart(_ intervals: [LaunchdCalendarInterval]) -> String? {
        guard let raw = intervals.first else { return nil }
        // Clamp to launchd's valid ranges before narrating — a corrupt or
        // hand-edited plist must degrade to the vague-but-true "on schedule",
        // never to garbage like "daily at 25:00" on a trust surface.
        let first = validated(raw)
        let text = calendarBase(first) + calendarTimeSuffix(first)
        return appendIntervalCount(text, count: intervals.count)
    }

    /// Drops out-of-range fields (hour 0–23, minute 0–59, weekday 0–7,
    /// day 1–31) so narration falls back a level instead of printing garbage.
    private static func validated(_ interval: LaunchdCalendarInterval) -> LaunchdCalendarInterval {
        LaunchdCalendarInterval(
            minute: interval.minute.flatMap { (0 ... 59).contains($0) ? $0 : nil },
            hour: interval.hour.flatMap { (0 ... 23).contains($0) ? $0 : nil },
            day: interval.day.flatMap { (1 ... 31).contains($0) ? $0 : nil },
            weekday: interval.weekday.flatMap { (0 ... 7).contains($0) ? $0 : nil },
            month: interval.month
        )
    }

    private static func calendarBase(_ interval: LaunchdCalendarInterval) -> String {
        if let weekday = interval.weekday {
            return "weekly on \(weekdayName(weekday))"
        }
        if let day = interval.day {
            return "monthly on day \(day)"
        }
        if interval.hour != nil {
            return "daily"
        }
        if interval.minute != nil {
            return "hourly"
        }
        return "on schedule"
    }

    private static func calendarTimeSuffix(_ interval: LaunchdCalendarInterval) -> String {
        switch (interval.hour, interval.minute) {
        case let (.some(hour), .some(minute)):
            return String(format: " at %02d:%02d", hour, minute)
        case let (.some(hour), .none):
            return String(format: " at %02d:00", hour)
        case let (.none, .some(minute)):
            return String(format: " at :%02d", minute)
        case (.none, .none):
            return ""
        }
    }

    private static func weekdayName(_ weekday: Int) -> String {
        switch weekday {
        case 0, 7: return "Sunday"
        case 1: return "Monday"
        case 2: return "Tuesday"
        case 3: return "Wednesday"
        case 4: return "Thursday"
        case 5: return "Friday"
        case 6: return "Saturday"
        default: return "weekday \(weekday)"
        }
    }

    private static func appendIntervalCount(_ text: String, count: Int) -> String {
        guard count > 1 else { return text }
        return "\(text) (+\(count - 1) more)"
    }

    // MARK: - Impact

    /// What likely breaks if the user disables this item — first matching
    /// signal only, so the line stays one calm sentence fragment.
    private func impactPart(
        identity: BinaryIdentity?,
        plist: LaunchdPlist?,
        reasons: Set<BackgroundItemReason>
    ) -> String? {
        if let category = identity?.sensitiveCategories.min(by: { $0.rawValue < $1.rawValue }) {
            return impactPhrase(for: category)
        }
        if listensForOtherProcesses(plist) {
            return "other apps may fail to reach it if disabled"
        }
        if reasons.contains(.parentAppMissing) {
            return "its app is gone — disabling should be safe"
        }
        if reasons.contains(.parentAppLikelyMissing) {
            return "its app appears uninstalled"
        }
        if reasons.contains(where: { $0.isSuspicious }) {
            return "review before trusting"
        }
        return nil
    }

    private func impactPhrase(for category: SensitiveVendorCategory) -> String {
        switch category {
        case .vpn: return "disabling may break VPN connectivity"
        case .passwordManager: return "disabling may break password autofill"
        case .mdm: return "part of device management — your org may require it"
        case .accessibility: return "disabling may break accessibility features"
        case .backup: return "disabling stops scheduled backups"
        case .security: return "disabling reduces security protection"
        }
    }

    private func listensForOtherProcesses(_ plist: LaunchdPlist?) -> Bool {
        guard let plist else { return false }
        return !plist.machServices.isEmpty || !plist.sockets.isEmpty
    }
}
