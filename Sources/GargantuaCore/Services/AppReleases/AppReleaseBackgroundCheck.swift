import Foundation
#if os(macOS)
    @preconcurrency import UserNotifications
#endif

/// What the background check last saw. Kept under its own defaults key so the
/// scheduler agent and the app never overwrite each other's data.
public struct AppReleaseBackgroundState: Codable, Sendable, Equatable {
    public static let userDefaultsKey = "appReleases.backgroundCheck"
    /// Updates available after ignore/skip, from the latest check by either
    /// process. Its own key so the app never rewrites the scheduler's state blob.
    public static let availableCountKey = "appReleases.availableUpdateCount"

    public var lastCheck: Date?
    /// Bundle ID to the highest version already announced for that app.
    public var announcedVersions: [String: AppReleaseVersion]

    /// Mostly-failed runs retried back to back; capped so a few permanently
    /// broken sources can't block the healthy ones forever.
    public var consecutiveFailedRuns: Int

    public init(
        lastCheck: Date? = nil,
        announcedVersions: [String: AppReleaseVersion] = [:],
        consecutiveFailedRuns: Int = 0
    ) {
        self.lastCheck = lastCheck
        self.announcedVersions = announcedVersions
        self.consecutiveFailedRuns = consecutiveFailedRuns
    }

    private struct StoredVersion: Codable {
        let short: String?
        let build: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastCheck = try container.decodeIfPresent(Date.self, forKey: .lastCheck)
        let stored = try container.decodeIfPresent([String: StoredVersion].self, forKey: .announcedVersions) ?? [:]
        announcedVersions = stored.mapValues { AppReleaseVersion(short: $0.short, build: $0.build) }
        consecutiveFailedRuns = try container.decodeIfPresent(Int.self, forKey: .consecutiveFailedRuns) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(lastCheck, forKey: .lastCheck)
        try container.encode(
            announcedVersions.mapValues { StoredVersion(short: $0.short, build: $0.build) },
            forKey: .announcedVersions
        )
        try container.encode(consecutiveFailedRuns, forKey: .consecutiveFailedRuns)
    }

    private enum CodingKeys: String, CodingKey {
        case lastCheck, announcedVersions, consecutiveFailedRuns
    }

    public static func stored(in defaults: UserDefaults = .standard) -> AppReleaseBackgroundState {
        guard let data = defaults.data(forKey: userDefaultsKey),
              let state = try? JSONDecoder().decode(AppReleaseBackgroundState.self, from: data)
        else {
            return AppReleaseBackgroundState()
        }
        return state
    }

    public func store(in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.userDefaultsKey)
    }

    public static func storedAvailableCount(in defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: availableCountKey)
    }

    public static func storeAvailableCount(_ count: Int, in defaults: UserDefaults = .standard) {
        defaults.set(count, forKey: availableCountKey)
    }
}

public protocol AppReleaseUpdateNotifying: Sendable {
    /// True when the notification was handed to the system; false when it
    /// couldn't be (permission not granted, add failed).
    func deliver(count: Int, appNames: [String]) async -> Bool
}

#if os(macOS)
    /// User notification backend for new app updates. A fixed identifier makes
    /// a newer notification replace the older one.
    public struct UserNotificationAppReleaseUpdateNotifier: AppReleaseUpdateNotifying {
        public static let identifier = "app-updates-available"

        private let center: UNUserNotificationCenter

        public init(center: UNUserNotificationCenter = .current()) {
            self.center = center
        }

        public static func content(count: Int, appNames: [String]) -> (title: String, body: String) {
            let title = count == 1 ? "1 app update available" : "\(count) app updates available"
            var body = appNames.prefix(3).joined(separator: ", ")
            if appNames.count > 3 { body += " and \(appNames.count - 3) more" }
            return (title, body)
        }

        public func deliver(count: Int, appNames: [String]) async -> Bool {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else { return false }

                let text = Self.content(count: count, appNames: appNames)
                let content = UNMutableNotificationContent()
                content.title = text.title
                content.body = text.body
                content.sound = .default

                let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
                try await center.add(request)
                return true
            } catch {
                return false
            }
        }
    }
#endif

public enum AppReleaseBackgroundCheckResult: Sendable, Equatable {
    case disabled
    case notDue
    /// Most queried sources failed (offline, rate limited); nothing was stored or announced.
    case failed
    case checked(availableCount: Int, notified: Bool)
}

