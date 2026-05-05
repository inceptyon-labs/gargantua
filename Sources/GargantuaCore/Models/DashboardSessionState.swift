import Foundation
import Observation

/// Triage state for the Dashboard.
///
/// Owned at the `MainContentView` level (mirrors `DeepCleanSessionState`,
/// `DiskExplorerState`, `FileHealthContainerState`, etc.) so a sidebar
/// nav away-and-back doesn't tear down the user's just-run triage and
/// re-prompt them to run it again.
@Observable @MainActor
public final class DashboardSessionState {
    public var alerts: [AlertItem] = []
    public var scanProgress = ScanProgress()
    public var hasRunTriageScan: Bool = false
    public var lastTriageAt: Date?

    public init() {}

    /// Hours after which a successful triage is considered stale and the
    /// dashboard surfaces a refresh hint instead of treating the existing
    /// results as authoritative.
    public static let staleAfter: TimeInterval = 24 * 60 * 60

    public var triageIsStale: Bool {
        guard let lastTriageAt else { return false }
        return Date().timeIntervalSince(lastTriageAt) >= Self.staleAfter
    }

    /// Short human-readable age of the last successful triage, e.g.
    /// "26h old" or "3d old". Empty when no triage has finished.
    public var triageAgeLabel: String {
        guard let lastTriageAt else { return "" }
        let interval = max(0, Date().timeIntervalSince(lastTriageAt))
        let hours = Int(interval / 3600)
        if hours < 48 {
            return "\(max(hours, 1))h old"
        }
        return "\(hours / 24)d old"
    }
}
