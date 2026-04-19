import SwiftUI

// MARK: - Duplicate Group Header

/// Collapsible header row for a `DuplicateGroup` in `DuplicateFinderView`.
///
/// Shows the short hash, file count, and "selected / ceiling" reclaimable
/// byte summary. Includes a tri-state checkbox that matches
/// `ScanGroupHeader`'s affordance and a "Keep one" quick action that
/// selects every file except the first (path-ascending).
struct DuplicateGroupHeader: View {
    let group: DuplicateGroup
    let isExpanded: Bool
    let selectionState: GroupSelectionState
    let reclaimableBytes: Int64
    let onToggle: () -> Void
    let onToggleSelection: () -> Void
    let onSelectAllButFirst: () -> Void

    var body: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Button(action: onToggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GargantuaColors.ink3)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            checkbox

            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 11))
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 12)

            Button(action: onToggle) {
                HStack(spacing: GargantuaSpacing.space2) {
                    Text(hashLabel)
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink)
                        .lineLimit(1)

                    Text("·")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink3)

                    Text("\(group.fileCount) files")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink2)

                    Text("·")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink3)

                    Text(bytesLabel)
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button("Keep one", action: onSelectAllButFirst)
                .font(GargantuaFonts.caption)
                .buttonStyle(.plain)
                .foregroundStyle(GargantuaColors.accent)
                .help("Select every file except the first — preserves one copy.")
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space4)
        .background(GargantuaColors.surface1)
    }

    private var hashLabel: String {
        group.shortHash.isEmpty ? group.id : "#\(group.shortHash)"
    }

    private var bytesLabel: String {
        if reclaimableBytes > 0 {
            return "\(AlertItem.formatBytes(reclaimableBytes)) / \(AlertItem.formatBytes(group.reclaimableCeilingBytes)) reclaimable"
        }
        return "\(AlertItem.formatBytes(group.reclaimableCeilingBytes)) reclaimable"
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
