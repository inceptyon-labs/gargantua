import SwiftUI

extension ScanBucketListView {
    @ViewBuilder
    func groupSection(_ group: ScanGroup) -> some View {
        let isExpanded = expandedGroupIDs.contains(group.id)

        ZStack(alignment: .trailing) {
            ScanGroupHeader(
                group: group,
                isExpanded: isExpanded,
                selectedIDs: selectedIDs,
                onToggle: { toggleGroup(group.id) },
                onToggleSelection: { toggleGroupSelection(group) }
            )

            if isReviewSafetyGroup(group),
               let onAdvisoryForReview,
               !group.items.isEmpty {
                reviewBucketAccessory(reviewBytes: group.totalSize) {
                    onAdvisoryForReview(displayedResults)
                }
                .padding(.trailing, GargantuaSpacing.space4)
            }
        }

        Rectangle()
            .fill(GargantuaColors.borderSoft)
            .frame(height: 1)

        if isExpanded {
            // First-occurrence dedup: track which explanations have already
            // been printed in this group and skip the prose on later rows
            // that repeat it. The path stays visible on every row so the
            // user can still see *which* npm project / cache the entry is.
            let explanationFirstSeen = firstOccurrenceIDs(in: group)
            ForEach(group.items) { item in
                itemRow(item, showExplanation: explanationFirstSeen.contains(item.id))

                Rectangle()
                    .fill(GargantuaColors.borderSoft)
                    .frame(height: 1)
            }
        }
    }

    /// IDs of items that are the first in `group` to carry their explanation
    /// string. Used to dedupe identical descriptions across many rows
    /// (e.g. "Node Modules — npm/yarn/pnpm dependencies. Restored with...").
    private func firstOccurrenceIDs(in group: ScanGroup) -> Set<String> {
        var seen = Set<String>()
        var firstIDs = Set<String>()
        for item in group.items where !item.explanation.isEmpty {
            if !seen.contains(item.explanation) {
                seen.insert(item.explanation)
                firstIDs.insert(item.id)
            }
        }
        // Always treat empty-explanation rows as "show" so a later non-empty
        // version of an empty-explanation item still surfaces its prose.
        for item in group.items where item.explanation.isEmpty {
            firstIDs.insert(item.id)
        }
        return firstIDs
    }

    private func isReviewSafetyGroup(_ group: ScanGroup) -> Bool {
        if case .safety(let level) = group.kind, level == .review { return true }
        return false
    }

    /// Compact "AI Review →" chip that floats on the trailing edge of the
    /// review-safety bucket header. Replaces the previous full-width REVIEW
    /// REQUIRED panel between the controls row and the bucket list.
    private func reviewBucketAccessory(
        reviewBytes: Int64,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 10, weight: .semibold))
                Text("AI Review")
                    .font(GargantuaFonts.caption)
                Text(AlertItem.formatBytes(reviewBytes))
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.review.opacity(0.8))
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(GargantuaColors.review)
            .padding(.horizontal, GargantuaSpacing.space2)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.18))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(GargantuaColors.review.opacity(0.32), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Open AI review for these items before confirming cleanup")
    }

    private func itemRow(_ item: ScanResult, showExplanation: Bool) -> some View {
        ScanResultRowView(
            item: item,
            isSelected: selectedIDs.contains(item.id),
            isFocused: focusedItemID == item.id,
            showExplanation: showExplanation,
            onToggleSelection: { toggleSelection(item.id) },
            onExplain: onExplain,
            onAddToExclusions: onAddToExclusions,
            onViewRule: onViewRule
        )
        .id(item.id)
    }

    func toggleGroup(_ id: String) {
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
    func toggleGroupSelection(_ group: ScanGroup) {
        let ids = group.selectableIDs
        guard !ids.isEmpty else { return }
        if ids.allSatisfy(selectedIDs.contains) {
            selectedIDs.subtract(ids)
        } else {
            selectedIDs.formUnion(ids)
        }
    }

    func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}
