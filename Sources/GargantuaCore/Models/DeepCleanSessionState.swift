import Foundation
import Observation

/// Top-level phases of the Deep Clean flow. Mirrors `SmartUninstallerPhase` so
/// the same cosmic-themed views (`EventHorizonConsoleView`, singularity
/// summary, asymmetric phase transitions) can render the cleanup lifecycle.
public enum DeepCleanPhase: Sendable, Equatable {
    /// Pre-scan landing screen.
    case idle
    /// Scanning the filesystem against rules.
    case scanning
    /// Scan results are showing; user is reviewing buckets.
    case results
    /// Cleanup is executing.
    case cleaning
    /// Post-cleanup summary.
    case summary
}

/// State shared by the Deep Clean view while users navigate around the app.
@Observable @MainActor
public final class DeepCleanSessionState {
    public var phase: DeepCleanPhase = .idle
    public var scanProgress = ScanProgress()
    public var scanResults: [ScanResult]?
    public var scanDuration: TimeInterval = 0
    public var selectedResultIDs: Set<String> = []
    public var isScanning = false
    public var showConfirmation = false
    public var isCleaning = false
    public var activeCleanupMethod: CleanupMethod = .trash
    public var cleanupResult: CleanupResult?
    /// In-flight scan or cleanup task. Stored so "Sever Tether" can cancel it
    /// from the EventHorizon console. Cleared by `prepareForScan` /
    /// `beginCleanup` / `clearResults` so a stale handle from a prior phase
    /// can't be cancelled by accident.
    public var activeTask: Task<Void, Never>?
    /// Live path-streaming view model backing the EventHorizon console
    /// during scan + cleaning phases. Persists across navigation alongside
    /// other session state.
    public let pathStream: PathStreamViewModel

    public init(pathStream: PathStreamViewModel = PathStreamViewModel()) {
        self.pathStream = pathStream
    }

    public func clearResults() {
        activeTask?.cancel()
        activeTask = nil
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

    /// User-initiated abort from the EventHorizon console. Cancels the
    /// in-flight scan or cleanup task, resets state, and returns the surface
    /// to idle. Items that were already cleaned stay cleaned — partial state
    /// is intentional, the audit trail will reflect what actually ran.
    public func severTether() {
        activeTask?.cancel()
        activeTask = nil
        isScanning = false
        isCleaning = false
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
        activeTask?.cancel()
        activeTask = nil
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
        selectedResultIDs = Set(results.filter { $0.safety == .safe }.map(\.id))
        scanResults = results
        isScanning = false
        phase = .results
    }

    public func failScan(_ message: String) {
        scanProgress.recordError(message)
        isScanning = false
        // Drop back to idle so the user sees the start screen + error banner
        // instead of a stuck "scanning" console.
        phase = .idle
    }

    public func beginCleanup(method: CleanupMethod) {
        activeTask?.cancel()
        activeTask = nil
        showConfirmation = false
        isCleaning = true
        activeCleanupMethod = method
        pathStream.clear()
        phase = .cleaning
    }

    public func finishCleanup(result: CleanupResult) {
        activeTask = nil
        isCleaning = false
        cleanupResult = result
        // Drop the items we just cleaned out of scanResults so dismissing
        // the summary returns the user to the results view minus what was
        // removed — instead of forcing a full re-scan to see what's left.
        if let current = scanResults {
            let succeededIDs = Set(result.succeededItems.map(\.item.id))
            scanResults = current.filter { !succeededIDs.contains($0.id) }
            selectedResultIDs.subtract(succeededIDs)
        }
        phase = .summary
    }

    public func dismissSummary() {
        activeTask?.cancel()
        activeTask = nil
        cleanupResult = nil
        showConfirmation = false
        activeCleanupMethod = .trash
        if let remaining = scanResults, !remaining.isEmpty {
            // Return to the results bucket view so the user can keep
            // working through what's left without re-scanning.
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
