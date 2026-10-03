import Foundation
import Observation

/// State shared by the AI Models view while users navigate around the app.
///
/// Mirrors `DeepCleanSessionState` so a scan triggered on the AI Models
/// screen survives sidebar navigation — coming back to the screen lands on
/// the cached results, not a fresh idle CTA. The header's Refresh / Rescan
/// buttons are the single way to re-run the scan.
@Observable @MainActor
public final class AIModelsState {
    public var phase: DeepCleanPhase = .idle
    public var scanProgress = ScanProgress()
    public var scanResults: [ScanResult]?
    public var scanDuration: TimeInterval = 0
    public var selectedResultIDs: Set<String> = []
    /// The results list's grouping, collapsed groups and search.
    public let listState = ScanBucketListState(groupingDefaultsKey: "results.grouping.aiModels", defaultGrouping: .folder)
    public var isScanning = false
    public var showConfirmation = false
    public var isCleaning = false
    public var activeCleanupMethod: CleanupMethod = .trash
    public var cleanupResult: CleanupResult?
    /// Live path-streaming view model backing the EventHorizon console
    /// during scan + cleaning phases. Persists across navigation alongside
    /// other session state.
    public let pathStream: PathStreamViewModel

    public init(pathStream: PathStreamViewModel = PathStreamViewModel()) {
        self.pathStream = pathStream
    }

    public func clearResults() {
        scanProgress = ScanProgress()
        scanDuration = 0
        scanResults = nil
        selectedResultIDs = []
        cleanupResult = nil
        showConfirmation = false
        activeCleanupMethod = .trash
        pathStream.clear()
        phase = .idle
    }

    public func prepareForScan() {
        isScanning = true
        scanProgress = ScanProgress()
        scanResults = nil
        selectedResultIDs = []
        cleanupResult = nil
        showConfirmation = false
        pathStream.clear()
        phase = .scanning
    }

    public func finishScan(results: [ScanResult], duration: TimeInterval) {
        scanDuration = duration
        listState.resetForNewResults()
        // Pre-check `safe` items so the user can fast-path the obvious wins.
        // AI model rules are mostly `review`, so this nudges nothing destructive.
        selectedResultIDs = Set(results.filter { $0.safety == .safe }.map(\.id))
        scanResults = results
        isScanning = false
        phase = .results
    }

    /// In-flight scan, so the console's Sever Tether can stop it.
    public var activeScanTask: Task<Void, Never>?

    /// Stops the running scan and returns to the start screen.
    public func cancelScan() {
        activeScanTask?.cancel()
        activeScanTask = nil
        isScanning = false
        scanProgress = ScanProgress()
        pathStream.clear()
        phase = .idle
    }

    public func failScan(_ message: String) {
        scanProgress.recordError(message)
        isScanning = false
        // Drop back to idle so the user sees the start screen + error banner
        // instead of a stuck "scanning" console.
        phase = .idle
    }

    public func beginCleanup(method: CleanupMethod) {
        showConfirmation = false
        isCleaning = true
        activeCleanupMethod = method
        pathStream.clear()
        phase = .cleaning
    }

    public func finishCleanup(result: CleanupResult) {
        isCleaning = false
        cleanupResult = result
        pruneCleaned(result)
        phase = .summary
    }

    /// Drop the items a clean (or an in-summary retry) removed out of
    /// `scanResults`, so dismissing the summary returns the user to the results
    /// list minus what was removed instead of forcing a full re-scan. Safe to
    /// call again on retry — it only ever removes succeeded ids.
    public func pruneCleaned(_ result: CleanupResult) {
        guard let current = scanResults else { return }
        let succeededIDs = Set(result.succeededItems.map(\.item.id))
        scanResults = current.filter { !succeededIDs.contains($0.id) }
        selectedResultIDs.subtract(succeededIDs)
    }

    /// License gate blocked the cleanup. Revert from the cleaning console
    /// back to the results list without discarding the scan.
    public func cancelCleanupForBlock() {
        isCleaning = false
        pathStream.clear()
        phase = .results
    }

    public func dismissSummary() {
        cleanupResult = nil
        showConfirmation = false
        activeCleanupMethod = .trash
        if let remaining = scanResults, !remaining.isEmpty {
            // Return to the results list so the user can keep working through
            // what's left without re-scanning.
            phase = .results
        } else {
            scanProgress = ScanProgress()
            scanDuration = 0
            scanResults = nil
            selectedResultIDs = []
            pathStream.clear()
            phase = .idle
        }
    }
}
