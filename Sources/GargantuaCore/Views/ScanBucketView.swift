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

    @State private var groupingMode: ScanGroupingMode = .safety
    @State private var expandedGroupIDs: Set<String>
    @State private var focusedItemID: String?
    @State private var naturalLanguageQuery: String = ""
    @State private var activeFilter: ScanFilterSet?
    @State private var filterStatus: String?
    @State private var isResolvingFilter = false
    @State private var showsRefineControls = false
    @State private var showsHelpLegend = false
    @FocusState private var isSearchFocused: Bool

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

    private var displayedResults: [ScanResult] {
        activeFilter?.apply(to: results) ?? results
    }

    private var groups: [ScanGroup] {
        ScanGrouper.group(displayedResults, mode: groupingMode)
    }

    private var reclaimableBytes: Int64 {
        displayedResults.filter { selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    private var hasReviewItems: Bool {
        displayedResults.contains(where: { $0.safety == .review })
    }

    private var reviewItemCount: Int {
        displayedResults.filter { $0.safety == .review }.count
    }

    private var reviewReclaimableBytes: Int64 {
        displayedResults
            .filter { $0.safety == .review }
            .reduce(0) { $0 + $1.size }
    }

    private var hasRefinementTools: Bool {
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
    private var navigableItemIDs: [String] {
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

    private var filterField: some View {
        HStack(spacing: GargantuaSpacing.space1) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(GargantuaColors.ink4)

            ZStack(alignment: .leading) {
                if naturalLanguageQuery.isEmpty {
                    Text("Search results")
                        .font(GargantuaFonts.body)
                        .foregroundStyle(GargantuaColors.ink2)
                        .allowsHitTesting(false)
                }

                TextField("", text: $naturalLanguageQuery)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .focused($isSearchFocused)
                    .onSubmit(resolveNaturalLanguageFilter)
                    .accessibilityLabel("Search results")
            }
            .frame(minWidth: 260, maxWidth: 460, minHeight: 24)

            if isResolvingFilter {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 16, height: 16)
            } else {
                Button(action: resolveNaturalLanguageFilter) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(GargantuaColors.accent)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .disabled(naturalLanguageQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(naturalLanguageQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                .help("Resolve search")
            }

            if activeFilter != nil || !naturalLanguageQuery.isEmpty || filterStatus != nil {
                Button(action: clearNaturalLanguageFilter) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(GargantuaColors.ink4)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, GargantuaSpacing.space2)
        .padding(.vertical, GargantuaSpacing.space1)
        .background(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .fill(isSearchFocused ? GargantuaColors.surface4 : GargantuaColors.surface3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(isSearchFocused ? GargantuaColors.borderFocus : GargantuaColors.borderEm, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            NSApp.activate(ignoringOtherApps: true)
            isSearchFocused = true
        }
    }

    /// Single condensed row replacing the previous summary bar + RESULTS card +
    /// REVIEW REQUIRED panel + Refine disclosure stack. Counts and the grouping
    /// picker stay visible at all times; the safety legend, refine field, and
    /// per-bucket "AI Review" chip live behind progressive disclosure so the
    /// list starts as close to the top as possible.
    private var controlsRow: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Text("RESULTS")
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink4)

            Text(controlsSummary)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink2)
                .lineLimit(1)

            Spacer(minLength: GargantuaSpacing.space3)

            ScanGroupingPicker(mode: $groupingMode)
                .onChange(of: groupingMode) { _, _ in
                    expandedGroupIDs = Set(groups.map(\.id))
                    focusedItemID = nil
                }

            if hasRefinementTools {
                controlIconButton(
                    systemImage: "line.3.horizontal.decrease.circle",
                    isActive: activeFilter != nil || showsRefineControls,
                    accessibility: "Refine results",
                    help: activeFilter != nil ? "Filter active — tap to edit or clear" : "Search and filter results"
                ) {
                    showsRefineControls.toggle()
                }
            }

            controlIconButton(
                systemImage: "questionmark.circle",
                isActive: showsHelpLegend,
                accessibility: "Safety legend",
                help: "What do Safe, Review, and Protected mean?"
            ) {
                showsHelpLegend.toggle()
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.surface2)
    }

    /// Compact summary in the controls row. When selection equals total, we
    /// drop the redundant "selected" qualifier; when it differs, both numbers
    /// are shown so the user always has the scan-total context (the previous
    /// "X GB selected" alone hid whether that was X of X or X of much-more).
    private var controlsSummary: String {
        let count = displayedResults.count
        let countText = "\(count) item\(count == 1 ? "" : "s")"
        let totalBytes = displayedResults.reduce(Int64(0)) { $0 + $1.size }
        let totalText = AlertItem.formatBytes(totalBytes)
        let durationText = formattedScanDuration

        if reclaimableBytes == totalBytes {
            return "\(countText) · \(totalText) · \(durationText)"
        }
        let selectedText = AlertItem.formatBytes(reclaimableBytes)
        return "\(countText) · \(totalText) total · \(selectedText) selected · \(durationText)"
    }

    private var formattedScanDuration: String {
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

    /// Three-line legend revealing what Safe / Review / Protected actually
    /// mean. Inline panel rather than a tooltip so the explanation reads on a
    /// trackpad without a hover gesture, which `mac` users on small Macs miss.
    private var helpLegendPanel: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            legendRow(
                color: GargantuaColors.safe,
                label: "Safe",
                detail: "Pre-selected, low-risk to remove. Caches, logs, and temp files."
            )
            legendRow(
                color: GargantuaColors.review,
                label: "Review",
                detail: "Flagged for a second look. Open AI Review on the bucket to summarize before you commit."
            )
            legendRow(
                color: GargantuaColors.protected_,
                label: "Protected",
                detail: "Locked. Removing these can break apps or system state."
            )
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface1)
    }

    /// Inline filter input revealed when the user taps the refine icon. The
    /// status string surfaces NL-resolution errors and the active match count.
    private var refineFieldPanel: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            filterField
            if let filterStatus {
                filterStatusView(filterStatus)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.surface1)
    }

    private func legendRow(color: Color, label: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space2) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)
                .frame(width: 64, alignment: .leading)
            Text(detail)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func controlIconButton(
        systemImage: String,
        isActive: Bool,
        accessibility: String,
        help helpText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? GargantuaColors.accent : GargantuaColors.ink3)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small, style: .continuous)
                        .fill(isActive ? GargantuaColors.accent.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
        .help(helpText)
    }
}

