import Foundation

/// Lightweight async wrapper around `ProcessInventoryScanning` so the view can
/// kick scans off the main actor and observe the result via `@Observable`.
/// Pulled into its own file so `ProcessInventoryView` stays under SwiftLint's
/// `file_length` cap.
@MainActor
@Observable
public final class ProcessInventorySession {
    public private(set) var scan: ProcessInventoryScan?
    public private(set) var isScanning = false
    /// True while `isScanning` is a post-action refresh shown over the list.
    public private(set) var isRefreshingInPlace = false
    /// Results of the active full-table search, or `nil` when not searching.
    /// Kept separate from `scan` so clearing the query restores the snapshot
    /// without a re-sample.
    public private(set) var searchResults: ProcessInventoryScan?
    /// True while a search find-pass is sampling, so the field can show a
    /// spinner without blanking the current list.
    public private(set) var isSearching = false
    /// IDs of processes currently being acted on. The row uses this to render
    /// a spinner inline so the user gets feedback while `kill(2)` runs.
    public private(set) var busyItemIDs: Set<String> = []
    /// The metric the snapshot is ranked by. Lives here, with the snapshot,
    /// so the toggle still matches the list after navigating away and back.
    public var sortMetric: ProcessSortMetric = .cpu

    /// Cap on search matches resolved + displayed. Generous enough to cover any
    /// real query; guards against resolving identity for hundreds of rows when
    /// a one-character query matches almost everything.
    public static let searchResultLimit = 200

    private let scanner: any ProcessInventoryScanning
    private let actionExecutor: (any ProcessActionExecuting)?

    /// Generation tag for search passes. A pass only publishes its results
    /// (or clears the spinner) if no newer pass superseded it while its
    /// detached find-pass ran — `Task.isCancelled` alone can't cover
    /// session-initiated re-runs like the post-stop refresh.
    private var searchGeneration = 0
    /// Trimmed query + metric of the most recent search pass, retained so a
    /// successful stop can re-run the active search after its re-scan. The
    /// metric is stored too: the stop captured its metric when the action
    /// began, and replaying that against a search the user has since
    /// re-sorted would overwrite the newer ordering.
    private var activeSearch: (query: String, metric: ProcessSortMetric)?

    public init(
        scanner: any ProcessInventoryScanning = DefaultProcessInventoryScanner(),
        actionExecutor: (any ProcessActionExecuting)? = DefaultProcessActionExecutor()
    ) {
        self.scanner = scanner
        self.actionExecutor = actionExecutor
    }

    /// - Parameter inPlace: a refresh after an action, which keeps the list
    ///   on screen (and its scroll position) instead of the sampling view.
    public func scan(metric: ProcessSortMetric, topN: Int?, inPlace: Bool = false) async {
        guard !isScanning else { return }
        isScanning = true
        isRefreshingInPlace = inPlace
        defer {
            isScanning = false
            isRefreshingInPlace = false
        }

        let scanner = self.scanner
        let result = await Task.detached(priority: .userInitiated) {
            await scanner.scan(metric: metric, topN: topN)
        }.value
        self.scan = result
    }

    public func clearSnapshot() {
        scan = nil
        clearSearch()
        busyItemIDs.removeAll()
    }

