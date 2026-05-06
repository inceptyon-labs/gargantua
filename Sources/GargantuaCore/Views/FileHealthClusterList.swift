import Foundation
import SwiftUI

struct FileHealthClusterList: View {
    let tab: FileHealthCategoryTab
    @Binding var filterText: String
    let session: FileHealthSessionState
    let onExplain: ((ScanResult) -> Void)?
    @Binding var clusterSuggestions: [String: [String: FileHealthClusterSuggestion]]
    @Binding var suggestingTabIDs: Set<String>
    @Binding var attemptedSuggestionTabIDs: Set<String>
    let onSuggestClusters: FileHealthView.ClusterSuggestionHandler?

    var body: some View {
        let filtered = filteredFindings

        VStack(alignment: .leading, spacing: 0) {
            tabHeader(filteredFindings: filtered)

            Rectangle()
                .fill(GargantuaColors.borderSoft)
                .frame(height: 1)

            FileHealthSimilarityControls(
                tab: tab,
                filteredCount: filtered.count,
                filterText: $filterText,
                clusterSuggestions: $clusterSuggestions,
                suggestingTabIDs: $suggestingTabIDs,
                attemptedSuggestionTabIDs: $attemptedSuggestionTabIDs,
                onSuggestClusters: onSuggestClusters
            )

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
            filterText = ""
        }
    }

    private var filteredFindings: [ScanResult] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return tab.findings }
        let expanded = FileHealthView.expandHomePrefix(needle)
        return tab.findings.filter { $0.path.localizedCaseInsensitiveContains(expanded) }
    }

    private func tabHeader(filteredFindings: [ScanResult]) -> some View {
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
}
