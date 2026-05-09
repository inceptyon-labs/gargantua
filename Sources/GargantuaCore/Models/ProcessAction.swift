import Foundation

/// A mutating action the user can apply to a `ProcessItem`.
///
/// `.stop` is the only action that actually changes process state from this
/// pane — `.removeSource` is a navigation handoff to the Background Items
/// review pane, where the privileged disable/delete pipeline already lives.
public enum ProcessAction: String, Sendable, Equatable, Hashable, Codable {
    /// Send `SIGTERM`, then `SIGKILL` if the process is still alive after a
    /// short grace window. Refused on `.protected_`, `/System/`, kernel tasks,
    /// and `launchd` itself.
    case stop
    /// Hand off to the Background Items review pane, pre-selected on the
    /// launchd plist that owns this process. The actual disable/delete runs
    /// through `BackgroundItemActionExecutor`, not from here.
    case removeSource
}

extension ProcessAction {
    /// Verb used in audit `command` fields and confirmation copy.
    public var verb: String {
        switch self {
        case .stop: "stop"
        case .removeSource: "remove_source"
        }
    }
}

/// Outcome of applying a `ProcessAction` to one process.
///
/// The audit pipeline records the same fields independently for forensic
/// recovery; this carries enough state for the UI to refresh its row in place
/// or trigger cross-pane navigation.
public struct ProcessActionOutcome: Sendable, Equatable {
    public let processID: String
    public let action: ProcessAction
    public let succeeded: Bool
    public let error: String?
    public let auditID: UUID?
    /// When the outcome is `.removeSource`, carries the launchd plist path the
    /// caller should hand off to the Background Items pane. `nil` for `.stop`.
    public let routedPlistPath: String?

    public init(
        processID: String,
        action: ProcessAction,
        succeeded: Bool,
        error: String? = nil,
        auditID: UUID? = nil,
        routedPlistPath: String? = nil
    ) {
        self.processID = processID
        self.action = action
        self.succeeded = succeeded
        self.error = error
        self.auditID = auditID
        self.routedPlistPath = routedPlistPath
    }
}

/// Reasons the action layer can refuse to even attempt an action — these never
/// reach `kill(2)` or the Background Items pane, so the user sees a precise
/// reason instead of a generic "rejected" string.
public enum ProcessActionRefusal: Error, LocalizedError, Equatable {
    /// Process safety level forbids stopping (currently only `.protected_`).
    case protectedItem
    /// Process executable lives under `/System/` — Apple-managed, off-limits.
    case systemPath
    /// Process is `launchd` (PID 1) or a kernel task (PID 0).
    case kernelOrInit
    /// Remove-source attempted on a process whose source is not a launchd
    /// item, or whose match confidence is too low to act on.
    case unsupportedRemoveSource
    /// Remove-source attempted on a launchd-backed process whose plist path
    /// is missing on the snapshot (defensive — should not occur in practice).
    case noPlistPath

    public var errorDescription: String? {
        switch self {
        case .protectedItem:
            "This process is system-protected and cannot be stopped from Gargantua."
        case .systemPath:
            "Processes under /System/ are managed by macOS and won't be stopped."
        case .kernelOrInit:
            "launchd and kernel tasks cannot be stopped."
        case .unsupportedRemoveSource:
            "Remove Source needs a confident link to a launchd plist. This process doesn't have one."
        case .noPlistPath:
            "This process's launchd source has no plist path on disk."
        }
    }
}
