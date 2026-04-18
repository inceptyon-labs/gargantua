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
        showConfirmation = false
        isCleaning = true
        activeCleanupMethod = method
        pathStream.clear()
        phase = .cleaning
    }

    public func finishCleanup(result: CleanupResult) {
        isCleaning = false
        cleanupResult = result
        phase = .summary
    }

    public func dismissSummary() {
        scanProgress = ScanProgress()
        scanDuration = 0
        cleanupResult = nil
        scanResults = nil
        selectedResultIDs = []
        activeCleanupMethod = .trash
        pathStream.clear()
        phase = .idle
    }
}
