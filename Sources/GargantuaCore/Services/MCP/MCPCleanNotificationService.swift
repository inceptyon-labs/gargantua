import Foundation
@preconcurrency import UserNotifications

// PRD §7.4 user-facing guardrail: before an MCP clean touches the disk, the
// app surfaces a local notification with a Cancel action. The user has a
// short grace period to tap Cancel; if they do, the clean is short-circuited.
// If they don't (or the notification never appears — unbundled CLI,
// permission denied), the clean proceeds.
//
// This file defines the service protocol, a noop fallback for unbundled
// deployments, a production `UNUserNotificationCenter` impl, and a factory
// that picks the right one at runtime. The handler does not invoke the
// service directly — it's wired into the `Cleaner` closure in `main.swift`,
// so unit tests of the handler don't need to know about notifications.

/// Decision returned by `MCPCleanNotificationService.request(...)`.
public enum MCPCleanDecision: Sendable, Equatable {
    /// User did not tap Cancel within the grace period. Cleaner proceeds.
    case proceed
    /// User tapped Cancel. Cleaner must short-circuit and audit the attempt.
    case cancelled
}

/// Surfaces a user-facing notification for an incoming MCP clean request and
/// waits up to a grace period for the user to tap Cancel. Synchronous: the
/// caller blocks on this thread until the decision is known. Thread-safe —
/// must be callable from the transport-dispatch thread (not the main
/// thread; `main.swift` moves the stdio transport off-main).
public protocol MCPCleanNotificationService: Sendable {
    /// Post the notification and block until the user responds or the grace
    /// period elapses. Never throws — notification subsystem failures must
    /// degrade to `.proceed` (notification is a courtesy, not a gate).
    func request(
        items: [ScanResult],
        method: CleanupMethod,
        clientID: String
    ) -> MCPCleanDecision
}

/// No-op impl used when the process cannot post user notifications (unbundled
/// CLI, no bundle identifier). Returns `.proceed` immediately.
public struct NoopMCPCleanNotificationService: MCPCleanNotificationService {
    public init() {}

    public func request(
        items: [ScanResult],
        method: CleanupMethod,
        clientID: String
    ) -> MCPCleanDecision {
        .proceed
    }
}

