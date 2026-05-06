import Foundation
import SwiftUI

// MARK: - File Health Container View

/// Scan-state owner for the File Health panel.
///
/// Accepts an externally owned `FileHealthContainerState` so scan results
/// survive sidebar navigation — switching away and back does not reset the
/// phase or discard findings.
public struct FileHealthContainerView: View {
    public typealias ClusterSuggestionHandler = @MainActor ([FileHealthClusterSummary]) async -> [FileHealthClusterSuggestion]

    public let state: FileHealthContainerState
    public let scanRoots: [URL]?
    public let profile: CleanupProfile
    public let engineFactory: (_ scanRoots: [URL], _ profile: CleanupProfile) throws -> any ScanAdapter
    public let onExplain: ((ScanResult) -> Void)?
    public let onSuggestClusters: ClusterSuggestionHandler?

    @State private var scanCoordinator = FileHealthScanCoordinator()

    public init(
        state: FileHealthContainerState,
        scanRoots: [URL]? = nil,
        profile: CleanupProfile = .deep,
        engine: (any ScanAdapter)? = nil,
        onExplain: ((ScanResult) -> Void)? = nil,
        onSuggestClusters: ClusterSuggestionHandler? = nil
    ) {
        self.state = state
        self.scanRoots = scanRoots
        self.profile = profile
        self.onExplain = onExplain
        self.onSuggestClusters = onSuggestClusters
        if let engine {
            self.engineFactory = { _, _ in engine }
        } else {
            self.engineFactory = FileHealthScanCoordinator.defaultEngine
        }
    }

    public var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            Group {
                switch state.phase {
                case .idle:
                    FileHealthIdleView(onScan: startScan)
                case .scanning:
                    FileHealthScanningView(
                        progress: state.scanProgress,
                        scanRootCount: resolvedScanRoots().count
                    )
                case .cleaning:
                    cleanupProgressView
                case .summary:
                    summaryState()
                case .results:
                    FileHealthView(
                        results: state.scanResults,
                        warnings: state.scanWarnings,
                        session: state.session,
                        onExplain: onExplain,
                        onBack: { state.clearResults() },
                        onRescan: startScan,
                        onSendToTrash: { state.showConfirmation = true },
                        onSuggestClusters: onSuggestClusters
                    )
                case .error:
                    FileHealthErrorView(
                        message: state.errorMessage ?? "Unknown scan error",
                        onRetry: startScan
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if state.showConfirmation {
                let selected = FileHealthCleanupFlow.selectedResults(
                    from: state.scanResults,
                    selectedIDs: state.session.selectedResultIDs
                )
                ConfirmationModalView(
                    items: selected,
                    allowsPermanentDelete: false,
                    onConfirm: { method in confirmCleanup(selected, method: method) },
                    onCancel: { state.showConfirmation = false }
                )
                .transition(.opacity)
            }
        }
        .onDisappear(perform: cancelActiveScan)
        .animation(.easeOut(duration: 0.15), value: state.showConfirmation)
    }

    // MARK: - Scan wiring

    func startScan() {
        scanCoordinator.startScan(
            state: state,
            scanRoots: scanRoots,
            profile: profile,
            engineFactory: engineFactory
        )
    }

    private func cancelActiveScan() {
        scanCoordinator.cancelActiveScan(state: state)
    }

    func resolvedScanRoots() -> [URL] {
        FileHealthScanCoordinator.resolvedScanRoots(scanRoots)
    }
}
