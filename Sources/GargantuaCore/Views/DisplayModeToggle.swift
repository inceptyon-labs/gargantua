import SwiftUI

/// Two-button toggle for treemap / list view, hand-rolled so it stays legible
/// against the dark `void_` background. The native segmented `Picker` renders
/// the unselected segment as dark-on-dark in this theme and is effectively
/// invisible, so we draw both segments explicitly with theme colors.
struct DisplayModeToggle: View {
    @Binding var selection: DiskExplorerDisplayMode

    var body: some View {
        HStack(spacing: 0) {
            segment(
                mode: .treemap,
                label: "Treemap",
                systemImage: "square.grid.2x2"
            )
            segment(
                mode: .list,
                label: "List",
                systemImage: "list.bullet"
            )
        }
        .background(GargantuaColors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .strokeBorder(GargantuaColors.border, lineWidth: 1)
        )
    }

    private func segment(mode: DiskExplorerDisplayMode, label: String, systemImage: String) -> some View {
        let isSelected = selection == mode
        return Button {
            selection = mode
        } label: {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(GargantuaFonts.label)
            }
            .foregroundStyle(isSelected ? Color.white : GargantuaColors.ink)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .frame(minWidth: 92)
            .background(isSelected ? GargantuaColors.accent : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
