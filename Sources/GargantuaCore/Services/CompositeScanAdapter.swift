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

    public init(primary: any ScanAdapter, bestEffort: [any ScanAdapter] = []) {
        self.primary = primary
        self.bestEffort = bestEffort
    }

    public func scan(progress: ScanProgress?) async throws -> [ScanResult] {
        try await scan(progress: progress, observer: nil)
    }

    public func scan(
        progress: ScanProgress?,
        observer: (any ScanProgressObserving)?
    ) async throws -> [ScanResult] {
        var combined = try await primary.scan(progress: progress, observer: observer)
        for adapter in bestEffort {
            do {
                let extra = try await adapter.scan(progress: progress, observer: observer)
                combined.append(contentsOf: extra)
            } catch {
                // Best-effort: swallow so a missing tool or transient
                // executor issue can't bring down the whole scan.
            }
        }
        return combined
    }
}