/// `UNUserNotificationCenter`-backed impl. Posts a notification with a Cancel
/// action and waits up to `gracePeriod` seconds for the user to respond.
///
/// Cancel signal flow:
/// 1. `request(...)` assigns a unique `notificationID`, registers a pending
///    `DispatchSemaphore` for it in `pendingByID`, and schedules the
///    notification with that ID embedded in `userInfo`.
/// 2. If the user taps Cancel, `UNUserNotificationCenter` invokes
///    `userNotificationCenter(_:didReceive:withCompletionHandler:)` on this
///    object (registered as the center's delegate). The delegate looks up the
///    notificationID in `pendingByID`, marks it as cancelled, and signals the
///    waiting semaphore.
/// 3. `request(...)` wakes from `semaphore.wait(timeout: gracePeriod)` and
///    returns `.cancelled` if the flag was set, `.proceed` otherwise.
/// 4. Either way, the pending delivered notification is removed so it does
///    not linger in Notification Center after the decision has been made.
///
/// Availability caveat: `UNUserNotificationCenter.current()` requires the
/// process to have a bundle identifier. Construct this via
/// `MCPCleanNotificationFactory.automatic(...)`, which falls back to Noop
/// when the process is unbundled.
public final class UNCleanNotificationService: NSObject,
    MCPCleanNotificationService,
    UNUserNotificationCenterDelegate,
    @unchecked Sendable {

    public static let cancelActionID = "GARGANTUA_MCP_CANCEL_CLEAN"
    public static let cleanCategoryID = "GARGANTUA_MCP_CLEAN_REQUEST"
    public static let notificationIDKey = "gargantua.mcp.clean.id"

    /// Grace period before the clean proceeds. PRD §7.4 silent on timing; 5s
    /// splits the difference between "user can react" and "agent waits too
    /// long". Configurable for tests.
    public let gracePeriod: TimeInterval

    private let center: UNUserNotificationCenter
    private let log: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var pendingByID: [String: Pending] = [:]

    private struct Pending {
        let semaphore: DispatchSemaphore
        var cancelled: Bool
    }

    public init(
        gracePeriod: TimeInterval = 5,
        center: UNUserNotificationCenter = .current(),
        log: (@Sendable (String) -> Void)? = nil
    ) {
        precondition(gracePeriod > 0, "gracePeriod must be positive")
        self.gracePeriod = gracePeriod
        self.center = center
        self.log = log
        super.init()

        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.cleanCategoryID,
                actions: [
                    UNNotificationAction(
                        identifier: Self.cancelActionID,
                        title: "Cancel",
                        options: [.destructive]
                    ),
                ],
                intentIdentifiers: [],
                options: []
            ),
        ])
    }

    public func request(
        items: [ScanResult],
        method: CleanupMethod,
        clientID: String
    ) -> MCPCleanDecision {
        let notificationID = UUID().uuidString
        let semaphore = DispatchSemaphore(value: 0)

        lock.lock()
        pendingByID[notificationID] = Pending(semaphore: semaphore, cancelled: false)
        lock.unlock()

        defer {
            lock.lock()
            pendingByID.removeValue(forKey: notificationID)
            lock.unlock()
            center.removeDeliveredNotifications(withIdentifiers: [notificationID])
            center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        }

        let content = UNMutableNotificationContent()
        content.title = "Cleanup requested by MCP client"
        content.body = Self.bodyMessage(items: items, method: method, clientID: clientID)
        content.categoryIdentifier = Self.cleanCategoryID
        content.userInfo = [Self.notificationIDKey: notificationID]
        content.sound = nil

        let noticeRequest = UNNotificationRequest(
            identifier: notificationID,
            content: content,
            trigger: nil
        )

        let postSemaphore = DispatchSemaphore(value: 0)
        center.add(noticeRequest) { [weak self] error in
            if let error { self?.log?("clean-notification add failed: \(error)") }
            postSemaphore.signal()
        }
        _ = postSemaphore.wait(timeout: .now() + 1)

        _ = semaphore.wait(timeout: .now() + gracePeriod)

        lock.lock()
        let cancelled = pendingByID[notificationID]?.cancelled ?? false
        lock.unlock()
        return cancelled ? .cancelled : .proceed
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard response.actionIdentifier == Self.cancelActionID else { return }

        let userInfo = response.notification.request.content.userInfo
        guard let notificationID = userInfo[Self.notificationIDKey] as? String else {
            return
        }

        lock.lock()
        if var pending = pendingByID[notificationID] {
            pending.cancelled = true
            pendingByID[notificationID] = pending
            pending.semaphore.signal()
        }
        lock.unlock()
    }

    // MARK: - Helpers

    static func bodyMessage(
        items: [ScanResult],
        method: CleanupMethod,
        clientID: String
    ) -> String {
        let verb = method == .delete ? "permanently delete" : "move to Trash"
        let totalBytes = items.reduce(Int64(0)) { $0 + $1.size }
        let sizeSuffix = totalBytes > 0 ? " (\(AlertItem.formatBytes(totalBytes)))" : ""
        return "\(clientID) wants to \(verb) \(items.count) item(s)\(sizeSuffix). Tap Cancel to block."
    }
}

/// Picks a notification service based on runtime availability. Use this in
/// `main.swift`; tests always inject a deterministic fake.
public enum MCPCleanNotificationFactory {
    /// Produces a production notification service when the process has a
    /// bundle identifier and can reach `UNUserNotificationCenter`. Returns
    /// `NoopMCPCleanNotificationService` otherwise. Never throws — a
    /// startup-time notification failure should not prevent the MCP server
    /// from serving other tools.
    public static func automatic(
        gracePeriod: TimeInterval = 5,
        log: (@Sendable (String) -> Void)? = nil
    ) -> any MCPCleanNotificationService {
        guard Bundle.main.bundleIdentifier != nil else {
            log?("notification service: unbundled process, using Noop (cleans will auto-proceed).")
            return NoopMCPCleanNotificationService()
        }
        return UNCleanNotificationService(gracePeriod: gracePeriod, log: log)
    }
}
