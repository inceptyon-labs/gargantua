import Foundation
#if os(macOS)
    import AppKit
    import Observation
    import UserNotifications

    /// A pane another part of the app asked the main window to show.
    @MainActor @Observable
    public final class AppNavigationRequest {
        public static let shared = AppNavigationRequest()
        public static let didRequest = Notification.Name("GargantuaAppNavigationRequest")
        public var pane: String?
        public init() {}
    }

    @MainActor
    public enum AppReleaseLinkHandler {
        /// Brings the main window forward; the app target replaces this with its window-aware version.
        public static var activateMainWindow: @MainActor () -> Void = { NSApp.activate() }

        public static func handle(_ url: URL) {
            switch AppReleaseLink.action(for: url) {
            case .open:
                AppNavigationRequest.shared.pane = "appUpdates"
                NotificationCenter.default.post(name: AppNavigationRequest.didRequest, object: nil)
                NSApp.unhide(nil)
                activateMainWindow()
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
