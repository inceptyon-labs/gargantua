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
    public let persistence: PersistenceController?

    @State private var expandedGroupIDs: Set<String>
    @State private var derivation: DuplicateFinderDerivation
    @State private var personalRoots: [URL]
    /// When `true`, drop both the personal-scope whitelist and the
    /// managed-tree blacklist — show every byte-identical group fclones
    /// surfaced. Default off: most matches outside the personal scope are
    /// app-managed noise the user can't act on file-by-file.
    @AppStorage("duplicateFinder.showEverything") private var showEverything: Bool = false

    public init(
        results: [ScanResult],
        selectedIDs: Binding<Set<String>>,
        onSendToTrash: (([ScanResult]) -> Void)? = nil,
        onExplain: ((ScanResult) -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        onRefresh: (() -> Void)? = nil,
        onRescan: (() -> Void)? = nil,
        persistence: PersistenceController? = nil
    ) {
        self.results = results
        self._selectedIDs = selectedIDs
        self.onSendToTrash = onSendToTrash
        self.onExplain = onExplain
        self.onBack = onBack
        self.onRefresh = onRefresh
        self.onRescan = onRescan
        self.persistence = persistence

        let initialRoots = Self.loadPersonalRoots(from: persistence)
        self._personalRoots = State(initialValue: initialRoots)

        // Compute derivation once at init using whatever toggle value is
        // already persisted; .onChange refreshes it on (results, toggle,
        // roots) change. Property accesses then read State (free) instead
        // of re-running filter+group every render — the previous shape
        // did O(N) work per access × ~6 accesses per render, which
        // beachballed during scroll on large duplicate sets.
        let initialShowEverything = UserDefaults.standard.bool(forKey: "duplicateFinder.showEverything")
        let initial = DuplicateFinderDerivation.compute(
            results: results,
            showEverything: initialShowEverything,
            personalRoots: initialRoots.isEmpty ? nil : initialRoots
        )
        self._derivation = State(initialValue: initial)
        // Expand the biggest few groups by default; large duplicate sets can
        // have hundreds of groups, and keeping them all open hurts scroll
        // performance and visual parse.
        self._expandedGroupIDs = State(initialValue: Set(initial.groups.prefix(5).map(\.id)))
    }

    /// Cheap key for change detection. ScanResult isn't Equatable, so we
    /// fingerprint the array via count + endpoint ids — sufficient because
    /// fclones output is regenerated wholesale per scan, never partially
    /// mutated in place. Personal-scope roots are folded in so a settings
    /// change re-derives without a rescan.
    private var derivationKey: String {
        let rootsFingerprint = personalRoots.map(\.path).joined(separator: ":")
        return "\(results.count)|\(results.first?.id ?? "")|\(results.last?.id ?? "")|\(showEverything)|\(rootsFingerprint)"
    }

    /// Read user-configured personal-scope roots from persistence, expanding
    /// `~/x` patterns to absolute URLs. Returns `[]` when persistence is
    /// unavailable or the table is empty so the caller can fall back to
    /// `defaultPersonalRoots()`. Seeding the defaults is the Settings VM's
    /// job — Duplicate Finder shouldn't write to the store.
    @MainActor
    private static func loadPersonalRoots(from persistence: PersistenceController?) -> [URL] {
        guard let persistence else { return [] }
        do {
            let patterns = try persistence.fetchPersonalScopeRoots().map(\.pattern)
            return DuplicateFinderScopeFilter.expand(patterns: patterns)
        } catch {
            return []
        }
    }

    private var visibleResults: [ScanResult] { derivation.visibleResults }

    private var hiddenSummary: DuplicateFinderHiddenSummary { derivation.hidden }

    private var groups: [DuplicateGroup] { derivation.groups }

    private var totalReclaimableSelected: Int64 {
        DuplicateFinderSelection.totalReclaimableBytes(
            groups: groups,
            selectedIDs: selectedIDs
        )
    }

    private var totalReclaimableCeiling: Int64 { derivation.totalReclaimableCeiling }

    private var totalVisibleFileCount: Int { derivation.visibleResults.count }

    /// Selectable rows across every group, keyed by id for O(1) lookup.
    /// Protected rows never appear here, so anything pulled through this map
    /// is guaranteed to be a legitimate trash candidate regardless of what
    /// the external `selectedIDs` binding carries.
    private var selectableByID: [String: ScanResult] { derivation.selectableByID }

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
        .onChange(of: derivationKey) { _, _ in
            derivation = DuplicateFinderDerivation.compute(
                results: results,
                showEverything: showEverything,
                personalRoots: personalRoots.isEmpty ? nil : personalRoots
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .gargantuaPersonalScopeRootsChanged)) { _ in
            personalRoots = Self.loadPersonalRoots(from: persistence)
        }
    }

    // MARK: - Summary Bar

    private var summaryBar: some View {
        HStack(spacing: GargantuaSpacing.space4) {
            summaryLabel("\(groups.count) groups")
            summaryDot
            summaryLabel("\(totalVisibleFileCount) files")
            summaryDot
            summaryLabel(AlertItem.formatBytes(totalReclaimableCeiling) + " reclaimable")

            if !showEverything {
                let hidden = hiddenSummary
                if hidden.groups > 0 {
                    summaryDot
                    summaryLabel("\(hidden.groups) outside personal scope hidden")
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }

            Spacer()

            scopeToggle
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.surface2)
    }

    private var scopeToggle: some View {
        Toggle(isOn: $showEverything) {
            Text("Show all duplicates")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink2)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .help("Off (default): show only duplicates inside ~/Documents, ~/Downloads, ~/Desktop, ~/Pictures, ~/Movies, ~/Music — and hide app-managed sub-trees like ~/Documents/Adobe. On: surface every byte-identical group fclones found, including dependency trees and system caches.")
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

    @ViewBuilder
    private var emptyState: some View {
        let hidden = hiddenSummary
        let filterIsHidingEverything = !showEverything && hidden.groups > 0

        VStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "doc.on.doc")
                .font(GargantuaFonts.display)
                .foregroundStyle(GargantuaColors.ink4)

            Text(filterIsHidingEverything
                ? "No duplicates in your personal folders"
                : "No duplicate groups to review")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink2)

            if filterIsHidingEverything {
                Text("\(hidden.groups) duplicate group\(hidden.groups == 1 ? "" : "s") (\(hidden.files) file\(hidden.files == 1 ? "" : "s"), \(AlertItem.formatBytes(hidden.reclaimableBytes))) live outside ~/Documents, ~/Downloads, ~/Desktop, ~/Pictures, ~/Movies, ~/Music — or inside app-managed sub-trees like ~/Documents/Adobe. Clear dependency trees and caches via Deep Clean.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)

                Button(action: { showEverything = true }) {
                    Text("Show all duplicates")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(
                            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                .fill(GargantuaColors.surface3)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, GargantuaSpacing.space1)
            } else {
                Text("Your scan roots are clean.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
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

        // Thicker top rule on every group except the first — turns adjacent
        // groups into visibly bounded units instead of a wall of warm rows.
        if group.id != groups.first?.id {
            Rectangle()
                .fill(GargantuaColors.borderEm)
                .frame(height: 2)
        }

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
                // 16px leading indent so file rows visually nest under the
                // header — the chevron's disclosure now reads as a tree, not
                // decoration. Padding sits outside the row's tinted
                // background so a void-colored gutter forms a natural rail.
                itemRow(file, differentiator: differentiators[file.path] ?? file.name)
                    .padding(.leading, 16)

                Rectangle()
                    .fill(GargantuaColors.borderSoft)
                    .frame(height: 1)
                    .padding(.leading, 16)
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
            Text("\(selectedResults.count) selected")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)

            if !selectedResults.isEmpty {
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
                        selectedResults.isEmpty
                            ? GargantuaColors.review.opacity(0.4)
                            : GargantuaColors.review
                    )
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .disabled(selectedResults.isEmpty || onSendToTrash == nil)
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
        // Halved from 0.12 so the header's `surface1` wins the contrast
        // competition; the safety hint is still legible on the row.
        switch item.safety {
        case .safe: GargantuaColors.safe.opacity(0.06)
        case .review: GargantuaColors.review.opacity(0.06)
        case .protected_: GargantuaColors.protected_.opacity(0.06)
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

// MARK: - Memoized derivation

/// Snapshot of every value the body needs from `(results, includeManaged)`.
/// Computed once per change of those inputs and cached in `@State` so scroll
/// frames don't re-run filter + grouper. Replaces a previous shape where each
/// view-property access ran the O(N) filter pipeline.
struct DuplicateFinderDerivation {
    let visibleResults: [ScanResult]
    let groups: [DuplicateGroup]
    let hidden: DuplicateFinderHiddenSummary
    let totalReclaimableCeiling: Int64
    let selectableByID: [String: ScanResult]

    static let empty = DuplicateFinderDerivation(
        visibleResults: [],
        groups: [],
        hidden: DuplicateFinderHiddenSummary(groups: 0, files: 0, reclaimableBytes: 0),
        totalReclaimableCeiling: 0,
        selectableByID: [:]
    )

    static func compute(
        results: [ScanResult],
        showEverything: Bool,
        personalRoots configuredRoots: [URL]? = nil
    ) -> DuplicateFinderDerivation {
        let personalRoots: [URL]?
        if showEverything {
            personalRoots = nil
        } else if let configured = configuredRoots, !configured.isEmpty {
            personalRoots = configured
        } else {
            personalRoots = DuplicateFinderScopeFilter.defaultPersonalRoots()
        }
        let visible = DuplicateFinderScopeFilter.apply(
            to: results,
            personalRoots: personalRoots,
            excludeManaged: !showEverything
        )
        let groups = DuplicateGrouper.group(visible)

        // Derive hidden via id-set difference instead of re-running the filter.
        let visibleIDs = Set(visible.map(\.id))
        let hiddenResults = results.filter { !visibleIDs.contains($0.id) }
        let hiddenGroups = DuplicateGrouper.group(hiddenResults)
        let hiddenBytes = hiddenGroups.reduce(Int64(0)) { sum, group in
            let (next, overflow) = sum.addingReportingOverflow(group.reclaimableCeilingBytes)
            return overflow ? Int64.max : next
        }

        let ceiling = groups.reduce(Int64(0)) { sum, group in
            let (next, overflow) = sum.addingReportingOverflow(group.reclaimableCeilingBytes)
            return overflow ? Int64.max : next
        }

        var selectable: [String: ScanResult] = [:]
        for group in groups {
            for file in group.files where file.safety != .protected_ {
                selectable[file.id] = file
            }
        }

        return DuplicateFinderDerivation(
            visibleResults: visible,
            groups: groups,
            hidden: DuplicateFinderHiddenSummary(
                groups: hiddenGroups.count,
                files: hiddenResults.count,
                reclaimableBytes: hiddenBytes
            ),
            totalReclaimableCeiling: ceiling,
            selectableByID: selectable
        )
    }
}

struct DuplicateFinderHiddenSummary {
    let groups: Int
    let files: Int
    let reclaimableBytes: Int64
}
