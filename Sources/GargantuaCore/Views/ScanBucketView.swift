import AppKit
import SwiftUI

// MARK: - Summary Bar

/// Top bar showing total items, reclaimable space, and scan duration.
public struct ScanSummaryBar: View {
    public let totalItems: Int
    public let reclaimableBytes: Int64
    public let scanDuration: TimeInterval

    public init(totalItems: Int, reclaimableBytes: Int64, scanDuration: TimeInterval) {
        self.totalItems = totalItems
        self.reclaimableBytes = reclaimableBytes
        self.scanDuration = scanDuration
    }

    public var body: some View {
        HStack(spacing: GargantuaSpacing.space4) {
            label("\(totalItems) items")
            separator
            label(AlertItem.formatBytes(reclaimableBytes) + " reclaimable")
            separator
            label(formattedDuration)
            Spacer()
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.surface2)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.ink2)
    }

    private var separator: some View {
        Text("·")
            .font(GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.ink3)
    }

    private var formattedDuration: String {
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
    public let onAddToWhitelist: ((ScanResult) -> Void)?
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
    @FocusState private var isSearchFocused: Bool

    public init(
        results: [ScanResult],
        scanDuration: TimeInterval,
        selectedIDs: Binding<Set<String>>,
        onExplain: ((ScanResult) -> Void)? = nil,
        onClean: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onAddToWhitelist: ((ScanResult) -> Void)? = nil,
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
        self.onAddToWhitelist = onAddToWhitelist
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

    /// Flat list of all visible item IDs, respecting expanded/collapsed groups.
    private var navigableItemIDs: [String] {
        groups.flatMap { group in
            expandedGroupIDs.contains(group.id) ? group.items.map(\.id) : []
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScanSummaryBar(
                totalItems: displayedResults.count,
                reclaimableBytes: reclaimableBytes,
                scanDuration: scanDuration
            )

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            HStack {
                ScanGroupingPicker(mode: $groupingMode)
                    .onChange(of: groupingMode) { _, _ in
                        // Expand all groups after a mode change so users see the new
                        // structure immediately rather than having to open every one.
                        expandedGroupIDs = Set(groups.map(\.id))
                        focusedItemID = nil
                    }
                Spacer()
                if let onAdvisoryForReview, displayedResults.contains(where: { $0.safety == .review }) {
                    Button { onAdvisoryForReview(displayedResults) } label: {
                        HStack(spacing: GargantuaSpacing.space1) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Review Advisories")
                                .font(GargantuaFonts.label)
                        }
                        .foregroundStyle(GargantuaColors.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Ask the AI to advise on review-tier items")
                }
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(GargantuaColors.surface2)

            if onResolveNaturalLanguageFilter != nil {
                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)

                HStack(spacing: GargantuaSpacing.space2) {
                    filterField
                    Spacer(minLength: GargantuaSpacing.space3)
                    if let filterStatus {
                        filterStatusView(filterStatus)
                    }
                }
                .padding(.horizontal, GargantuaSpacing.space4)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.surface1)
            }

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groups) { group in
                            groupSection(group)
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
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { guard !isSearchFocused else { return .ignored }; moveFocus(direction: -1); return .handled }
        .onKeyPress(.downArrow) { guard !isSearchFocused else { return .ignored }; moveFocus(direction: 1); return .handled }
        .onKeyPress(.space) { guard !isSearchFocused else { return .ignored }; toggleFocusedSelection(); return .handled }
        .onKeyPress(.return) { guard !isSearchFocused else { return .ignored }; triggerClean(); return .handled }
        .onKeyPress(.escape) { guard !isSearchFocused else { return .ignored }; handleEscape(); return .handled }
        .onKeyPress(.tab) { guard !isSearchFocused else { return .ignored }; jumpToNextGroup(); return .handled }
        .onKeyPress(characters: .init(charactersIn: "a")) { keyPress in
            guard !isSearchFocused else { return .ignored }
            guard keyPress.modifiers == .command else { return .ignored }
            selectAllSafe()
            return .handled
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

            TextField("Search results", text: $naturalLanguageQuery)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink)
                .textFieldStyle(.plain)
                .lineLimit(1)
                .focused($isSearchFocused)
                .frame(minWidth: 240, maxWidth: 420)
                .onSubmit(resolveNaturalLanguageFilter)

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
                .fill(GargantuaColors.surface3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(GargantuaColors.borderSoft, lineWidth: 1)
        )
    }

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
        HStack {
            Text("\(selectedIDs.count) selected")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)

            if !selectedIDs.isEmpty {
                Text("(\(AlertItem.formatBytes(reclaimableBytes)))")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }

            Spacer()

            Button(action: triggerClean) {
                Text("Clean Selected")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(.white)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(
                        selectedIDs.isEmpty
                            ? GargantuaColors.protected_.opacity(0.4)
                            : GargantuaColors.protected_
                    )
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
    }

    @ViewBuilder
    private func groupSection(_ group: ScanGroup) -> some View {
        let isExpanded = expandedGroupIDs.contains(group.id)

        ScanGroupHeader(
            group: group,
            isExpanded: isExpanded,
            selectedIDs: selectedIDs,
            onToggle: { toggleGroup(group.id) },
            onToggleSelection: { toggleGroupSelection(group) }
        )

        Rectangle()
            .fill(GargantuaColors.borderSoft)
            .frame(height: 1)

        if isExpanded {
            ForEach(group.items) { item in
                itemRow(item)

                Rectangle()
                    .fill(GargantuaColors.borderSoft)
                    .frame(height: 1)
            }
        }
    }

    private func itemRow(_ item: ScanResult) -> some View {
        let selected = selectedIDs.contains(item.id)
        return Group {
            if item.safety == .protected_ {
                protectedRow(item)
                    .contextMenu { scanItemContextMenu(item) }
            } else {
                // Branch on selection so SwiftUI sees two different structural
                // paths and cannot reuse a stale DenseScanItemRow whose isSelected
                // field it treated as unchanged. Forces a fresh render on flip.
                if selected {
                    DenseScanItemRow(
                        item: item,
                        isSelected: true,
                        isFocused: focusedItemID == item.id,
                        onToggleSelection: { toggleSelection(item.id) },
                        onExplain: onExplain.map { handler in { handler(item) } }
                    )
                    .contextMenu { scanItemContextMenu(item) }
                } else {
                    DenseScanItemRow(
                        item: item,
                        isSelected: false,
                        isFocused: focusedItemID == item.id,
                        onToggleSelection: { toggleSelection(item.id) },
                        onExplain: onExplain.map { handler in { handler(item) } }
                    )
                    .contextMenu { scanItemContextMenu(item) }
                }
            }
        }
        .id(item.id)
    }

    /// Protected items: shown but dimmed, locked indicator, no checkbox.
    private func protectedRow(_ item: ScanResult) -> some View {
        HStack(spacing: GargantuaSpacing.space2) {
            ConfidenceOrbit(confidence: item.confidence, safety: item.safety)

            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(GargantuaColors.ink4)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: GargantuaSpacing.space1) {
                    Text(item.name)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(1)

                    if !item.explanation.isEmpty {
                        Text(item.explanation)
                            .font(GargantuaFonts.body)
                            .foregroundStyle(GargantuaColors.ink4)
                            .lineLimit(1)
                    }
                }

                Text(item.path)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink4)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(AlertItem.formatBytes(item.size))
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink3)
                .lineLimit(1)
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space3)
        .background(GargantuaColors.protected_.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(GargantuaColors.borderFocus, lineWidth: 2)
                .padding(1)
                .opacity(focusedItemID == item.id ? 1 : 0)
        )
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func scanItemContextMenu(_ item: ScanResult) -> some View {
        Button {
            NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }

        Divider()

        Button {
            onAddToWhitelist?(item)
        } label: {
            Label("Add to Whitelist", systemImage: "shield.slash")
        }

        Button {
            onViewRule?(item)
        } label: {
            Label("View Rule", systemImage: "doc.text.magnifyingglass")
        }
    }

    // MARK: - Keyboard Actions

    private func moveFocus(direction: Int) {
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
    }

    private func trimSelectionToDisplayedResults() {
        let visible = Set(displayedResults.map(\.id))
        selectedIDs.formIntersection(visible)
    }
}
