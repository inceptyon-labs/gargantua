import Foundation

/// A mutating action the user can apply to a `BackgroundItem`.
public enum BackgroundItemAction: String, Sendable, Equatable, Hashable, Codable {
    /// Stop the job and prevent it from running again. `launchctl bootout` +
    /// `disable` so subsequent loads are also rejected.
    case disable
    /// Inverse of `.disable` — `launchctl enable` and re-bootstrap.
    case enable
    /// Delete the plist (trash-first). Pre-condition: the item must already be
    /// disabled in the prior pane state. Out-of-scope on `.protected_` items.
    case delete
}

extension BackgroundItemAction {
    /// Human-verb used in audit `command` fields and confirmation copy.
    public var verb: String {
        switch self {
        case .disable: "disable"
        case .enable: "enable"
        case .delete: "delete"
        }
    }
}

/// Outcome of applying a `BackgroundItemAction` to one item.
///
/// Carries enough state for the UI to refresh its row in place (the audit
/// pipeline records the same fields independently for forensic recovery).
public struct BackgroundItemActionOutcome: Sendable, Equatable {
    public let itemID: String
    public let action: BackgroundItemAction
    public let succeeded: Bool
    public let error: String?
    public let auditID: UUID?

    public init(
        itemID: String,
        action: BackgroundItemAction,
        succeeded: Bool,
        error: String? = nil,
        auditID: UUID? = nil
    ) {
        self.itemID = itemID
        self.action = action
        self.succeeded = succeeded
        self.error = error
        self.auditID = auditID
    }
}

/// Reasons the action layer can refuse to even attempt an action — these never
/// reach the privileged helper, so the user sees a precise reason instead of a
/// generic "rejected by helper" string.
public enum BackgroundItemActionRefusal: Error, LocalizedError, Equatable {
    /// Item's safety level forbids deletion (currently only `.protected_`).
    case protectedItem
    /// Item's source can't be programmatically controlled (login items,
    /// startup items).
    case unsupportedSource
    /// Delete attempted on an item that has not been disabled first.
    case deleteRequiresDisable
    /// Delete attempted on an item that has no on-disk plist (login items).
    case noPlistToDelete
    /// Unknown user uid — the user-domain `gui/<uid>/<label>` target needs one.
    case missingUserID

    public var errorDescription: String? {
        switch self {
        case .protectedItem:
            "This item is system-protected and cannot be modified through Gargantua."
        case .unsupportedSource:
            "This source can't be controlled programmatically. Use System Settings → Login Items."
        case .deleteRequiresDisable:
            "Disable the item first; deletion only runs on items already disabled."
        case .noPlistToDelete:
            "There is no plist file on disk to delete for this item."
        case .missingUserID:
            "Could not determine the current user identifier; aborting."
        }
    }
}
