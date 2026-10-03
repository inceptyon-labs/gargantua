import Foundation

/// Aggregates multiple `ScanAdapter`s into a single adapter whose results are
/// the concatenation of each underlying adapter's `scan()` output.
///
/// Failures in any single adapter abort the composite scan, but optional
/// adapters can be wrapped via `bestEffort:` so they swallow their own
/// failures and yield an empty result. Used to surface
/// `CommandActionScanAdapter` results alongside `NativeScanAdapter` output
/// without rewriting every scan-view's adapter wiring.
public struct CompositeScanAdapter: ScanAdapter {
    private let primary: any ScanAdapter
    private let bestEffort: [any ScanAdapter]
    private let exclusions: PathExclusionMatcher

    public init(
        primary: any ScanAdapter,
        bestEffort: [any ScanAdapter] = [],
        exclusions: PathExclusionMatcher = .none
    ) {
        self.primary = primary
        self.bestEffort = bestEffort
        self.exclusions = exclusions
    }

    public func scan(progress: ScanProgress?) async throws -> [ScanResult] {
        try await scan(progress: progress, observer: nil)
    }

    public func scan(
        progress: ScanProgress?,
        observer: (any ScanProgressObserving)?
    ) async throws -> [ScanResult] {
        // Record each adapter's parent-chain resolution the moment that
        // adapter returns — not once at the tail — so a symlink swapped in
        // while a *later* best-effort adapter is still running can't be
        // captured as scan-time truth and slip past the pre-delete guard.
        // Recording is idempotent, so adapters that already record at item
        // creation (NativeScanAdapter) pass through unchanged.
        var combined = try await primary.scan(progress: progress, observer: observer)
            .map { $0.recordingScanTimeAncestry() }
        for adapter in bestEffort {
            do {
                let extra = try await adapter.scan(progress: progress, observer: observer)
                combined.append(contentsOf: extra.map { $0.recordingScanTimeAncestry() })
            } catch {
                // Best-effort: swallow so a missing tool or transient
                // executor issue can't bring down the whole scan.
            }
        }
        return exclusions.filter(combined)
    }
}
