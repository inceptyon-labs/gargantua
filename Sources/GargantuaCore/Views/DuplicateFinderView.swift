import AppKit
import SwiftUI

// MARK: - Duplicate Finder View

/// Duplicate-file review UI fed by `FclonesAdapter` output.
///
/// Renders fclones-tagged `ScanResult`s clustered by hash group. Each group
/// shows its short hash, file count, total reclaimable bytes (keep-one
/// assumption), and the list of duplicate paths. Users review and pick which
/// copies to trash; nothing is pre-selected (review-by-default).
///
/// The "Send to Trash" action is surfaced via the `onSendToTrash` callback —
/// this view never performs destructive file operations. Callers must route
/// the callback through the Trust Layer / `ConfirmationModalView` before any
/// real trash call.
public struct DuplicateFinderView: View {
    public let results: [ScanResult]
    @Binding public var selectedIDs: Set<String>
    public let onSendToTrash: (([ScanResult]) -> Void)?
    public let onExplain: ((ScanResult) -> Void)?
    public let onBack: (() -> Void)?
    public let onRescan: (() -> Void)?

    @State private var expandedGroupIDs: Set<String>

    public init(
        results: [ScanResult],
        selectedIDs: Binding<Set<String>>,
        onSendToTrash: (([ScanResult]) -> Void)? = nil,
        onExplain: ((ScanResult) -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        onRescan: (() -> Void)? = nil
    ) {
        self.results = results
        self._selectedIDs = selectedIDs
        self.onSendToTrash = onSendToTrash
        self.onExplain = onExplain
        self.onBack = onBack
        self.onRescan = onRescan
        // Expand the biggest few groups by default; large duplicate sets can
        // have hundreds of groups, and keeping them all open hurts scroll
        // performance and visual parse.
        let initialGroups = DuplicateGrouper.group(results)
        self._expandedGroupIDs = State(initialValue: Set(initialGroups.prefix(5).map(\.id)))
    }

    private var groups: [DuplicateGroup] {
        DuplicateGrouper.group(results)
    }

    private var totalReclaimableSelected: Int64 {
        DuplicateFinderSelection.totalReclaimableBytes(
            groups: groups,
            selectedIDs: selectedIDs
        )
    }

    private var totalReclaimableCeiling: Int64 {
        groups.reduce(Int64(0)) { sum, group in
            let (next, overflow) = sum.addingReportingOverflow(group.reclaimableCeilingBytes)
            return overflow ? Int64.max : next
        }
    }

    /// Selectable rows across every group, keyed by id for O(1) lookup.
    /// Protected rows never appear here, so anything pulled through this map
    /// is guaranteed to be a legitimate trash candidate regardless of what
    /// the external `selectedIDs` binding carries.
    private var selectableByID: [String: ScanResult] {
        var map: [String: ScanResult] = [:]
        for group in groups {
            for file in group.files where file.safety != .protected_ {
                map[file.id] = file
            }
        }
        return map
    }

    /// Sanitized handoff for `onSendToTrash` — drops any id that isn't a
    /// current, selectable, ungrouped-free row. Defends the Trust Layer
    /// boundary against stale or externally mutated `selectedIDs`.
    private var selectedResults: [ScanResult] {
        let allowed = selectableByID
        return selectedIDs.compactMap { allowed[$0] }
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScanResultsHeader(
                title: "Duplicate Finder",
                onBack: onBack,
                onRescan: onRescan
            )

            summaryBar

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            if groups.isEmpty {
                emptyState
            } else {
                contentList
            }

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            actionBar
        }
    }

    // MARK: - Summary Bar

    private var summaryBar: some View {
        HStack(spacing: GargantuaSpacing.space4) {
            summaryLabel("\(groups.count) groups")
            summaryDot
            summaryLabel("\(results.count) files")
            summaryDot
            summaryLabel(AlertItem.formatBytes(totalReclaimableCeiling) + " reclaimable")
            Spacer()
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.surface2)
    }

    private func summaryLabel(_ text: String) -> some View {
        Text(text)
            .font(GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.ink2)
    }

