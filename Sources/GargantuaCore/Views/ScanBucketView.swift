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

    @State private var groupingMode: ScanGroupingMode = .safety
    @State private var expandedGroupIDs: Set<String>
    @State private var focusedItemID: String?

    public init(
        results: [ScanResult],
        scanDuration: TimeInterval,
        selectedIDs: Binding<Set<String>>,
        onExplain: ((ScanResult) -> Void)? = nil,
        onClean: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onAddToWhitelist: ((ScanResult) -> Void)? = nil,
        onViewRule: ((ScanResult) -> Void)? = nil
    ) {
        self.results = results
        self.scanDuration = scanDuration
        self._selectedIDs = selectedIDs
        self.onExplain = onExplain
        self.onClean = onClean
        self.onCancel = onCancel
        self.onAddToWhitelist = onAddToWhitelist
        self.onViewRule = onViewRule
        // Start with every safety group expanded so the list doesn't flash
        // collapsed on mount.
        let initialGroups = ScanGrouper.group(results, mode: .safety)
        self._expandedGroupIDs = State(initialValue: Set(initialGroups.map(\.id)))
    }

    private var groups: [ScanGroup] {
        ScanGrouper.group(results, mode: groupingMode)
    }

    private var reclaimableBytes: Int64 {
        results.filter { selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.size }
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
                totalItems: results.count,
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
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(GargantuaColors.surface2)

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
        .onKeyPress(.upArrow) { moveFocus(direction: -1); return .handled }
        .onKeyPress(.downArrow) { moveFocus(direction: 1); return .handled }
        .onKeyPress(.space) { toggleFocusedSelection(); return .handled }
        .onKeyPress(.return) { triggerClean(); return .handled }
        .onKeyPress(.escape) { handleEscape(); return .handled }
        .onKeyPress(.tab) { jumpToNextGroup(); return .handled }
        .onKeyPress(characters: .init(charactersIn: "a")) { keyPress in
            guard keyPress.modifiers == .command else { return .ignored }
            selectAllSafe()
            return .handled
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

    @ViewBuilder
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
        let item = results.first { $0.id == id }
        guard item?.safety != .protected_ else { return }
        toggleSelection(id)
    }

    private func selectAllSafe() {
        let safeIDs = results.filter { $0.safety == .safe }.map(\.id)
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
}
