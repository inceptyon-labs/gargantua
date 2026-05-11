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
    /// The metric `items` is currently sorted by. Updated by `resort` calls
    /// in the session so the UI stays in sync.
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

    public static let empty = ProcessInventoryScan(
        items: [],
        totalProcessCount: 0,
        sortedBy: .cpu,
        topN: nil,
        scannedAt: .distantPast
    )
}

/// Orchestrates `ProcessSnapshotProvider` + `LaunchdItemIndex` +
/// `BinaryIdentityResolver` + `ProcessLaunchSourceMatcher` +
/// `ProcessSafetyClassifier` into a single `[ProcessItem]` list.
public protocol ProcessInventoryScanning: Sendable {
    /// Run a scan, ranking by `metric` and capping at `topN` items.
    func scan(metric: ProcessSortMetric, topN: Int?) async -> ProcessInventoryScan
}