    private var summaryDot: some View {
        Text("·")
            .font(GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.ink3)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 32))
                .foregroundStyle(GargantuaColors.ink4)
            Text("No duplicate groups to review")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink2)
            Text("Run a duplicate scan from Deep Clean to populate this view.")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var contentList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(groups) { group in
                    groupSection(group)
                }
            }
        }
    }

    @ViewBuilder
    private func groupSection(_ group: DuplicateGroup) -> some View {
        let isExpanded = expandedGroupIDs.contains(group.id)

        DuplicateGroupHeader(
            group: group,
            isExpanded: isExpanded,
            selectionState: group.selectionState(selectedIDs: selectedIDs),
            reclaimableBytes: group.reclaimableBytes(selectedIDs: selectedIDs),
            onToggle: { toggleGroup(group.id) },
            onToggleSelection: { toggleGroupSelection(group) },
            onSelectAllButFirst: { selectAllButFirst(in: group) }
        )

        Rectangle()
            .fill(GargantuaColors.borderSoft)
            .frame(height: 1)

        if isExpanded {
            ForEach(group.files) { file in
                itemRow(file)

                Rectangle()
                    .fill(GargantuaColors.borderSoft)
                    .frame(height: 1)
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: ScanResult) -> some View {
        let selected = selectedIDs.contains(item.id)
        // Branch on selection so SwiftUI sees two distinct structural paths
        // and cannot reuse a stale row whose isSelected it treats as
        // unchanged — same mitigation as ScanBucketView.
        Group {
            if item.safety == .protected_ {
                // Protected duplicates are read-only: shown for context but
                // never toggleable. Mirrors ScanBucketView.protectedRow.
                protectedRow(item)
                    .contextMenu { rowContextMenu(item) }
            } else if selected {
                DenseScanItemRow(
                    item: item,
                    isSelected: true,
                    isFocused: false,
                    onToggleSelection: { toggleSelection(item.id) },
                    onExplain: onExplain.map { handler in { handler(item) } }
                )
                .contextMenu { rowContextMenu(item) }
            } else {
                DenseScanItemRow(
                    item: item,
                    isSelected: false,
                    isFocused: false,
                    onToggleSelection: { toggleSelection(item.id) },
                    onExplain: onExplain.map { handler in { handler(item) } }
                )
                .contextMenu { rowContextMenu(item) }
            }
        }
        .id(item.id)
    }

    /// Read-only row for `.protected_` duplicates. Shown dimmed with a lock
    /// indicator and no checkbox or tap-to-select affordance.
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
    }

    @ViewBuilder
    private func rowContextMenu(_ item: ScanResult) -> some View {
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
    }
}

// MARK: - Action Bar

extension DuplicateFinderView {
    var actionBar: some View {
        HStack {
            Text("\(selectedIDs.count) selected")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)

            if !selectedIDs.isEmpty {
                Text("(\(AlertItem.formatBytes(totalReclaimableSelected)))")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }

            Spacer()

            Button(action: triggerTrash) {
                Text("Send to Trash")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(.white)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(
                        selectedIDs.isEmpty
                            ? GargantuaColors.review.opacity(0.4)
                            : GargantuaColors.review
                    )
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .disabled(selectedIDs.isEmpty || onSendToTrash == nil)
            .help(
                onSendToTrash == nil
                    ? "Destructive actions are disabled until Trust Layer wiring is complete."
                    : "Route selected duplicates through the Trust Layer before trashing."
            )
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
    }
}

// MARK: - Actions

extension DuplicateFinderView {
    func triggerTrash() {
        guard !selectedIDs.isEmpty else { return }
        onSendToTrash?(selectedResults)
    }

    func toggleGroup(_ id: String) {
        if expandedGroupIDs.contains(id) {
            expandedGroupIDs.remove(id)
        } else {
            expandedGroupIDs.insert(id)
        }
    }

    func toggleGroupSelection(_ group: DuplicateGroup) {
        let ids = group.selectableIDs
        guard !ids.isEmpty else { return }
        if ids.allSatisfy(selectedIDs.contains) {
            selectedIDs.subtract(ids)
        } else {
            selectedIDs.formUnion(ids)
        }
    }

    func selectAllButFirst(in group: DuplicateGroup) {
        selectedIDs.subtract(group.files.map(\.id))
        selectedIDs.formUnion(DuplicateFinderSelection.selectAllButFirst(in: group))
    }

    func toggleSelection(_ id: String) {
        // Defense in depth: refuse to add ids for protected or unknown
        // (ungrouped) rows, even if something upstream attempts to feed
        // them through. Removal always succeeds so stale ids can be
        // cleaned out by unchecking.
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            return
        }
        guard selectableByID[id] != nil else { return }
        selectedIDs.insert(id)
    }
}
