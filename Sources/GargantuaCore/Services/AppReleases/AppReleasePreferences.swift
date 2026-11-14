import Foundation

/// The App Updater's user choices: apps to ignore, single versions to skip,
/// and the opt-in daily check.
public struct AppReleasePreferences: Codable, Sendable, Equatable {
    public static let userDefaultsKey = "appReleases.preferences"

    public var ignoredBundleIDs: Set<String>
    /// Bundle ID to the exact `displayVersion` the user skipped. A newer
    /// release shows again.
    public var skippedVersions: [String: String]
    /// Daily check while Gargantua is running. Off by default: the updater
    /// contacts vendors' servers only when the user asks.
    public var autoCheckEnabled: Bool
    public var lastAutoCheck: Date?

    public init(
        ignoredBundleIDs: Set<String> = [],
        skippedVersions: [String: String] = [:],
        autoCheckEnabled: Bool = false,
        lastAutoCheck: Date? = nil
    ) {
        self.ignoredBundleIDs = ignoredBundleIDs
        self.skippedVersions = skippedVersions
        self.autoCheckEnabled = autoCheckEnabled
        self.lastAutoCheck = lastAutoCheck
    }

    public static func stored(in defaults: UserDefaults = .standard) -> AppReleasePreferences {
        guard let data = defaults.data(forKey: userDefaultsKey),
              let preferences = try? JSONDecoder().decode(AppReleasePreferences.self, from: data)
        else {
            return AppReleasePreferences()
        }
        return preferences
    }

    public func store(in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.userDefaultsKey)
    }

    /// Whether the daily check should run now.
    public func isAutoCheckDue(now: Date = Date(), interval: TimeInterval = 24 * 60 * 60) -> Bool {
        guard autoCheckEnabled else { return false }
        guard let lastAutoCheck else { return true }
        return now.timeIntervalSince(lastAutoCheck) >= interval
    }
}
