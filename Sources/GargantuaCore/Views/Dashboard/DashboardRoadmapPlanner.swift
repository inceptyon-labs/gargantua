import Foundation

@MainActor
struct DashboardRoadmapPlanner {
    let alerts: [AlertItem]
    let scanProgress: ScanProgress
    let hasRunTriageScan: Bool
    let triageIsStale: Bool
    let triageAgeLabel: String
    let diskUsage: Double
    let freeDiskGB: Int
    /// User-installed app count for the Smart Uninstaller pill. `0` falls
    /// back to a generic label so a not-yet-loaded count doesn't show "0 apps".
    var installedAppCount: Int = 0

    var headline: String {
        if scanProgress.isScanning { return "Building the cleanup roadmap" }
        if !hasRunTriageScan { return "Run triage, then follow the tool roadmap" }
        if triageIsStale {
            return "Triage is \(triageAgeLabel) — refresh before acting"
        }
        if alerts.isEmpty { return "No obvious bulk cleanup found by triage" }
        return "Start with \(steps.first?.title ?? "the top cleanup step")"
    }

    var detail: String {
        if scanProgress.isScanning {
            return "The triage scan is checking lightweight local rules and grouping findings by the tool that should handle them."
        }
        if !hasRunTriageScan {
            return "Triage checks caches, logs, trash, installers, and developer artifacts. "
                + "It does not uninstall apps or run duplicate matching. "
                + "Its job is to rank which deeper tool you should open first."
        }
        if triageIsStale {
            return "The last triage finished \(triageAgeLabel). Disk state may have shifted "
                + "— re-run before you act on the roadmap below."
        }
        if alerts.isEmpty {
            return "The lightweight pass did not find safe or review-tier cleanup groups. "
                + "Use the manual tools below when disk pressure still feels wrong."
        }
        return "The list below is ordered from highest reclaimable impact to deeper manual passes. "
            + "Each row routes to the tool that owns that kind of cleanup."
    }

    var statusPill: String {
        if scanProgress.isScanning { return "triage running" }
        if !hasRunTriageScan { return "triage not run" }
        if triageIsStale { return "triage \(triageAgeLabel) · refresh" }
        if alerts.isEmpty { return "triage clear" }
        return "\(alerts.count) triage groups"
    }
}
