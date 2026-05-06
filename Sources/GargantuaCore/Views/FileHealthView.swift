import AppKit
import SwiftUI

// MARK: - File Health View

/// File Health review UI fed by ``CzkawkaAdapter`` output.
///
/// Renders czkawka findings as a horizontal tab strip (one tab per category
/// that produced findings) plus a scrollable item list for the selected tab.
///
/// Trust Layer visual defaults are carried through from
/// ``CzkawkaTrustDefaults`` — safe tabs use the desaturated green token and
/// review tabs use the amber token (same palette used across the rest of the
/// Trust Layer surface area).
public struct FileHealthView: View {
    public typealias ClusterSuggestionHandler = @MainActor ([FileHealthClusterSummary]) async -> [FileHealthClusterSuggestion]

    public let results: [ScanResult]
    public let warnings: [String]
    public let session: FileHealthSessionState
    public let onExplain: ((ScanResult) -> Void)?
    public let onBack: (() -> Void)?
    public let onRescan: (() -> Void)?
    public let onSendToTrash: (() -> Void)?
    public let onSuggestClusters: ClusterSuggestionHandler?

    @State private var selectedTabID: String?
    @State private var filterText: String = ""
    @State private var clusterSuggestions: [String: [String: FileHealthClusterSuggestion]] = [:]
    @State private var suggestingTabIDs: Set<String> = []
    /// Tab ids whose Suggest call has run at least once. Lets the UI tell
    /// "haven't asked yet" apart from "asked and got nothing" — the
    /// difference between an unrun action and a real "the model declined"
    /// signal.
    @State private var attemptedSuggestionTabIDs: Set<String> = []

    @Environment(\.activeAIEngineKind) private var activeAIEngineKind

    public init(
        results: [ScanResult],
        warnings: [String] = [],
        session: FileHealthSessionState? = nil,
        onExplain: ((ScanResult) -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        onRescan: (() -> Void)? = nil,
        onSendToTrash: (() -> Void)? = nil,
        onSuggestClusters: ClusterSuggestionHandler? = nil
    ) {
        self.results = results
        self.warnings = warnings
        self.session = session ?? FileHealthSessionState()
        self.onExplain = onExplain
        self.onBack = onBack
        self.onRescan = onRescan
        self.onSendToTrash = onSendToTrash
        self.onSuggestClusters = onSuggestClusters
    }

    private var tabs: [FileHealthCategoryTab] {
        FileHealthGrouper.group(results)
    }

    private var selectedTab: FileHealthCategoryTab? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first(where: { $0.id == selectedTabID }) ?? tabs.first
    }

    private var totalFindings: Int {
        tabs.reduce(0) { $0 + $1.count }
    }

    /// Sum of every flagged file's size. Called "flagged" rather than
    /// "reclaimable" because similarity groups expect the user to keep at
    /// least one member per group — the true reclaim ceiling is lower.
    private var totalFlaggedBytes: Int64 {
        tabs.reduce(Int64(0)) { sum, tab in
            let (next, overflow) = sum.addingReportingOverflow(tab.totalSize)
            return overflow ? Int64.max : next
        }
    }

    private var selectedResults: [ScanResult] {
        FileHealthCleanupFlow.selectedResults(
            from: results,
            selectedIDs: session.selectedResultIDs
        )
    }

