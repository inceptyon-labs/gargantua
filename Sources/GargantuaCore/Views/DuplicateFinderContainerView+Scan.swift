import Foundation
import OSLog
import SwiftUI

extension DuplicateFinderContainerView {
    func startScan() {
        // The state class cancels any in-flight task, bumps the generation,
        // and wipes the cache up-front (a Rescan must not leave stale data
        // around if the new scan ultimately fails).
        state.prepareForScan()
        let generation = state.scanGeneration

        let roots = resolvedScanRoots()
        let engine: any ScanAdapter
        do {
            engine = try engineFactory(roots)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            duplicateFinderContainerLogger.error("Failed to build duplicate-scan engine: \(message, privacy: .public)")
            state.failScan(message)
            return
        }

        // Reset selection so a stale scan's ids can't point into a new result set.
        selectedIDs = []
        let progress = state.scanProgress

        state.activeScanTask = Task {
            let resultsOrError: Result<([ScanResult], [String]), Error>
            do {
                let results = try await engine.scan(progress: progress, observer: nil)
                let errors = await MainActor.run { progress.errors }
                resultsOrError = .success((results, errors))
            } catch {
                resultsOrError = .failure(error)
            }

            await MainActor.run {
                // Drop any completion that belongs to a superseded scan.
                guard generation == state.scanGeneration else { return }
                switch resultsOrError {
                case .success(let (results, errors)):
                    state.finishScan(results: results, errors: errors)
                case .failure(let error):
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    duplicateFinderContainerLogger.error("Duplicate scan failed: \(message, privacy: .public)")
                    state.failScan(message)
                }
                state.activeScanTask = nil
            }
        }
    }

    /// Re-stat every cached path off the main actor, drop missing ones, and
    /// publish the pruned list. Cheap relative to a full fclones run — even
    /// for tens of thousands of paths it's a few hundred ms of stat() calls.
    func refreshResults() {
        guard !state.isRefreshing, case .results(let current) = state.scanState else { return }
        state.isRefreshing = true

        let snapshot = current
        Task.detached(priority: .userInitiated) {
            let paths = snapshot.map(\.path)
            var existing: Set<String> = []
            existing.reserveCapacity(paths.count)
            let fileManager = FileManager.default
            for path in paths where fileManager.fileExists(atPath: path) {
                existing.insert(path)
            }
            let pruned = DuplicateFinderRefresh.prune(
                results: snapshot,
                existingPaths: existing
            )

            await MainActor.run {
                // Bail if a Rescan landed while we were stat()-ing — the new
                // scan's results win.
                guard case .results = state.scanState else {
                    state.isRefreshing = false
                    return
                }
                selectedIDs = DuplicateFinderRefresh.sanitizeSelection(
                    selectedIDs: selectedIDs,
                    against: pruned
                )
                state.applyRefresh(pruned: pruned)
                state.isRefreshing = false
            }
        }
    }

    /// Re-enter results from idle using the cached scan output, no work needed.
    func showCachedResults() {
        guard let cached = state.cachedResults else { return }
        // Sanitize selection in case anything changed about the cached set
        // (e.g. a previous refresh dropped rows while idle).
        selectedIDs = DuplicateFinderRefresh.sanitizeSelection(
            selectedIDs: selectedIDs,
            against: cached
        )
        state.showCachedResults()
    }

    func resolvedScanRoots() -> [URL] {
        if let scanRoots, !scanRoots.isEmpty {
            return scanRoots
        }
        return PathExpander.defaultScanRoots()
    }

    /// Build the default pipeline: a `ScanEngine` wrapping `FclonesAdapter`.
    ///
    /// Wrapped in an engine rather than returned as a bare adapter so future
    /// work can compose additional duplicate-aware adapters without changing
    /// the call site.
    static func defaultEngine(scanRoots: [URL]) throws -> any ScanAdapter {
        let fclones = try FclonesAdapter.autoDetect(scanRoots: scanRoots)
        return ScanEngine(adapters: [fclones])
    }
}
