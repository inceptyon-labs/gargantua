import Foundation
import Observation

/// Top-level phases of the File Health flow.
public enum FileHealthPhase: Sendable, Equatable {
    case idle
    case scanning
    case results
    case cleaning
    case summary
    case error
}

/// Scan-lifecycle state shared across navigation for the File Health panel.
///
/// Mirrors `DeepCleanSessionState` so switching sidebar items doesn't reset
/// an in-progress or completed scan. Owned at the `MainContentView` level
/// and passed down to `FileHealthContainerView`.
@Observable @MainActor
public final class FileHealthContainerState {
    public var phase: FileHealthPhase = .idle
    public var scanProgress: ScanProgress = ScanProgress()
    public var scanResults: [ScanResult] = []
    public var scanWarnings: [String] = []
    public var errorMessage: String? = nil
    public var session: FileHealthSessionState = FileHealthSessionState()
    public var showConfirmation: Bool = false
    /// Set when a cleanup finishes; cleared on dismiss.
    public var cleanupResult: CleanupResult? = nil
    /// Results that survived the last cleanup (returned to after dismiss).
    public var cleanupRemainingResults: [ScanResult] = []
    public var cleanupRemainingWarnings: [String] = []

    public init() {}

    // MARK: - Transitions

    public func prepareForScan() {
        scanProgress = ScanProgress()
        scanResults = []
        scanWarnings = []
        errorMessage = nil
        cleanupResult = nil
        cleanupRemainingResults = []
        cleanupRemainingWarnings = []
        showConfirmation = false
        session.clear()
        phase = .scanning
    }

    /// Apply scan output. Mirrors the old `deriveScanState` logic:
    /// no results + errors → error; everything else → results (with warnings if any).
    public func finishScan(results: [ScanResult], errors: [String]) {
        if results.isEmpty && !errors.isEmpty {
            errorMessage = errors.joined(separator: "\n")
            phase = .error
        } else {
            scanResults = results
            scanWarnings = errors
            session.finishScan(results: results)
            phase = .results
        }
    }

    public func failScan(_ message: String) {
        errorMessage = message
        phase = .error
    }

    public func beginCleanup() {
        showConfirmation = false
        phase = .cleaning
    }

    public func finishCleanup(
        result: CleanupResult,
        remaining: [ScanResult],
        warnings: [String]
    ) {
        cleanupResult = result
        cleanupRemainingResults = remaining
        cleanupRemainingWarnings = warnings
        phase = .summary
    }

    public func dismissSummary() {
        if cleanupRemainingResults.isEmpty {
            clearResults()
        } else {
            scanResults = cleanupRemainingResults
            scanWarnings = cleanupRemainingWarnings
            cleanupResult = nil
            cleanupRemainingResults = []
            cleanupRemainingWarnings = []
            phase = .results
        }
    }

    public func clearResults() {
        scanProgress = ScanProgress()
        scanResults = []
        scanWarnings = []
        errorMessage = nil
        cleanupResult = nil
        cleanupRemainingResults = []
        cleanupRemainingWarnings = []
        showConfirmation = false
        session.clear()
        phase = .idle
    }
}