    private var selectedBytes: Int64 {
        selectedResults.reduce(Int64(0)) { sum, result in
            let (next, overflow) = sum.addingReportingOverflow(result.size)
            return overflow ? Int64.max : next
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScanResultsHeader(
                title: "File Health",
                onBack: onBack,
                onRescan: onRescan
            )

            summaryBar

            if !warnings.isEmpty {
                partialFailureBanner
            }

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            if tabs.isEmpty {
                emptyState
            } else {
                tabStrip

                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)

                if let tab = selectedTab {
                    findingsList(for: tab)
                }

                if onSendToTrash != nil {
                    bottomActionBar
                }
            }
        }
    }

    // MARK: - Partial Failure Banner

    private var partialFailureBanner: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(GargantuaColors.review)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text("Scan completed with warnings")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Text(warnings.joined(separator: "\n"))
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.reviewDim)
    }

    // MARK: - Summary Bar

    private var summaryBar: some View {
        HStack(spacing: GargantuaSpacing.space4) {
            summaryLabel("\(tabs.count) categor\(tabs.count == 1 ? "y" : "ies")")
            summaryDot
            summaryLabel("\(totalFindings) item\(totalFindings == 1 ? "" : "s")")
            if totalFlaggedBytes > 0 {
                summaryDot
                summaryLabel(AlertItem.formatBytes(totalFlaggedBytes) + " flagged")
            }
            Spacer()
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.surface2)
    }

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            HStack(spacing: GargantuaSpacing.space3) {
                VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    if selectedResults.isEmpty {
                        Text("No items selected")
                            .font(GargantuaFonts.label)
                            .foregroundStyle(GargantuaColors.ink2)
                        Text("Pick safe items above to send them to the Trash.")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink3)
                    } else {
                        Text("\(selectedResults.count) item\(selectedResults.count == 1 ? "" : "s") selected")
                            .font(GargantuaFonts.label)
                            .foregroundStyle(GargantuaColors.ink)
                        Text("\(AlertItem.formatBytes(selectedBytes)) ready for Trash")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink3)
                    }
                }

                Spacer()

                if !selectedResults.isEmpty {
                    Button {
                        session.selectedResultIDs.removeAll()
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
                    .keyboardShortcut(.escape, modifiers: [])
                }

                if let onSendToTrash {
                    Button(action: onSendToTrash) {
                        HStack(spacing: GargantuaSpacing.space2) {
                            Image(systemName: "trash")
                                .font(.system(size: 11, weight: .semibold))
                            // Byte count lives inside the button so the action
                            // and its consequence read together at the moment
                            // of click — no triangulating across the screen.
                            if selectedResults.isEmpty {
                                Text("Send to Trash")
                                    .font(GargantuaFonts.label)
                            } else {
                                Text("Send \(selectedResults.count) item\(selectedResults.count == 1 ? "" : "s") · \(AlertItem.formatBytes(selectedBytes)) to Trash")
                                    .font(GargantuaFonts.label)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(
                            selectedResults.isEmpty
                                ? GargantuaColors.accent.opacity(0.4)
                                : GargantuaColors.accent
                        )
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedResults.isEmpty)
                    .keyboardShortcut(.delete, modifiers: .command)
                    .accessibilityLabel("Send selected File Health items to Trash")
                }
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space3)
            .background(GargantuaColors.surface1)
        }
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

    // MARK: - Tab Strip

    private var tabStrip: some View {
        // Derive the highlighted chip from `selectedTab` (which gracefully
        // falls back to tabs.first when selectedTabID points at a now-gone
        // tab), so a stale id from the previous scan can't silently leave
        // every chip visually unselected.
        let activeID = selectedTab?.id
        let selection = session.selectedResultIDs
        return FlowLayout(spacing: GargantuaSpacing.space1) {
            ForEach(tabs) { tab in
                FileHealthTabChip(
                    tab: tab,
                    isSelected: tab.id == activeID,
                    selectedCount: tab.selectedCount(in: selection),
                    onSelect: { selectedTabID = tab.id }
                )
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GargantuaColors.surface1)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 32))
                .foregroundStyle(GargantuaColors.safe)
            Text("No file-health issues found")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink2)
            Text("czkawka didn't flag anything across your scan roots.")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Findings List

    private func filteredFindings(for tab: FileHealthCategoryTab) -> [ScanResult] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return tab.findings }
        let expanded = Self.expandHomePrefix(needle)
        return tab.findings.filter { $0.path.localizedCaseInsensitiveContains(expanded) }
    }

    /// Expand a leading `~/` to the absolute home path so cluster ids — which
    /// the chip fills the filter with — can substring-match against the
    /// absolute paths czkawka returns. Pass-through for inputs without a
    /// tilde, so users typing fragments like `node_modules` still work.
    static func expandHomePrefix(_ raw: String) -> String {
        guard raw.hasPrefix("~/") else { return raw }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/" + raw.dropFirst(2)
    }

    @ViewBuilder
    private func findingsList(for tab: FileHealthCategoryTab) -> some View {
        let filtered = filteredFindings(for: tab)

        VStack(alignment: .leading, spacing: 0) {
            tabHeader(tab, filteredFindings: filtered)

            Rectangle()
                .fill(GargantuaColors.borderSoft)
                .frame(height: 1)

            filterRow(for: tab, filtered: filtered)

            Rectangle()
                .fill(GargantuaColors.borderSoft)
                .frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if tab.category.isGrouped {
                        groupedFindingsList(for: tab, filtered: filtered)
                    } else {
                        flatFindingsList(filtered)
                    }
                }
            }
        }
        .onChange(of: tab.id) { _, _ in
            // Each tab carries its own search context; scope leaks are
            // worse than typing.
            filterText = ""
        }
    }

    private func tabHeader(
        _ tab: FileHealthCategoryTab,
        filteredFindings: [ScanResult]
    ) -> some View {
        // Tab header carries category identity + per-tab bulk selection.
        // Select all / Deselect all operate on the *visible* (filtered) IDs
        // so the user can never bulk-trash items they can't see — keeps the
        // "what you see is what you trash" mental model intact even with a
        // narrowing filter applied.
        let visibleIDs = filteredFindings.map(\.id)
        let visibleCount = visibleIDs.count
        let selectedVisible = session.selectedResultIDs.intersection(visibleIDs).count
        let allVisibleSelected = !visibleIDs.isEmpty && selectedVisible == visibleCount

        return HStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: tab.iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tab.safety.tintColor)
                .frame(width: 20)

            Text(tab.label)
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            HStack(spacing: GargantuaSpacing.space2) {
                Button("Select all") { session.selectAll(visibleIDs) }
                    .buttonStyle(.plain)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(allVisibleSelected ? GargantuaColors.ink4 : GargantuaColors.accent)
                    .disabled(allVisibleSelected)

                Text("·")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink4)

                Button("Deselect all") { session.deselectAll(visibleIDs) }
                    .buttonStyle(.plain)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(selectedVisible == 0 ? GargantuaColors.ink4 : GargantuaColors.accent)
                    .disabled(selectedVisible == 0)
            }
            .padding(.leading, GargantuaSpacing.space2)

            Spacer()

            if tab.totalSize > 0 {
                Text(AlertItem.formatBytes(tab.totalSize) + " flagged")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface2)
    }

    @ViewBuilder
    private func filterRow(
        for tab: FileHealthCategoryTab,
        filtered: [ScanResult]
    ) -> some View {
        let clusters = FileHealthPathClusterer.clusters(from: tab.findings)
        let trimmedFilter = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filterIsActive = !trimmedFilter.isEmpty
        let tabSuggestions = clusterSuggestions[tab.id] ?? [:]
        let isSuggesting = suggestingTabIDs.contains(tab.id)

        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(GargantuaColors.ink3)

                TextField(
                    "Filter by path",
                    text: $filterText
                )
                .textFieldStyle(.plain)
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink)

                if filterIsActive {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(GargantuaColors.ink3)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                    .accessibilityLabel("Clear filter")
                }

                Spacer()

                if filterIsActive {
                    Text("\(filtered.count) of \(tab.count) visible")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .fill(GargantuaColors.surface3)
            )

            if !clusters.isEmpty {
                let expandedFilter = Self.expandHomePrefix(trimmedFilter)
                HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
                    FlowLayout(spacing: GargantuaSpacing.space1) {
                        ForEach(clusters) { cluster in
                            FileHealthPathClusterChip(
                                cluster: cluster,
                                suggestion: tabSuggestions[cluster.id],
                                isActive: expandedFilter == Self.expandHomePrefix(cluster.id),
                                onSelect: { filterText = cluster.id }
                            )
                        }
                    }

                    if onSuggestClusters != nil, activeAIEngineKind == .mlx {
                        suggestButton(for: tab, clusters: clusters, isSuggesting: isSuggesting)
                    }
                }
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.surface1)
    }

    @ViewBuilder
    private func suggestButton(
        for tab: FileHealthCategoryTab,
        clusters: [FileHealthPathCluster],
        isSuggesting: Bool
    ) -> some View {
        let attempted = attemptedSuggestionTabIDs.contains(tab.id)
        let suggestionCount = (clusterSuggestions[tab.id] ?? [:]).count
        let returnedNothing = attempted && suggestionCount == 0

        VStack(alignment: .trailing, spacing: 2) {
            Button {
                Task { await runClusterSuggestion(for: tab, clusters: clusters) }
            } label: {
                HStack(spacing: GargantuaSpacing.space1) {
                    if isSuggesting {
                        AccretionDiskView(activityRate: 18, size: 11)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                    }
                    Text(suggestButtonLabel(
                        isSuggesting: isSuggesting,
                        attempted: attempted,
                        hasSuggestions: suggestionCount > 0
                    ))
                    .font(GargantuaFonts.caption)
                }
                .foregroundStyle(isSuggesting ? GargantuaColors.ink3 : GargantuaColors.accent)
                .padding(.horizontal, GargantuaSpacing.space2)
                .padding(.vertical, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                        .stroke(isSuggesting ? GargantuaColors.borderSoft : GargantuaColors.accent.opacity(0.5), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSuggesting)
            .help(suggestButtonHelp(
                attempted: attempted,
                hasSuggestions: suggestionCount > 0
            ))

            if returnedNothing, !isSuggesting {
                Text("AI returned no suggestions — model may not be downloaded.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
    }

    private func suggestButtonLabel(
        isSuggesting: Bool,
        attempted: Bool,
        hasSuggestions: Bool
    ) -> String {
        if isSuggesting { return "Thinking…" }
        if hasSuggestions { return "Re-suggest" }
        if attempted { return "Try again" }
        return "Suggest"
    }

    private func suggestButtonHelp(attempted: Bool, hasSuggestions: Bool) -> String {
        if hasSuggestions {
            return "Ask the local AI engine to re-label these clusters."
        }
        if attempted {
            return "The local AI engine returned no suggestions on the last attempt. The model may not be downloaded — check Settings."
        }
        return "Ask the local AI engine to label these clusters and recommend safety per group."
    }

    @MainActor
    private func runClusterSuggestion(
        for tab: FileHealthCategoryTab,
        clusters: [FileHealthPathCluster]
    ) async {
        guard let onSuggestClusters,
              !suggestingTabIDs.contains(tab.id),
              !clusters.isEmpty
        else { return }

        let samples = FileHealthPathClusterer.samplesByCluster(
            clusters,
            findings: tab.findings
        )
        let summaries = clusters.map { cluster in
            FileHealthClusterSummary(
                id: cluster.id,
                category: tab.label,
                count: cluster.count,
                totalSize: cluster.totalSize,
                samplePaths: samples[cluster.id] ?? []
            )
        }

        suggestingTabIDs.insert(tab.id)
        defer { suggestingTabIDs.remove(tab.id) }

        let suggestions = await onSuggestClusters(summaries)
        let byID = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.clusterID, $0) })
        clusterSuggestions[tab.id] = byID
        attemptedSuggestionTabIDs.insert(tab.id)
    }
}

// MARK: - Path Cluster Chip

private struct FileHealthPathClusterChip: View {
    let cluster: FileHealthPathCluster
    let suggestion: FileHealthClusterSuggestion?
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: GargantuaSpacing.space1) {
                if let suggestion {
                    Circle()
                        .fill(suggestion.safety.tintColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }

                Text(cluster.displayLabel)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(isActive ? GargantuaColors.ink : GargantuaColors.ink2)
                    .fixedSize(horizontal: true, vertical: false)

                if let suggestion {
                    Text("·")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink4)
                    Text(suggestion.label)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Text("\(cluster.count)")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink3)
            }
            .padding(.horizontal, GargantuaSpacing.space2)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .fill(isActive ? GargantuaColors.surface3 : GargantuaColors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .stroke(isActive ? GargantuaColors.accent : GargantuaColors.borderSoft, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(accessibilityLabelText)
    }

    private var helpText: String {
        let baseSize = "\(cluster.count) items in \(cluster.id) (\(AlertItem.formatBytes(cluster.totalSize)))"
        if let suggestion, !suggestion.rationale.isEmpty {
            return "\(suggestion.label) — \(suggestion.rationale)\n\(baseSize)"
        }
        return baseSize
    }

    private var accessibilityLabelText: String {
        if let suggestion {
            return "Filter by \(cluster.displayLabel), \(cluster.count) items, AI suggests: \(suggestion.label), \(suggestion.safety.rawValue) safety."
        }
        return "Filter by \(cluster.displayLabel), \(cluster.count) items"
    }
}

// MARK: - Tab Chip

private struct FileHealthTabChip: View {
    let tab: FileHealthCategoryTab
    let isSelected: Bool
    let selectedCount: Int
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tab.safety.tintColor)

                Text(tab.label)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(isSelected ? GargantuaColors.ink : GargantuaColors.ink2)
                    .fixedSize(horizontal: true, vertical: false)

                selectionBadge
            }
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .fill(isSelected ? GargantuaColors.surface3 : Color.clear)
            )
            .overlay(alignment: .bottom) {
                // Underline carries selection state, not safety. Hawking Blue
                // is the interactive vocabulary; safety tint stays on the icon
                // and badge background.
                Rectangle()
                    .fill(isSelected ? GargantuaColors.accent : .clear)
                    .frame(height: 2)
                    .padding(.horizontal, GargantuaSpacing.space2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var selectionBadge: some View {
        // Single-line "selected/total" when partially selected, otherwise the
        // total count. Per-tab selected bytes intentionally omitted: bytes
        // already live in the tab header ("X flagged") and the bottom action
        // bar (global selection). Putting them here too made chips tall and
        // forced an unwrappable horizontal scroll.
        Text(selectedCount > 0 ? "\(selectedCount)/\(tab.count)" : "\(tab.count)")
            .font(GargantuaFonts.caption)
            .foregroundStyle(selectedCount > 0 ? GargantuaColors.ink2 : GargantuaColors.ink3)
            .padding(.horizontal, GargantuaSpacing.space1)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .fill(tab.safety.tintBackground)
            )
    }
}
