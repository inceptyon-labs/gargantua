import Foundation
import GargantuaLicensing
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
    @State private var blockedReason: BlockReason?
    @State private var auditWriteFailed = false

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
                case .cleaning:
                    DuplicateFinderCleaningView()
                case .summary(let result, let priorResults):
                    ScrollView {
                        CleanupSummaryView(
                            result: result,
                            auditWriteFailed: auditWriteFailed,
                            onExplain: onExplain,
                            onDismiss: { dismissCleanupSummary(priorResults) }
                        )
                        .padding(GargantuaSpacing.space5)
                    }
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
        .destructiveActionGate(reason: $blockedReason)
    }

    private func trashConfirmed(_ items: [ScanResult], method: CleanupMethod) async {
        // License gate fronts the send-to-trash. On blocked, refuse the delete
        // and present the Unlock sheet instead.
        if let reason = await DestructiveActionGate.blockReason() {
            blockedReason = reason
            return
        }
        // Remember the list to return to, and show a busy phase — the results
        // view is otherwise fully interactive while the engine runs.
        guard let priorResults = state.beginCleanup() else { return }

        let engine = CleanupEngine(privilegedHelper: XPCPrivilegedUninstallHelper())
        let result = await engine.clean(items, method: method)
        do {
            try AuditWriter().record(result: result)
            auditWriteFailed = false
        } catch {
            auditWriteFailed = true
            duplicateFinderContainerLogger.warning("Failed to write audit entry: \(error.localizedDescription)")
        }
        selectedIDs.subtract(result.succeededItems.map(\.item.id))
        // Route through the shared summary rather than dropping straight back
        // into the list. This is the surface where deleting the wrong copy is
        // unrecoverable, so a failed delete must be reported, not left to
        // reappear silently as an unchanged row.
        state.finishCleanup(result: result, returningTo: priorResults)
        onCleanupCompleted?(result)
    }

    private func dismissCleanupSummary(_ priorResults: [ScanResult]) {
        state.dismissSummary(showing: priorResults)
        // Prune paths that are actually gone now that we are back on the list.
        refreshResults()
    }
}

/// Busy state shown while a confirmed delete runs.
struct DuplicateFinderCleaningView: View {
    var body: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            AccretionDiskView(activityRate: 24, size: 56, color: GargantuaColors.accent)
            Text("Removing selected duplicates…")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Removing selected duplicates")
    }
}
