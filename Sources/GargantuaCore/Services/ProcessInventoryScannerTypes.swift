import Foundation

/// Result of one process-inventory scan pass.
public struct ProcessInventoryScan: Sendable, Equatable {
    /// Ranked list returned for display. When `topN` is provided, the scanner
    /// caps this list before expensive identity/signature resolution so the
    /// snapshot stays quick on process-heavy machines.
    public let items: [ProcessItem]
    /// Total number of running processes the snapshot saw — useful so the
    /// footer can say "showing top 50 of 432 running" without the UI having
    /// to re-query.
    public let totalProcessCount: Int
    /// The metric `items` is sorted by.
    public let sortedBy: ProcessSortMetric
    /// Preferred display cap used by the scanner.
    public let topN: Int?
    /// When the scan completed.
    public let scannedAt: Date

    public init(
        items: [ProcessItem],
        totalProcessCount: Int,
        sortedBy: ProcessSortMetric,
        topN: Int?,
        scannedAt: Date
    ) {
        self.items = items
        self.totalProcessCount = totalProcessCount
        self.sortedBy = sortedBy
        self.topN = topN
        self.scannedAt = scannedAt
    }
}

/// Orchestrates `ProcessSnapshotProvider` + `LaunchdItemIndex` +
/// `BinaryIdentityResolver` + `ProcessLaunchSourceMatcher` +
/// `ProcessSafetyClassifier` into a single `[ProcessItem]` list.
public protocol ProcessInventoryScanning: Sendable {
    /// Run a scan, ranking by `metric` and capping at `topN` items.
    func scan(metric: ProcessSortMetric, topN: Int?) async -> ProcessInventoryScan

    /// Find processes across the FULL table whose command, path, PID, or parent
    /// name matches `query`, ranked by `metric` and capped at `limit`. Distinct
    /// from filtering a `scan` result, which only sees the top-N.
    func search(query: String, metric: ProcessSortMetric, limit: Int) async -> ProcessInventoryScan
}

public extension ProcessInventoryScanning {
    /// Correctness fallback for conformers that don't specialize search: scan
    /// uncapped, then filter the fully-built items (so it can also match the
    /// resolved display name). `DefaultProcessInventoryScanner` overrides this
    /// with a cheaper raw-sample pre-filter that resolves identity only for
    /// matches.
    func search(query: String, metric: ProcessSortMetric, limit: Int) async -> ProcessInventoryScan {
        let full = await scan(metric: metric, topN: nil)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return ProcessInventoryScan(
                items: [],
                totalProcessCount: full.totalProcessCount,
                sortedBy: metric,
                topN: nil,
                scannedAt: full.scannedAt
            )
        }
        let matched = full.items.filter { item in
            item.command.lowercased().contains(needle)
                || item.displayName.lowercased().contains(needle)
                || (item.executablePath?.lowercased().contains(needle) ?? false)
                || String(item.pid).contains(needle)
                || (item.parentName?.lowercased().contains(needle) ?? false)
        }
        return ProcessInventoryScan(
            items: Array(matched.prefix(limit)),
            totalProcessCount: full.totalProcessCount,
            sortedBy: metric,
            topN: nil,
            scannedAt: full.scannedAt
        )
    }
}
