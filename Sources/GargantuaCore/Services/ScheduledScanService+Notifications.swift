import Foundation
#if os(macOS)
    @preconcurrency import UserNotifications
#endif

/// Delivers user-visible notifications for scheduled scan results.
public protocol ScheduledScanNotificationDelivering: Sendable {
    /// Posts a user-visible notification for the supplied scheduled scan summary.
    func deliver(summary: ScheduledScanSummary) async
}

/// Notification backend that intentionally drops scheduled scan summaries.
public struct NoopScheduledScanNotifier: ScheduledScanNotificationDelivering {
    /// Creates a no-op notifier.
    public init() {}
    /// Ignores the supplied scheduled scan summary.
    public func deliver(summary: ScheduledScanSummary) async {}
}

#if os(macOS)
    /// User notification backend for scheduled scan results.
    public struct UserNotificationScheduledScanNotifier: ScheduledScanNotificationDelivering {
        private let center: UNUserNotificationCenter

        /// Creates a notifier using the supplied notification center.
        public init(center: UNUserNotificationCenter = .current()) {
            self.center = center
        }

        /// Requests notification permission and posts the scheduled scan summary.
        public func deliver(summary: ScheduledScanSummary) async {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else { return }

                let content = UNMutableNotificationContent()
                content.title = "Gargantua scheduled scan complete"
                content.body = summary.detail
                content.sound = .default

                let request = UNNotificationRequest(
                    identifier: summary.id,
                    content: content,
                    trigger: nil
                )
                try await center.add(request)
            } catch {
                return
            }
        }
    }
#endif
