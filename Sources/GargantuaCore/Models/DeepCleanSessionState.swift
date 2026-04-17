import Foundation
import Observation

/// State shared by the Deep Clean view while users navigate around the app.
@Observable @MainActor
public final class DeepCleanSessionState {
    public var scanProgress = ScanProgress()
    public var scanResults: [ScanResult]?
    public var scanDuration: TimeInterval = 0
    public var selectedResultIDs: Set<String> = []
    public var isScanning = false
    public var showConfirmation = false
    public var isCleaning = false
    public var activeCleanupMethod: CleanupMethod = .trash
    public var cleanupResult: CleanupResult?

    public init() {}

    public func clearResults() {
        scanResults = nil
        selectedResultIDs = []
        cleanupResult = nil
        showConfirmation = false
        activeCleanupMethod = .trash
    }

    public func prepareForScan() {
        isScanning = true
        scanProgress = ScanProgress()
        scanResults = nil
        selectedResultIDs = []
        cleanupResult = nil
        showConfirmation = false
    }

    public func finishScan(results: [ScanResult], duration: TimeInterval) {
        scanDuration = duration
        selectedResultIDs = Set(results.filter { $0.safety == .safe }.map(\.id))
        scanResults = results
        isScanning = false
    }

    public func failScan(_ message: String) {
        scanProgress.recordError(message)
        isScanning = false
    }

    public func beginCleanup(method: CleanupMethod) {
        showConfirmation = false
        isCleaning = true
        activeCleanupMethod = method
    }

    public func finishCleanup(result: CleanupResult) {
        isCleaning = false
        cleanupResult = result
    }

    public func dismissSummary() {
        cleanupResult = nil
        scanResults = nil
        selectedResultIDs = []
        activeCleanupMethod = .trash
    }
}
