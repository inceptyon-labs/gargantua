import Foundation
import Observation

/// Top-level phases of the Duplicate Finder flow.
public enum DuplicateFinderScanState: Sendable {
    case idle
    case scanning
    case results([ScanResult])
    case error(String)
}

/// Scan-lifecycle state shared across navigation for the Duplicate Finder.
///
/// Owned at the `MainContentView` level (mirrors `FileHealthContainerState`,
/// `DeepCleanSessionState`, `SmartUninstallerViewModel`) so a sidebar nav
/// away-and-back doesn't tear down the cache or in-flight scan task. The
/// view layer reads these properties directly via `@Bindable`/`@Observable`.
@Observable @MainActor
public final class DuplicateFinderContainerState {
    public var scanState: DuplicateFinderScanState = .idle
    public var scanProgress: ScanProgress = ScanProgress()

    /// Generation tag used to drop completion of a superseded scan. Bumped
    /// on every `prepareForScan()`; only the matching completion is allowed
    /// to publish state.
    public var scanGeneration: Int = 0

    /// In-flight scan task, retained so a Rescan can cancel its predecessor.
    public var activeScanTask: Task<Void, Never>?

    /// Last successful scan, retained across Back / sidebar navigation so
    /// re-entering the view doesn't re-run fclones. Cleared at the start of
    /// every Rescan.
    public var cachedResults: [ScanResult]?
    public var cachedAt: Date?

    /// True while a Refresh is in flight; used to prevent overlapping prunes.
    public var isRefreshing: Bool = false

    public init() {}

    // MARK: - Transitions

    /// Reset selection-irrelevant state and bump the generation so any
    /// in-flight scan's completion is ignored. Caller is responsible for
    /// clearing selection (which lives at the parent view level).
    public func prepareForScan() {
        activeScanTask?.cancel()
        scanGeneration &+= 1
        cachedResults = nil
        cachedAt = nil
        scanProgress = ScanProgress()
        scanState = .scanning
    }

    /// Apply a finished scan's outcome, replacing the cache on success.
    /// Mirrors the original `deriveScanState` logic — silent fclones
    /// failures (empty results + errors) become `.error`, partial successes
    /// surface as `.results` with warnings preserved on `scanProgress`.
    public func finishScan(results: [ScanResult], errors: [String]) {
        let next = Self.deriveScanState(results: results, errors: errors)
        scanState = next
        if case .results(let results) = next {
            cachedResults = results
            cachedAt = Date()
        }
    }

    public func failScan(_ message: String) {
        scanState = .error(message)
    }

    /// Replace the live + cached results after a successful Refresh prune.
    public func applyRefresh(pruned: [ScanResult]) {
        scanState = .results(pruned)
        cachedResults = pruned
        cachedAt = Date()
    }

    /// Re-enter results from idle using the cached scan output.
    public func showCachedResults() {
        guard let cachedResults else { return }
        scanState = .results(cachedResults)
    }

    public func returnToIdle() {
        scanState = .idle
    }

    // MARK: - Pure helpers

    /// Derive the terminal scan state from a finished scan's results + the
    /// errors an adapter recorded on `ScanProgress`.
    ///
    /// `FclonesAdapter` reports hard failures (timeout, non-zero exit, JSON
    /// parse failure) by appending to `progress.errors` and returning `[]`
    /// rather than throwing. If we don't translate that into `.error`, a
    /// silent scan failure would render as "No duplicates found" — the
    /// user would never know something broke.
    public nonisolated static func deriveScanState(
        results: [ScanResult],
        errors: [String]
    ) -> DuplicateFinderScanState {
        if results.isEmpty, !errors.isEmpty {
            return .error(errors.joined(separator: "\n"))
        }
        return .results(results)
    }
}