/// The scheduler agent's daily update check: opt-in, at most once per
/// `interval`, and it notifies only about updates it hasn't announced before.
public struct AppReleaseBackgroundCheck: Sendable {
    /// A suite name, not `UserDefaults`, which isn't `Sendable`. Nil is `.standard`.
    private let suiteName: String?
    private let inventory: any AppReleaseInventoryProviding
    private let checker: any AppReleaseChecking
    private let notifier: any AppReleaseUpdateNotifying
    private let interval: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        suiteName: String?,
        inventory: any AppReleaseInventoryProviding,
        checker: any AppReleaseChecking,
        notifier: any AppReleaseUpdateNotifying,
        interval: TimeInterval = 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.suiteName = suiteName
        self.inventory = inventory
        self.checker = checker
        self.notifier = notifier
        self.interval = interval
        self.now = now
    }

    public func runIfDue() async -> AppReleaseBackgroundCheckResult {
        let defaults: UserDefaults
        if let suiteName {
            guard let suite = UserDefaults(suiteName: suiteName) else { return .disabled }
            defaults = suite
        } else {
            defaults = .standard
        }
        let preferences = AppReleasePreferences.stored(in: defaults)
        guard preferences.backgroundCheckEnabled else { return .disabled }

        let state = AppReleaseBackgroundState.stored(in: defaults)
        if let lastCheck = state.lastCheck, now().timeIntervalSince(lastCheck) < interval { return .notDue }

        let apps = await inventory.installedApps()
        // The user can turn the check off while a run is in flight; re-read
        // before contacting any source and again before announcing.
        guard AppReleasePreferences.stored(in: defaults).backgroundCheckEnabled else { return .disabled }
        let rows = await checker.check(apps, preferences: preferences)
        guard AppReleasePreferences.stored(in: defaults).backgroundCheckEnabled else { return .disabled }
        if Self.mostQueriedFailed(rows), state.consecutiveFailedRuns < Self.maxFailedRetries {
            var retry = state
            retry.consecutiveFailedRuns += 1
            retry.store(in: defaults)
            return .failed
        }

        let available = rows.compactMap { row in row.availableCandidate.map { (app: row.app, version: $0.version) } }
        var announced = state.announcedVersions.filter { Set(apps.map(\.bundleID)).contains($0.key) }
        let hasNew = available.contains { entry in
            guard let prior = announced[entry.app.bundleID] else { return true }
            return entry.version.isNewer(than: prior)
        }
        var delivered = false
        if hasNew {
            delivered = await notifier.deliver(count: available.count, appNames: available.map(\.app.name).sorted())
        }
        // An undelivered notification leaves its updates unannounced so a later
        // run (e.g. once permission is granted) announces them.
        if delivered || !hasNew { Self.raise(&announced, to: available) }
        Self.enrich(&announced, from: available)
        AppReleaseBackgroundState(lastCheck: now(), announcedVersions: announced).store(in: defaults)
        AppReleaseBackgroundState.storeAvailableCount(available.count, in: defaults)
        return .checked(availableCount: available.count, notified: delivered)
    }

    private static let maxFailedRetries = 3

    /// A release first announced without a build (e.g. from Homebrew) takes the
    /// build once a source reports one, so a later build of it isn't tied
    /// against the missing one. Never changes what counts as new.
    private static func enrich(
        _ announced: inout [String: AppReleaseVersion],
        from available: [(app: InstalledApp, version: AppReleaseVersion)]
    ) {
        for entry in available {
            let id = entry.app.bundleID
            guard let prior = announced[id], prior.build == nil, entry.version.build != nil,
                  prior.short == entry.version.short
            else { continue }
            announced[id] = entry.version
        }
    }

    private static func raise(
        _ announced: inout [String: AppReleaseVersion],
        to available: [(app: InstalledApp, version: AppReleaseVersion)]
    ) {
        for entry in available {
            let id = entry.app.bundleID
            if let prior = announced[id], !entry.version.isNewer(than: prior) { continue }
            announced[id] = entry.version
        }
    }

    /// Rows the user opted out of or no source knows say nothing about the
    /// network. When most of the rest failed (e.g. waking before Wi-Fi), the
    /// run is retried on the agent's next wake instead of a day later.
    private static func mostQueriedFailed(_ rows: [AppReleaseRow]) -> Bool {
        let queried = rows.filter { row in
            switch row.status {
            case .ignored, .untracked, .skippedVersion: false
            default: true
            }
        }
        let failed = queried.filter { if case .failed = $0.status { true } else { false } }.count
        return !queried.isEmpty && failed * 2 > queried.count
    }

    /// The containing app's bundle ID, which is its defaults suite, for the
    /// scheduler agent whose own bundle ID differs. Nil outside an `.app`
    /// bundle (e.g. `swift run`).
    public static func containingAppSuiteName(executable: URL? = Bundle.main.executableURL) -> String? {
        var url = executable?.resolvingSymlinksInPath()
        while let current = url, current.path != "/" {
            if current.pathExtension == "app" {
                // Not `Bundle(url:)`: for the scheduler inside the app it returns
                // the scheduler's own bundle (its embedded Info.plist wins).
                let plistURL = current.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: plistURL),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let identifier = plist["CFBundleIdentifier"] as? String,
                      identifier != Bundle.main.bundleIdentifier
                else { return nil }
                return identifier
            }
            url = current.deletingLastPathComponent()
        }
        return nil
    }
}
