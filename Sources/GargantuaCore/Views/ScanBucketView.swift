import SwiftUI

// MARK: - Scan Bucket List View

/// Scan results list with switchable grouping (safety / folder / category).
///
/// Safety mode keeps the existing three-bucket UX with pre-selection of safe
/// items. Folder and category modes produce groups sorted by total reclaimable
/// bytes so the biggest piles float to the top. Protected items are always
/// rendered locked regardless of grouping.
///
/// Keyboard shortcuts:
/// - Up/Down arrows: navigate between items
/// - Space: toggle selection of focused item
/// - Cmd+A: select all safe items
/// - Enter: trigger clean flow
/// - Tab: jump to next group
/// - Escape: clear focus
public struct ScanBucketListView: View {
    public let results: [ScanResult]
    public let scanDuration: TimeInterval
    @Binding public var selectedIDs: Set<String>
    /// id → reason for items that are view-only (protected roots, non-allowlisted
    /// system paths). These render locked and cannot be selected, the same way
    /// `protected` safety items do. Empty for surfaces without removability gating.
    public let viewOnlyReasons: [String: String]
    /// id → the running app blocking that item (a browser holding its cache, …).
    /// These render locked with a "Quit <app>" affordance; quitting unblocks them.
    public let blockedApps: [String: BlockedApp]
    /// Invoked with a result id when the user taps "Quit <app>".
    public let onQuitBlockingApp: ((String) -> Void)?
    public let onExplain: ((ScanResult) -> Void)?
    public let onClean: (() -> Void)?
    /// Runs a fresh scan (⌘R). Leaving the results is the header's Back
    /// button; Esc and ⌘. never discard them.
    public let onRescan: (() -> Void)?
    public let onAddToExclusions: ((ScanResult) -> Void)?
    public let onViewRule: ((ScanResult) -> Void)?
    public let onAdvisoryForReview: (([ScanResult]) -> Void)?
    public let onResolveNaturalLanguageFilter: ((String) async -> ScanFilterSet?)?

    @State var groupingMode: ScanGroupingMode
    @State var expandedGroupIDs: Set<String>
    @State var focusedItemID: String?
    @State var naturalLanguageQuery: String = ""
    @State var activeFilter: ScanFilterSet?
    @State var filterStatus: String?
    @State var isResolvingFilter = false
    @State var showsRefineControls = false
    @State var showsHelpLegend = false
    /// Selected items the current filter hides. Only visible items can be
    /// cleaned while filtering; these come back when the filter changes or
    /// clears.
    @State var selectionHiddenByFilter: Set<String> = []
    /// Memoizes the expensive grouping/sort so unrelated body re-evals (a
    /// checkbox toggle, a focus move) on a large result set don't re-group.
    @State private var groupMemo = ScanGroupMemo()
    @FocusState var isSearchFocused: Bool

    public init(
        results: [ScanResult],
        scanDuration: TimeInterval,
        selectedIDs: Binding<Set<String>>,
        initialGroupingMode: ScanGroupingMode = .safety,
        viewOnlyReasons: [String: String] = [:],
        blockedApps: [String: BlockedApp] = [:],
        onQuitBlockingApp: ((String) -> Void)? = nil,
        onExplain: ((ScanResult) -> Void)? = nil,
        onClean: (() -> Void)? = nil,
        onRescan: (() -> Void)? = nil,
        onAddToExclusions: ((ScanResult) -> Void)? = nil,
        onViewRule: ((ScanResult) -> Void)? = nil,
        onAdvisoryForReview: (([ScanResult]) -> Void)? = nil,
        onResolveNaturalLanguageFilter: ((String) async -> ScanFilterSet?)? = nil
    ) {
        self.results = results
        self.scanDuration = scanDuration
        self._selectedIDs = selectedIDs
        self.viewOnlyReasons = viewOnlyReasons
        self.blockedApps = blockedApps
        self.onQuitBlockingApp = onQuitBlockingApp
        self.onExplain = onExplain
        self.onClean = onClean
        self.onRescan = onRescan
        self.onAddToExclusions = onAddToExclusions
        self.onViewRule = onViewRule
        self.onAdvisoryForReview = onAdvisoryForReview
        self.onResolveNaturalLanguageFilter = onResolveNaturalLanguageFilter
        self._groupingMode = State(initialValue: initialGroupingMode)
        // Start with every group expanded so the list doesn't flash collapsed
        // on mount.
        let initialGroups = ScanGrouper.group(results, mode: initialGroupingMode)
        self._expandedGroupIDs = State(initialValue: Set(initialGroups.map(\.id)))
    }

