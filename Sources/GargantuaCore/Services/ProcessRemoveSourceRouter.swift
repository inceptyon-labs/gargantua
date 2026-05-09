import Foundation

/// Decision the row UI needs to make when the user clicks "Remove Source" on
/// a `ProcessItem`. Carries either the launchd plist path that should be
/// pre-selected on the Background Items pane, or a structured refusal the
/// view can render as an inline reason.
public enum ProcessRemoveSourceRouting: Sendable, Equatable {
    /// Hand off to the Background Items review pane with this plist path
    /// pre-selected. The Background Items pane runs the actual disable/delete
    /// through `BackgroundItemActionExecutor` once the user confirms there.
    case routeToBackgroundItems(plistPath: String, label: String)
    /// Cannot route. Carries the refusal kind so callers can pick UX (the
    /// row uses the human description for tooltips / inline reason; the
    /// router exposes the enum case so tests don't depend on copy).
    case unsupported(ProcessActionRefusal, reason: String)
}

/// Decides whether a `ProcessItem` is eligible for the "Remove Source" handoff
/// to the Background Items pane.
///
/// The handoff is intentionally narrow: the user gets the affordance only when
/// there is a confident link to a launchd plist (`.exact` or `.path`
/// confidence). Heuristic matches and non-launchd sources route to refusal so
/// the user is never asked to authorize a delete on the wrong plist.
public struct ProcessRemoveSourceRouter: Sendable {
    public init() {}

    public func route(_ item: ProcessItem) -> ProcessRemoveSourceRouting {
        // Only `.exact` (PID 1 parent + path match) and `.path` (path match
        // alone) are confident enough to act on. `.heuristic` and `.unknown`
        // are advisory only — surfacing the user's plist that may have
        // nothing to do with the running process would be a footgun.
        guard item.launchConfidence == .exact || item.launchConfidence == .path else {
            return .unsupported(
                .unsupportedRemoveSource,
                reason: "Match confidence is \(item.launchConfidence.displayLabel.lowercased()); need exact or path."
            )
        }
        guard case let .launchd(_, label, plistPath) = item.launchSource else {
            return .unsupported(
                .unsupportedRemoveSource,
                reason: "Launch source \(item.launchSource.displayLabel.lowercased()) has no plist to remove."
            )
        }
        // Defensive: the matcher always supplies a non-empty plist path on
        // `.launchd` cases, but if a future code path manufactures one
        // without it, we want the user to see why.
        guard !plistPath.isEmpty else {
            return .unsupported(
                .noPlistPath,
                reason: "Launch source has no on-disk plist path."
            )
        }
        return .routeToBackgroundItems(plistPath: plistPath, label: label)
    }
}
