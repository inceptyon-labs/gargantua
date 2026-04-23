import Foundation

/// Safety classification for scan results.
///
/// Derived deterministically from YAML rules — AI can never change a safety level.
/// Each level maps to a confirmation tier, default selection state, and UI color.
public enum SafetyLevel: String, Codable, Sendable, CaseIterable {
    case safe
    case review
    case protected_ = "protected"

    /// Whether items at this level are pre-selected for cleanup.
    public var isSelectedByDefault: Bool {
        switch self {
        case .safe: true
        case .review, .protected_: false
        }
    }

    /// Whether the user can select items at this level for cleanup without override.
    public var isActionable: Bool {
        switch self {
        case .safe, .review: true
        case .protected_: false
        }
    }

    /// Confirmation tier required for cleanup at this safety level.
    public var confirmationTier: ConfirmationTier {
        switch self {
        case .safe: .singleButton
        case .review: .summaryDialog
        case .protected_: .fullModal
        }
    }
}

/// Confirmation UX tier that scales with risk.
public enum ConfirmationTier: String, Codable, Sendable {
    /// Single "Clean" button with total size. Used when all items are safe.
    case singleButton
    /// Summary dialog listing review items explicitly. Used with mixed safe + review.
    case summaryDialog
    /// Full modal with item-by-item acknowledgment. Used when protected items are selected.
    case fullModal
    /// MCP-initiated action. Confirmation is encoded at the protocol layer
    /// (`MCPCleanInput.confirm == true` is required to even decode the
    /// payload); recorded as a distinct tier so audit readers can see that
    /// the clean did not go through an app-level UX flow.
    case mcp
}
