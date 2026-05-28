import Foundation
import OSLog
import SwiftUI

let duplicateFinderContainerLogger = Logger(subsystem: "com.gargantua.core", category: "DuplicateFinderContainerView")

// MARK: - Duplicate Finder Container View

/// Renders the Duplicate Finder flow against a `DuplicateFinderContainerState`
/// owned by `MainContentView` so the cache, in-flight task, and last-scan
/// timestamp survive sidebar navigation.
///
/// Builds a `ScanEngine` pipeline containing `FclonesAdapter` (per PRD §8.4
/// sequential pipeline rule) and renders one of four phases:
///   1. **Idle** — "Scan for duplicates" call-to-action, or a "View previous
///      results / Scan again" pair when a cached scan exists.
///   2. **Scanning** — progress indicator.
///   3. **Results** — `DuplicateFinderView` with the discovered groups.
///   4. **Error** — binary-missing or scan-failure message with retry.
public struct DuplicateFinderContainerView: View {
    public let scanRoots: [URL]?
    public let state: DuplicateFinderContainerState
    @Binding public var selectedIDs: Set<String>
    public let engineFactory: (_ scanRoots: [URL]) throws -> any ScanAdapter
    public let onSendToTrash: (([ScanResult]) -> Void)?
    public let onExplain: ((ScanResult) -> Void)?
    public let persistence: PersistenceController?
    public let onCleanupCompleted: ((CleanupResult) -> Void)?

    @State private var showConfirmation = false
    @State private var pendingTrashItems: [ScanResult] = []

    public init(
        state: DuplicateFinderContainerState,
        scanRoots: [URL]? = nil,
        selectedIDs: Binding<Set<String>>,
        engine: (any ScanAdapter)? = nil,
        onSendToTrash: (([ScanResult]) -> Void)? = nil,
        onExplain: ((ScanResult) -> Void)? = nil,
        persistence: PersistenceController? = nil,
        onCleanupCompleted: ((CleanupResult) -> Void)? = nil
    ) {
        self.state = state
        self.scanRoots = scanRoots
        self._selectedIDs = selectedIDs
        self.onSendToTrash = onSendToTrash
        self.onExplain = onExplain
        self.persistence = persistence
        self.onCleanupCompleted = onCleanupCompleted
        if let engine {
            self.engineFactory = { _ in engine }
        } else {
            self.engineFactory = Self.defaultEngine
        }
    }

    private var trashHandler: (([ScanResult]) -> Void) {
        onSendToTrash ?? { items in
            pendingTrashItems = items
            showConfirmation = true
        }
    }

    public var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            Group {
                switch state.scanState {
                case .idle:
                    DuplicateFinderIdleView(
                        subtitle: idleSubtitle,
                        hasCachedResults: state.cachedResults != nil,
                        onShowCachedResults: showCachedResults,
                        onStartScan: startScan
                    )
                case .scanning:
                    DuplicateFinderScanningView(progress: state.scanProgress)
                case .results(let results):
                    DuplicateFinderView(
                        results: results,
                        selectedIDs: $selectedIDs,
                        onSendToTrash: trashHandler,
                        onExplain: onExplain,
                        onBack: { state.returnToIdle() },
                        onRefresh: refreshResults,
                        onRescan: startScan,
                        persistence: persistence
                    )
                case .error(let message):
                    DuplicateFinderErrorView(message: message, onRetry: startScan)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showConfirmation, !pendingTrashItems.isEmpty {
                ConfirmationModalView(
                    items: pendingTrashItems,
                    onConfirm: { method in
                        showConfirmation = false
                        let items = pendingTrashItems
                        pendingTrashItems = []
                        Task { await trashConfirmed(items, method: method) }
                    },
                    onCancel: {
                        showConfirmation = false
                        pendingTrashItems = []
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showConfirmation)
    }

    private func trashConfirmed(_ items: [ScanResult], method: CleanupMethod) async {
        let engine = CleanupEngine()
        let result = await engine.clean(items, method: method)
        do {
            try AuditWriter().record(result: result)
        } catch {
            duplicateFinderContainerLogger.warning("Failed to write audit entry: \(error.localizedDescription)")
        }
        selectedIDs.subtract(result.succeededItems.map(\.item.id))
        refreshResults()
        onCleanupCompleted?(result)
    }
}
