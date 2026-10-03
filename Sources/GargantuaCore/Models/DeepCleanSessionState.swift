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
    public var scanResults: [ScanResult]? {
        didSet { blockedAppsByID = Self.blockedApps(in: scanResults) }
    }

    /// `blockedByApp` per result ID, rebuilt whenever `scanResults` changes so
    /// per-row and confirmation-time lookups don't search the whole list.
    private var blockedAppsByID: [String: BlockedApp] = [:]
    public var scanDuration: TimeInterval = 0
    public var selectedResultIDs: Set<String> = []
    /// Per-result removability, reconciled at scan time (protected roots,
    /// `protected` safety, and the privileged allowlist). View-only items are
    /// surfaced but never selectable or executed. Keyed by `ScanResult.id`;
    /// a missing entry means `.removable`.
    public var removability: [String: Removability] = [:]
    /// Items whose blocking app the user quit this session — they unlock in place
    /// (no re-scan) and are auto-selected so they're included on the next clean.
    public var unblockedResultIDs: Set<String> = []
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
    private let appTerminator: any RunningApplicationTerminating

    public init(
        pathStream: PathStreamViewModel = PathStreamViewModel(),
        appTerminator: any RunningApplicationTerminating = WorkspaceRunningApplicationTerminator()
    ) {
        self.pathStream = pathStream
        self.appTerminator = appTerminator
    }

    public func clearResults() {
        activeTask?.cancel()
        activeTask = nil
        scanProgress = ScanProgress()
        scanDuration = 0
        scanResults = nil
        selectedResultIDs = []
        removability = [:]
        unblockedResultIDs = []
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
        removability = [:]
        unblockedResultIDs = []
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
        removability = [:]
        unblockedResultIDs = []
        cleanupResult = nil
        showConfirmation = false
        pathStream.clear()
        phase = .scanning
    }

    /// - Parameter precomputedRemovability: the reconciled map when the caller
    ///   already built it off the main actor; reconciled here otherwise.
    public func finishScan(
        results: [ScanResult],
        duration: TimeInterval,
        precomputedRemovability: [String: Removability]? = nil
    ) {
        scanDuration = duration
        // Reconcile removability fresh each scan so user-added protected roots
        // are current. View-only items are excluded from the default selection;
        // only removable, rule-`safe` items pre-select.
        let map = precomputedRemovability ?? RemovabilityReconciler().map(for: results)
        removability = map
        unblockedResultIDs = []
        selectedResultIDs = Set(
            results
                .filter {
                    $0.safety == .safe
                        && (map[$0.id]?.isRemovable ?? true)
                        && $0.blockedByApp == nil
                }
                .map(\.id)
        )
        scanResults = results
        isScanning = false
        phase = .results
    }

    /// Whether the user may select this result for cleanup. View-only items
    /// (protected roots, protected safety, non-allowlisted system paths) and
    /// items blocked by a running app cannot be selected.
    public func isSelectable(_ id: String) -> Bool {
        guard blockedApp(for: id) == nil else { return false }
        return removability[id]?.isRemovable ?? true
    }

    /// The app currently blocking this item, unless its app was already quit
    /// this session.
    public func blockedApp(for id: String) -> BlockedApp? {
        guard !unblockedResultIDs.contains(id) else { return nil }
        return blockedAppsByID[id]
    }

    private static func blockedApps(in results: [ScanResult]?) -> [String: BlockedApp] {
        var byID: [String: BlockedApp] = [:]
        for result in results ?? [] where byID[result.id] == nil {
            if let app = result.blockedByApp {
                byID[result.id] = app
            }
        }
        return byID
    }

    /// Quit the app blocking `id`. On success, unlock and select every item that
    /// app was holding (not just this one), in place — no re-scan — so they're
    /// included when the user proceeds to clean. Returns whether the app exited.
    public func quitBlockingApp(for id: String) async -> Bool {
        guard let app = blockedApp(for: id) else { return true }
        let exited = await appTerminator.terminateRunningApplications(
            bundleIdentifier: app.bundleID,
            timeout: 10
        )
        guard exited else { return false }
        let affectedResults = (scanResults ?? []).filter { $0.blockedByApp?.bundleID == app.bundleID }
        unblockedResultIDs.formUnion(affectedResults.map(\.id))
        // Pre-select only what a fresh scan would: safe items. Review items
        // the app was holding unlock but stay unselected.
        for result in affectedResults where result.safety == .safe && isSelectable(result.id) {
            selectedResultIDs.insert(result.id)
        }
        return true
    }

    /// The reason a result is view-only, if it is. `nil` when removable.
    public func viewOnlyReason(_ id: String) -> String? {
        removability[id]?.viewOnlyReason
    }

    /// Select a result if it is removable; view-only items are ignored so a
    /// "select all" can never queue something that will fail on execute.
    public func select(_ id: String) {
        guard isSelectable(id) else { return }
        selectedResultIDs.insert(id)
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

    /// Removes results from the list and the selection (e.g. a path the user
    /// just excluded).
    public func dropResults(_ ids: Set<String>) {
        if let current = scanResults {
            scanResults = current.filter { !ids.contains($0.id) }
        }
        selectedResultIDs.subtract(ids)
    }

    /// Folds a summary-screen retry into the session: recovered items leave the
    /// results list and selection, and the stored cleanup result reflects the
    /// retry, so coming back to the summary doesn't offer them again.
    public func applyRetry(_ retry: CleanupResult) {
        let succeededIDs = Set(retry.succeededItems.map(\.item.id))
        if let current = scanResults {
            scanResults = current.filter { !succeededIDs.contains($0.id) }
        }
        selectedResultIDs.subtract(succeededIDs)
        if let previous = cleanupResult {
            cleanupResult = CleanupResult(
                itemResults: CleanupSummaryView.mergeRetry(into: previous.itemResults, retry: retry.itemResults),
                cleanupMethod: previous.cleanupMethod
            )
        }
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
            removability = [:]
            unblockedResultIDs = []
            pathStream.clear()
            phase = .idle
        }
    }
}
