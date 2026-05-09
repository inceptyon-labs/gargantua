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

    /// Subtract a destination cleanup's freed bytes/items from matching alerts so
    /// the dashboard's NEXT ACTIONS roadmap re-ranks immediately instead of
    /// staying stuck on a destination the user just emptied. Alerts are matched
    /// by category; an alert that is fully cleared is dropped, and remaining
    /// alerts are re-sorted by reclaimable size to keep "Start Here" honest.
    public func applyCleanupDelta(_ result: CleanupResult) {
        let clearedByCategory = Dictionary(
            grouping: result.succeededItems,
            by: { $0.item.category }
        )
        guard !clearedByCategory.isEmpty else { return }

        let updated: [AlertItem] = alerts.compactMap { alert in
            guard let cleared = clearedByCategory[alert.category] else { return alert }
            let clearedBytes = cleared.reduce(Int64(0)) { $0 + $1.item.size }
            let remainingSize = max(0, alert.reclaimableSize - clearedBytes)
            let remainingCount = max(0, alert.itemCount - cleared.count)
            if remainingSize == 0 || remainingCount == 0 { return nil }
            return AlertItem(
                id: alert.id,
                reclaimableSize: remainingSize,
                itemCount: remainingCount,
                category: alert.category,
                categoryLabel: alert.categoryLabel,
                staleness: alert.staleness,
                destination: alert.destination
            )
        }
        alerts = updated.sorted { $0.reclaimableSize > $1.reclaimableSize }
    }
}
