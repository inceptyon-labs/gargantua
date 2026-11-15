import Foundation
#if os(macOS)
    import AppKit
#endif

/// A background check's "N app updates available" notice, handed to the app so
/// the notification comes from Gargantua and a click opens App Updates.
public struct AppReleaseAnnouncement: Codable, Sendable, Equatable {
    /// Written only by the scheduler agent.
    public static let pendingKey = "appReleases.pendingAnnouncement"
    /// ID of the last announcement the app posted. Written only by the app.
    public static let postedKey = "appReleases.postedAnnouncementID"

    public var id: UUID
    public var count: Int
    public var appNames: [String]
    public var created: Date

    public init(id: UUID = UUID(), count: Int, appNames: [String], created: Date = Date()) {
        self.id = id
        self.count = count
        self.appNames = appNames
        self.created = created
    }

    public static func pending(in defaults: UserDefaults) -> AppReleaseAnnouncement? {
        guard let data = defaults.data(forKey: pendingKey) else { return nil }
        return try? JSONDecoder().decode(AppReleaseAnnouncement.self, from: data)
    }

    public func storePending(in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.pendingKey)
        }
    }
}

public enum AppReleaseAnnouncementPoster {
    /// Posts the scheduler's pending announcement once, if it is recent enough.
    @discardableResult
    public static func postPending(
        defaults: UserDefaults = .standard,
        notifier: any AppReleaseUpdateNotifying,
        now: Date = Date(),
        maxAge: TimeInterval = 24 * 60 * 60
    ) async -> Bool {
        guard let pending = AppReleaseAnnouncement.pending(in: defaults),
              pending.id.uuidString != defaults.string(forKey: AppReleaseAnnouncement.postedKey),
              (0 ..< maxAge).contains(now.timeIntervalSince(pending.created))
        else { return false }
        let delivered = await notifier.deliver(count: pending.count, appNames: pending.appNames)
        if delivered { defaults.set(pending.id.uuidString, forKey: AppReleaseAnnouncement.postedKey) }
        return delivered
    }
}

public enum AppReleaseLink {
    public static let openURL = URL(string: "gargantua://app-updates")!
    public static let announceURL = URL(string: "gargantua://app-updates?announce=1")!

    public enum Action: Equatable, Sendable { case open, announce }

    public static func action(for url: URL) -> Action? {
        guard url.scheme?.lowercased() == "gargantua", url.host?.lowercased() == "app-updates" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name == "announce" } ? .announce : .open
    }
}

#if os(macOS)
    /// Scheduler-side notifier: stores the announcement in the app's defaults and
    /// asks the app to post it. The URL carries no notification text.
    public struct ContainingAppUpdateNotifier: AppReleaseUpdateNotifying {
        let suiteName: String
        let appURL: URL
        let appBundleID: String
        let open: @Sendable (URL, URL, String) async -> Bool

        public init(
            suiteName: String,
            appURL: URL,
            appBundleID: String,
            open: @escaping @Sendable (URL, URL, String) async -> Bool = ContainingAppUpdateNotifier.openWithoutActivating
        ) {
            self.suiteName = suiteName
            self.appURL = appURL
            self.appBundleID = appBundleID
            self.open = open
        }

        public func deliver(count: Int, appNames: [String]) async -> Bool {
            guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
            AppReleaseAnnouncement(count: count, appNames: appNames).storePending(in: defaults)
            return await open(appURL, AppReleaseLink.announceURL, appBundleID)
        }

        /// Hide only a launch this hand-off causes; a running Gargantua is left as it is.
        static func shouldHide(runningCount: Int) -> Bool { runningCount == 0 }

        public static func openWithoutActivating(app: URL, link: URL, bundleID: String) async -> Bool {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            // Launching just to post must not show a window; a running app is left as is.
            // The ID is passed in: `Bundle(url:)` on the app returns the scheduler's own bundle here.
            configuration.hides = shouldHide(
                runningCount: NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count
            )
            do {
                _ = try await NSWorkspace.shared.open([link], withApplicationAt: app, configuration: configuration)
                return true
            } catch {
                return false
            }
        }
    }
#endif
