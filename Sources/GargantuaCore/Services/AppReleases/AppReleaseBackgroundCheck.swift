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
    /// "<bundleID>@<displayVersion>" for updates already announced.
    public var notifiedUpdateKeys: Set<String>

    public init(lastCheck: Date? = nil, notifiedUpdateKeys: Set<String> = []) {
        self.lastCheck = lastCheck
        self.notifiedUpdateKeys = notifiedUpdateKeys
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastCheck = try container.decodeIfPresent(Date.self, forKey: .lastCheck)
        notifiedUpdateKeys = try container.decodeIfPresent(Set<String>.self, forKey: .notifiedUpdateKeys) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case lastCheck, notifiedUpdateKeys
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
    func deliver(count: Int, appNames: [String]) async
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

        public func deliver(count: Int, appNames: [String]) async {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else { return }

                let text = Self.content(count: count, appNames: appNames)
                let content = UNMutableNotificationContent()
                content.title = text.title
                content.body = text.body
                content.sound = .default

                let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
                try await center.add(request)
            } catch {
                return
            }
        }
    }
#endif

public enum AppReleaseBackgroundCheckResult: Sendable, Equatable {
    case disabled
    case notDue
    /// Every source failed (offline, rate limited); nothing was stored or announced.
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
        let rows = await checker.check(apps, preferences: preferences)
        let failedIDs = Set(rows.compactMap { row -> String? in
            if case .failed = row.status { return row.app.bundleID }
            return nil
        })
        if !rows.isEmpty, failedIDs.count == rows.count { return .failed }

        let available = rows.compactMap { row in row.availableCandidate.map { (row.app, $0) } }
        let current = Set(available.map { "\($0.0.bundleID)@\($0.1.displayVersion)" })
        // An app whose source failed this run keeps its announced key so it
        // isn't announced again once the source answers.
        let carried = state.notifiedUpdateKeys.filter { key in
            failedIDs.contains { key.hasPrefix("\($0)@") }
        }
        let keys = current.union(carried)

        let notified = !current.subtracting(state.notifiedUpdateKeys).isEmpty
        if notified {
            await notifier.deliver(count: keys.count, appNames: available.map(\.0.name).sorted())
        }
        AppReleaseBackgroundState(lastCheck: now(), notifiedUpdateKeys: keys).store(in: defaults)
        AppReleaseBackgroundState.storeAvailableCount(keys.count, in: defaults)
        return .checked(availableCount: keys.count, notified: notified)
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
