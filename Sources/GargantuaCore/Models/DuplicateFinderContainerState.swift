import Foundation
import Observation

/// Top-level phases of the Duplicate Finder flow.
public enum DuplicateFinderScanState: Sendable {
    case idle
    case scanning
    case results([ScanResult])
    /// A confirmed delete is in flight. Without this the results list stays
    /// fully interactive and looks inert while `CleanupEngine.clean` runs.
    case cleaning
    /// Terminal state of a delete, rendered through the shared
    /// `CleanupSummaryView` so failures are reported the way every other
    /// destructive surface reports them. Carries the results to return to
    /// when the user dismisses the summary.
    case summary(CleanupResult, returningTo: [ScanResult])
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

    /// Enter the busy phase for a confirmed delete, remembering the list to
    /// come back to. Returns the remembered results, or `nil` when the caller
    /// is not on the results screen and the delete should not proceed.
    @discardableResult
    public func beginCleanup() -> [ScanResult]? {
        guard case .results(let current) = scanState else { return nil }
        scanState = .cleaning
        return current
    }

    /// Show the cleanup summary. Deleting the wrong copy of a duplicate is
    /// unrecoverable, so this surface must report failures rather than
    /// silently leaving failed rows in the list.
    public func finishCleanup(result: CleanupResult, returningTo results: [ScanResult]) {
        scanState = .summary(result, returningTo: results)
    }

    /// Leave the summary and go back to the (refreshed) duplicate list.
    public func dismissSummary(showing results: [ScanResult]) {
        scanState = .results(results)
        cachedResults = results
        cachedAt = Date()
    }

    /// Replace the live + cached results after a successful Refresh prune —
    /// unless a Rescan superseded the refresh while it ran (generation
    /// mismatch, same guard as the scan completion) or the user navigated
    /// off the results state. Clears `isRefreshing` either way. Returns
    /// whether the prune was applied.
    @discardableResult
    public func applyRefresh(pruned: [ScanResult], generation: Int) -> Bool {
        isRefreshing = false
        guard generation == scanGeneration, case .results = scanState else { return false }
        scanState = .results(pruned)
        cachedResults = pruned
        cachedAt = Date()
        return true
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
