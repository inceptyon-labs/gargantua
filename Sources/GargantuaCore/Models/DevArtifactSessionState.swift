import Foundation
import Observation

/// State shared by the Dev Purge view while users navigate around the app.
///
/// Owned at the `MainContentView` level (mirrors `DeepCleanSessionState`) so a
/// sidebar nav away-and-back doesn't tear down an in-flight scan or cleanup:
/// the task's completion lands here rather than in deallocated view storage,
/// the summary survives navigation, and returning mid-clean re-renders the
/// cleaning console instead of an idle screen that could start a second
/// overlapping clean.
@Observable @MainActor
public final class DevArtifactSessionState {
    /// Smart-default lifecycle. Empty until ecosystem detection completes;
    /// then seeded from `DevArtifactDetection.detectEcosystems` plus the
    /// always-on cross-cutting set. The user is free to widen from there.
    public var selectedBucketIDs: Set<String> = []
    public var detectionState: EcosystemDetectionState = .pending
    /// Ecosystem ids the probe positively identified on disk. Used as a
    /// visual signal in the bucket list ("on disk" dot) and in the toolbar
    /// tally so the user can see which buckets are pre-selected because
    /// they were actually found, vs. which are available but absent.
    public var detectedEcosystemIDs: Set<String> = []
    /// Per-bucket size totals from the most recent scan. Keyed by bucket id.
    public var bucketEstimates: [String: Int64] = [:]
    public var scanProgress = ScanProgress()
    public var scanResults: [ScanResult]?
    public var scanDuration: TimeInterval = 0
    public var selectedResultIDs: Set<String> = []
    public var isScanRequested = false
    public var showConfirmation = false
    public var isCleaning = false
    public var activeCleanupMethod: CleanupMethod = .trash
    public var cleanupResult: CleanupResult?
    /// The last cleanup's audit entry couldn't be written; the summary says so.
    public var auditWriteFailed = false
    public var phase: DeepCleanPhase = .idle
    /// In-flight scan or cleanup task. Held so "Sever Tether" can cancel
    /// from inside the EventHorizon console. Always overwrite when starting
    /// new work so a stale handle can't leak across phases.
    public var activeTask: Task<Void, Never>?
    /// Live path-streaming view model backing the EventHorizon console
    /// during scan + cleaning phases. Persists across navigation alongside
    /// other session state.
    public let pathStream: PathStreamViewModel

    public init(pathStream: PathStreamViewModel = PathStreamViewModel()) {
        self.pathStream = pathStream
    }

    // MARK: - Transitions

    public func prepareForScan() {
        activeTask?.cancel()
        activeTask = nil
        isScanRequested = true
        showConfirmation = false
        scanProgress = ScanProgress()
        pathStream.clear()
        phase = .scanning
    }

    /// Publish a finished scan: pre-select safe items and pivot to results.
    /// `estimates` comes from the full (unfiltered) result set so the user
    /// sees what's available even in buckets they currently have unchecked.
    public func finishScan(
        results: [ScanResult],
        duration: TimeInterval,
        estimates: [String: Int64]
    ) {
        scanDuration = duration
        bucketEstimates = estimates
        selectedResultIDs = Set(results.filter { $0.safety == .safe }.map(\.id))
        scanResults = results
        isScanRequested = false
        phase = .results
    }

    public func failScan(_ message: String) {
        scanProgress.recordError(message)
        isScanRequested = false
        phase = .idle
    }

    public func beginCleanup(method: CleanupMethod) {
        activeTask?.cancel()
        activeTask = nil
        auditWriteFailed = false
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
        // Drop what was cleaned so Done returns to the remaining results, as
        // Deep Clean does, instead of discarding them and forcing a rescan.
        if let current = scanResults {
            let succeededIDs = Set(result.succeededItems.map(\.item.id))
            scanResults = current.filter { !succeededIDs.contains($0.id) }
            selectedResultIDs.subtract(succeededIDs)
        }
        phase = .summary
    }

    /// User-initiated abort from the EventHorizon console. Cancels the
    /// in-flight scan or cleanup task and rewinds to the category-selection
    /// idle screen. Items already cleaned during this run stay cleaned.
    public func severTether() {
        activeTask?.cancel()
        activeTask = nil
        isScanRequested = false
        isCleaning = false
        showConfirmation = false
        scanProgress = ScanProgress()
        scanDuration = 0
        scanResults = nil
        selectedResultIDs = []
        cleanupResult = nil
        activeCleanupMethod = .trash
        pathStream.clear()
        phase = .idle
    }

    public func dismissSummary() {
        cleanupResult = nil
        showConfirmation = false
        activeCleanupMethod = .trash
        pathStream.clear()
        if let remaining = scanResults, !remaining.isEmpty {
            phase = .results
        } else {
            scanResults = nil
            phase = .idle
        }
    }

    /// Back / cancel from the results view — drop results, keep bucket
    /// selection and estimates so the idle screen picks up where it was.
    /// Clears `showConfirmation` too: leaving it set would replay a stale
    /// confirmation modal the moment the next scan repopulates results.
    public func returnToIdle() {
        scanResults = nil
        showConfirmation = false
        pathStream.clear()
        phase = .idle
    }
}
