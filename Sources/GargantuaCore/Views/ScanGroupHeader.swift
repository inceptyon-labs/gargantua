import SwiftUI

// MARK: - Group Header

/// Collapsible header for a `ScanGroup`. Icon and any subtitle are driven by
/// `group.kind`, so safety-mode groups get a colored dot while folder/category
/// modes get an SF Symbol. A tri-state checkbox on the left bulk-selects the
/// group's selectable items (or shows a lock for all-protected groups).
struct ScanGroupHeader: View {
    let group: ScanGroup
    let isExpanded: Bool
    let selectionState: GroupSelectionState
    let onToggle: () -> Void
    let onToggleSelection: () -> Void

    var body: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Button(action: onToggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GargantuaColors.ink3)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            groupCheckbox

            leadingIcon

            Button(action: onToggle) {
                HStack(spacing: GargantuaSpacing.space2) {
                    Text(group.title)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .lineLimit(1)

                    if let subtitle = group.subtitle {
                        Text(subtitle)
                            .font(GargantuaFonts.monoPath)
                            .foregroundStyle(GargantuaColors.ink3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Text("·")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink3)

                    Text("\(group.count) items")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink2)

                    Text("·")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink3)

                    Text(AlertItem.formatBytes(group.totalSize))
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space4)
        .background(GargantuaColors.surface1)
    }

    @ViewBuilder
    private var groupCheckbox: some View {
        switch selectionState {
        case .allProtected:
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(GargantuaColors.ink4)
                .frame(width: 24, height: 24)
        case .none, .partial, .all:
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        selectionState == .none
                            ? Color.clear
                            : GargantuaColors.accent
                    )
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

    @ViewBuilder
    private var leadingIcon: some View {
        switch group.kind {
        case .safety(let level):
            Circle()
                .fill(safetyColor(level))
                .frame(width: 8, height: 8)
        case .folder:
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 12)
        case .category:
            Image(systemName: "tag.fill")
                .font(.system(size: 10))
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 12)
        }
    }

    private func safetyColor(_ level: SafetyLevel) -> Color {
        switch level {
        case .safe:       return GargantuaColors.safe
        case .review:     return GargantuaColors.review
        case .protected_: return GargantuaColors.protected_
        }
    }
}

// MARK: - Grouping Mode Picker

/// Custom segmented picker — macOS's built-in `.segmented` `Picker` dims the
/// inactive segments so hard they were nearly invisible in this UI's palette.
struct ScanGroupingPicker: View {
    @Binding var mode: ScanGroupingMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ScanGroupingMode.allCases) { candidate in
                Button {
                    mode = candidate
                } label: {
                    Text(candidate.label)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(
                            mode == candidate
                                ? GargantuaColors.ink
                                : GargantuaColors.ink2
                        )
                        .padding(.horizontal, GargantuaSpacing.space3)
                        .padding(.vertical, GargantuaSpacing.space1)
                        .frame(maxWidth: .infinity)
                        .background(
                            mode == candidate
                                ? GargantuaColors.surface3
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(GargantuaColors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        .frame(maxWidth: 280)
    }
}
