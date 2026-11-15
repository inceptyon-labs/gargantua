import Foundation
#if os(macOS)
    import AppKit
    import Observation
    import UserNotifications

    /// A pane another part of the app asked the main window to show.
    @MainActor @Observable
    public final class AppNavigationRequest {
        public static let shared = AppNavigationRequest()
        public var pane: String?
        public init() {}
    }

    @MainActor
    public enum AppReleaseLinkHandler {
        public static func handle(_ url: URL) {
            switch AppReleaseLink.action(for: url) {
            case .open:
                AppNavigationRequest.shared.pane = "appUpdates"
                NSApp.unhide(nil)
                NSApp.activate()
            case .announce:
                // Posts a stored announcement; the URL itself carries no text.
                Task { await AppReleaseAnnouncementPoster.postPending(notifier: UserNotificationAppReleaseUpdateNotifier()) }
            case nil:
                return
            }
        }
    }

    /// Opens App Updates when the update notification is clicked.
    public final class AppReleaseNotificationResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {
        public static let shared = AppReleaseNotificationResponder()

        public func userNotificationCenter(
            _: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            guard response.notification.request.identifier == UserNotificationAppReleaseUpdateNotifier.identifier else { return }
            await MainActor.run { AppReleaseLinkHandler.handle(AppReleaseLink.openURL) }
        }

        public func userNotificationCenter(
            _: UNUserNotificationCenter,
            willPresent _: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .list, .sound]
        }
    }
#endif
