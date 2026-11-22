import Foundation

/// Underlying cause of a failed cleanup, recovered from the error string.
///
/// The distinction matters because Full Disk Access is rarely the real blocker:
/// granting it lets Gargantua *enumerate* protected locations, but it does not
/// grant ownership of root-owned files. Deleting those returns POSIX `EPERM`,
/// which is a different failure than a TCC/Full Disk Access denial and is fixed
/// by the privileged helper (root), not by toggling a permission the user has
/// usually already granted.
public enum CleanupFailureKind: Sendable, Equatable {
    case none
    /// File is owned by root or another user; needs the privileged helper.
    case ownership
    /// Permission-class failure with no more specific signal.
    case permission
    case other
}

public enum CleanupFailureClassifier {
    public static func kind(of error: String?) -> CleanupFailureKind {
        guard let raw = error?.lowercased(), !raw.isEmpty else { return .none }

        // POSIX EPERM / Cocoa "no permission": the file exists but the current
        // user can't remove it — almost always root or other-user ownership.
        if raw.contains("operation not permitted")
            || raw.contains("not permitted")
            || raw.contains("don’t have permission")
            || raw.contains("don't have permission")
            || raw.contains("permission denied")
            || raw.contains("owned by") {
            return .ownership
        }

        if raw.contains("permission") || raw.contains("not allowed")
            || raw.contains("operation not allowed") || raw.contains("access") {
            return .permission
        }

        return .other
    }

    /// True when the failure is permission-class — i.e. a root-privileged helper
    /// could plausibly complete the removal.
    public static func isElevatable(_ error: String?) -> Bool {
        switch kind(of: error) {
        case .ownership, .permission:
            true
        case .none, .other:
            false
        }
    }

    /// Plain-language reason for display. Maps the recovered kind to a human
    /// message, keeps macOS's own description when it's already readable, and
    /// never surfaces a bare "unknown error" or an empty string. The raw error
    /// stays on the model (for `kind(of:)`/audit); this is display-only.
    public static func friendlyReason(for error: String?) -> String {
        let raw = (error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind(of: error) {
        case .ownership:
            // The helper already tried and refused: its allow-list covers system
            // cache and log folders only, so "needs the helper" would be wrong.
            if raw.lowercased().contains("privileged helper rejected path") {
                return "Permission denied, and it’s outside the system folders Gargantua’s privileged helper may clean."
            }
            return "Owned by macOS or another user — needs Gargantua’s privileged helper."
        case .permission:
            return "Permission denied for this item."
        case .none, .other:
            let low = raw.lowercased()
            if low.contains("busy") || low.contains("in use") {
                return "In use by a running app — quit it, then retry."
            }
            if low.contains("read-only") || low.contains("read only") {
                return "On a read-only volume."
            }
            if raw.isEmpty || low == "unknown error" {
                return "Couldn’t be removed — macOS gave no further detail."
            }
            return raw
        }
    }
}
