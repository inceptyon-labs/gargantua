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
///
/// Destructive operations (trash) are still routed through the caller-provided
/// `onSendToTrash` closure so the Trust Layer boundary stays above this view.
public struct DuplicateFinderContainerView: View {
    public let scanRoots: [URL]?
    @Bindable public var state: DuplicateFinderContainerState
    @Binding public var selectedIDs: Set<String>
    public let engineFactory: (_ scanRoots: [URL]) throws -> any ScanAdapter
    public let onSendToTrash: (([ScanResult]) -> Void)?
    public let onExplain: ((ScanResult) -> Void)?
    public let persistence: PersistenceController?

    public init(
        state: DuplicateFinderContainerState,
        scanRoots: [URL]? = nil,
        selectedIDs: Binding<Set<String>>,
        engine: (any ScanAdapter)? = nil,
        onSendToTrash: (([ScanResult]) -> Void)? = nil,
        onExplain: ((ScanResult) -> Void)? = nil,
        persistence: PersistenceController? = nil
    ) {
        self.state = state
        self.scanRoots = scanRoots
        self._selectedIDs = selectedIDs
        self.onSendToTrash = onSendToTrash
        self.onExplain = onExplain
        self.persistence = persistence
        if let engine {
            self.engineFactory = { _ in engine }
        } else {
            self.engineFactory = Self.defaultEngine
        }
    }

    public var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            Group {
                switch state.scanState {
                case .idle:
                    idleView
                case .scanning:
                    scanningView
                case .results(let results):
                    DuplicateFinderView(
                        results: results,
                        selectedIDs: $selectedIDs,
                        onSendToTrash: onSendToTrash,
                        onExplain: onExplain,
                        onBack: { state.returnToIdle() },
                        onRefresh: refreshResults,
                        onRescan: startScan,
                        persistence: persistence
                    )
                case .error(let message):
                    errorView(message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
