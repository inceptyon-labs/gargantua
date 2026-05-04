import SwiftUI

// MARK: - Duplicate Group Header

/// Collapsible header row for a `DuplicateGroup` in `DuplicateFinderView`.
///
/// Surfaces a deterministic, human-readable classification (icon + title +
/// crumb + plain-English explainer) instead of the raw fclones short hash. The
/// hash is preserved in the help-tooltip for power users. Tri-state checkbox
/// matches `ScanGroupHeader`'s affordance; a "Keep one" quick action selects
/// every file except the first (path-ascending).
struct DuplicateGroupHeader: View {
    let group: DuplicateGroup
    let classification: DuplicateGroupClassification
    let isExpanded: Bool
    let selectionState: GroupSelectionState
    let reclaimableBytes: Int64
    let onToggle: () -> Void
    let onToggleSelection: () -> Void
    let onSelectAllButFirst: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
            Button(action: onToggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GargantuaColors.ink3)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            checkbox

            Image(systemName: classification.icon)
                .font(.system(size: 12))
                .foregroundStyle(categoryTint)
                .frame(width: 16, height: 16)
                .padding(.top, 2)

            Button(action: onToggle) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: GargantuaSpacing.space2) {
                        Text(classification.title)
                            .font(GargantuaFonts.label)
                            .foregroundStyle(GargantuaColors.ink)
                            .lineLimit(1)

                        Text("·")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink3)

                        Text("\(group.fileCount) files")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink2)

                        Text("·")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink3)

                        Text(bytesLabel)
                            .font(GargantuaFonts.monoData)
                            .foregroundStyle(GargantuaColors.ink)

                        Spacer(minLength: 0)
                    }

                    Text(classification.explainer)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if !classification.pathCrumb.isEmpty {
                        Text(classification.pathCrumb)
                            .font(GargantuaFonts.monoPath)
                            .foregroundStyle(GargantuaColors.ink4)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hashTooltip)

            Button("Keep one", action: onSelectAllButFirst)
                .font(GargantuaFonts.caption)
                .buttonStyle(.plain)
                .foregroundStyle(GargantuaColors.accent)
                .help("Select every file except the first — preserves one copy.")
                .padding(.top, 1)
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space4)
        .background(GargantuaColors.surface1)
    }

    private var hashTooltip: String {
        let hash = group.shortHash.isEmpty ? group.id : "#\(group.shortHash)"
        return "Group \(hash) — same content across \(group.fileCount) files."
    }

    private var bytesLabel: String {
        if reclaimableBytes > 0 {
            return "\(AlertItem.formatBytes(reclaimableBytes)) / \(AlertItem.formatBytes(group.reclaimableCeilingBytes)) reclaimable"
        }
        return "\(AlertItem.formatBytes(group.reclaimableCeilingBytes)) reclaimable"
    }

    private var categoryTint: Color {
        switch classification.category {
        case .appCache, .appAutosave, .devArtifact: return GargantuaColors.safe
        case .download, .userDocument, .media: return GargantuaColors.review
        case .appSupport: return GargantuaColors.review
        case .generic: return GargantuaColors.ink3
        }
    }

    @ViewBuilder
    private var checkbox: some View {
        switch selectionState {
        case .allProtected:
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(GargantuaColors.ink4)
                .frame(width: 24, height: 24)
        case .none, .partial, .all:
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(selectionState == .none ? Color.clear : GargantuaColors.accent)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(
                                selectionState == .none
                                    ? GargantuaColors.borderEm
                                    : GargantuaColors.accent,
                                lineWidth: 1.5
                            )
                    )
                    .frame(width: 16, height: 16)

                switch selectionState {
                case .all:
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                case .partial:
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                case .none, .allProtected:
                    EmptyView()
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleSelection)
        }
    }
}
