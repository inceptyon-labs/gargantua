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
///
/// This view is intentionally read-only today: destructive actions remain
/// gated behind the Confirmation flow that Duplicate Finder also waits on.
public struct FileHealthView: View {
    public let results: [ScanResult]
    public let onExplain: ((ScanResult) -> Void)?
    public let onRescan: (() -> Void)?

    @State private var selectedTabID: String?

    public init(
        results: [ScanResult],
        onExplain: ((ScanResult) -> Void)? = nil,
        onRescan: (() -> Void)? = nil
    ) {
        self.results = results
        self.onExplain = onExplain
        self.onRescan = onRescan
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

    private var totalReclaimableBytes: Int64 {
        tabs.reduce(Int64(0)) { sum, tab in
            let (next, overflow) = sum.addingReportingOverflow(tab.totalSize)
            return overflow ? Int64.max : next
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            summaryBar

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

    // MARK: - Summary Bar

    private var summaryBar: some View {
        HStack(spacing: GargantuaSpacing.space4) {
            summaryLabel("\(tabs.count) categor\(tabs.count == 1 ? "y" : "ies")")
            summaryDot
            summaryLabel("\(totalFindings) item\(totalFindings == 1 ? "" : "s")")
            if totalReclaimableBytes > 0 {
                summaryDot
                summaryLabel(AlertItem.formatBytes(totalReclaimableBytes) + " total")
            }

            Spacer()

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
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: GargantuaSpacing.space1) {
                ForEach(tabs) { tab in
                    FileHealthTabChip(
                        tab: tab,
                        isSelected: tab.id == activeID,
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
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: tab.iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tab.safety.tintColor)
                .frame(width: 20)

            Text(tab.label)
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            Text("\(tab.count)")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)

            Spacer()

            if tab.totalSize > 0 {
                Text(AlertItem.formatBytes(tab.totalSize))
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

                Text("\(tab.count)")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .padding(.horizontal, GargantuaSpacing.space1)
                    .background(
                        RoundedRectangle(cornerRadius: GargantuaRadius.small)
                            .fill(tab.safety.tintBackground)
                    )
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
}

// MARK: - Finding Row

private struct FileHealthFindingRow: View {
    let result: ScanResult
    let onExplain: ((ScanResult) -> Void)?

    var body: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .lineLimit(1)

                Text(result.path)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !result.explanation.isEmpty {
                    Text(result.explanation)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(1)
                }
            }

            Spacer()

            if result.size > 0 {
                Text(AlertItem.formatBytes(result.size))
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .contextMenu {
            Button {
                NSWorkspace.shared.selectFile(result.path, inFileViewerRootedAtPath: "")
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.path, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }

            if let onExplain {
                Divider()
                Button {
                    onExplain(result)
                } label: {
                    Label("Explain", systemImage: "questionmark.circle")
                }
            }
        }
    }
}

// MARK: - Safety Palette

private extension SafetyLevel {
    var tintColor: Color {
        switch self {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }

    var tintBackground: Color {
        switch self {
        case .safe: GargantuaColors.safeDim
        case .review: GargantuaColors.reviewDim
        case .protected_: GargantuaColors.protectedDim
        }
    }
}
