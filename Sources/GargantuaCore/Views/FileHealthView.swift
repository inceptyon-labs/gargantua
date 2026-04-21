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
    public let results: [ScanResult]
    public let warnings: [String]
    public let session: FileHealthSessionState
    public let onExplain: ((ScanResult) -> Void)?
    public let onRescan: (() -> Void)?
    public let onSendToTrash: (() -> Void)?

    @State private var selectedTabID: String?

    public init(
        results: [ScanResult],
        warnings: [String] = [],
        session: FileHealthSessionState? = nil,
        onExplain: ((ScanResult) -> Void)? = nil,
        onRescan: (() -> Void)? = nil,
        onSendToTrash: (() -> Void)? = nil
    ) {
        self.results = results
        self.warnings = warnings
        self.session = session ?? FileHealthSessionState()
        self.onExplain = onExplain
        self.onRescan = onRescan
        self.onSendToTrash = onSendToTrash
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

            if let onSendToTrash, !selectedResults.isEmpty {
                Button(action: onSendToTrash) {
                    HStack(spacing: GargantuaSpacing.space1) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Send to Trash")
                        Text("\(selectedResults.count) · \(AlertItem.formatBytes(selectedBytes))")
                            .foregroundStyle(GargantuaColors.ink.opacity(0.75))
                    }
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, GargantuaSpacing.space3)
                        .padding(.vertical, GargantuaSpacing.space1)
                        .background(
                            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                .fill(GargantuaColors.accent)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send selected File Health items to Trash")
            }

            if let onRescan {
                Button(action: onRescan) {
                    Label("Rescan", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink2)
                        .padding(.horizontal, GargantuaSpacing.space3)
                        .padding(.vertical, GargantuaSpacing.space1)
                        .background(
                            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                .fill(GargantuaColors.surface3)
                        )
                }
                .buttonStyle(.plain)
            }
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
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: GargantuaSpacing.space1) {
                ForEach(tabs) { tab in
                    FileHealthTabChip(
                        tab: tab,
                        isSelected: tab.id == activeID,
                        selectedCount: tab.selectedCount(in: selection),
                        selectedBytes: tab.selectedBytes(in: selection),
                        onSelect: { selectedTabID = tab.id }
                    )
                }
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space2)
        }
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

    @ViewBuilder
    private func findingsList(for tab: FileHealthCategoryTab) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            tabHeader(tab)

            Rectangle()
                .fill(GargantuaColors.borderSoft)
                .frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tab.findings) { finding in
                        FileHealthFindingRow(
                            result: finding,
                            isSelected: session.isSelected(finding.id),
                            onToggleSelection: { session.toggleSelection(for: finding.id) },
                            onExplain: onExplain
                        )

                        Rectangle()
                            .fill(GargantuaColors.borderSoft)
                            .frame(height: 1)
                    }
                }
            }
        }
    }

    private func tabHeader(_ tab: FileHealthCategoryTab) -> some View {
        let selectedCount = tab.selectedCount(in: session.selectedResultIDs)
        let selectedBytes = tab.selectedBytes(in: session.selectedResultIDs)
        return HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: tab.iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tab.safety.tintColor)
                .frame(width: 20)

            Text(tab.label)
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            Text("\(selectedCount) of \(tab.count) selected")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)

            Spacer()

            if selectedBytes > 0 {
                Text(AlertItem.formatBytes(selectedBytes) + " reclaimable")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(tab.safety.tintColor)
            } else if tab.totalSize > 0 {
                Text(AlertItem.formatBytes(tab.totalSize) + " flagged")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface2)
    }
}

// MARK: - Tab Chip

private struct FileHealthTabChip: View {
    let tab: FileHealthCategoryTab
    let isSelected: Bool
    let selectedCount: Int
    let selectedBytes: Int64
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

                selectionBadge
            }
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .fill(isSelected ? GargantuaColors.surface3 : Color.clear)
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSelected ? tab.safety.tintColor : .clear)
                    .frame(height: 2)
                    .padding(.horizontal, GargantuaSpacing.space2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var selectionBadge: some View {
        // Badge reads "selected / total" plus selected bytes, so switching
        // tabs never hides a partial selection the user made elsewhere.
        if selectedCount > 0 {
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(selectedCount)/\(tab.count)")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)

                Text(AlertItem.formatBytes(selectedBytes))
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(tab.safety.tintColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, GargantuaSpacing.space1)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .fill(tab.safety.tintBackground)
            )
        } else {
            Text("\(tab.count)")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .padding(.horizontal, GargantuaSpacing.space1)
                .background(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                        .fill(tab.safety.tintBackground)
                )
        }
    }
}
