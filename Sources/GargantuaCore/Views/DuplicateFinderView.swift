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
    public let onRefresh: (() -> Void)?
    public let onRescan: (() -> Void)?

    @State private var expandedGroupIDs: Set<String>

    public init(
        results: [ScanResult],
        selectedIDs: Binding<Set<String>>,
        onSendToTrash: (([ScanResult]) -> Void)? = nil,
        onExplain: ((ScanResult) -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        onRefresh: (() -> Void)? = nil,
        onRescan: (() -> Void)? = nil
    ) {
        self.results = results
        self._selectedIDs = selectedIDs
        self.onSendToTrash = onSendToTrash
        self.onExplain = onExplain
        self.onBack = onBack
        self.onRefresh = onRefresh
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
                onRefresh: onRefresh,
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
        let classification = DuplicateGroupClassifier.classify(group)
        let differentiators = DuplicatePathDifferentiator.compute(paths: group.files.map(\.path))

        DuplicateGroupHeader(
            group: group,
            classification: classification,
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
                itemRow(file, differentiator: differentiators[file.path] ?? file.name)

                Rectangle()
                    .fill(GargantuaColors.borderSoft)
                    .frame(height: 1)
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: ScanResult, differentiator: String) -> some View {
        let selected = selectedIDs.contains(item.id)
        // Branch on selection so SwiftUI sees two distinct structural paths
        // and cannot reuse a stale row whose isSelected it treats as
        // unchanged — same mitigation as ScanBucketView.
        Group {
            if item.safety == .protected_ {
                // Protected duplicates are read-only: shown for context but
                // never toggleable. Mirrors ScanBucketView.protectedRow.
                protectedRow(item, differentiator: differentiator)
                    .contextMenu { rowContextMenu(item) }
            } else {
                DuplicateFileRow(
                    item: item,
                    differentiator: differentiator,
                    isSelected: selected,
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
    private func protectedRow(_ item: ScanResult, differentiator: String) -> some View {
        HStack(spacing: GargantuaSpacing.space2) {
            ConfidenceOrbit(confidence: item.confidence, safety: item.safety)

            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(GargantuaColors.ink4)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(differentiator)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(item.path)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink4)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
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

// MARK: - Duplicate File Row

/// Row tuned for the duplicate finder: differentiating path slice up front,
/// original filename + tilde-collapsed full path as secondary context. We skip
/// the per-row size badge (every file in a group is identical) and the per-row
/// explanation (the group header carries one explainer for the whole pile).
private struct DuplicateFileRow: View {
    let item: ScanResult
    let differentiator: String
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onExplain: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            ConfidenceOrbit(confidence: item.confidence, safety: item.safety)

            Button(action: onToggleSelection) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(
                            isSelected ? safetyColor : GargantuaColors.borderEm,
                            lineWidth: 1.5
                        )
                        .frame(width: 16, height: 16)
                        .background(isSelected ? safetyColor : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(differentiator)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: GargantuaSpacing.space1) {
                    if differentiator != item.name {
                        Text(item.name)
                            .font(GargantuaFonts.monoPath)
                            .foregroundStyle(GargantuaColors.ink3)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text("·")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink4)
                    }

                    Text(tildeCollapsed(item.path))
                        .font(GargantuaFonts.monoPath)
                        .foregroundStyle(GargantuaColors.ink4)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if isHovered, onExplain != nil {
                Button(action: onExplain ?? {}) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(GargantuaColors.accent)
                }
                .buttonStyle(.plain)
                .help("Show explanation")
            } else if onExplain != nil {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.clear)
            }
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space3)
        .background(safetyDimColor)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleSelection)
        .onHover { isHovered = $0 }
        .help(item.path)
    }

    private var safetyColor: Color {
        switch item.safety {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }

    private var safetyDimColor: Color {
        switch item.safety {
        case .safe: GargantuaColors.safe.opacity(0.12)
        case .review: GargantuaColors.review.opacity(0.12)
        case .protected_: GargantuaColors.protected_.opacity(0.12)
        }
    }

    private func tildeCollapsed(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