    var displayedResults: [ScanResult] {
        activeFilter?.apply(to: results) ?? results
    }

    var groups: [ScanGroup] {
        groupMemo.groups(results: results, mode: groupingMode, filter: activeFilter)
    }

    /// Nested results (a folder and something inside it) count once.
    var reclaimableBytes: Int64 {
        distinctBytes(displayedResults.filter { selectedIDs.contains($0.id) })
    }

    func distinctBytes(_ subset: [ScanResult]) -> Int64 {
        ScanResultOverlapReconciler.distinctBytes(subset, containers: groupMemo.containers(results: results))
    }

    private var hasReviewItems: Bool {
        displayedResults.contains(where: { $0.safety == .review })
    }

    private var reviewItemCount: Int {
        displayedResults.filter { $0.safety == .review }.count
    }

    private var reviewReclaimableBytes: Int64 {
        distinctBytes(displayedResults.filter { $0.safety == .review })
    }

    var hasRefinementTools: Bool {
        onResolveNaturalLanguageFilter != nil
    }

    private var shouldShowRefineDetails: Bool {
        hasRefinementTools && (
            showsRefineControls ||
                activeFilter != nil ||
                filterStatus != nil ||
                !naturalLanguageQuery.isEmpty
        )
    }

    /// Flat list of all visible item IDs, respecting expanded/collapsed groups.
    var navigableItemIDs: [String] {
        groups.flatMap { group in
            expandedGroupIDs.contains(group.id) ? group.items.map(\.id) : []
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            controlsRow

            if showsHelpLegend {
                Rectangle()
                    .fill(GargantuaColors.borderSoft)
                    .frame(height: 1)
                helpLegendPanel
            }

            if hasRefinementTools && shouldShowRefineDetails {
                Rectangle()
                    .fill(GargantuaColors.borderSoft)
                    .frame(height: 1)
                refineFieldPanel
            }

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if groups.isEmpty {
                            ScanBucketEmptyView(isFiltered: activeFilter != nil)
                        } else {
                            ForEach(groups) { group in
                                groupSection(group)
                            }
                        }
                    }
                }
                .focusable(!groups.isEmpty)
                .onKeyPress(.upArrow) { moveFocus(direction: -1); return .handled }
                .onKeyPress(.downArrow) { moveFocus(direction: 1); return .handled }
                .onKeyPress(.space) { toggleFocusedSelection(); return .handled }
                .onKeyPress(.escape) { handleEscape(); return .handled }
                .onChange(of: focusedItemID) { _, newID in
                    if let newID {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            actionBar
        }
        .onChange(of: activeFilter) { _, _ in
            reconcileSelectionWithFilter()
            expandedGroupIDs = Set(groups.map(\.id))
            focusedItemID = nil
        }
        .focusedSceneValue(\.resultsActions, keyboardActions)
    }

    var formattedScanDuration: String {
        if scanDuration < 1 {
            return String(format: "%.0f ms", scanDuration * 1000)
        } else if scanDuration < 60 {
            return String(format: "%.1f s", scanDuration)
        } else {
            let minutes = Int(scanDuration) / 60
            let seconds = Int(scanDuration) % 60
            return "\(minutes)m \(seconds)s"
        }
    }
}

/// Memoizes `ScanGrouper.group` (a `Dictionary(grouping:)` + per-group sort +
/// O(n log n) top-level sort) for `ScanBucketListView`. `results` is immutable
/// for the view's lifetime, so the grouping depends only on the grouping mode
/// and the active filter — a per-keystroke selection toggle re-runs `body` but
/// hits the cache instead of re-grouping a multi-thousand-item result set.
@MainActor
final class ScanGroupMemo {
    private struct Key: Equatable {
        let mode: ScanGroupingMode
        let filter: ScanFilterSet?
        let resultCount: Int
    }

    private var key: Key?
    private var cached: [ScanGroup] = []
    private var containersKey: Int?
    private var cachedContainers: [String: [String]] = [:]

    func containers(results: [ScanResult]) -> [String: [String]] {
        if containersKey == results.count { return cachedContainers }
        cachedContainers = ScanResultOverlapReconciler.containers(in: results)
        containersKey = results.count
        return cachedContainers
    }

    func groups(results: [ScanResult], mode: ScanGroupingMode, filter: ScanFilterSet?) -> [ScanGroup] {
        let key = Key(mode: mode, filter: filter, resultCount: results.count)
        if key == self.key { return cached }
        let displayed = filter?.apply(to: results) ?? results
        cached = ScanGrouper.group(displayed, mode: mode)
        self.key = key
        return cached
    }
}
