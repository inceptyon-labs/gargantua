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
    /// IDs of processes currently being acted on. The row uses this to render
    /// a spinner inline so the user gets feedback while `kill(2)` runs.
    public private(set) var busyItemIDs: Set<String> = []

    private let scanner: any ProcessInventoryScanning
    private let actionExecutor: (any ProcessActionExecuting)?

    public init(
        scanner: any ProcessInventoryScanning = DefaultProcessInventoryScanner(),
        actionExecutor: (any ProcessActionExecuting)? = DefaultProcessActionExecutor()
    ) {
        self.scanner = scanner
        self.actionExecutor = actionExecutor
    }

    public func scan(metric: ProcessSortMetric, topN: Int?) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let scanner = self.scanner
        let result = await Task.detached(priority: .userInitiated) {
            await scanner.scan(metric: metric, topN: topN)
        }.value
        self.scan = result
    }

    public func clearSnapshot() {
        scan = nil
        busyItemIDs.removeAll()
    }

    /// Run a `ProcessAction` against `item`, marking the row busy for the
    /// duration. After a successful `.stop`, the session re-scans so the row
    /// disappears (or shows the orphaned-state if the source is still on
    /// disk). `.removeSource` does not re-scan — the caller is expected to
    /// navigate away to the Background Items pane.
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
            await scan(metric: metric, topN: topN)
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