    /// Run a full-table search and publish the matches. The view debounces and
    /// cancels via `.task(id:)`; the generation tag additionally drops a
    /// superseded pass that was already past cancellation when the newer one
    /// started, so it can neither overwrite the newer results nor clear the
    /// spinner the newer pass still owns.
    public func search(query: String, metric: ProcessSortMetric) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clearSearch(); return }

        searchGeneration &+= 1
        let generation = searchGeneration
        activeSearch = (trimmed, metric)
        isSearching = true
        defer {
            if generation == searchGeneration { isSearching = false }
        }

        // `scanner.search` is a nonisolated async method, so awaiting it
        // directly runs it off the main actor (SE-0338) while keeping it a
        // child of the caller's `.task(id:)`. A superseded query then cancels
        // this pass instead of leaving a detached task to finish sampling and
        // resolving signatures whose results are already moot.
        let result = await scanner.search(query: trimmed, metric: metric, limit: Self.searchResultLimit)

        // A newer query may have superseded this one while the find pass ran;
        // don't let the stale result overwrite it.
        if Task.isCancelled || generation != searchGeneration { return }
        searchResults = result
    }

    /// Drop search state and fall back to showing the captured snapshot.
    /// Bumps the generation so an in-flight pass can't resurrect the
    /// results it was computing.
    public func clearSearch() {
        searchGeneration &+= 1
        activeSearch = nil
        searchResults = nil
        isSearching = false
    }

    /// Run a `ProcessAction` against `item`, marking the row busy for the
    /// duration. After a successful `.stop`, the session re-scans (and
    /// re-runs any active search) so the row disappears (or shows the
    /// orphaned-state if the source is still on disk). `.removeSource` does
    /// not re-scan — the caller is expected to navigate away to the
    /// Background Items pane.
    public func perform(
        _ action: ProcessAction,
        on item: ProcessItem,
        metric: ProcessSortMetric,
        topN: Int?
    ) async -> ProcessActionOutcome {
        guard let actionExecutor else {
            return ProcessActionOutcome(
                processID: item.id,
                action: action,
                succeeded: false,
                error: "Process action executor is not configured."
            )
        }
        busyItemIDs.insert(item.id)
        defer { busyItemIDs.remove(item.id) }

        let outcome: ProcessActionOutcome
        switch action {
        case .stop:
            outcome = await actionExecutor.stop(item)
        case .removeSource:
            outcome = await actionExecutor.removeSource(item)
        }

        if outcome.succeeded, action == .stop {
            await scan(metric: metric, topN: topN, inPlace: true)
            // The visible list may be showing search results; re-run the
            // active search so the stopped row disappears instead of
            // lingering with a stale (possibly recycled) PID that a second
            // Stop would signal. Uses the stored query AND metric — the
            // user may have re-sorted since this stop began.
            if let active = activeSearch {
                await search(query: active.query, metric: active.metric)
            }
        }
        return outcome
    }

    /// Re-rank the captured snapshot in place. Avoids the 500 ms sample
    /// window when the user just wants to toggle between CPU and Memory.
    /// If the original scan was top-N capped, this re-sorts that same slice.
    public func resort(by metric: ProcessSortMetric) {
        guard let current = scan else { return }
        if current.sortedBy == metric { return }
        let resorted = Self.rank(current.items, by: metric)
        self.scan = ProcessInventoryScan(
            items: resorted,
            totalProcessCount: current.totalProcessCount,
            sortedBy: metric,
            topN: current.topN,
            scannedAt: current.scannedAt
        )
    }

    /// Mirrors `DefaultProcessInventoryScanner.rank` so the in-place re-sort
    /// agrees with the scanner's tie-break ordering. Keep these aligned.
    private static func rank(_ items: [ProcessItem], by metric: ProcessSortMetric) -> [ProcessItem] {
        items.sorted { lhs, rhs in
            let lhsP = DefaultProcessInventoryScanner.primary(lhs, metric: metric)
            let rhsP = DefaultProcessInventoryScanner.primary(rhs, metric: metric)
            if lhsP != rhsP { return lhsP > rhsP }
            let lhsS = DefaultProcessInventoryScanner.secondary(lhs, metric: metric)
            let rhsS = DefaultProcessInventoryScanner.secondary(rhs, metric: metric)
            if lhsS != rhsS { return lhsS > rhsS }
            let nameCmp = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameCmp != .orderedSame { return nameCmp == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}

// MARK: - Synthetic ScanResult bridge

extension ProcessItem {
    /// Convert to a `ScanResult` so the existing `AIExplanationController`
    /// can drive the AI fallback sheet without a parallel pipeline. This is
    /// strictly a presentation bridge — nothing in the cleanup engine ever
    /// reads a synthetic result.
    public func toScanResult() -> ScanResult {
        let attribution = SourceAttribution(
            name: identity?.vendorDisplayName ?? identity?.bundleName ?? command,
            bundleID: identity?.bundleIdentifier,
            verifySignature: false
        )
        let categoryName: String = {
            switch launchSource {
            case .launchd: "background_process_launchd"
            case .foregroundApp: "background_process_foreground"
            case .userSession: "background_process_user_session"
            case .childProcess: "background_process_child"
            case .unknown: "background_process_unknown"
            }
        }()
        // Sort reason tags for deterministic output — `Set.map` order varies
        // between runs and would otherwise leak nondeterminism into the AI
        // prompt.
        var tags = reasons.map(\.rawValue).sorted()
        tags.append("confidence:\(launchConfidence.rawValue)")
        return ScanResult(
            id: id,
            name: displayName,
            path: executablePath ?? command,
            size: 0,
            safety: safety,
            confidence: explanationConfidence,
            explanation: explanation,
            source: attribution,
            lastAccessed: nil,
            category: categoryName,
            tags: tags,
            regenerates: false,
            regenerateCommand: nil
        )
    }

    /// Heuristic confidence for the explanation sheet. Identity + bundle
    /// present → 90, signed but unbundled → 70, unsigned → 40, no identity
    /// → 30. Used only in the synthetic bridge.
    private var explanationConfidence: Int {
        guard let identity else { return 30 }
        if identity.bundlePath != nil, identity.vendor != .unsigned { return 90 }
        if identity.vendor == .unsigned { return 40 }
        return 70
    }
}
