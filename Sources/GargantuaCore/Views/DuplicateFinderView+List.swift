import AppKit
import SwiftUI

// MARK: - List

extension DuplicateFinderView {
    var contentList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(groups) { group in
                    groupSection(group)
                }
            }
        }
    }

    @ViewBuilder
    func groupSection(_ group: DuplicateGroup) -> some View {
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
                itemRow(file, differentiator: differentiators[file.path] ?? file.name)

                Rectangle()
                    .fill(GargantuaColors.borderSoft)
                    .frame(height: 1)
            }
        }
    }

    @ViewBuilder
    func itemRow(_ item: ScanResult, differentiator: String) -> some View {
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
    func protectedRow(_ item: ScanResult, differentiator: String) -> some View {
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
    func rowContextMenu(_ item: ScanResult) -> some View {
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
