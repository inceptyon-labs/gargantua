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
    /// Check about once a day from the scheduler agent, even while Gargantua is
    /// closed, and notify about new updates. Off by default.
    public var backgroundCheckEnabled: Bool
    /// Bundle ID to the release Gargantua found installed under another
    /// version string.
    public var confirmedReleases: [String: AppReleaseConfirmedRelease]

    public init(
        ignoredBundleIDs: Set<String> = [],
        skippedVersions: [String: String] = [:],
        autoCheckEnabled: Bool = false,
        lastAutoCheck: Date? = nil,
        backgroundCheckEnabled: Bool = false,
        confirmedReleases: [String: AppReleaseConfirmedRelease] = [:]
    ) {
        self.ignoredBundleIDs = ignoredBundleIDs
        self.skippedVersions = skippedVersions
        self.autoCheckEnabled = autoCheckEnabled
        self.lastAutoCheck = lastAutoCheck
        self.backgroundCheckEnabled = backgroundCheckEnabled
        self.confirmedReleases = confirmedReleases
    }

    /// Every field is optional so blobs stored before a field existed still
    /// decode instead of resetting the user's ignored apps and skipped versions.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ignoredBundleIDs = try container.decodeIfPresent(Set<String>.self, forKey: .ignoredBundleIDs) ?? []
        skippedVersions = try container.decodeIfPresent([String: String].self, forKey: .skippedVersions) ?? [:]
        autoCheckEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoCheckEnabled) ?? false
        lastAutoCheck = try container.decodeIfPresent(Date.self, forKey: .lastAutoCheck)
        backgroundCheckEnabled = try container.decodeIfPresent(Bool.self, forKey: .backgroundCheckEnabled) ?? false
        confirmedReleases = try container
            .decodeIfPresent([String: AppReleaseConfirmedRelease].self, forKey: .confirmedReleases) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case ignoredBundleIDs, skippedVersions, autoCheckEnabled, lastAutoCheck, backgroundCheckEnabled, confirmedReleases
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
    public func isAutoCheckDue(
        now: Date = Date(),
        interval: TimeInterval = 24 * 60 * 60,
        lastBackgroundCheck: Date? = nil
    ) -> Bool {
        guard autoCheckEnabled else { return false }
        return ![lastAutoCheck, lastBackgroundCheck].compactMap { $0 }
            .contains { (0 ..< interval).contains(now.timeIntervalSince($0)) }
    }
}
