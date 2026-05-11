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
/// - Escape: clear focus or cancel
public struct ScanBucketListView: View {
    public let results: [ScanResult]
    public let scanDuration: TimeInterval
    @Binding public var selectedIDs: Set<String>
    public let onExplain: ((ScanResult) -> Void)?
    public let onClean: (() -> Void)?
    public let onCancel: (() -> Void)?
    public let onAddToExclusions: ((ScanResult) -> Void)?
    public let onViewRule: ((ScanResult) -> Void)?
    public let onAdvisoryForReview: (([ScanResult]) -> Void)?
    public let onResolveNaturalLanguageFilter: ((String) async -> ScanFilterSet?)?

    @State var groupingMode: ScanGroupingMode = .safety
    @State var expandedGroupIDs: Set<String>
    @State var focusedItemID: String?
    @State var naturalLanguageQuery: String = ""
    @State var activeFilter: ScanFilterSet?
    @State var filterStatus: String?
    @State var isResolvingFilter = false
    @State var showsRefineControls = false
    @State var showsHelpLegend = false
    @FocusState var isSearchFocused: Bool

    public init(
        results: [ScanResult],
        scanDuration: TimeInterval,
        selectedIDs: Binding<Set<String>>,
        onExplain: ((ScanResult) -> Void)? = nil,
        onClean: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onAddToExclusions: ((ScanResult) -> Void)? = nil,
        onViewRule: ((ScanResult) -> Void)? = nil,
        onAdvisoryForReview: (([ScanResult]) -> Void)? = nil,
        onResolveNaturalLanguageFilter: ((String) async -> ScanFilterSet?)? = nil
    ) {
        self.results = results
        self.scanDuration = scanDuration
        self._selectedIDs = selectedIDs
        self.onExplain = onExplain
        self.onClean = onClean
        self.onCancel = onCancel
        self.onAddToExclusions = onAddToExclusions
        self.onViewRule = onViewRule
        self.onAdvisoryForReview = onAdvisoryForReview
        self.onResolveNaturalLanguageFilter = onResolveNaturalLanguageFilter
        // Start with every safety group expanded so the list doesn't flash
        // collapsed on mount.
        let initialGroups = ScanGrouper.group(results, mode: .safety)
        self._expandedGroupIDs = State(initialValue: Set(initialGroups.map(\.id)))
    }

    var displayedResults: [ScanResult] {
        activeFilter?.apply(to: results) ?? results
    }

    var groups: [ScanGroup] {
        ScanGrouper.group(displayedResults, mode: groupingMode)
    }

    var reclaimableBytes: Int64 {
        displayedResults.filter { selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    var hasReviewItems: Bool {
        displayedResults.contains(where: { $0.safety == .review })
    }

    var reviewItemCount: Int {
        displayedResults.filter { $0.safety == .review }.count
    }

    var reviewReclaimableBytes: Int64 {
        displayedResults
            .filter { $0.safety == .review }
            .reduce(0) { $0 + $1.size }
    }

    var hasRefinementTools: Bool {
        onResolveNaturalLanguageFilter != nil
    }

    var shouldShowRefineDetails: Bool {
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
            trimSelectionToDisplayedResults()
            expandedGroupIDs = Set(groups.map(\.id))
            focusedItemID = nil
        }
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
