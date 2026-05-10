import Foundation

/// User-selected Sparkle update channel.
///
/// Stable always receives default-channel appcast items. Beta additionally
/// opts into Sparkle's `beta` channel.
public enum AppUpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case stable
    case beta

    public static let userDefaultsKey = "appUpdateChannel"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .stable: "Stable"
        case .beta: "Beta"
        }
    }

    public var detail: String {
        switch self {
        case .stable: "Default releases only"
        case .beta: "Default and beta releases"
        }
    }

    public static func stored(in defaults: UserDefaults = .standard) -> AppUpdateChannel {
        guard let rawValue = defaults.string(forKey: userDefaultsKey),
              let channel = AppUpdateChannel(rawValue: rawValue)
        else {
            return .stable
        }
        return channel
    }

    public func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.userDefaultsKey)
    }
}

/// Observable state and user actions for the Updates settings pane.
///
/// Sparkle itself lives in the app target. This adapter keeps SettingsView
/// independent from Sparkle so unit tests and previews can exercise the UI
/// model without an updater configured.
@MainActor
public final class AppUpdateSettingsViewModel: ObservableObject {
    @Published public private(set) var automaticallyChecksForUpdates: Bool
    @Published public private(set) var automaticallyDownloadsUpdates: Bool
    @Published public private(set) var allowsAutomaticUpdates: Bool
    @Published public private(set) var canCheckForUpdates: Bool
    @Published public private(set) var lastUpdateCheckDate: Date?
    @Published public private(set) var feedURL: URL?
    @Published public private(set) var channel: AppUpdateChannel

    public var checkForUpdates: (() -> Void)?
    public var setAutomaticallyChecksForUpdates: ((Bool) -> Void)?
    public var setAutomaticallyDownloadsUpdates: ((Bool) -> Void)?
    public var setChannel: ((AppUpdateChannel) -> Void)?

    private let defaults: UserDefaults

    public init(
        defaults: UserDefaults = .standard,
        automaticallyChecksForUpdates: Bool = false,
        automaticallyDownloadsUpdates: Bool = false,
        allowsAutomaticUpdates: Bool = true,
        canCheckForUpdates: Bool = false,
        lastUpdateCheckDate: Date? = nil,
        feedURL: URL? = nil
    ) {
        self.defaults = defaults
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        self.allowsAutomaticUpdates = allowsAutomaticUpdates
        self.canCheckForUpdates = canCheckForUpdates
        self.lastUpdateCheckDate = lastUpdateCheckDate
        self.feedURL = feedURL
        self.channel = AppUpdateChannel.stored(in: defaults)
    }

    public struct Snapshot: Sendable {
        public let automaticallyChecksForUpdates: Bool
        public let automaticallyDownloadsUpdates: Bool
        public let allowsAutomaticUpdates: Bool
        public let canCheckForUpdates: Bool
        public let lastUpdateCheckDate: Date?
        public let feedURL: URL?

        public init(
            automaticallyChecksForUpdates: Bool,
            automaticallyDownloadsUpdates: Bool,
            allowsAutomaticUpdates: Bool,
            canCheckForUpdates: Bool,
            lastUpdateCheckDate: Date?,
            feedURL: URL?
        ) {
            self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            self.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
            self.allowsAutomaticUpdates = allowsAutomaticUpdates
            self.canCheckForUpdates = canCheckForUpdates
            self.lastUpdateCheckDate = lastUpdateCheckDate
            self.feedURL = feedURL
        }
    }

    public func refresh(_ snapshot: Snapshot) {
        automaticallyChecksForUpdates = snapshot.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = snapshot.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = snapshot.allowsAutomaticUpdates
        canCheckForUpdates = snapshot.canCheckForUpdates
        lastUpdateCheckDate = snapshot.lastUpdateCheckDate
        feedURL = snapshot.feedURL
    }

    public func userCheckForUpdates() {
        guard canCheckForUpdates else { return }
        checkForUpdates?()
    }

    public func userSetAutomaticallyChecksForUpdates(_ value: Bool) {
        automaticallyChecksForUpdates = value
        if !value {
            automaticallyDownloadsUpdates = false
        }
        setAutomaticallyChecksForUpdates?(value)
    }

    public func userSetAutomaticallyDownloadsUpdates(_ value: Bool) {
        let allowedValue = value && automaticallyChecksForUpdates && allowsAutomaticUpdates
        automaticallyDownloadsUpdates = allowedValue
        setAutomaticallyDownloadsUpdates?(allowedValue)
    }

    public func userSetChannel(_ value: AppUpdateChannel) {
        channel = value
        value.store(in: defaults)
        setChannel?(value)
    }
}
