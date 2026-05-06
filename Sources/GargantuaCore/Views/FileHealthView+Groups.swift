import SwiftUI

/// Findings-list rendering for ``FileHealthView``.
///
/// Lives in an extension file so the per-group section header — with three
/// bulk-selection buttons each carrying their own help text and disabled
/// rules — can grow without pushing the main `FileHealthView.swift` past its
/// SwiftLint type-body threshold.
extension FileHealthView {
    /// Flat, ungrouped row list for non-similarity categories (Empty Files,
    /// Big Files, etc.). Reused as the fall-through path for grouped
    /// categories whose findings happen to carry no group id.
    @ViewBuilder
    func flatFindingsList(_ filtered: [ScanResult]) -> some View {
        ForEach(filtered) { finding in
            FileHealthFindingRow(
                result: finding,
                groupContext: nil,
                isSelected: session.isSelected(finding.id),
                onToggleSelection: { session.toggleSelection(for: finding.id) },
                onExplain: onExplain
            )

            Rectangle()
                .fill(GargantuaColors.borderSoft)
                .frame(height: 1)
        }
    }

    /// Section-segmented row list for similarity categories (Similar Images,
    /// Similar Videos). Each czkawka cluster gets its own pinned header with
    /// bulk-selection actions scoped to that group only.
    @ViewBuilder
    func groupedFindingsList(
        for tab: FileHealthCategoryTab,
        filtered: [ScanResult]
    ) -> some View {
        let sections = tab.groupedFindings(filteredBy: filtered)
        ForEach(sections) { section in
            Section {
                ForEach(section.findings) { finding in
                    FileHealthFindingRow(
                        result: finding,
                        // Per-row group label is redundant once the section
                        // header carries the same information — pass nil to
                        // suppress the in-row "Group N · M copies" line.
                        groupContext: nil,
                        isSelected: session.isSelected(finding.id),
                        onToggleSelection: { session.toggleSelection(for: finding.id) },
                        onExplain: onExplain
                    )

                    Rectangle()
                        .fill(GargantuaColors.borderSoft)
                        .frame(height: 1)
                }
            } header: {
                groupSectionHeader(section)
            }
        }
    }

    /// Pinned header for one group section. Carries identity (Group N · M
    /// copies · total size) and three bulk-selection buttons:
    ///
    /// - **Keep largest, trash rest** — adds every member except the largest
    ///   to the selection. Disabled for single-member groups.
    /// - **Keep newest, trash rest** — adds every member except the most
    ///   recently accessed. Falls back to size-based keeper when no member
    ///   carries a `lastAccessed` timestamp so the action never silently
    ///   no-ops.
    /// - **Trash all / Deselect all** — toggles between selecting every
    ///   member (no keeper retained — the explicit opt-out) and clearing the
    ///   group's selection. Tinted as a `review`-tier action to flag the
    ///   destructive nature when no copy is being retained.
    func groupSectionHeader(
        _ section: FileHealthCategoryTab.GroupSection
    ) -> some View {
        let memberIDs = section.findings.map(\.id)
        let selectedInGroup = session.selectedResultIDs.intersection(memberIDs).count
        let allSelected = !memberIDs.isEmpty && selectedInGroup == memberIDs.count

        return HStack(spacing: GargantuaSpacing.space3) {
            groupSectionIdentity(section)
            Spacer()
            groupSectionActions(section, memberIDs: memberIDs, allSelected: allSelected)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GargantuaColors.surface2)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(GargantuaColors.borderSoft)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func groupSectionIdentity(
        _ section: FileHealthCategoryTab.GroupSection
    ) -> some View {
        Text("Group \(section.context.index)")
            .font(GargantuaFonts.label)
            .foregroundStyle(GargantuaColors.ink)

        groupSectionDot()

        Text("\(section.context.count) cop\(section.context.count == 1 ? "y" : "ies")")
            .font(GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.ink3)

        if section.totalSize > 0 {
            groupSectionDot()
            Text(AlertItem.formatBytes(section.totalSize) + " total")
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink3)
        }
    }

    @ViewBuilder
    private func groupSectionActions(
        _ section: FileHealthCategoryTab.GroupSection,
        memberIDs: [String],
        allSelected: Bool
    ) -> some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Button("Keep largest, trash rest") {
                session.selectAll(Array(FileHealthGroupActions.keepLargest(in: section.findings)))
            }
            .buttonStyle(.plain)
            .font(GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.accent)
            .disabled(section.findings.count < 2)
            .help("Select every copy except the largest in this group")

            groupSectionDot()

            Button("Keep newest, trash rest") {
                session.selectAll(Array(FileHealthGroupActions.keepNewest(in: section.findings)))
            }
            .buttonStyle(.plain)
            .font(GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.accent)
            .disabled(section.findings.count < 2)
            .help("Select every copy except the most recently accessed in this group")

            groupSectionDot()

            Button(allSelected ? "Deselect all" : "Trash all") {
                if allSelected {
                    session.deselectAll(memberIDs)
                } else {
                    session.selectAll(Array(FileHealthGroupActions.trashAll(in: section.findings)))
                }
            }
            .buttonStyle(.plain)
            .font(GargantuaFonts.caption)
            .foregroundStyle(allSelected ? GargantuaColors.ink2 : GargantuaColors.review)
            .help(
                allSelected
                    ? "Clear this group's selection"
                    : "Select every copy in this group — no keeper retained"
            )
        }
    }

    private func groupSectionDot() -> some View {
        Text("·")
            .font(GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.ink4)
    }
}
