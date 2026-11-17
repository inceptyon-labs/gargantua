import Foundation
import os
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
    /// ID of the last announcement the app could not post because the user
    /// has notifications turned off for Gargantua. Written only by the app.
    public static let refusedKey = "appReleases.refusedAnnouncementID"

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

    /// Whether the app has dealt with the pending announcement: it posted it,
    /// or found notifications turned off. Either way a retry has nothing to add.
    public static func isPendingSettled(in defaults: UserDefaults) -> Bool {
        guard let id = pending(in: defaults)?.id.uuidString else { return false }
        return defaults.string(forKey: postedKey) == id || defaults.string(forKey: refusedKey) == id
    }
}

public enum AppReleaseAnnouncementPoster {
    /// Announcements being posted now. A hidden launch calls `postPending`
    /// from the launch path and from the announce link at once; only one may
    /// deliver.
    private static let posting = OSAllocatedUnfairLock(initialState: Set<UUID>())

    /// Posts the scheduler's pending announcement once, if it is recent enough.
    @discardableResult
    public static func postPending(
        defaults: UserDefaults = .standard,
        notifier: any AppReleaseUpdateNotifying,
        now: Date = Date(),
        maxAge: TimeInterval = 24 * 60 * 60
    ) async -> Bool {
        guard let pending = AppReleaseAnnouncement.pending(in: defaults),
              (0 ..< maxAge).contains(now.timeIntervalSince(pending.created)),
              posting.withLock({ $0.insert(pending.id).inserted })
        else { return false }
        defer { posting.withLock { _ = $0.remove(pending.id) } }
        // Read after the claim, so a call that just finished posting is seen.
        let id = pending.id.uuidString
        guard id != defaults.string(forKey: AppReleaseAnnouncement.postedKey) else { return false }

        let delivered = await notifier.deliver(count: pending.count, appNames: pending.appNames)
        if delivered {
            defaults.set(id, forKey: AppReleaseAnnouncement.postedKey)
        } else if await notifier.isRefused() {
            defaults.set(id, forKey: AppReleaseAnnouncement.refusedKey)
        }
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
        let confirmTimeout: TimeInterval
        let pollInterval: TimeInterval
        let open: @Sendable (URL, URL, String) async -> Bool

        public init(
            suiteName: String,
            appURL: URL,
            appBundleID: String,
            confirmTimeout: TimeInterval = 15,
            pollInterval: TimeInterval = 0.5,
            open: @escaping @Sendable (URL, URL, String) async -> Bool = ContainingAppUpdateNotifier.openWithoutActivating
        ) {
            self.suiteName = suiteName
            self.appURL = appURL
            self.appBundleID = appBundleID
            self.confirmTimeout = confirmTimeout
            self.pollInterval = pollInterval
            self.open = open
        }

        public func deliver(count: Int, appNames: [String]) async -> Bool {
            guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
            let announcement = AppReleaseAnnouncement(count: count, appNames: appNames)
            announcement.storePending(in: defaults)
            guard await open(appURL, AppReleaseLink.announceURL, appBundleID) else { return false }
            // Opening the app isn't delivery: wait for it to record that it posted this one.
            let deadline = Date().addingTimeInterval(confirmTimeout)
            let id = announcement.id.uuidString
            while true {
                let current = UserDefaults(suiteName: suiteName)
                if current?.string(forKey: AppReleaseAnnouncement.postedKey) == id { return true }
                // Notifications are off for the app; waiting longer changes nothing.
                if current?.string(forKey: AppReleaseAnnouncement.refusedKey) == id { return false }
                guard Date() < deadline else { return false }
                try? await Task.sleep(for: .seconds(pollInterval))
            }
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