// MARK: - Keyboard navigation, selection, and presentation helpers

//
// Extracted into an in-file extension so ScanBucketListView's
// primary body stays under the 350-line type_body_length threshold.

extension ScanBucketListView {

    private func filterStatusView(_ status: String) -> some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: activeFilter == nil ? "exclamationmark.triangle" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(activeFilter == nil ? GargantuaColors.review : GargantuaColors.accent)
            Text(status)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .lineLimit(1)
        }
    }

    private var actionBar: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                if selectedIDs.isEmpty {
                    Text("No items selected")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink2)
                    Text("Select safe items to build a cleanup plan.")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                } else {
                    Text("\(selectedIDs.count) items selected")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                    Text("\(AlertItem.formatBytes(reclaimableBytes)) ready for confirmation")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }

            Spacer()

            if !selectedIDs.isEmpty {
                Button {
                    selectedIDs.removeAll()
                } label: {
                    Text("Clear Selection")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink2)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(
                            RoundedRectangle(cornerRadius: GargantuaRadius.small, style: .continuous)
                                .fill(GargantuaColors.surface3)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: GargantuaRadius.small, style: .continuous)
                                .stroke(GargantuaColors.borderEm, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            Button(action: triggerClean) {
                Text("Review Cleanup")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(.white)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(
                        selectedIDs.isEmpty
                            ? GargantuaColors.accent.opacity(0.4)
                            : GargantuaColors.accent
                    )
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface1)
    }

    @ViewBuilder
    private func groupSection(_ group: ScanGroup) -> some View {
        let isExpanded = expandedGroupIDs.contains(group.id)

        ZStack(alignment: .trailing) {
            ScanGroupHeader(
                group: group,
                isExpanded: isExpanded,
                selectedIDs: selectedIDs,
                onToggle: { toggleGroup(group.id) },
                onToggleSelection: { toggleGroupSelection(group) }
            )

            if isReviewSafetyGroup(group),
               let onAdvisoryForReview,
               !group.items.isEmpty {
                reviewBucketAccessory(reviewBytes: group.totalSize) {
                    onAdvisoryForReview(displayedResults)
                }
                .padding(.trailing, GargantuaSpacing.space4)
            }
        }

        Rectangle()
            .fill(GargantuaColors.borderSoft)
            .frame(height: 1)

        if isExpanded {
            // First-occurrence dedup: track which explanations have already
            // been printed in this group and skip the prose on later rows
            // that repeat it. The path stays visible on every row so the
            // user can still see *which* npm project / cache the entry is.
            let explanationFirstSeen = firstOccurrenceIDs(in: group)
            ForEach(group.items) { item in
                itemRow(item, showExplanation: explanationFirstSeen.contains(item.id))

                Rectangle()
                    .fill(GargantuaColors.borderSoft)
                    .frame(height: 1)
            }
        }
    }

    /// IDs of items that are the first in `group` to carry their explanation
    /// string. Used to dedupe identical descriptions across many rows
    /// (e.g. "Node Modules — npm/yarn/pnpm dependencies. Restored with...").
    private func firstOccurrenceIDs(in group: ScanGroup) -> Set<String> {
        var seen = Set<String>()
        var firstIDs = Set<String>()
        for item in group.items where !item.explanation.isEmpty {
            if !seen.contains(item.explanation) {
                seen.insert(item.explanation)
                firstIDs.insert(item.id)
            }
        }
        // Always treat empty-explanation rows as "show" so a later non-empty
        // version of an empty-explanation item still surfaces its prose.
        for item in group.items where item.explanation.isEmpty {
            firstIDs.insert(item.id)
        }
        return firstIDs
    }

    private func isReviewSafetyGroup(_ group: ScanGroup) -> Bool {
        if case .safety(let level) = group.kind, level == .review { return true }
        return false
    }

    /// Compact "AI Review →" chip that floats on the trailing edge of the
    /// review-safety bucket header. Replaces the previous full-width REVIEW
    /// REQUIRED panel between the controls row and the bucket list.
    private func reviewBucketAccessory(
        reviewBytes: Int64,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 10, weight: .semibold))
                Text("AI Review")
                    .font(GargantuaFonts.caption)
                Text(AlertItem.formatBytes(reviewBytes))
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.review.opacity(0.8))
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(GargantuaColors.review)
            .padding(.horizontal, GargantuaSpacing.space2)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.18))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(GargantuaColors.review.opacity(0.32), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Open AI review for these items before confirming cleanup")
    }

    private func itemRow(_ item: ScanResult, showExplanation: Bool) -> some View {
        ScanResultRowView(
            item: item,
            isSelected: selectedIDs.contains(item.id),
            isFocused: focusedItemID == item.id,
            showExplanation: showExplanation,
            onToggleSelection: { toggleSelection(item.id) },
            onExplain: onExplain,
            onAddToExclusions: onAddToExclusions,
            onViewRule: onViewRule
        )
        .id(item.id)
    }

    // MARK: - Keyboard Actions

    fileprivate func moveFocus(direction: Int) {
        let items = navigableItemIDs
        guard !items.isEmpty else { return }

        guard let current = focusedItemID, let index = items.firstIndex(of: current) else {
            focusedItemID = direction > 0 ? items.first : items.last
            return
        }

        let newIndex = index + direction
        guard items.indices.contains(newIndex) else { return }
        focusedItemID = items[newIndex]
    }

    private func toggleFocusedSelection() {
        guard let id = focusedItemID else { return }
        let item = displayedResults.first { $0.id == id }
        guard item?.safety != .protected_ else { return }
        toggleSelection(id)
    }

    private func selectAllSafe() {
        let safeIDs = displayedResults.filter { $0.safety == .safe }.map(\.id)
        selectedIDs = Set(safeIDs)
    }

    private func triggerClean() {
        guard !selectedIDs.isEmpty else { return }
        onClean?()
    }

    private func handleEscape() {
        if focusedItemID != nil {
            focusedItemID = nil
        } else {
            onCancel?()
        }
    }

    private func jumpToNextGroup() {
        let expandedList = groups.filter { expandedGroupIDs.contains($0.id) && !$0.items.isEmpty }
        guard !expandedList.isEmpty else { return }

        if let currentID = focusedItemID {
            let currentIdx = expandedList.firstIndex { $0.items.contains { $0.id == currentID } }
            if let idx = currentIdx {
                let nextIdx = (idx + 1) % expandedList.count
                focusedItemID = expandedList[nextIdx].items.first?.id
            } else {
                focusedItemID = expandedList.first?.items.first?.id
            }
        } else {
            focusedItemID = expandedList.first?.items.first?.id
        }
    }

    private func toggleGroup(_ id: String) {
        if expandedGroupIDs.contains(id) {
            expandedGroupIDs.remove(id)
        } else {
            expandedGroupIDs.insert(id)
        }
    }

    /// Bulk-toggle selection for a group. Protected items are always skipped.
    /// Only a fully-selected group deselects on click; `.none` and `.partial`
    /// both complete to `.all`. This matches the user's mental model that the
    /// checkbox affordance is "fill the box".
    /// State is recomputed from live `selectedIDs` at call time.
    private func toggleGroupSelection(_ group: ScanGroup) {
        let ids = group.selectableIDs
        guard !ids.isEmpty else { return }
        if ids.allSatisfy(selectedIDs.contains) {
            selectedIDs.subtract(ids)
        } else {
            selectedIDs.formUnion(ids)
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func resolveNaturalLanguageFilter() {
        guard let resolver = onResolveNaturalLanguageFilter else { return }
        let query = naturalLanguageQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isResolvingFilter else { return }

        isResolvingFilter = true
        Task {
            let filter = await resolver(query)
            await MainActor.run {
                isResolvingFilter = false
                if let filter {
                    activeFilter = filter
                    let count = filter.apply(to: results).count
                    filterStatus = "\(count) match\(count == 1 ? "" : "es")"
                } else {
                    activeFilter = nil
                    filterStatus = "Didn't understand"
                }
            }
        }
    }

    private func clearNaturalLanguageFilter() {
        naturalLanguageQuery = ""
        activeFilter = nil
        filterStatus = nil
        isResolvingFilter = false
        if hasRefinementTools {
            showsRefineControls = false
        }
    }

    private func trimSelectionToDisplayedResults() {
        let visible = Set(displayedResults.map(\.id))
        selectedIDs.formIntersection(visible)
    }
}
