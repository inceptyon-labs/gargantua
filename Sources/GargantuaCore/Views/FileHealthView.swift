import Foundation
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
                    FileHealthClusterList(
                        tab: tab,
                        filterText: $filterText,
                        session: session,
                        onExplain: onExplain,
                        clusterSuggestions: $clusterSuggestions,
                        suggestingTabIDs: $suggestingTabIDs,
                        attemptedSuggestionTabIDs: $attemptedSuggestionTabIDs,
                        onSuggestClusters: onSuggestClusters
                    )
                }

                if let onSendToTrash {
                    FileHealthFooter(
                        selectedResults: selectedResults,
                        selectedBytes: selectedBytes,
                        onClearSelection: { session.selectedResultIDs.removeAll() },
                        onSendToTrash: onSendToTrash
                    )
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

    /// Expand a leading `~/` to the absolute home path so cluster ids — which
    /// the chip fills the filter with — can substring-match against the
    /// absolute paths czkawka returns. Pass-through for inputs without a
    /// tilde, so users typing fragments like `node_modules` still work.
    static func expandHomePrefix(_ raw: String) -> String {
        guard raw.hasPrefix("~/") else { return raw }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/" + raw.dropFirst(2)
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
